<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Outbox extends Model
{
    public $timestamps = false;
    protected $table = 'outbox';

    protected $fillable = ['topic', 'key', 'payload', 'created_at', 'sent_at'];

    protected $casts = [
        'payload' => 'array',
        'created_at' => 'datetime',
        'sent_at' => 'datetime',
    ];
}
