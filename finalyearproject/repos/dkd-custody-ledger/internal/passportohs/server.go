// Package passportohs is custody's read-only gRPC OHS for passport heads (B2B-F2 / EF-API-1
// internal-plane = gRPC). It mirrors the REST GET /v1/custody/passports/{ppid} so other contexts
// (e.g. B2B) can resolve a passport over gRPC instead of REST.
package passportohs

import (
	"context"
	"errors"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/passportohs/pb"
)

// headStore is the narrow read port (custody *store.Store satisfies it).
type headStore interface {
	GetHead(ctx context.Context, ppid string) (*custody.Passport, error)
}

type Server struct {
	pb.UnimplementedCustodyPassportOhsServer
	st  headStore
	err error // the store's not-found sentinel, injected so this package need not import store
}

func New(st headStore, notFound error) *Server { return &Server{st: st, err: notFound} }

func (s *Server) GetPassport(ctx context.Context, req *pb.GetPassportRequest) (*pb.PassportReply, error) {
	p, err := s.st.GetHead(ctx, req.GetPpid())
	if err != nil {
		if errors.Is(err, s.err) {
			return &pb.PassportReply{Found: false, Ppid: req.GetPpid()}, nil
		}
		return nil, err
	}
	return &pb.PassportReply{
		Found:         true,
		Ppid:          p.PPID,
		Gpid:          p.GPID,
		CurrentHolder: p.CurrentHolder,
		Status:        string(p.Status),
	}, nil
}
