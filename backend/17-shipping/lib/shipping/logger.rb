require "json"
require "net/http"
require "uri"

# Three log sinks: stdout (JSON) + MongoDB forensic + Elasticsearch (:9200, ECS). The Mongo
# + ES writes run on a BACKGROUND thread off the Puma request thread (§11, §16-f), draining
# a bounded queue (drop-not-block). Every line carries the APM trace id. OTP/PII (recipient
# phone/address) are NEVER passed here.
module Shipping
  module Logger
    MAX_QUEUE = 10_000
    BATCH = 200
    @queue = Thread::Queue.new
    @mongo_coll = nil
    @mongo_up = false
    @es_uri = nil
    @es_auth = nil
    @drainer = nil

    class << self
      def start
        connect_mongo
        connect_es
        @drainer ||= Thread.new { drain_loop }
      end

      def info(msg, **extra)  = write("INFO", msg, extra)
      def warn(msg, **extra)  = write("WARNING", msg, extra)
      def error(msg, **extra) = write("ERROR", msg, extra)

      def mongo_healthy? = @mongo_up

      private

      def write(level, message, extra)
        now = Time.now.utc
        ts = now.strftime("%Y-%m-%dT%H:%M:%S.") + format("%03dZ", now.nsec / 1_000_000)
        doc = {
          "@timestamp" => ts,
          "log" => { "level" => level.downcase }, "logger" => "shipping",
          "message" => message,
          "service" => { "name" => ShippingSettings.service_name, "environment" => ShippingSettings.app_env },
          "labels" => { "tenant" => ShippingSettings.tenant, "env_version" => ShippingSettings.env_version },
        }.merge(trace_fields).merge(stringify(extra))
        $stdout.puts(JSON.generate(doc))
        @queue.push(doc) if @queue.size < MAX_QUEUE
      rescue StandardError
        nil
      end

      def trace_fields
        return {} unless defined?(ElasticAPM)
        tx = ElasticAPM.current_transaction
        return {} unless tx
        { "trace" => { "id" => tx.trace_id }, "transaction" => { "id" => tx.id } }
      rescue StandardError
        {}
      end

      def stringify(h) = h.transform_keys(&:to_s)

      def connect_mongo
        uri = ENV.fetch("MONGO_LOG_URI", "")
        return if uri.empty?
        require "mongo"
        Mongo::Logger.logger.level = ::Logger::FATAL
        client = Mongo::Client.new(uri, server_selection_timeout: 3, database: ENV.fetch("MONGO_LOG_DB", "mongo_db_dokandar_application_logs"))
        @mongo_coll = client[ShippingSettings.service_name]
        @mongo_up = true
      rescue StandardError => e
        $stderr.puts("mongo log sink connect failed: #{e.class}")
        @mongo_up = false
      end

      def connect_es
        url = ENV.fetch("ELASTIC_SEARCH_URL", "")
        return if url.empty?
        @es_uri = URI("#{url.chomp('/')}/logs-app-#{ShippingSettings.service_name}-default/_bulk")
        u = ENV.fetch("ELASTIC_SEARCH_USERNAME", "")
        @es_auth = u.empty? ? nil : [u, ENV.fetch("ELASTIC_SEARCH_PASSWORD", "")]
      end

      def drain_loop
        loop do
          batch = []
          batch << @queue.pop
          batch << @queue.pop while !@queue.empty? && batch.size < BATCH
          flush_mongo(batch)
          flush_es(batch)
        rescue StandardError
          sleep 1
        end
      end

      def flush_mongo(batch)
        return unless @mongo_coll
        @mongo_coll.insert_many(batch.map { |d| d.dup }, ordered: false)
        @mongo_up = true
      rescue StandardError
        @mongo_up = false
      end

      def flush_es(batch)
        return unless @es_uri
        body = +""
        batch.each do |d|
          clean = d.reject { |k, _| k == "_id" }
          body << JSON.generate({ create: {} }) << "\n" << JSON.generate(clean) << "\n"
        end
        req = Net::HTTP::Post.new(@es_uri)
        req["Content-Type"] = "application/x-ndjson"
        req.basic_auth(*@es_auth) if @es_auth
        req.body = body
        Net::HTTP.start(@es_uri.host, @es_uri.port, open_timeout: 3, read_timeout: 4) { |h| h.request(req) }
      rescue StandardError
        nil
      end
    end
  end
end
