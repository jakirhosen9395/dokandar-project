<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Outbox;
use App\Models\Shop;
use App\Models\ShopkeeperKycCache;
use App\Support\Json;
use App\Support\Metrics;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Validator;
use Symfony\Component\HttpFoundation\Response;

/**
 * Core shop CRUD per docs/services/shop.md §5.1–5.5.
 * Every state-changing write produces a `ShopChanged` outbox row in the
 * SAME transaction so the event is published iff the change committed.
 */
class ShopController extends Controller
{
    public function listMine(Request $r): Response
    {
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        $q = Shop::query()->orderBy('created_at');
        if ($role !== 'admin') {
            $q->where('owner_id', $uid);
        }
        return Json::response(['shops' => $q->get()]);
    }

    public function create(Request $r): Response
    {
        $role = (string) $r->attributes->get('role', '');
        if (! in_array($role, ['shopkeeper', 'admin'], true)) {
            return Json::error(403, 'insufficient_role',
                "Role '$role' cannot create shops; shopkeeper or admin required.",
                (string) $r->header('X-Request-Id', ''));
        }
        $payload = $r->json()->all();
        $v = Validator::make($payload, [
            'handle' => 'required|string|min:3|max:60|regex:/^[a-z0-9-]+$/',
            'name'   => 'required|string|min:2|max:120',
            'name_bn' => 'nullable|string|max:120',
            'description' => 'nullable|string',
            'category_id' => 'nullable|uuid',
            'contact_phone' => 'nullable|string|max:20',
            'contact_email' => 'nullable|email|max:255',
            'address' => 'nullable|array',
            'lat' => 'nullable|numeric|between:-90,90',
            'lon' => 'nullable|numeric|between:-180,180',
        ]);
        if ($v->fails()) {
            return Json::error(422, 'validation_error', 'invalid body',
                (string) $r->header('X-Request-Id', ''), $v->errors());
        }

        $uid = (string) $r->attributes->get('user_id', '');
        if (Shop::where('handle', $payload['handle'])->exists()) {
            return Json::error(409, 'handle_taken',
                "Handle '{$payload['handle']}' is already in use.",
                (string) $r->header('X-Request-Id', ''));
        }

        try {
            $shop = DB::transaction(function () use ($payload, $uid) {
                $s = Shop::create(array_merge($payload, [
                    'owner_id' => $uid,
                    'status' => 'draft',
                ]));
                self::emitShopChanged($s, ['transition' => 'created']);
                return $s;
            });
        } catch (\Throwable $e) {
            return Json::error(500, 'internal_error', $e->getMessage(),
                (string) $r->header('X-Request-Id', ''));
        }
        try { Metrics::shopsCreated()->inc([Metrics::svc()]); } catch (\Throwable $e) {}
        return Json::response(['shop' => $shop], 201);
    }

    public function show(Request $r, string $id): Response
    {
        $s = Shop::find($id);
        if (! $s) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        return Json::response(['shop' => $s]);
    }

    public function showByHandle(Request $r, string $handle): Response
    {
        $s = Shop::where('handle', $handle)->first();
        if (! $s) {
            return Json::error(404, 'shop_not_found', "No shop with handle '$handle'.",
                (string) $r->header('X-Request-Id', ''));
        }
        $arr = $s->toArray();
        // Strip owner PII on the public surface (§5.3).
        unset($arr['contact_phone'], $arr['contact_email']);
        // Denormalised KYC badge (§5.3 / §15) from the cache the KYC consumer
        // maintains — lets the storefront render Verified without calling auth.
        $arr['kyc_tier'] = ShopkeeperKycCache::where('user_id', $s->owner_id)->value('tier') ?? 'unverified';
        return Json::response(['shop' => $arr]);
    }

    public function patch(Request $r, string $id): Response
    {
        return $this->updateShared($r, $id, allowStatus: true);
    }

    public function update(Request $r, string $id): Response
    {
        return $this->updateShared($r, $id, allowStatus: false);
    }

    private function updateShared(Request $r, string $id, bool $allowStatus): Response
    {
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        $s = Shop::find($id);
        if (! $s) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        if ($s->owner_id !== $uid && $role !== 'admin') {
            return Json::error(403, 'not_owner', 'You do not own this shop.',
                (string) $r->header('X-Request-Id', ''));
        }
        $payload = $r->json()->all();
        $rules = [
            'name' => 'sometimes|string|min:2|max:120',
            'name_bn' => 'sometimes|nullable|string|max:120',
            'description' => 'sometimes|nullable|string',
            'category_id' => 'sometimes|nullable|uuid',
            'contact_phone' => 'sometimes|nullable|string|max:20',
            'contact_email' => 'sometimes|nullable|email|max:255',
            'address' => 'sometimes|nullable|array',
            'lat' => 'sometimes|nullable|numeric|between:-90,90',
            'lon' => 'sometimes|nullable|numeric|between:-180,180',
            'logo_key' => 'sometimes|nullable|string|max:255',
            'banner_key' => 'sometimes|nullable|string|max:255',
        ];
        if ($allowStatus) {
            $rules['status'] = 'sometimes|in:draft,live,paused,suspended,closed';
        }
        $v = Validator::make($payload, $rules);
        if ($v->fails()) {
            return Json::error(422, 'validation_error', 'invalid body',
                (string) $r->header('X-Request-Id', ''), $v->errors());
        }

        if ($allowStatus && isset($payload['status']) && $payload['status'] !== $s->status) {
            $err = $this->validateTransition($s->status, $payload['status'], $role);
            if ($err !== null) {
                [$status, $code, $msg] = $err;
                return Json::error($status, $code, $msg, (string) $r->header('X-Request-Id', ''));
            }
        }

        try {
            DB::transaction(function () use ($s, $payload) {
                $oldStatus = $s->status;
                $s->fill($payload)->save();
                $changedKeys = array_keys(array_intersect_key($payload, array_flip([
                    'name', 'description', 'category_id', 'address', 'lat', 'lon',
                    'contact_phone', 'contact_email', 'logo_key', 'banner_key', 'status',
                ])));
                self::emitShopChanged($s, [
                    'transition' => $s->status !== $oldStatus ? $oldStatus . '->' . $s->status : 'updated',
                    'fields'     => $changedKeys,
                ]);
            });
        } catch (\Throwable $e) {
            return Json::error(500, 'internal_error', $e->getMessage(),
                (string) $r->header('X-Request-Id', ''));
        }
        return Json::response(['shop' => $s->fresh()]);
    }

    public function destroy(Request $r, string $id): Response
    {
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        $s = Shop::find($id);
        if (! $s) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        if ($s->owner_id !== $uid && $role !== 'admin') {
            return Json::error(403, 'not_owner', 'You do not own this shop.',
                (string) $r->header('X-Request-Id', ''));
        }
        try {
            DB::transaction(function () use ($s) {
                $oldStatus = $s->status;
                $s->status = 'closed';
                $s->save();
                self::emitShopChanged($s, ['transition' => $oldStatus . '->closed']);
            });
        } catch (\Throwable $e) {
            return Json::error(500, 'internal_error', $e->getMessage(),
                (string) $r->header('X-Request-Id', ''));
        }
        return new Response('', 204);
    }

    public function activate(Request $r, string $id): Response
    {
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        $s = Shop::find($id);
        if (! $s) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        if ($s->owner_id !== $uid && $role !== 'admin') {
            return Json::error(403, 'not_owner', 'You do not own this shop.',
                (string) $r->header('X-Request-Id', ''));
        }
        $err = $this->validateTransition($s->status, 'live', $role);
        if ($err !== null) {
            [$status, $code, $msg] = $err;
            return Json::error($status, $code, $msg, (string) $r->header('X-Request-Id', ''));
        }
        try {
            DB::transaction(function () use ($s) {
                $oldStatus = $s->status;
                $s->status = 'live';
                $s->save();
                self::emitShopChanged($s, ['transition' => $oldStatus . '->live']);
            });
        } catch (\Throwable $e) {
            return Json::error(500, 'internal_error', $e->getMessage(),
                (string) $r->header('X-Request-Id', ''));
        }
        try { Metrics::shopsActivated()->inc([Metrics::svc()]); } catch (\Throwable $e) {}
        return Json::response(['shop' => $s->fresh()]);
    }

    /**
     * State machine per docs/services/shop.md §4:
     *   draft  → live
     *   live   ↔ paused
     *   live   → suspended (admin only)
     *   suspended → live (admin only)
     *   *      → closed (terminal)
     */
    private function validateTransition(string $from, string $to, string $role): ?array
    {
        if ($from === $to) return null;
        if ($to === 'closed') return null;
        $allowed = match ($from) {
            'draft'     => ['live'],
            'live'      => ['paused', 'suspended'],
            'paused'    => ['live'],
            'suspended' => $role === 'admin' ? ['live'] : [],
            'closed'    => [],
            default     => [],
        };
        if (! in_array($to, $allowed, true)) {
            return [422, 'invalid_status_transition', "Cannot move shop from '$from' to '$to'."];
        }
        if ($to === 'suspended' && $role !== 'admin') {
            return [403, 'admin_only_transition', "Only admin can suspend a shop."];
        }
        return null;
    }

    public static function emitShopChanged(Shop $s, array $extra = []): void
    {
        Outbox::create([
            'topic'   => config('shop.kafka.topic_shop'),
            'key'     => $s->id,
            'payload' => array_merge([
                'event'    => 'ShopChanged',
                'shop_id'  => $s->id,
                'owner_id' => $s->owner_id,
                'handle'   => $s->handle,
                'name'     => $s->name,
                'name_bn'  => $s->name_bn,
                'status'   => $s->status,
                'category_id' => $s->category_id,
                'lat'      => $s->lat,
                'lon'      => $s->lon,
                'at'       => now()->toIso8601String(),
            ], $extra),
            'created_at' => now(),
        ]);
    }
}
