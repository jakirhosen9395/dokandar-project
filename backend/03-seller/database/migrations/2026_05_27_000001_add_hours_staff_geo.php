<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Adds the rest of the shop-service schema per docs/services/shop.md §4:
 *   - shop_hours  (operating hours, one row per day per shop)
 *   - shop_staff  (staff↔shop assignment, multi-shop per staff)
 *   - cube + earthdistance extensions for the "near me" radius search
 *     (PostGIS isn't available in the components postgres image, but
 *     earthdistance is — same metres-based distance API).
 */
return new class extends Migration
{
    public function up(): void
    {
        DB::statement('CREATE EXTENSION IF NOT EXISTS cube');
        DB::statement('CREATE EXTENSION IF NOT EXISTS earthdistance');

        Schema::create('shop_hours', function ($table) {
            $table->uuid('id')->primary()->default(DB::raw('gen_random_uuid()'));
            $table->uuid('shop_id');
            // 0 = Sunday … 6 = Saturday.
            $table->smallInteger('day_of_week');
            $table->time('open_time')->nullable();
            $table->time('close_time')->nullable();
            $table->boolean('is_closed')->default(false);
            // Single-row-per-day invariant (split hours are explicitly out of
            // scope for v1 per the spec's edge-cases table).
            $table->unique(['shop_id', 'day_of_week']);
            $table->index('shop_id');
            $table->foreign('shop_id')->references('id')->on('shops')->cascadeOnDelete();
        });

        Schema::create('shop_staff', function ($table) {
            $table->uuid('id')->primary()->default(DB::raw('gen_random_uuid()'));
            $table->uuid('shop_id');
            $table->uuid('user_id'); // shop_staff user id from Auth (no FK)
            $table->timestampTz('assigned_at')->default(DB::raw('now()'));
            $table->unique(['shop_id', 'user_id']);
            $table->index('user_id');
            $table->foreign('shop_id')->references('id')->on('shops')->cascadeOnDelete();
        });

        // Btree pre-filter for the "near me" bounding box. The exact metres
        // distance is computed via earth_distance(ll_to_earth(...), ll_to_earth(...)).
        DB::statement('CREATE INDEX IF NOT EXISTS idx_shops_lat_lon ON shops (lat, lon) WHERE status = \'live\'');
    }

    public function down(): void
    {
        Schema::dropIfExists('shop_staff');
        Schema::dropIfExists('shop_hours');
        DB::statement('DROP INDEX IF EXISTS idx_shops_lat_lon');
        // We leave the extensions in place — they're cheap and may be in use
        // by other migrations/teams on the shared postgres instance.
    }
};
