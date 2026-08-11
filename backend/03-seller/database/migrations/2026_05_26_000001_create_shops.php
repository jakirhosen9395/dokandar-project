<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Shop schema. Plain lat/lon for the first cut — PostGIS-based "near me"
 * comes when Search is built. owner_id mirrors Auth's users.id without
 * a cross-service FK (consistency is asynchronous via Kafka events).
 */
return new class extends Migration
{
    public function up(): void
    {
        DB::statement('CREATE EXTENSION IF NOT EXISTS pgcrypto');

        // The shop_status enum is declared inline; we don't use Postgres native
        // ENUMs to keep the migration portable across stages.
        Schema::create('shop_categories', function ($table) {
            $table->uuid('id')->primary()->default(DB::raw('gen_random_uuid()'));
            $table->string('name', 80);
            // 'global' (admin-defined, available to all shopkeepers) or
            // 'private' (a single shopkeeper's category, scoped to owner_id).
            $table->string('scope', 10)->default('global');
            $table->uuid('owner_id')->nullable(); // null for global scope
            $table->timestamps();
            $table->unique(['scope', 'owner_id', 'name']);
        });

        Schema::create('shops', function ($table) {
            $table->uuid('id')->primary()->default(DB::raw('gen_random_uuid()'));
            $table->uuid('owner_id');                      // shopkeeper user_id from Auth
            $table->string('handle', 60)->unique();        // dokandar.com/shops/<handle>
            $table->string('name', 120);
            $table->text('description')->nullable();
            $table->uuid('category_id')->nullable();
            $table->string('logo_key', 255)->nullable();   // S3 key (Media issues)
            $table->string('banner_key', 255)->nullable();
            $table->string('contact_phone', 20)->nullable();
            $table->string('contact_email', 255)->nullable();
            $table->jsonb('address')->nullable();
            $table->double('lat')->nullable();
            $table->double('lon')->nullable();
            // Lifecycle: draft → live → paused → live | suspended | closed
            $table->string('status', 20)->default('draft');
            $table->timestamps();
            $table->index('owner_id');
            $table->index('status');
        });

        Schema::create('outbox', function ($table) {
            $table->bigIncrements('id');
            $table->string('topic', 120);
            $table->string('key', 120)->nullable();
            $table->jsonb('payload');
            $table->timestamp('created_at')->default(DB::raw('now()'));
            $table->timestamp('sent_at')->nullable();
            $table->index(['sent_at', 'id']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('outbox');
        Schema::dropIfExists('shops');
        Schema::dropIfExists('shop_categories');
    }
};
