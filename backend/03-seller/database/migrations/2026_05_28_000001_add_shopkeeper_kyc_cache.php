<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Denormalised shopkeeper KYC tier cache (v2.0 §15). Populated by the
 * shop:consume-kyc-events consumer from auth's dokandar.kyc.approved /
 * dokandar.kyc.rejected events.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasTable('shopkeeper_kyc_cache')) {
            return;
        }
        Schema::create('shopkeeper_kyc_cache', function (Blueprint $t) {
            $t->uuid('user_id')->primary();
            $t->string('tier', 20)->default('unverified');
            $t->timestampTz('last_updated_at')->default(DB::raw('now()'));
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('shopkeeper_kyc_cache');
    }
};
