<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * Bangladesh administrative areas (v2.0 §3.5) — reference data backing the
 * cascading Division → District → Upazila → Union/Thana address picker
 * (GET /admin-areas/*). Seeded by BdAdminAreasSeeder. Changes infrequently.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('bd_admin_areas')) {
            return;
        }
        Schema::create('bd_admin_areas', function (Blueprint $t) {
            $t->string('division', 40);
            $t->string('district', 60);
            $t->string('upazila', 80);
            $t->string('union_thana', 80);
            $t->double('lat_centroid')->nullable();
            $t->double('lon_centroid')->nullable();
            $t->primary(['division', 'district', 'upazila', 'union_thana']);
            $t->index('division');
            $t->index(['division', 'district']);
            $t->index(['division', 'district', 'upazila']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('bd_admin_areas');
    }
};
