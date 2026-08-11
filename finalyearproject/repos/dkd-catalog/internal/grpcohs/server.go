// Package grpcohs is the catalog R7 master-data OHS over gRPC (CAT-01): the internal-plane Product
// read-model resolver other contexts call to resolve a GPID (never a local fork of GPID).
package grpcohs

import (
	"context"
	"errors"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/grpcohs/pb"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

// Server implements the generated CatalogProductOhs gRPC service over the catalog store.
type Server struct {
	pb.UnimplementedCatalogProductOhsServer
	st *store.Store
}

func New(st *store.Store) *Server { return &Server{st: st} }

// ResolveProduct maps a GPID to its canonical product read-model. A missing product is a normal
// {found:false} reply (not a gRPC error); only infrastructure failures surface as errors.
func (s *Server) ResolveProduct(ctx context.Context, req *pb.ResolveProductRequest) (*pb.ProductReply, error) {
	p, err := s.st.GetProduct(ctx, req.GetGpid())
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return &pb.ProductReply{Found: false, Gpid: req.GetGpid()}, nil
		}
		return nil, err
	}
	return &pb.ProductReply{
		Found:        true,
		Gpid:         string(p.GPID),
		CategoryPath: p.CategoryPath,
		NamesBn:      p.NamesBn,
		NamesEn:      p.NamesEn,
		BaseUnit:     p.BaseUnit,
		Status:       string(p.Status),
		CreatedBy:    p.CreatedBy,
		CreatedAt:    p.CreatedAtMs,
		UpdatedAt:    p.UpdatedAtMs,
		Version:      p.Version,
	}, nil
}
