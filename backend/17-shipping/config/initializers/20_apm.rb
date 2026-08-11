# Elastic APM (Ruby) — started manually (the gem is require:false) and inserted at the TOP
# of the Rack stack (`insert_before 0`), the Family-A "outermost" rule (§11, §16-d), so the
# edge span is the trace root and the 3-sink logger can stamp every line with the trace id.
if !ENV.fetch("APM_SERVER_URL", "").empty?
  begin
    require "elastic-apm"
    require "elastic_apm/rails"
    # ElasticAPM::Rails.start (not ElasticAPM.start) attaches the Rails subscriber — the gem's
    # require:false manual start otherwise runs in bare-Rack mode: every transaction is named "Rack"
    # and ActiveRecord SQL spans are never captured. Rails.start gives controller#action names + pg spans.
    ElasticAPM::Rails.start(
      service_name: ENV.fetch("APM_SERVICE_NAME", "17-shipping"),
      service_version: ShippingSettings.code_version,
      environment: ShippingSettings.app_env,
      server_url: ENV.fetch("APM_SERVER_URL", ""),
      secret_token: ENV.fetch("APM_SECRET_TOKEN", ""),
      verify_server_cert: false,
      # NOT ignoring /ready: the Docker HEALTHCHECK probes /ready every ~30s; recording it keeps the
      # service in the APM inventory even when idle (matches the 11 fleet services that already do).
      transaction_ignore_urls: ["/metrics", "/health"],
      log_level: ::Logger::FATAL,
    )
    Rails.application.config.middleware.insert_before(0, ElasticAPM::Middleware) if ElasticAPM.running?
    if ElasticAPM.running?
      # Rename the Neo4j HTTP dependency (auto-instrumented Net::HTTP to :7474) from its raw IP:port
      # to a friendly "neo4j" node in Dependencies + the service map — there is no Bolt auto-naming.
      ElasticAPM.add_filter(:friendly_neo4j) do |payload|
        svc = payload.dig(:span, :context, :destination, :service)
        if svc && svc[:resource].is_a?(String) && svc[:resource].include?(":7474")
          svc[:resource] = "neo4j"
          svc[:name] = "neo4j" if svc.key?(:name)
        end
        payload
      end
    end
    at_exit { ElasticAPM.stop }
  rescue StandardError => e
    warn "elastic-apm not started: #{e.class}: #{e.message}"
  end
end
