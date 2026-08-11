<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\BdAdminArea;
use App\Support\Json;
use Illuminate\Support\Facades\Redis;
use Symfony\Component\HttpFoundation\Response;

/**
 * BD admin-area cascading picker (docs/services/shop.md §8.8). Public,
 * read-only. Results cached in Redis 86400s — the dataset changes rarely.
 *
 *   GET /admin-areas/divisions
 *   GET /admin-areas/{division}/districts
 *   GET /admin-areas/{division}/{district}/upazilas
 *   GET /admin-areas/{division}/{district}/{upazila}/unions
 */
class AdminAreasController extends Controller
{
    private const TTL = 86400;

    public function divisions(): Response
    {
        return Json::response(['items' => $this->cached('shop:area:divisions', function () {
            return BdAdminArea::query()->distinct()->orderBy('division')->pluck('division')->all();
        })]);
    }

    public function districts(string $division): Response
    {
        $division = $this->norm($division);
        return Json::response(['items' => $this->cached("shop:area:dist:{$division}", function () use ($division) {
            return BdAdminArea::query()->where('division', $division)
                ->distinct()->orderBy('district')->pluck('district')->all();
        })]);
    }

    public function upazilas(string $division, string $district): Response
    {
        $division = $this->norm($division);
        $district = $this->norm($district);
        return Json::response(['items' => $this->cached("shop:area:upz:{$division}:{$district}", function () use ($division, $district) {
            return BdAdminArea::query()->where('division', $division)->where('district', $district)
                ->distinct()->orderBy('upazila')->pluck('upazila')->all();
        })]);
    }

    public function unions(string $division, string $district, string $upazila): Response
    {
        $division = $this->norm($division);
        $district = $this->norm($district);
        $upazila  = $this->norm($upazila);
        return Json::response(['items' => $this->cached("shop:area:uni:{$division}:{$district}:{$upazila}", function () use ($division, $district, $upazila) {
            return BdAdminArea::query()->where('division', $division)->where('district', $district)->where('upazila', $upazila)
                ->distinct()->orderBy('union_thana')->pluck('union_thana')->all();
        })]);
    }

    private function norm(string $s): string
    {
        return trim(urldecode($s));
    }

    /** Redis cache-aside; degrades to the DB query if Redis is unavailable. */
    private function cached(string $key, \Closure $fn): array
    {
        try {
            $hit = Redis::get($key);
            if ($hit !== null && $hit !== false) {
                return json_decode($hit, true) ?: [];
            }
        } catch (\Throwable $e) {
            // Redis down — fall through to DB.
        }
        $val = $fn();
        try {
            Redis::setex($key, self::TTL, json_encode($val));
        } catch (\Throwable $e) {
            // ignore cache write failure
        }
        return $val;
    }
}
