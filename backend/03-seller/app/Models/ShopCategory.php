<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class ShopCategory extends Model
{
    public $timestamps = true;
    public $incrementing = false;
    protected $keyType = 'string';
    protected $table = 'shop_categories';

    protected $fillable = ['id', 'name', 'scope', 'owner_id'];

    protected static function booted(): void
    {
        static::creating(function (ShopCategory $c) {
            if (empty($c->id)) {
                $c->id = (string) Str::uuid();
            }
            if (empty($c->scope)) {
                $c->scope = 'global';
            }
        });
    }
}
