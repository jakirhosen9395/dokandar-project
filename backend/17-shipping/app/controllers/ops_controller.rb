require "socket"

# The five operational endpoints. /ready gates PostgreSQL ALWAYS (§8.1); Neo4j/Kafka are
# diagnostic-only on /health and never flip status.
class OpsController < ApplicationController
  def ready
    ok, ms, detail = check_pg
    render_pretty({ status: ok ? "ready" : "not_ready",
                    identity: ShippingSettings.identity,
                    dependencies: [{ name: "postgres", reachable: ok, latency_ms: ms, detail: detail }] },
                  status: ok ? 200 : 503)
  end

  def health
    pg_ok, _ms, pg_d = check_pg
    neo_ok, neo_d = tcp_url(ENV["NEO4J_URL"], 7687)
    kafka_ok, kafka_d = tcp_hostport(ENV["KAFKA_BOOTSTRAP"], 9092)
    mlog = mongo_logs_health
    apm_ok = !ENV.fetch("APM_SERVER_URL", "").empty?
    es = ENV.fetch("ELASTIC_SEARCH_URL", "").chomp("/")
    render_pretty({
      status: pg_ok ? "healthy" : "unhealthy",       # PostgreSQL-driven (§8.2 core=postgres)
      identity: ShippingSettings.identity,
      checks: {
        postgres:   { ok: pg_ok, detail: pg_d },
        neo4j:      { ok: neo_ok, detail: neo_d },
        kafka:      { ok: kafka_ok, detail: kafka_d },
        mongo_logs: { ok: mlog, detail: mlog ? "ok" : "unreachable" },
        apm:        { ok: apm_ok, detail: apm_ok ? "configured" : "disabled" },
      },
      observability: {
        apm_service_name: ENV.fetch("APM_SERVICE_NAME", "17-shipping"),
        logs_sink_mongo: "#{ENV.fetch('MONGO_LOG_DB', 'mongo_db_dokandar_application_logs')}.#{ShippingSettings.service_name}",
        logs_sink_es: "#{es}/logs-app-#{ShippingSettings.service_name}-*",
      },
    }, status: pg_ok ? 200 : 503)
  end

  def data
    path = Rails.root.join("data", ShippingSettings.tenant, "result.json")
    return render_error("no_snapshot", "data/#{ShippingSettings.tenant}/result.json not present", status: 404) unless File.exist?(path)
    begin
      snap = JSON.parse(File.read(path))
      raise "not object" unless snap.is_a?(Hash)
    rescue StandardError
      return render_error("snapshot_parse_failed", "snapshot is not a JSON object", status: 500)
    end
    render_pretty({ identity: ShippingSettings.identity }.merge(snap), status: 200)
  end

  def metrics
    # shipping_outbox_pending is computed at scrape time (relay lag).
    refresh_outbox_gauge
    render body: ShippingMetrics.render, content_type: "text/plain; version=0.0.4; charset=utf-8", status: 200
  end

  def openapi
    render body: JSON.pretty_generate(ShippingOpenapi.document), content_type: "application/json", status: 200
  end

  def docs
    render body: ShippingOpenapi.swagger_ui_html, content_type: "text/html; charset=utf-8", status: 200
  end

  private

  def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000.0

  def check_pg
    t = now_ms
    ActiveRecord::Base.connection.execute("SELECT 1")
    [true, (now_ms - t).round(2), "ok"]
  rescue StandardError => e
    [false, 0.0, "err:#{e.class.name.split('::').last}"]
  end

  def tcp(host, port)
    Socket.tcp(host, port, connect_timeout: 2) { |s| s.close }
    [true, "tcp-ok"]
  rescue StandardError
    [false, "unreachable"]
  end

  def tcp_hostport(spec, default_port)
    return [false, "not-configured"] if spec.to_s.empty?
    h, p = spec.to_s.split(",").first.to_s.split(":")
    tcp(h, (p || default_port).to_i)
  end

  def tcp_url(url, default_port)
    return [false, "not-configured"] if url.to_s.empty?
    u = URI.parse(url.to_s.sub(%r{\Abolt://}, "http://").sub(%r{\Aneo4j://}, "http://"))
    tcp(u.host, (u.port || default_port).to_i)
  rescue StandardError
    [false, "bad-url"]
  end

  def mongo_logs_health
    if defined?(Shipping::Logger) && Shipping::Logger.respond_to?(:mongo_healthy?)
      Shipping::Logger.mongo_healthy?
    else
      !ENV.fetch("MONGO_LOG_URI", "").empty?
    end
  end

  def refresh_outbox_gauge
    n = defined?(Outbox) ? Outbox.where(sent_at: nil).count : 0
    ShippingMetrics.set_outbox_pending(n)
  rescue StandardError
    nil
  end
end
