require "grpc"
require "fileutils"

# Shipping.QuoteDelivery gRPC server (§7). Stubs are generated at boot from
# proto/shipping.proto into a tmpdir (grpc_tools_ruby_protoc) — no committed generated
# code. Internal-token gated (constant-time). Runs in its own thread (Shipping::Workers).
module Shipping
  module GrpcServer
    OUT = "/tmp/dokandar_shipping_grpc".freeze

    module_function

    def generate_and_require
      FileUtils.mkdir_p(OUT)
      proto_dir = Rails.root.join("proto").to_s
      unless File.exist?(File.join(OUT, "shipping_pb.rb"))
        ok = system("grpc_tools_ruby_protoc", "-I", proto_dir,
                    "--ruby_out=#{OUT}", "--grpc_out=#{OUT}",
                    File.join(proto_dir, "shipping.proto"))
        raise "grpc_tools_ruby_protoc failed" unless ok
      end
      $LOAD_PATH.unshift(OUT) unless $LOAD_PATH.include?(OUT)
      require "shipping_pb"
      require "shipping_services_pb"
    end

    def start
      return unless ShippingSettings.grpc_enabled
      generate_and_require
      server = GRPC::RpcServer.new
      server.add_http2_port("0.0.0.0:#{ShippingSettings.grpc_port}", :this_port_is_insecure)
      server.handle(impl_class)
      Shipping::Logger.info("grpc Shipping listening on 0.0.0.0:#{ShippingSettings.grpc_port}")
      server.run # blocks until shutdown
    rescue StandardError => e
      Shipping::Logger.warn("grpc server not started: #{e.class}: #{e.message}")
    end

    def impl_class
      Class.new(Dokandar::Shipping::V1::Shipping::Service) do
        def quote_delivery(req, call)
          tok = call.metadata["x-internal-token"]
          raise GRPC::Unauthenticated.new("missing or invalid x-internal-token") unless ShippingAuth.internal_ok?(tok)
          q = CourierSelector.quote(address_tier: req.address_tier, weight_grams: req.weight_grams, upazila_code: req.upazila_code)
          raise GRPC::FailedPrecondition.new("no active courier serves this tier") unless q
          ShippingMetrics.quote!(q[:courier])
          Dokandar::Shipping::V1::QuoteResponse.new(
            courier: q[:courier].to_s, fee_minor: q[:fee_minor].to_i,
            eta_hours: q[:eta_hours].to_i, distance_km: q[:distance_km].to_f,
          )
        end
      end
    end
  end
end
