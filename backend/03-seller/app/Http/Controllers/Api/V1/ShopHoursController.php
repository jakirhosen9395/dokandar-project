<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Shop;
use App\Models\ShopHour;
use App\Support\Json;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Symfony\Component\HttpFoundation\Response;

/**
 * Operating hours (docs/services/shop.md §5.6).
 *   GET /api/v1/shop/shops/{id}/hours   public — 7 rows (Sun..Sat)
 *   PUT /api/v1/shop/shops/{id}/hours   owner/staff — replace atomically
 *
 * Edge-case policy is in the spec table; the PUT handler enforces the
 * UNIQUE(shop_id, day_of_week) invariant and `open_time < close_time`
 * (unless is_closed=true, when the times are ignored).
 */
class ShopHoursController extends Controller
{
    public function show(Request $r, string $id): Response
    {
        $shop = Shop::find($id);
        if (! $shop) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        $rows = ShopHour::where('shop_id', $id)->orderBy('day_of_week')->get();
        return Json::response(['hours' => $rows]);
    }

    public function replace(Request $r, string $id): Response
    {
        $shop = Shop::find($id);
        if (! $shop) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        $isStaff = DB::table('shop_staff')
            ->where('shop_id', $id)->where('user_id', $uid)->exists();
        if ($shop->owner_id !== $uid && $role !== 'admin' && ! $isStaff) {
            return Json::error(403, 'not_owner', 'You do not own this shop.',
                (string) $r->header('X-Request-Id', ''));
        }
        $payload = $r->json()->all();
        $v = Validator::make($payload, [
            'hours' => 'required|array|min:1|max:7',
            'hours.*.day_of_week' => 'required|integer|between:0,6',
            'hours.*.open_time'   => 'nullable|date_format:H:i:s',
            'hours.*.close_time'  => 'nullable|date_format:H:i:s',
            'hours.*.is_closed'   => 'nullable|boolean',
        ]);
        if ($v->fails()) {
            return Json::error(422, 'validation_error', 'invalid body',
                (string) $r->header('X-Request-Id', ''), $v->errors());
        }
        $seenDays = [];
        foreach ($payload['hours'] as $i => $h) {
            $d = (int) $h['day_of_week'];
            if (isset($seenDays[$d])) {
                return Json::error(422, 'unsupported_split_hours',
                    "day_of_week=$d appears twice; v1 only supports one row per day.",
                    (string) $r->header('X-Request-Id', ''));
            }
            $seenDays[$d] = true;
            if (empty($h['is_closed'])) {
                if (!isset($h['open_time']) || !isset($h['close_time'])) {
                    return Json::error(422, 'validation_error',
                        "hours[$i]: open_time and close_time required when is_closed is false.",
                        (string) $r->header('X-Request-Id', ''));
                }
                if ($h['open_time'] >= $h['close_time']) {
                    return Json::error(422, 'validation_error',
                        "hours[$i]: open_time must precede close_time (overnight requires two rows; see spec).",
                        (string) $r->header('X-Request-Id', ''));
                }
            }
        }
        try {
            DB::transaction(function () use ($id, $payload) {
                ShopHour::where('shop_id', $id)->delete();
                foreach ($payload['hours'] as $h) {
                    ShopHour::create([
                        'shop_id'     => $id,
                        'day_of_week' => (int) $h['day_of_week'],
                        'open_time'   => empty($h['is_closed']) ? $h['open_time'] : null,
                        'close_time'  => empty($h['is_closed']) ? $h['close_time'] : null,
                        'is_closed'   => (bool) ($h['is_closed'] ?? false),
                    ]);
                }
            });
        } catch (\Throwable $e) {
            return Json::error(500, 'internal_error', $e->getMessage(),
                (string) $r->header('X-Request-Id', ''));
        }
        $rows = ShopHour::where('shop_id', $id)->orderBy('day_of_week')->get();
        return Json::response(['hours' => $rows]);
    }
}
