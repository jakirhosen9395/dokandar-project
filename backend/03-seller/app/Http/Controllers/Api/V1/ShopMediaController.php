<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Shop;
use App\Support\Json;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * Logo/banner upload mediation (docs/services/shop.md §5.7, BL §4.1).
 *
 * The spec routes bytes through the Media service via gRPC:
 *   1. Client → Shop: POST /shops/{id}/logo
 *   2. Shop  → Media (gRPC `PresignUpload`): returns presigned PUT URL + key
 *   3. Client → S3 (PUT bytes)
 *   4. Client → Shop: PATCH /shops/{id} { logo_key }
 *
 * Media is not deployed today; we emit a 503 envelope with a clear
 * `error.code=media_unavailable` so the API contract is honoured and
 * clients know the bytes path is offline. When Media lands this method
 * fans out to the gRPC client and returns the presigned URL.
 */
class ShopMediaController extends Controller
{
    public function presignLogo(Request $r, string $id): Response
    {
        return $this->presign($r, $id, 'shop_logo');
    }

    public function presignBanner(Request $r, string $id): Response
    {
        return $this->presign($r, $id, 'shop_banner');
    }

    private function presign(Request $r, string $id, string $kind): Response
    {
        $shop = Shop::find($id);
        if (! $shop) {
            return Json::error(404, 'shop_not_found', "No shop with id $id.",
                (string) $r->header('X-Request-Id', ''));
        }
        $uid = (string) $r->attributes->get('user_id', '');
        $role = (string) $r->attributes->get('role', '');
        $isStaff = \Illuminate\Support\Facades\DB::table('shop_staff')
            ->where('shop_id', $id)->where('user_id', $uid)->exists();
        if ($shop->owner_id !== $uid && $role !== 'admin' && ! $isStaff) {
            return Json::error(403, 'not_owner', 'You do not own this shop.',
                (string) $r->header('X-Request-Id', ''));
        }

        $mediaHost = (string) env('MEDIA_GRPC_HOST', '');
        if ($mediaHost === '') {
            return Json::error(503, 'media_unavailable',
                'The Media service is not deployed; logo/banner uploads are temporarily disabled. '
                . 'See /health.checks.grpc_media for the diagnostic state.',
                (string) $r->header('X-Request-Id', ''));
        }
        // TODO: when Media lands, wire the gRPC client here. Return shape:
        //   { upload_url, key, expires_in, content_type, max_bytes }
        return Json::error(501, 'not_implemented',
            'Media gRPC client is wired but PresignUpload is not yet implemented in this image.',
            (string) $r->header('X-Request-Id', ''));
    }
}
