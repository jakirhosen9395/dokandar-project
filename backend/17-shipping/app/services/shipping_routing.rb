require "net/http"
require "uri"
require "json"

# Road-graph routing (§3.2). Neo4j is a NON-GATING optimizer: a distance query is attempted
# over the upazila road graph, falling back to the delivery_zones zone-table estimate when
# Neo4j is down/cold (the VRP solver itself is an open item, §17). Uses the Neo4j HTTP
# transaction API (:7474) — no Bolt native-ext dependency. Every call degrades gracefully.
module ShippingRouting
  module_function

  def distance_km(upazila_code)
    via_neo4j(upazila_code) || via_zone_table(upazila_code) || { distance_km: 25.0, source: "default" }
  end

  def via_zone_table(code)
    return nil if code.to_s.empty?
    z = DeliveryZone.find_by(upazila_code: code)
    return nil unless z&.fallback_distance_km
    { distance_km: z.fallback_distance_km.to_f, source: "zone_table" }
  rescue StandardError
    nil
  end

  def via_neo4j(code)
    return nil if code.to_s.empty?
    rows = cypher("MATCH (u:Upazila {code:$code})-[r:ROAD_TO]->(:Hub) RETURN min(r.distance_km) AS d",
                  { code: code })
    d = rows&.dig(0, "row", 0)
    d ? { distance_km: d.to_f, source: "neo4j" } : nil
  rescue StandardError
    nil
  end

  def neo4j_healthy?
    !cypher("RETURN 1 AS ok", {}).nil?
  rescue StandardError
    false
  end

  # POST a single Cypher statement to the Neo4j HTTP tx/commit endpoint; returns the
  # results' `data` array or nil. Best-effort, short timeout.
  def cypher(statement, params)
    bolt = ENV.fetch("NEO4J_URL", "")
    return nil if bolt.empty?
    host = URI.parse(bolt.sub(%r{\A(bolt|neo4j)://}, "http://")).host
    db = ENV.fetch("NEO4J_DATABASE", "neo4j")
    uri = URI("http://#{host}:7474/db/#{db}/tx/commit")
    req = Net::HTTP::Post.new(uri)
    req.basic_auth(ENV.fetch("NEO4J_USERNAME", "neo4j"), ENV.fetch("NEO4J_PASSWORD", ""))
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(statements: [{ statement: statement, parameters: params }])
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 2, read_timeout: 2) { |h| h.request(req) }
    return nil unless res.is_a?(Net::HTTPSuccess)
    body = JSON.parse(res.body)
    return nil if body["errors"]&.any?
    body.dig("results", 0, "data")
  rescue StandardError
    nil
  end
end
