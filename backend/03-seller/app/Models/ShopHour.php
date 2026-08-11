<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class ShopHour extends Model
{
    public $timestamps = false;
    public $incrementing = false;
    protected $keyType = 'string';
    protected $table = 'shop_hours';

    protected $fillable = ['id', 'shop_id', 'day_of_week', 'open_time', 'close_time', 'is_closed'];

    protected $casts = [
        'day_of_week' => 'integer',
        'is_closed'   => 'boolean',
    ];

    protected static function booted(): void
    {
        static::creating(function (ShopHour $h) {
            if (empty($h->id)) {
                $h->id = (string) Str::uuid();
            }
        });
    }
}
