<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Str;

class Shop extends Model
{
    public $timestamps = true;
    public $incrementing = false;
    protected $keyType = 'string';
    protected $table = 'shops';

    protected $fillable = [
        'id', 'owner_id', 'handle', 'name', 'name_bn', 'description', 'category_id',
        'logo_key', 'banner_key', 'contact_phone', 'contact_email',
        'address', 'lat', 'lon', 'status',
    ];

    protected $casts = [
        'address' => 'array',
        'lat' => 'float',
        'lon' => 'float',
    ];

    protected static function booted(): void
    {
        static::creating(function (Shop $s) {
            if (empty($s->id)) {
                $s->id = (string) Str::uuid();
            }
            if (empty($s->status)) {
                $s->status = 'draft';
            }
        });
    }
}
