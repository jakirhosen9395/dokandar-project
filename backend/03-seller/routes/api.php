<?php

use App\Http\Controllers\Api\V1\AdminAreasController;
use App\Http\Controllers\Api\V1\CategoryController;
use App\Http\Controllers\Api\V1\ShopController;
use App\Http\Controllers\Api\V1\ShopHoursController;
use App\Http\Controllers\Api\V1\ShopStaffController;
use App\Http\Controllers\Api\V1\ShopGeoController;
use App\Http\Controllers\Api\V1\ShopMediaController;
use App\Http\Controllers\OpsController;
use App\Http\Middleware\VerifyJwt;
use Illuminate\Support\Facades\Route;

/*
| The Shop service exposes:
|   - 6 contract endpoints (/ready /health /data /metrics /openapi.json /docs)
|   - business APIs under /api/v1/shop/*  (full surface per docs/services/shop.md)
| Any other path is intercepted by the bare-404 handler in bootstrap/app.php.
|
| Boot time is read from /tmp/dokandar-seller.boot (written once by the runtime
| at start) via App\Support\BootTime — using microtime() here would reset
| every request (php -S / php-fpm is request-per-process).
*/

Route::get('/ready',        [OpsController::class, 'ready']);
Route::get('/health',       [OpsController::class, 'health']);
Route::get('/data',         [OpsController::class, 'data']);
Route::get('/metrics',      [OpsController::class, 'metrics']);
Route::get('/openapi.json', [OpsController::class, 'openapi']);
Route::get('/docs',         [OpsController::class, 'docs']);

// UUID constraint pattern — prevents "/api/v1/shop/shops" being interpreted
// as `/{id}=shops` and crashing on UUID validation.
$uuid = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
$handle = '[a-z0-9-]+';

// --- public reads (no JWT required) ---
Route::get('/api/v1/shop/categories',                  [CategoryController::class, 'index']);

// BD admin-area cascading picker (Division → District → Upazila → Union).
Route::get('/api/v1/shop/admin-areas/divisions',                          [AdminAreasController::class, 'divisions']);
Route::get('/api/v1/shop/admin-areas/{division}/districts',               [AdminAreasController::class, 'districts']);
Route::get('/api/v1/shop/admin-areas/{division}/{district}/upazilas',     [AdminAreasController::class, 'upazilas']);
Route::get('/api/v1/shop/admin-areas/{division}/{district}/{upazila}/unions', [AdminAreasController::class, 'unions']);
Route::get('/api/v1/shop/shops/near',                  [ShopGeoController::class, 'near']);
Route::get('/api/v1/shop/shops/handle/{handle}',       [ShopController::class, 'showByHandle'])
    ->where('handle', $handle);
Route::get('/api/v1/shop/shops/{id}/hours',            [ShopHoursController::class, 'show'])
    ->where('id', $uuid);
Route::get('/api/v1/shop/shops/{id}',                  [ShopController::class, 'show'])
    ->where('id', $uuid);
// Backwards-compat: GET by id without the /shops/ segment.
Route::get('/api/v1/shop/{id}',                        [ShopController::class, 'show'])
    ->where('id', $uuid);

// --- authenticated routes ---
Route::middleware([VerifyJwt::class])->group(function () use ($uuid) {
    // Categories
    Route::post('/api/v1/shop/categories',             [CategoryController::class, 'store']);

    // Spec routes — /shops/* surface
    Route::get( '/api/v1/shop/shops',                  [ShopController::class, 'listMine']);
    Route::post('/api/v1/shop/shops',                  [ShopController::class, 'create']);
    Route::patch('/api/v1/shop/shops/{id}',            [ShopController::class, 'patch'])
        ->where('id', $uuid);
    Route::delete('/api/v1/shop/shops/{id}',           [ShopController::class, 'destroy'])
        ->where('id', $uuid);
    Route::post('/api/v1/shop/shops/{id}/activate',    [ShopController::class, 'activate'])
        ->where('id', $uuid);

    // Hours
    Route::put('/api/v1/shop/shops/{id}/hours',        [ShopHoursController::class, 'replace'])
        ->where('id', $uuid);

    // Staff
    Route::post('/api/v1/shop/shops/{id}/staff',       [ShopStaffController::class, 'assign'])
        ->where('id', $uuid);
    Route::delete('/api/v1/shop/shops/{id}/staff/{userId}', [ShopStaffController::class, 'remove'])
        ->where(['id' => $uuid, 'userId' => $uuid]);

    // Media (logo + banner) — gRPC client to Media; 503 when Media isn't deployed.
    Route::post('/api/v1/shop/shops/{id}/logo',        [ShopMediaController::class, 'presignLogo'])
        ->where('id', $uuid);
    Route::post('/api/v1/shop/shops/{id}/banner',      [ShopMediaController::class, 'presignBanner'])
        ->where('id', $uuid);

    // Backwards-compat aliases — same handlers as /shops above.
    Route::get( '/api/v1/shop/me',                     [ShopController::class, 'listMine']);
    Route::post('/api/v1/shop/me',                     [ShopController::class, 'create']);
    Route::put( '/api/v1/shop/{id}',                   [ShopController::class, 'update'])
        ->where('id', $uuid);
    Route::post('/api/v1/shop/{id}/activate',          [ShopController::class, 'activate'])
        ->where('id', $uuid);
});
