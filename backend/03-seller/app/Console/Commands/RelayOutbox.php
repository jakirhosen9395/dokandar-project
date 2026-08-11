<?php

namespace App\Console\Commands;

use App\Models\Outbox;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * Outbox relay: reads unsent outbox rows and publishes them to Kafka.
 *
 * Runs as a long-lived loop (artisan command launched alongside the HTTP
 * server in the container's entrypoint). For first-cut, the producer uses
 * plain librdkafka via the `rdkafka` PECL extension. If rdkafka is NOT
 * installed in the runtime image, the relay logs a warning and exits —
 * the outbox table fills up but HTTP is unaffected.
 */
class RelayOutbox extends Command
{
    protected $signature = 'shop:relay-outbox {--interval=2}';
    protected $description = 'Drain unsent outbox rows to Kafka.';

    public function handle(): int
    {
        $bootstrap = config('shop.kafka.bootstrap');
        if (empty($bootstrap)) {
            Log::warning('outbox: KAFKA_BOOTSTRAP empty — relay stopped', ['name' => 'seller.outbox']);
            return 0;
        }
        if (! extension_loaded('rdkafka')) {
            Log::warning('outbox: rdkafka PHP extension not loaded — relay is a no-op (table will fill). Build the image with rdkafka enabled to ship events.', ['name' => 'seller.outbox']);
            // Keep the process alive so docker doesn't restart it; sleep forever.
            while (true) { sleep(60); }
        }

        // Configure rdkafka producer.
        $conf = new \RdKafka\Conf();
        $conf->set('bootstrap.servers', $bootstrap);
        $conf->set('acks', 'all');
        $conf->set('enable.idempotence', 'true');
        $producer = new \RdKafka\Producer($conf);

        $interval = (int) $this->option('interval');
        Log::info("outbox-relay started interval={$interval}s bootstrap={$bootstrap}", ['name' => 'seller.outbox']);
        while (true) {
            $sent = 0;
            try {
                // §16-c: claim unsent rows with FOR UPDATE SKIP LOCKED inside a
                // transaction so multiple relay replicas never double-drain the
                // same rows (the reference omitted this — single-relay only).
                // Produce + flush happen while the rows are locked; a second
                // relay simply skips them and grabs others. acks=all +
                // idempotence + idempotent downstream consumers make the
                // at-least-once boundary safe.
                DB::transaction(function () use ($producer, &$sent) {
                    // §16-c: FOR UPDATE SKIP LOCKED so multiple relay replicas
                    // never double-drain. Laravel's Eloquent builder has no
                    // skipLocked() method — pass the raw lock clause via lock().
                    $rows = Outbox::whereNull('sent_at')
                        ->orderBy('id')->limit(100)
                        ->lock('for update skip locked')
                        ->get();
                    foreach ($rows as $row) {
                        $topic = $producer->newTopic($row->topic);
                        $payload = is_string($row->payload) ? $row->payload : json_encode($row->payload);
                        $topic->produce(RD_KAFKA_PARTITION_UA, 0, $payload, $row->key);
                        $producer->poll(0);
                        $row->sent_at = now();
                        $row->save();
                        $sent++;
                    }
                    if ($sent > 0) {
                        $producer->flush(2000);
                    }
                });
                if ($sent > 0) {
                    Log::info("outbox: marked $sent sent", ['name' => 'seller.outbox']);
                }
            } catch (\Throwable $e) {
                Log::warning('outbox: relay batch failed (rolled back, will retry)', ['name' => 'seller.outbox', 'err' => $e->getMessage()]);
            }
            sleep($interval);
        }
    }
}
