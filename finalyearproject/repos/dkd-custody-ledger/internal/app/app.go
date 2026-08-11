// Package app wires custody-ledger-svc: dedicated dkd_custody Postgres (R1 isolation),
// WORM chain store, outbox relay to the spine, the government recall-directive consumer,
// and the REST /v1 command surface. /ready flips only after DB migrate + broker pings.
package app

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"net"

	"google.golang.org/grpc"
	"sync"
	"sync/atomic"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/api"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/catalogclient"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/identityclient"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/passportohs"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/passportohs/pb"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/config"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/directive"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/obs"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/outbox"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/security"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/signing"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/store"
)

type App struct {
	identity *identityclient.Client
	cfg     config.Config
	log     *slog.Logger
	metrics *obs.Metrics
	server  *httpx.Server
	store   *store.Store
	relay     *outbox.Relay
	cons      *consumer.Consumer
	grpcSrv   *grpc.Server
	traceStop func(context.Context) error
	wg        sync.WaitGroup
	ready   atomic.Bool
}

func New(cfg config.Config, log *slog.Logger) *App {
	return &App{cfg: cfg, log: log, metrics: obs.NewMetrics()}
}

func (a *App) isReady() bool { return a.ready.Load() }

func (a *App) Start(ctx context.Context) error {
	// C3-F10: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT unset).
	_, a.traceStop = obs.InitTracer(ctx, a.cfg.ServiceName, a.cfg.OtlpEndpoint)

	st, err := store.Open(ctx, a.cfg.DSN())
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	a.store = st
	if err := st.Migrate(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	cat := catalogclient.New(a.cfg.CatalogURL)
	idc, err := identityclient.New(a.cfg.IdentityGrpcURL) // C3-F5: Identity OHS KYC-tier gate (no-op if unset)
	if err != nil {
		return fmt.Errorf("identity client: %w", err)
	}
	a.identity = idc
	// Signer-key trust anchor (C3-F2c; FR-PASS-070): decode the configured CA public key. An unset
	// or malformed key yields a nil anchor, and signer-key registration then FAILS CLOSED (rejects
	// every binding) — never an open endpoint. The CA PRIVATE key is never held here.
	var trustAnchor ed25519.PublicKey
	if a.cfg.TrustAnchorPubKey != "" {
		pk, err := signing.DecodePublicKey(a.cfg.TrustAnchorPubKey)
		if err != nil {
			return fmt.Errorf("decode DKD_CUSTODY_TRUST_ANCHOR_PUBKEY: %w", err)
		}
		trustAnchor = pk
	} else {
		a.log.Warn("DKD_CUSTODY_TRUST_ANCHOR_PUBKEY unset — signer-key registration is CLOSED (fail-closed root of trust)")
	}
	// Attestation-authority key (C3-F2e; FR-PASS-014/FR-PASS-070): decode the configured authority
	// public key that authorizes single-signature, reference-linked custody moves (e.g. a logistics
	// POD). An unset/malformed key yields a nil authority, and attestation mode then FAILS CLOSED
	// (a transfer bearing an attestationSignature is rejected — never demoted to the human path).
	// The authority PRIVATE key is never held here (it lives in logistics).
	var attestationAuthority ed25519.PublicKey
	if a.cfg.AttestationAuthorityPubKey != "" {
		pk, err := signing.DecodePublicKey(a.cfg.AttestationAuthorityPubKey)
		if err != nil {
			return fmt.Errorf("decode DKD_CUSTODY_ATTESTATION_AUTHORITY_PUBKEY: %w", err)
		}
		attestationAuthority = pk
	} else {
		a.log.Warn("DKD_CUSTODY_ATTESTATION_AUTHORITY_PUBKEY unset — attestation-authority transfers are UNAVAILABLE (fail-closed; human dual-signature still required)")
	}
	apiH := api.New(st, cat, idc, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() }, trustAnchor, attestationAuthority)
	auth := security.New(a.cfg.JWTIssuer, nil)
	a.server = httpx.New(a.cfg.ServiceName, a.cfg.HTTPPort, a.cfg.MetricsPort,
		a.log, a.metrics, auth, a.isReady, apiH.Register)
	if err := a.server.Start(); err != nil {
		return fmt.Errorf("http listeners: %w", err)
	}

	// B2B-F2 / EF-API-1: expose the passport read-model over gRPC (internal OHS plane).
	lis, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", a.cfg.GrpcPort))
	if err != nil {
		return fmt.Errorf("grpc listen: %w", err)
	}
	a.grpcSrv = grpc.NewServer()
	pb.RegisterCustodyPassportOhsServer(a.grpcSrv, passportohs.New(st, store.ErrNotFound))
	go func() {
		if err := a.grpcSrv.Serve(lis); err != nil {
			a.log.Warn("grpc server stopped", "err", err.Error())
		}
	}()
	a.log.Info("custody passport gRPC OHS listening", "port", a.cfg.GrpcPort)

	relay, err := outbox.New(a.cfg.Brokers(), st, a.log, a.metrics)
	if err != nil {
		return fmt.Errorf("build outbox relay: %w", err)
	}
	a.relay = relay
	if err := relay.Ping(ctx); err != nil {
		return fmt.Errorf("kafka ping (producer): %w", err)
	}

	dir := directive.New(st, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
	cons, err := consumer.New(
		consumer.Config{Brokers: a.cfg.Brokers(), Group: a.cfg.ConsumerGroup, Topics: directive.Topics()},
		a.log, dir.Handle, dir.Park,
	)
	if err != nil {
		return fmt.Errorf("build consumer: %w", err)
	}
	a.cons = cons
	if err := cons.Ping(ctx); err != nil {
		return fmt.Errorf("kafka ping (consumer): %w", err)
	}

	a.wg.Add(2)
	go func() { defer a.wg.Done(); relay.Run(ctx) }()
	go func() { defer a.wg.Done(); cons.Run(ctx) }()
	a.ready.Store(true)
	a.log.Info("custody-ledger-svc started (R1 SOLE provenance writer)",
		"db", a.cfg.DBName, "catalog_precondition", cat.Enabled())
	return nil
}

func (a *App) Stop(ctx context.Context) error {
	a.ready.Store(false)
	if a.cons != nil {
		a.cons.Close()
	}
	if a.traceStop != nil {
		_ = a.traceStop(ctx)
	}
	a.wg.Wait()
	if a.relay != nil {
		a.relay.Close()
	}
	if a.store != nil {
		a.store.Close()
	}
	if a.grpcSrv != nil {
		a.grpcSrv.GracefulStop()
	}
	if a.server != nil {
		return a.server.Stop(ctx)
	}
	return nil
}
