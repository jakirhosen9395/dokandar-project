// Package identityclient is custody's gRPC client for the Identity master-data OHS (R7). C3-F5 uses
// it to gate passport initialization on the holder's KYC tier (≥ BASIC per FR-PASS). No-op when
// DKD_IDENTITY_GRPC_URL is unset (dev): the gate opens rather than blocking the service.
package identityclient

import (
	"context"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/identityclient/pb"
)

type Client struct {
	conn *grpc.ClientConn
	c    pb.IdentityPartyOhsClient
}

func New(addr string) (*Client, error) {
	if addr == "" {
		return &Client{}, nil
	}
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	return &Client{conn: conn, c: pb.NewIdentityPartyOhsClient(conn)}, nil
}

// KycTier returns the holder's KYC tier (UNVERIFIED|BASIC|FULL|BUSINESS), or "" when the client is
// unconfigured (dev) so callers treat the gate as open.
func (cl *Client) KycTier(ctx context.Context, did string) (string, error) {
	if cl == nil || cl.c == nil {
		return "", nil
	}
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	r, err := cl.c.GetKycTier(cctx, &pb.GetKycTierRequest{Did: did})
	if err != nil {
		return "", err
	}
	return r.GetKycTier(), nil
}

// Enabled reports whether a real Identity OHS connection is configured.
func (cl *Client) Enabled() bool { return cl != nil && cl.c != nil }

func (cl *Client) Close() {
	if cl != nil && cl.conn != nil {
		_ = cl.conn.Close()
	}
}
