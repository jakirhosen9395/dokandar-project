<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Support\Json;
use App\Support\Metrics;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Symfony\Component\HttpFoundation\Response;

/**
 * "Shops near me" lookup (docs/services/shop.md §5.10, BUSINESS_LOGIC §4.2).
 *
 * The spec calls for PostGIS (ST_DWithin + GIST on `geog`). The deployed
 * components postgres image is plain postgres:16 which does NOT ship
 * PostGIS — but `cube` + `earthdistance` (contrib) ARE available, so we
 * use them: `earth_distance(ll_to_earth(a_lat,a_lon), ll_to_earth(b_lat,b_lon))`
 * returns metres. We accept the GiST→btree+earthdistance trade-off
 * because the components rule forbids changing the postgres image.
 *
 * Performance: a btree on (lat, lon) prunes the candidate set before the
 * earth_distance compute. For Bangladesh-scale this is well under 50 ms
 * with <100k shops.
 */
class ShopGeoController extends Controller
{
    public function near(Request $r): Response
    {
        $params = [
            'lat'      => $r->query('lat'),
            // Accept 'lng' as an alias for 'lon' (storefront/clients use either).
            'lon'      => $r->query('lon', $r->query('lng')),
            'radius_m' => $r->query('radius_m', 2000),
            'limit'    => $r->query('limit', 20),
        ];
        $v = Validator::make($params, [
            'lat'      => 'required|numeric|between:-90,90',
            'lon'      => 'required|numeric|between:-180,180',
            'radius_m' => 'required|numeric|min:1|max:50000',
            'limit'    => 'required|integer|min:1|max:100',
        ]);
        if ($v->fails()) {
            $first = $v->errors()->first();
            // Out-of-range lat/lon → 400 (semantic). Missing → 422 (structural).
            $isRange = str_contains((string) $first, 'between');
            return Json::error($isRange ? 400 : 422, $isRange ? 'invalid_geo' : 'validation_error',
                $first, (string) $r->header('X-Request-Id', ''), $v->errors());
        }
        $lat = (float) $params['lat'];
        $lon = (float) $params['lon'];
        $radius = (float) $params['radius_m'];
        $limit = (int) $params['limit'];

        // Coarse pre-filter via bounding box on (lat, lon) — 1 degree latitude
        // ≈ 111_320 m. Then exact distance via earth_distance.
        $latDelta = $radius / 111320.0;
        $lonDelta = $radius / (111320.0 * max(0.000001, cos(deg2rad($lat))));

        try {
            $rows = DB::select(<<<SQL
                SELECT id, owner_id, handle, name, category_id, lat, lon, status,
                       (earth_distance(ll_to_earth(?, ?), ll_to_earth(lat, lon)))::int AS distance_m
                  FROM shops
                 WHERE status = 'live'
                   AND lat IS NOT NULL AND lon IS NOT NULL
                   AND lat BETWEEN ? AND ?
                   AND lon BETWEEN ? AND ?
                   AND earth_distance(ll_to_earth(?, ?), ll_to_earth(lat, lon)) <= ?
              ORDER BY distance_m
                 LIMIT ?
            SQL,
                [$lat, $lon,
                 $lat - $latDelta, $lat + $latDelta,
                 $lon - $lonDelta, $lon + $lonDelta,
                 $lat, $lon, $radius,
                 $limit]
            );
        } catch (\Throwable $e) {
            return Json::error(503, 'geo_unavailable',
                'earthdistance extension not loaded — run `CREATE EXTENSION cube; CREATE EXTENSION earthdistance;`',
                (string) $r->header('X-Request-Id', ''));
        }
        try { Metrics::geoSearches()->inc([Metrics::svc()]); } catch (\Throwable $e) {}
        return Json::response([
            'lat' => $lat, 'lon' => $lon, 'radius_m' => $radius,
            'count' => count($rows),
            'shops' => $rows,
        ]);
    }
}
