<?php

namespace App\Http\Controllers;

use App\Support\BootTime;
use App\Support\Json;
use App\Support\Metrics;
use App\Support\Runtime;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use Symfony\Component\HttpFoundation\Response;

/**
 * Contract endpoints (/ready /health /data /metrics /openapi /docs).
 * Body shape matches docs/contracts/service-contract.md:
 *   /ready  → status + identity + traffic-gating deps (postgres always; redis when on the request path)
 *   /health → status + identity + ALL deps + observability block
 * Every JSON body is rendered through App\Support\Json (2-space indent,
 * unescaped unicode/slashes, trailing newline).
 */
class OpsController extends Controller
{
    private function identity(): array
    {
        return [
            'service_name'   => config('shop.identity.service_name'),
            'code_version'   => config('shop.identity.code_version'),
            'env_version'    => config('shop.identity.env_version'),
            'tenant'         => config('shop.identity.tenant'),
            'env'            => config('shop.identity.env'),
            'uptime_seconds' => BootTime::uptimeSeconds(),
        ];
    }

    public function ready(): Response
    {
        // §16-a: /ready gates traffic-BLOCKING deps only — PostgreSQL.
        // Redis (DB 2) is a degradable handle cache (miss → fall through to
        // Postgres), so it belongs on /health, NEVER on /ready.
        $deps = [
            $this->checkPostgres(),
        ];
        $allOk = ! in_array(false, array_column($deps, 'reachable'), true);
        return Json::response([
            'status'       => $allOk ? 'ready' : 'not_ready',
            'identity'     => $this->identity(),
            'dependencies' => $deps,
        ], $allOk ? 200 : 503);
    }

    public function health(): Response
    {
        $checks = [
            'postgres'   => $this->checkPostgresDetail(),
            'redis'      => $this->checkRedisDetail(),
            'kafka'      => $this->checkKafkaDetail(),
            'mongo_logs' => $this->checkMongoDetail(),
            'apm'        => $this->checkApmDetail(),
        ];
        // gRPC deps — diagnostic ONLY (never gate /ready or /health):
        //   grpc_auth   — wired (staff-assign verification),
        //   grpc_media  — not deployed → not_configured,
        //   grpc_coupon — not deployed → not_configured.
        $checks['grpc_auth']   = $this->checkGrpcDetail((string) config('shop.grpc.auth'), 'auth');
        $checks['grpc_media']  = $this->checkGrpcDetail((string) config('shop.grpc.media'), 'media');
        $checks['grpc_coupon'] = $this->checkGrpcDetail((string) config('shop.grpc.coupon'), 'coupon');

        // healthy = all CORE deps ok. The grpc_* checks are diagnostic.
        $core = array_diff_key($checks, ['grpc_auth' => 1, 'grpc_media' => 1, 'grpc_coupon' => 1]);
        $coreOks = array_map(fn ($c) => (bool) ($c['ok'] ?? false), $core);
        $healthy = ! in_array(false, $coreOks, true);

        return Json::response([
            'status'   => $healthy ? 'healthy' : 'unhealthy',
            'identity' => $this->identity(),
            'checks'   => $checks,
            'observability' => [
                'apm_service_name' => config('shop.apm.service_name'),
                'apm_server_url'   => config('shop.apm.server_url'),
                'logs_sink_mongo'  => 'mongodb://' . config('shop.logs.mongo_db') . '/' . config('shop.identity.service_name'),
                'logs_sink_es'     => config('shop.logs.es_url')
                    ? rtrim(config('shop.logs.es_url'), '/') . '/logs-app-' . config('shop.identity.service_name') . '-*'
                    : 'disabled',
            ],
        ], $healthy ? 200 : 503);
    }

    public function data(): Response
    {
        $tenant = config('shop.identity.tenant');
        $f = base_path("data/{$tenant}/result.json");
        if (! is_file($f)) {
            return Json::error(404, 'no_snapshot',
                "data/{$tenant}/result.json not present (run data/{$tenant}/collect.sh)", '');
        }
        $payload = json_decode(@file_get_contents($f), true);
        if (! is_array($payload)) {
            return Json::error(500, 'snapshot_parse_failed', 'invalid JSON', '');
        }
        // identity block first, then the collect.sh snapshot fields
        return Json::response(array_merge(['identity' => $this->identity()], $payload));
    }

    public function openapi(): Response
    {
        $i = $this->identity();
        $desc = sprintf(
            "**service_name**: `%s` &nbsp;|&nbsp; **code_version**: `%s` &nbsp;|&nbsp; **env_version**: `%s` &nbsp;|&nbsp; **tenant**: `%s` &nbsp;|&nbsp; **env**: `%s`\n\n".
            "### How to test\n".
            "1. Click **Authorize** and paste a Bearer **access token** from the auth service ".
            "(`POST /api/v1/auth/login/request` → `/login/verify`, or `/signup/verify`). Public reads ".
            "(`GET /shops/{id}`, `/shops/near`, `/shops/handle/{handle}`, `/categories`, `/admin-areas/*`) need no token.\n".
            "2. Request bodies are pre-filled with working examples. **`handle` must be globally unique** — change it on reruns (a repeat returns `409 handle_taken`).\n".
            "3. Only `shopkeeper`/`admin` can create shops/categories; `shop_staff` is restricted.",
            $i['service_name'], $i['code_version'], $i['env_version'], $i['tenant'], $i['env']
        );

        $bearer = [['bearerJwt' => []]];
        $uuidEx   = '11111111-1111-4111-8111-111111111111';
        $staffEx  = '22222222-2222-4222-8222-222222222222';

        // ---- builders ----------------------------------------------------
        $op = function (string $operationId, string $summary, string $tag, bool $secured, array $params = [], ?array $body = null, array $responses = []) use ($bearer) {
            $o = ['operationId' => $operationId, 'tags' => [$tag], 'summary' => $summary,
                  'responses' => $responses ?: ['200' => ['description' => 'OK']]];
            if ($secured) { $o['security'] = $bearer; }
            if ($params)  { $o['parameters'] = $params; }
            if ($body !== null) { $o['requestBody'] = $body; }
            return $o;
        };
        $body = fn (string $ref, array $ex) => [
            'required' => true,
            'content'  => ['application/json' => [
                'schema'  => ['$ref' => '#/components/schemas/' . $ref],
                'example' => $ex,
            ]],
        ];
        $pathP = fn (string $name, $ex, string $fmt = '') => [
            'name' => $name, 'in' => 'path', 'required' => true,
            'schema' => $fmt ? ['type' => 'string', 'format' => $fmt] : ['type' => 'string'],
            'example' => $ex,
        ];
        $queryP = fn (string $name, string $type, bool $req, $ex, string $desc = '') => array_filter([
            'name' => $name, 'in' => 'query', 'required' => $req,
            'schema' => ['type' => $type], 'example' => $ex,
            'description' => $desc,
        ], fn ($v) => $v !== '');
        $ok  = fn (string $code, string $d) => [$code => ['description' => $d]];
        $err = fn (string $code, string $d) => [$code => ['description' => $d,
            'content' => ['application/json' => ['schema' => ['$ref' => '#/components/schemas/ErrorEnvelope']]]]];

        // ---- request-body examples (prefill the Try-it-out box) ----------
        $shopCreateEx = [
            'handle' => 'my-shop-01', 'name' => 'My General Store', 'name_bn' => 'আমার দোকান',
            'description' => 'We sell everything you need', 'contact_phone' => '+8801712345678',
            'contact_email' => 'shop@example.com',
            'address' => ['division' => 'Dhaka', 'district' => 'Dhaka', 'upazila' => 'Gulshan'],
            'lat' => 23.8103, 'lon' => 90.4125,
        ];
        $shopPatchEx = ['name' => 'My Updated Store', 'description' => 'Now with more products', 'contact_phone' => '+8801712345678'];
        $categoryEx  = ['name' => 'Electronics', 'scope' => 'private'];
        $hoursEx     = ['hours' => [
            ['day_of_week' => 0, 'open_time' => '09:00:00', 'close_time' => '22:00:00', 'is_closed' => false],
            ['day_of_week' => 1, 'open_time' => '09:00:00', 'close_time' => '22:00:00', 'is_closed' => false],
            ['day_of_week' => 5, 'is_closed' => true],
        ]];
        $staffAssignEx = ['user_id' => $staffEx];

        // ---- schemas -----------------------------------------------------
        $schemas = [
            'ShopCreate' => [
                'type' => 'object', 'required' => ['handle', 'name'],
                'properties' => [
                    'handle'        => ['type' => 'string', 'description' => 'unique, ^[a-z0-9-]+$, 3–60', 'example' => 'my-shop-01'],
                    'name'          => ['type' => 'string', 'example' => 'My General Store'],
                    'name_bn'       => ['type' => 'string', 'nullable' => true, 'example' => 'আমার দোকান'],
                    'description'   => ['type' => 'string', 'nullable' => true],
                    'category_id'   => ['type' => 'string', 'format' => 'uuid', 'nullable' => true],
                    'contact_phone' => ['type' => 'string', 'nullable' => true, 'example' => '+8801712345678'],
                    'contact_email' => ['type' => 'string', 'format' => 'email', 'nullable' => true],
                    'address'       => ['type' => 'object', 'additionalProperties' => true],
                    'lat'           => ['type' => 'number', 'format' => 'double', 'nullable' => true, 'example' => 23.8103],
                    'lon'           => ['type' => 'number', 'format' => 'double', 'nullable' => true, 'example' => 90.4125],
                ],
            ],
            'ShopPatch' => [
                'type' => 'object',
                'properties' => [
                    'name'          => ['type' => 'string'],
                    'name_bn'       => ['type' => 'string', 'nullable' => true],
                    'description'   => ['type' => 'string', 'nullable' => true],
                    'category_id'   => ['type' => 'string', 'format' => 'uuid', 'nullable' => true],
                    'contact_phone' => ['type' => 'string', 'nullable' => true],
                    'contact_email' => ['type' => 'string', 'format' => 'email', 'nullable' => true],
                    'address'       => ['type' => 'object', 'additionalProperties' => true],
                    'lat'           => ['type' => 'number', 'format' => 'double', 'nullable' => true],
                    'lon'           => ['type' => 'number', 'format' => 'double', 'nullable' => true],
                    'logo_key'      => ['type' => 'string', 'nullable' => true],
                    'banner_key'    => ['type' => 'string', 'nullable' => true],
                    'status'        => ['type' => 'string', 'enum' => ['draft', 'live', 'paused', 'suspended', 'closed']],
                ],
            ],
            'CategoryCreate' => [
                'type' => 'object', 'required' => ['name'],
                'properties' => [
                    'name'  => ['type' => 'string', 'example' => 'Electronics'],
                    'scope' => ['type' => 'string', 'enum' => ['global', 'private'], 'description' => 'global is admin-only', 'example' => 'private'],
                ],
            ],
            'HoursReplace' => [
                'type' => 'object', 'required' => ['hours'],
                'properties' => ['hours' => [
                    'type' => 'array',
                    'items' => [
                        'type' => 'object', 'required' => ['day_of_week'],
                        'properties' => [
                            'day_of_week' => ['type' => 'integer', 'minimum' => 0, 'maximum' => 6, 'description' => '0=Sun … 6=Sat'],
                            'open_time'   => ['type' => 'string', 'example' => '09:00:00'],
                            'close_time'  => ['type' => 'string', 'example' => '22:00:00'],
                            'is_closed'   => ['type' => 'boolean'],
                        ],
                    ],
                ]],
            ],
            'StaffAssign' => [
                'type' => 'object', 'required' => ['user_id'],
                'properties' => ['user_id' => ['type' => 'string', 'format' => 'uuid',
                    'description' => 'an auth user with role shop_staff owned by this shopkeeper', 'example' => $staffEx]],
            ],
            'ErrorEnvelope' => [
                'type' => 'object',
                'required' => ['error'],
                'properties' => ['error' => [
                    'type' => 'object',
                    'required' => ['code', 'message', 'request_id'],
                    'properties' => [
                        'code'       => ['type' => 'string', 'description' => 'stable lowercase_snake machine code', 'example' => 'validation_error'],
                        'message'    => ['type' => 'string', 'description' => 'human-readable (scrubbed) message', 'example' => 'shop handle already in use'],
                        'request_id' => ['type' => 'string', 'description' => 'honour-or-mint x-request-id', 'example' => '11111111-1111-4111-8111-111111111111'],
                        'details'    => ['type' => 'object', 'additionalProperties' => true, 'description' => 'optional structured context', 'example' => new \stdClass()],
                    ],
                ]],
            ],
        ];

        $auth401 = $err('401', 'token_missing / token_invalid');

        $paths = [
            '/ready'   => ['get' => $op('opsReady', 'Readiness probe (postgres only)', 'ops', false, [], null, $ok('200', 'ready') + $ok('503', 'not_ready'))],
            '/health'  => ['get' => $op('opsHealth', 'Full health + dependency checks', 'ops', false, [], null, $ok('200', 'healthy') + $ok('503', 'unhealthy'))],
            '/data'    => ['get' => $op('opsData', 'Table counts + host snapshot', 'ops', false, [], null, $ok('200', 'snapshot') + $err('404', 'no_snapshot'))],
            '/metrics' => ['get' => $op('opsMetrics', 'Prometheus metrics', 'ops', false, [], null, $ok('200', 'exposition'))],

            // ---- public reads ----
            '/api/v1/shop/categories' => [
                'get'  => $op('listCategories', 'List shop categories', 'categories', false, [], null, $ok('200', '{categories:[…]}')),
                'post' => $op('createCategory', 'Create a category (admin/shopkeeper)', 'categories', true, [], $body('CategoryCreate', $categoryEx),
                    $ok('201', 'created') + $auth401 + $err('403', 'staff_cannot_define_shop_category / insufficient_role') + $err('409', 'category_duplicate') + $err('422', 'validation_error')),
            ],
            '/api/v1/shop/admin-areas/divisions' => [
                'get' => $op('listDivisions', 'BD divisions (cascading address picker)', 'admin-areas', false, [], null, $ok('200', '{items:[…]}')),
            ],
            '/api/v1/shop/admin-areas/{division}/districts' => [
                'get' => $op('listDistricts', 'Districts under a division', 'admin-areas', false, [$pathP('division', 'Dhaka')], null, $ok('200', '{items:[…]}')),
            ],
            '/api/v1/shop/admin-areas/{division}/{district}/upazilas' => [
                'get' => $op('listUpazilas', 'Upazilas under a district', 'admin-areas', false, [$pathP('division', 'Dhaka'), $pathP('district', 'Dhaka')], null, $ok('200', '{items:[…]}')),
            ],
            '/api/v1/shop/admin-areas/{division}/{district}/{upazila}/unions' => [
                'get' => $op('listUnions', 'Unions under an upazila', 'admin-areas', false, [$pathP('division', 'Dhaka'), $pathP('district', 'Dhaka'), $pathP('upazila', 'Gulshan')], null, $ok('200', '{items:[…]}')),
            ],
            '/api/v1/shop/shops/near' => [
                'get' => $op('listNearbyShops', 'Nearby live shops (geo)', 'shops', false, [
                    $queryP('lat', 'number', true, 23.8103, 'latitude -90..90'),
                    $queryP('lon', 'number', true, 90.4125, 'longitude -180..180'),
                    $queryP('radius_m', 'number', false, 5000, 'metres, default 2000'),
                    $queryP('limit', 'integer', false, 20, 'default 20, max 100'),
                ], null, $ok('200', '{lat,lon,radius_m,count,shops[]}') + $err('422', 'validation_error')),
            ],
            '/api/v1/shop/shops/handle/{handle}' => [
                'get' => $op('getShopByHandle', 'Public shop by handle', 'shops', false, [$pathP('handle', 'my-shop-01')], null, $ok('200', 'shop (PII stripped)') + $err('404', 'shop_not_found')),
            ],
            '/api/v1/shop/shops/{id}/hours' => [
                'get' => $op('getShopHours', 'Shop opening hours', 'hours', false, [$pathP('id', $uuidEx, 'uuid')], null, $ok('200', '{hours:[…]}') + $err('404', 'shop_not_found')),
                'put' => $op('replaceShopHours', 'Replace opening hours (owner/staff/admin)', 'hours', true, [$pathP('id', $uuidEx, 'uuid')], $body('HoursReplace', $hoursEx),
                    $ok('200', '{hours:[…]}') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found') + $err('422', 'validation_error')),
            ],
            '/api/v1/shop/shops/{id}' => [
                'get'    => $op('getShop', 'Public shop by id', 'shops', false, [$pathP('id', $uuidEx, 'uuid')], null, $ok('200', 'shop (PII stripped)') + $err('404', 'shop_not_found')),
                'patch'  => $op('updateShop', 'Update a shop (owner/admin)', 'shops', true, [$pathP('id', $uuidEx, 'uuid')], $body('ShopPatch', $shopPatchEx),
                    $ok('200', 'updated shop') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found') + $err('422', 'validation_error / invalid_status_transition')),
                'delete' => $op('closeShop', 'Close a shop (owner/admin)', 'shops', true, [$pathP('id', $uuidEx, 'uuid')], null,
                    $ok('204', 'closed') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found')),
            ],
            '/api/v1/shop/shops' => [
                'get'  => $op('listShops', 'List my shops (admin: all)', 'shops', true, [], null, $ok('200', '{shops:[…]}') + $auth401),
                'post' => $op('createShop', 'Create a shop (shopkeeper/admin)', 'shops', true, [], $body('ShopCreate', $shopCreateEx),
                    $ok('201', 'created (status=draft)') + $auth401 + $err('403', 'insufficient_role') + $err('409', 'handle_taken') + $err('422', 'validation_error')),
            ],
            '/api/v1/shop/shops/{id}/activate' => [
                'post' => $op('activateShop', 'Activate a shop → live (owner/admin)', 'shops', true, [$pathP('id', $uuidEx, 'uuid')], null,
                    $ok('200', 'shop (status=live)') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found') + $err('422', 'invalid_status_transition')),
            ],
            '/api/v1/shop/shops/{id}/staff' => [
                'post' => $op('assignShopStaff', 'Assign shop staff (owner/admin)', 'staff', true, [$pathP('id', $uuidEx, 'uuid')], $body('StaffAssign', $staffAssignEx),
                    $ok('201', 'assigned') + $auth401 + $err('403', 'not_owner / cross_owner_staff') + $err('404', 'shop_not_found') + $err('409', 'already_assigned') + $err('422', 'validation_error / not_shop_staff_role')),
            ],
            '/api/v1/shop/shops/{id}/staff/{userId}' => [
                'delete' => $op('removeShopStaff', 'Remove shop staff (owner/admin)', 'staff', true, [$pathP('id', $uuidEx, 'uuid'), $pathP('userId', $staffEx, 'uuid')], null,
                    $ok('204', 'removed (idempotent)') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found')),
            ],
            '/api/v1/shop/shops/{id}/logo' => [
                'post' => $op('presignShopLogo', 'Presign a logo upload (owner/staff/admin)', 'media', true, [$pathP('id', $uuidEx, 'uuid')], null,
                    $ok('200', '{upload_url,key,…}') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found') + $err('503', 'media_unavailable')),
            ],
            '/api/v1/shop/shops/{id}/banner' => [
                'post' => $op('presignShopBanner', 'Presign a banner upload (owner/staff/admin)', 'media', true, [$pathP('id', $uuidEx, 'uuid')], null,
                    $ok('200', '{upload_url,key,…}') + $auth401 + $err('403', 'not_owner') + $err('404', 'shop_not_found') + $err('503', 'media_unavailable')),
            ],

            // ---- backwards-compat aliases ----
            '/api/v1/shop/me' => [
                'get'  => $op('listMyShopsAlias', 'Alias of GET /shops (list mine)', 'compat', true, [], null, $ok('200', '{shops:[…]}') + $auth401),
                'post' => $op('createShopAlias', 'Alias of POST /shops (create)', 'compat', true, [], $body('ShopCreate', $shopCreateEx),
                    $ok('201', 'created') + $auth401 + $err('409', 'handle_taken') + $err('422', 'validation_error')),
            ],
            '/api/v1/shop/{id}' => [
                'get' => $op('getShopAlias', 'Alias of GET /shops/{id}', 'compat', false, [$pathP('id', $uuidEx, 'uuid')], null, $ok('200', 'shop') + $err('404', 'shop_not_found')),
                'put' => $op('updateShopAlias', 'Alias of PATCH /shops/{id}', 'compat', true, [$pathP('id', $uuidEx, 'uuid')], $body('ShopPatch', $shopPatchEx),
                    $ok('200', 'updated shop') + $auth401 + $err('404', 'shop_not_found') + $err('422', 'validation_error')),
            ],
            '/api/v1/shop/{id}/activate' => [
                'post' => $op('activateShopAlias', 'Alias of POST /shops/{id}/activate', 'compat', true, [$pathP('id', $uuidEx, 'uuid')], null,
                    $ok('200', 'shop (status=live)') + $auth401 + $err('404', 'shop_not_found') + $err('422', 'invalid_status_transition')),
            ],
        ];

        return Json::response([
            'openapi' => '3.0.3',
            'info' => [
                'title'       => 'DOKANDAR Seller Service',
                'version'     => $i['code_version'],
                'description' => $desc,
                'contact'     => [
                    'name'  => 'DOKANDAR Platform',
                    'url'   => 'https://dokandar.com.bd',
                    'email' => 'api@dokandar.com.bd',
                ],
                'license'     => ['name' => 'Proprietary'],
            ],
            'servers' => [
                ['url' => 'https://api.dokandar.com.bd', 'description' => 'prod'],
                ['url' => 'http://localhost:10003', 'description' => 'local'],
            ],
            'tags' => [
                ['name' => 'ops', 'description' => 'Operational / contract surface'],
                ['name' => 'shops', 'description' => 'Shop lifecycle'],
                ['name' => 'categories', 'description' => 'Shop categories'],
                ['name' => 'hours', 'description' => 'Opening hours'],
                ['name' => 'staff', 'description' => 'Shop staff assignment'],
                ['name' => 'media', 'description' => 'Logo / banner presign (via Media gRPC)'],
                ['name' => 'admin-areas', 'description' => 'Public BD geo picker'],
                ['name' => 'compat', 'description' => 'Backwards-compat aliases'],
            ],
            'components' => [
                'securitySchemes' => [
                    'bearerJwt' => ['type' => 'http', 'scheme' => 'bearer', 'bearerFormat' => 'JWT'],
                ],
                'schemas' => $schemas,
            ],
            'paths' => $paths,
        ]);
    }

    public function docs(): Response
    {
        $html = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>03-seller API</title>'
            . '<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head>'
            . '<body><div id="swagger-ui"></div>'
            . '<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>'
            . '<script>window.ui = SwaggerUIBundle({ url: "/openapi.json", dom_id: "#swagger-ui", deepLinking: true, persistAuthorization: true });</script>'
            . '</body></html>';
        return new Response($html, 200, ['Content-Type' => 'text/html; charset=utf-8']);
    }

    public function metrics(): Response
    {
        try {
            $pending = (int) DB::table('outbox')->whereNull('sent_at')->count();
            Metrics::outboxPending()->set($pending, [Metrics::svc()]);
        } catch (\Throwable $e) {
            // DB hiccup must not break /metrics.
        }
        return new Response(Metrics::render(), 200, [
            'Content-Type' => 'text/plain; version=0.0.4; charset=utf-8',
        ]);
    }

    // ---- probes -----------------------------------------------------------

    private function checkPostgres(): array
    {
        // wrapSpan emits the friendly "postgres" dependency span (subtype postgresql) via the manual
        // ElasticApm span API. Liveness uses getPdo() — forcing the PDO connection round-trips Laravel's
        // `set search_path` to PostgreSQL (a real liveness probe) without an EXTRA table-less SELECT that
        // the agent also can't name. NOTE: the elastic_apm PHP agent (C extension) auto-instruments every
        // PDO statement and labels its destination "unknown_DB" — it cannot resolve the pgsql driver from
        // Laravel's wrapped PDO, and the agent exposes NO span-filter/processor API (unlike the Node/Ruby/
        // Python agents) to rename it. See the BLOCKED_BY_AGENT_LIMITATION note in the audit; the DB
        // dependency is still correctly represented as "postgres" via this wrapSpan.
        return $this->wrapSpan('dep.postgres', 'db', 'postgresql', 'postgres', function () {
            $t = microtime(true);
            try {
                DB::connection()->getPdo();
                return ['name' => 'postgres', 'reachable' => true, 'latency_ms' => $this->ms($t)];
            } catch (\Throwable $e) {
                return ['name' => 'postgres', 'reachable' => false, 'latency_ms' => $this->ms($t)];
            }
        });
    }

    private function checkPostgresDetail(): array
    {
        return $this->wrapSpan('dep.postgres', 'db', 'postgresql', 'postgres', function () {
            try {
                DB::connection()->getPdo();
                return ['ok' => true, 'detail' => 'ok'];
            } catch (\Throwable $e) {
                return ['ok' => false, 'detail' => substr($e->getMessage(), 0, 80)];
            }
        });
    }

    private function checkRedis(): array
    {
        return $this->wrapSpan('dep.redis', 'cache', 'redis', 'redis', function () {
            $t = microtime(true);
            try {
                Redis::connection()->ping();
                return ['name' => 'redis', 'reachable' => true, 'latency_ms' => $this->ms($t)];
            } catch (\Throwable $e) {
                return ['name' => 'redis', 'reachable' => false, 'latency_ms' => $this->ms($t)];
            }
        });
    }

    private function checkRedisDetail(): array
    {
        return $this->wrapSpan('dep.redis', 'cache', 'redis', 'redis', function () {
            try {
                Redis::connection()->ping();
                return ['ok' => true, 'detail' => 'PONG'];
            } catch (\Throwable $e) {
                return ['ok' => false, 'detail' => substr($e->getMessage(), 0, 80)];
            }
        });
    }

    private function checkKafkaDetail(): array
    {
        return $this->wrapSpan('dep.kafka', 'messaging', 'kafka', 'kafka', function () {
            $bs = config('shop.kafka.bootstrap');
            if (empty($bs)) return ['ok' => false, 'detail' => 'KAFKA_BOOTSTRAP unset'];
            [$host, $port] = array_pad(explode(':', $bs, 2), 2, '9092');
            $errno = 0; $errstr = '';
            $s = @fsockopen($host, (int) $port, $errno, $errstr, 1.5);
            if (! $s) return ['ok' => false, 'detail' => $errstr ?: "errno $errno"];
            fclose($s);
            return ['ok' => true, 'detail' => 'tcp-ok'];
        });
    }

    private function checkMongoDetail(): array
    {
        return $this->wrapSpan('dep.mongo_logs', 'db', 'mongodb', 'mongo_logs', function () {
            $uri = config('shop.logs.mongo_uri');
            if (empty($uri)) return ['ok' => false, 'detail' => 'MONGO_LOG_URI unset'];
            try {
                $cli = new \MongoDB\Client($uri, ['serverSelectionTimeoutMS' => 1500]);
                $cli->selectDatabase('admin')->command(['ping' => 1]);
                return ['ok' => true, 'detail' => 'ping-ok'];
            } catch (\Throwable $e) {
                return ['ok' => false, 'detail' => substr($e->getMessage(), 0, 80)];
            }
        });
    }

    private function checkApmDetail(): array
    {
        // dep.apm passes null resource so the Service Map doesn't draw a self-loop.
        return $this->wrapSpan('dep.apm', 'external', 'apm-server', null, function () {
            [$ok, $detail] = Runtime::probeApm(config('shop.apm.server_url') ?? '');
            return ['ok' => $ok, 'detail' => $detail];
        });
    }

    /** Generic gRPC diagnostic: TCP-reachability of a host:port, or not_configured. */
    private function checkGrpcDetail(string $hostPort, string $resource): array
    {
        return $this->wrapSpan("dep.grpc_$resource", 'external', 'grpc', $resource, function () use ($hostPort) {
            if ($hostPort === '') return ['ok' => false, 'detail' => 'not_configured'];
            [$host, $port] = array_pad(explode(':', $hostPort, 2), 2, '50051');
            $errno = 0; $errstr = '';
            $s = @fsockopen($host, (int) $port, $errno, $errstr, 1.5);
            if (! $s) return ['ok' => false, 'detail' => $errstr ?: "errno $errno"];
            fclose($s);
            return ['ok' => true, 'detail' => "$hostPort tcp-ok"];
        });
    }

    private function ms(float $t): float { return round((microtime(true) - $t) * 1000, 1); }

    private function wrapSpan(string $name, string $type, string $subtype, ?string $resource, \Closure $fn)
    {
        if (! class_exists('\Elastic\Apm\ElasticApm')) {
            return $fn();
        }
        try {
            $tx = \Elastic\Apm\ElasticApm::getCurrentTransaction();
            $span = $tx->beginCurrentSpan($name, $type, $subtype);
            if ($resource !== null) {
                $span->context()->destination()->setService($resource, $resource, $subtype);
                $span->context()->service()->target()->setName($resource);
                $span->context()->service()->target()->setType($subtype);
            }
            try {
                return $fn();
            } finally {
                $span->end();
            }
        } catch (\Throwable $e) {
            return $fn();
        }
    }
}
