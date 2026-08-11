<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

/**
 * v2.0 §14 bilingual content: Bangla shop name (`name_bn`) alongside the
 * existing English `name`. Mirrors catalog's name_bn/name_en support.
 */
return new class extends Migration
{
    public function up(): void
    {
        if (Schema::hasColumn('shops', 'name_bn')) {
            return;
        }
        Schema::table('shops', function (Blueprint $t) {
            $t->string('name_bn', 120)->nullable()->after('name');
        });
    }

    public function down(): void
    {
        if (! Schema::hasColumn('shops', 'name_bn')) {
            return;
        }
        Schema::table('shops', function (Blueprint $t) {
            $t->dropColumn('name_bn');
        });
    }
};
