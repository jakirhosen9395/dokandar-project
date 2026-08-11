// Package grpcserver implements the dokandar.profile.v1.ProfileQuery
// service on :GRPC_PORT. The .pb generated files live in ./pb (output
// of `protoc` in the Dockerfile build stage and a `go generate` step
// for native builds). x-internal-token is enforced on every RPC.
package grpcserver

import (
	"context"
	"net"

	"github.com/google/uuid"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	"github.com/dokandar/dokandar-profile/internal/domain/address"
	"github.com/dokandar/dokandar-profile/internal/domain/profile"
	"github.com/dokandar/dokandar-profile/internal/grpcserver/pb"
	"github.com/dokandar/dokandar-profile/internal/observability"
)

type Server struct {
	pb.UnimplementedProfileQueryServer
	Profiles      *profile.Store
	Addresses     *address.Store
	InternalToken string
}

func (s *Server) checkInternal(ctx context.Context) error {
	md, _ := metadata.FromIncomingContext(ctx)
	got := md.Get("x-internal-token")
	if len(got) == 0 || got[0] != s.InternalToken || s.InternalToken == "" {
		return status.Error(codes.Unauthenticated, "missing or invalid x-internal-token")
	}
	return nil
}

func (s *Server) LookupProfile(ctx context.Context, req *pb.LookupProfileRequest) (*pb.Profile, error) {
	if err := s.checkInternal(ctx); err != nil {
		observability.GrpcLookup.WithLabelValues("unauthenticated").Inc()
		return nil, err
	}
	if req.GetUserId() == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id required")
	}
	if _, err := uuid.Parse(req.GetUserId()); err != nil {
		observability.GrpcLookup.WithLabelValues("invalid_argument").Inc()
		return nil, status.Error(codes.InvalidArgument, "user_id must be a UUID")
	}
	p, err := s.Profiles.Get(ctx, req.UserId)
	if err == profile.ErrNotFound {
		observability.GrpcLookup.WithLabelValues("not_found").Inc()
		return nil, status.Error(codes.NotFound, "profile not found")
	}
	if err != nil {
		observability.GrpcLookup.WithLabelValues("error").Inc()
		return nil, status.Error(codes.Internal, err.Error())
	}
	observability.GrpcLookup.WithLabelValues("ok").Inc()
	out := &pb.Profile{
		UserId:         p.UserID,
		Phone:          p.Phone,
		NameEn:         strOrEmpty(p.NameEn),
		NameBn:         strOrEmpty(p.NameBn),
		Locale:         p.Locale,
		Kyc:            p.Kyc,
		AvatarUrl:      "",
		WhatsappNumber: strOrEmpty(p.WhatsappNumber),
	}
	if p.Email != nil {
		out.Email = *p.Email
	}
	if p.AvatarMediaID != nil && *p.AvatarMediaID != "" {
		out.AvatarUrl = "media://" + *p.AvatarMediaID
	}
	return out, nil
}

func (s *Server) GetDefaultAddress(ctx context.Context, req *pb.GetDefaultAddressRequest) (*pb.Address, error) {
	if err := s.checkInternal(ctx); err != nil {
		return nil, err
	}
	if req.GetUserId() == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id required")
	}
	if _, err := uuid.Parse(req.GetUserId()); err != nil {
		return nil, status.Error(codes.InvalidArgument, "user_id must be a UUID")
	}
	addrs, err := s.Addresses.List(ctx, req.UserId)
	if err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}
	for i := range addrs {
		a := &addrs[i]
		if a.IsDefault {
			return &pb.Address{
				Id: a.ID, UserId: a.UserID, Label: a.Label,
				RecipientName: a.RecipientName, RecipientPhone: a.RecipientPhone,
				DivisionCode: a.DivisionCode, DistrictCode: a.DistrictCode,
				UpazilaCode: a.UpazilaCode, UnionCode: strOrEmpty(a.UnionCode),
				Line1: a.Line1, Line2: strOrEmpty(a.Line2), Landmark: strOrEmpty(a.Landmark),
				Lat: f64OrZero(a.Lat), Lng: f64OrZero(a.Lng),
			}, nil
		}
	}
	return nil, status.Error(codes.NotFound, "no default address")
}

// Serve binds and runs the gRPC server until the listener errors or the
// context is canceled.
func Serve(ctx context.Context, addr string, s *Server) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	srv := grpc.NewServer()
	pb.RegisterProfileQueryServer(srv, s)

	go func() {
		<-ctx.Done()
		srv.GracefulStop()
	}()
	return srv.Serve(lis)
}

func strOrEmpty(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
func f64OrZero(p *float64) float64 {
	if p == nil {
		return 0
	}
	return *p
}
