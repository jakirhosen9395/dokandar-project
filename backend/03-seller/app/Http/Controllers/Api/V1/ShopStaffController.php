<?php

namespace App\Http\Controllers\Api\V1;

use App\Grpc\AuthClient;
use App\Http\Controllers\Controller;
use App\Models\Shop;
use App\Models\ShopStaff;
use App\Support\Json;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Validator;
use Symfony\Component\HttpFoundation\Response;

/**
 * Staff↔shop assignment (docs/services/shop.md §5.9, BUSINESS_LOGIC §4.4).
 *   POST   /api/v1/shop/shops/{id}/staff           owner only
 *   DELETE /api/v1/shop/shops/{id}/staff/{userId}  owner only
 *
 * A staff member may serve many shops, but only shops owned by the same
 * shopkeeper. The role check is enforced by who can call POST (owner of
 * the target shop). Cross-owner reassignment is rejected at the row
 * level by the UNIQUE(shop_id, user_id) constraint plus the owner check
 * here.
 */
class ShopStaffController extends Controller
{
    public function assign(Request $r, string $id): Response
    {
        $shop = Shop::find($id);
        if (! $shop) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        if ($shop->owner_id !== $uid && $role !== 'admin') {
            return Json::error(403, 'not_owner', 'Only the shop owner can assign staff.',
                (string) $r->header('X-Request-Id', ''));
        }
        $payload = $r->json()->all();
        $v = Validator::make($payload, [
            'user_id' => 'required|uuid',
        ]);
        if ($v->fails()) {
            return Json::error(422, 'validation_error', 'invalid body',
                (string) $r->header('X-Request-Id', ''), $v->errors());
        }
        $staffUid = $payload['user_id'];
        $rid = (string) $r->header('X-Request-Id', '');
        if (ShopStaff::where('shop_id', $id)->where('user_id', $staffUid)->exists()) {
            return Json::error(409, 'already_assigned',
                "User $staffUid is already assigned to this shop.", $rid);
        }

        // Verify the target is a shop_staff owned by the caller, via auth gRPC
        // (BL §4.4). On gRPC transport failure → 503 (per shop.md failure modes).
        // When gRPC isn't usable at all (extension/host missing) we degrade to
        // the local owner check + a logged warning rather than hard-blocking.
        $client = new AuthClient((string) config('shop.grpc.auth'), (string) config('shop.internal_token'));
        if ($client->usable()) {
            try {
                $info = $client->lookupShopkeeper($staffUid);
            } catch (\Throwable $e) {
                Log::warning('staff-assign: auth gRPC failed', ['name' => 'seller.grpc', 'err' => $e->getMessage()]);
                return Json::error(503, 'grpc_auth_unavailable',
                    'Cannot verify the staff member with auth right now.', $rid);
            }
            if (! ($info['exists'] ?? false)) {
                return Json::error(422, 'validation_error', 'Target user does not exist.',
                    $rid, ['user_id' => ['not_found']]);
            }
            if (($info['role'] ?? '') !== 'shop_staff') {
                return Json::error(422, 'not_shop_staff_role',
                    "Target user role is '" . ($info['role'] ?? '') . "', expected shop_staff.", $rid);
            }
            if (($info['owner_id'] ?? '') !== '' && $info['owner_id'] !== $uid && $role !== 'admin') {
                return Json::error(403, 'cross_owner_staff',
                    'That staff member belongs to a different shopkeeper.', $rid);
            }
        } else {
            Log::warning('staff-assign: auth gRPC unusable — skipping target verification',
                ['name' => 'seller.grpc', 'auth_host' => (string) config('shop.grpc.auth')]);
        }

        $row = ShopStaff::create([
            'shop_id' => $id,
            'user_id' => $staffUid,
        ]);
        return Json::response(['staff' => $row], 201);
    }

    public function remove(Request $r, string $id, string $userId): Response
    {
        $shop = Shop::find($id);
        if (! $shop) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        if ($shop->owner_id !== $uid && $role !== 'admin') {
            return Json::error(403, 'not_owner', 'Only the shop owner can remove staff.',
                (string) $r->header('X-Request-Id', ''));
        }
        // Idempotent: removing a non-assignment still returns 204.
        ShopStaff::where('shop_id', $id)->where('user_id', $userId)->delete();
        return new Response('', 204);
    }
}
