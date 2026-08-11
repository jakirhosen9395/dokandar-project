<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * BD administrative area row (full Division→District→Upazila→Union path).
 * Composite-keyed reference table; read-only at runtime (seeded once).
 */
class BdAdminArea extends Model
{
    protected $table = 'bd_admin_areas';
    public $incrementing = false;
    public $timestamps = false;

    protected $fillable = [
        'division', 'district', 'upazila', 'union_thana',
        'lat_centroid', 'lon_centroid',
    ];

    protected $casts = [
        'lat_centroid' => 'float',
        'lon_centroid' => 'float',
    ];
}
