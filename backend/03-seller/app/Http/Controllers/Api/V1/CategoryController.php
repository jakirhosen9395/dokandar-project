<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\ShopCategory;
use App\Support\Json;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Validator;
use Symfony\Component\HttpFoundation\Response;

/**
 * Shop categories per BUSINESS_LOGIC §4.1:
 *   - Admin defines globals (scope=global, owner_id=null)
 *   - Shopkeeper defines their own private (scope=private, owner_id=<user>)
 *   - Staff CANNOT define shop categories (returns 403)
 */
class CategoryController extends Controller
{
    public function index(Request $r): Response
    {
        $uid = (string) $r->attributes->get('user_id', '');
        $q = ShopCategory::query();
        if ($uid !== '') {
            $q->where(function ($q) use ($uid) {
                $q->where('scope', 'global')
                  ->orWhere(function ($q) use ($uid) {
                      $q->where('scope', 'private')->where('owner_id', $uid);
                  });
            });
        } else {
            $q->where('scope', 'global');
        }
        return Json::response(['categories' => $q->orderBy('name')->get()]);
    }

    public function store(Request $r): Response
    {
        $role = (string) $r->attributes->get('role', '');
        if (! in_array($role, ['admin', 'shopkeeper'], true)) {
            return Json::error(403, 'staff_cannot_define_shop_category',
                "Only admin or shopkeeper may define categories; got role '$role'.",
                (string) $r->header('X-Request-Id', ''));
        }
        $v = Validator::make($r->json()->all(), [
            'name'  => 'required|string|min:1|max:80',
            'scope' => 'nullable|in:global,private',
        ]);
        if ($v->fails()) {
            return Json::error(422, 'validation_error', 'invalid body',
                (string) $r->header('X-Request-Id', ''), $v->errors());
        }
        $scope = $r->json('scope', $role === 'admin' ? 'global' : 'private');
        if ($scope === 'global' && $role !== 'admin') {
            return Json::error(403, 'insufficient_role',
                'Only admin may define global categories.',
                (string) $r->header('X-Request-Id', ''));
        }
        // Race-safe insert: catch unique(scope,owner_id,name) violation → 409.
        try {
            $c = ShopCategory::create([
                'name'     => trim($r->json('name')),
                'scope'    => $scope,
                'owner_id' => $scope === 'private' ? $r->attributes->get('user_id') : null,
            ]);
        } catch (\Illuminate\Database\QueryException $e) {
            if ((string) $e->getCode() === '23505') {
                return Json::error(409, 'category_duplicate',
                    'A category with that name already exists in this scope.',
                    (string) $r->header('X-Request-Id', ''));
            }
            throw $e;
        }
        return Json::response(['category' => $c], 201);
    }
}
