// Package reservationohs is inventory's gRPC OHS for the G2 strong-local reserve/transition
// writes (B2B-F2 / EF-API-1 internal plane). It mirrors the REST /v1/inventory/reservations
// endpoints so other contexts (e.g. B2B) can reserve/release/confirm over gRPC.
package reservationohs

import (
	"context"
	"errors"

	"gitlab.com/final-year-project3354127/inventory-svc/internal/reservationohs/pb"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/store"
)

type resStore interface {
	Reserve(ctx context.Context, idemKey, gpid, holder string, qty, at int64) (store.Reservation, error)
	Transition(ctx context.Context, resID, to string, at int64) (store.Reservation, error)
}

type Server struct {
	pb.UnimplementedInventoryReservationOhsServer
	st  resStore
	now func() int64
}

func New(st resStore, now func() int64) *Server { return &Server{st: st, now: now} }

func (s *Server) Reserve(ctx context.Context, req *pb.ReserveRequest) (*pb.ReserveReply, error) {
	r, err := s.st.Reserve(ctx, req.GetIdempotencyKey(), req.GetGpid(), req.GetHolder(), req.GetQuantity(), s.now())
	if err != nil {
		if errors.Is(err, store.ErrInsufficientStock) {
			return &pb.ReserveReply{Ok: false, InsufficientStock: true}, nil
		}
		return nil, err
	}
	return &pb.ReserveReply{Ok: true, ResId: r.ResID}, nil
}

func (s *Server) Transition(ctx context.Context, req *pb.TransitionRequest) (*pb.TransitionReply, error) {
	r, err := s.st.Transition(ctx, req.GetResId(), req.GetTo(), s.now())
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return &pb.TransitionReply{Ok: false, NotFound: true}, nil
		}
		return nil, err
	}
	return &pb.TransitionReply{Ok: true, State: r.State}, nil
}
