<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class ShopStaff extends Model
{
    public $timestamps = false;
    public $incrementing = false;
    protected $keyType = 'string';
    protected $table = 'shop_staff';

    protected $fillable = ['id', 'shop_id', 'user_id', 'assigned_at'];

    protected $casts = [
        'assigned_at' => 'datetime',
    ];

    protected static function booted(): void
    {
        static::creating(function (ShopStaff $s) {
            if (empty($s->id)) {
                $s->id = (string) Str::uuid();
            }
            if (empty($s->assigned_at)) {
                $s->assigned_at = now();
            }
        });
    }
}
