<?php

namespace App\Console\Commands;

use App\Models\Shop;
use App\Models\ShopkeeperKycCache;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Facades\Redis;

/**
 * KYC denormalisation consumer (v2.0 §15). Subscribes to auth's KYC events
 * and maintains shopkeeper_kyc_cache so storefront reads render the Verified
 * badge without a synchronous call to auth.
 *
 * Raw librdkafka consumer (mirrors RelayOutbox's producer pattern). Group
 * `shop` so it gets an independent copy of the events. If rdkafka is not
 * present the command stays alive as a no-op so docker doesn't restart it.
 */
class ConsumeKycEvents extends Command
{
    protected $signature = 'shop:consume-kyc-events';
    protected $description = 'Consume auth KYC events → denormalise shopkeeper_kyc_cache.';

    public function handle(): int
    {
        $bootstrap = config('shop.kafka.bootstrap');
        if (empty($bootstrap)) {
            Log::warning('kyc-consumer: KAFKA_BOOTSTRAP empty — consumer stopped', ['name' => 'seller.kafka']);
            return 0;
        }
        if (! extension_loaded('rdkafka')) {
            Log::warning('kyc-consumer: rdkafka extension not loaded — consumer is a no-op', ['name' => 'seller.kafka']);
            while (true) {
                sleep(60);
            }
        }

        $approved = config('shop.kafka.topic_kyc_approved');
        $rejected = config('shop.kafka.topic_kyc_rejected');
        $group    = config('shop.kafka.consumer_group', 'seller');

        $conf = new \RdKafka\Conf();
        $conf->set('bootstrap.servers', $bootstrap);
        $conf->set('group.id', $group);
        $conf->set('auto.offset.reset', 'earliest');
        // §16-d: manual commit AFTER a successful handle (commit-after-handle).
        // The reference used enable.auto.commit=true → at-most-once on a crash
        // mid-handle. We commit the offset only once process() succeeds.
        $conf->set('enable.auto.commit', 'false');

        $consumer = new \RdKafka\KafkaConsumer($conf);
        $consumer->subscribe([$approved, $rejected]);

        Log::info('kafka: kyc consumer started', [
            'name'    => 'shop.kafka',
            'topics'  => [$approved, $rejected],
            'group'   => $group,
            'brokers' => [$bootstrap],
        ]);

        while (true) {
            $msg = $consumer->consume(1000);
            // Some librdkafka/php-rdkafka builds return null on an idle poll
            // (instead of a TIMED_OUT message); guard so the loop never crashes.
            if ($msg === null) { usleep(200000); continue; }
            switch ($msg->err) {
                case RD_KAFKA_RESP_ERR_NO_ERROR:
                    // §16-d: commit the offset ONLY after a successful handle.
                    // A failed handle is left uncommitted → reprocessed (the
                    // UPSERT keyed by user_id is idempotent, so that is safe).
                    if ($this->process($msg, $approved)) {
                        $consumer->commit($msg);
                    }
                    break;
                case RD_KAFKA_RESP_ERR__PARTITION_EOF:
                case RD_KAFKA_RESP_ERR__TIMED_OUT:
                    break;
                default:
                    Log::warning('kyc-consumer: kafka error', ['name' => 'seller.consumer', 'err' => $msg->errstr()]);
                    break;
            }
        }
    }

    private function process(\RdKafka\Message $msg, string $approvedTopic): bool
    {
        try {
            $body = json_decode((string) $msg->payload, true) ?: [];
            // Some producers wrap the event under a "payload" key — unwrap.
            if (isset($body['payload']) && is_array($body['payload'])) {
                $body = $body['payload'];
            }
            $userId = $body['user_id'] ?? null;
            if (! $userId) {
                return true; // nothing actionable — offset may advance
            }
            $event = $body['event'] ?? '';
            $isApproved = ($msg->topic_name === $approvedTopic) || ($event === 'KycApproved');
            $tier = $isApproved ? 'verified' : 'unverified';

            ShopkeeperKycCache::updateOrCreate(
                ['user_id' => $userId],
                ['tier' => $tier, 'last_updated_at' => now()]
            );

            $busted = 0;
            foreach (Shop::where('owner_id', $userId)->pluck('handle') as $h) {
                Redis::del("shop:handle:{$h}");
                $busted++;
            }

            Log::info('kyc cache updated', [
                'name'       => 'shop.consumer',
                'user_id'    => $userId,
                'tier'       => $tier,
                'shops_bust' => $busted,
                'topic'      => $msg->topic_name,
            ]);
            return true;
        } catch (\Throwable $e) {
            Log::warning('kyc-consumer: process failed (offset NOT committed, will retry)', ['name' => 'seller.consumer', 'err' => $e->getMessage()]);
            return false;
        }
    }
}
