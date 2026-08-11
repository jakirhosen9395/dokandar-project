<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

/**
 * Denormalised KYC tier per shopkeeper (v2.0 §15). Maintained by the
 * shop:consume-kyc-events Kafka consumer so storefront reads
 * (GET /shops/handle/{h}) render the Verified badge without calling auth.
 */
class ShopkeeperKycCache extends Model
{
    protected $table = 'shopkeeper_kyc_cache';
    protected $primaryKey = 'user_id';
    public $incrementing = false;
    protected $keyType = 'string';
    public $timestamps = false;

    protected $fillable = ['user_id', 'tier', 'last_updated_at'];
}
