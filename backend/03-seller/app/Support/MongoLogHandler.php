<?php

namespace App\Support;

use Monolog\Handler\AbstractProcessingHandler;
use Monolog\Level;
use Monolog\LogRecord;

/**
 * In-process MongoDB log sink — inserts each record into
 * `<MONGO_LOG_DB>.shop`, matching the auth/profile durable-log convention.
 *
 * Writes the same canonical shape as JsonLogFormatter (asctime / name /
 * levelname / message + extras) so Mongo + stdout + ES queries align.
 *
 * Fire-and-forget: bounded connect/socket timeouts; on the first failure
 * the handler disables itself for the rest of the process so logging never
 * stalls a request. NEVER logs through Monolog (would feed back on itself).
 */
class MongoLogHandler extends AbstractProcessingHandler
{
    private ?object $coll = null;
    private bool $failed = false;

    public function __construct(
        private readonly string $uri,
        private readonly string $db,
        private readonly string $collection = '03-seller',
        int|string|Level $level = Level::Info,
        bool $bubble = true,
    ) {
        parent::__construct($level, $bubble);
    }

    public function isHandling(LogRecord $record): bool
    {
        if ($this->uri === '' || $this->failed) {
            return false;
        }
        return parent::isHandling($record);
    }

    protected function write(LogRecord $record): void
    {
        $coll = $this->collection();
        if ($coll === null) {
            return;
        }
        try {
            $coll->insertOne($this->toDoc($record));
        } catch (\Throwable $e) {
            $this->failed = true;
            @error_log('[mongo-log] drop: ' . $e->getMessage());
        }
    }

    private function collection(): ?object
    {
        if ($this->coll !== null) {
            return $this->coll;
        }
        if (! class_exists('\MongoDB\Client')) {
            $this->failed = true;
            return null;
        }
        try {
            $client = new \MongoDB\Client($this->uri, [
                'serverSelectionTimeoutMS' => 800,
                'connectTimeoutMS'         => 800,
                'socketTimeoutMS'          => 1500,
            ]);
            $this->coll = $client->selectDatabase($this->db)->selectCollection($this->collection);
            return $this->coll;
        } catch (\Throwable $e) {
            $this->failed = true;
            @error_log('[mongo-log] connect failed: ' . $e->getMessage());
            return null;
        }
    }

    private function toDoc(LogRecord $record): array
    {
        $ctx = $record->context;
        $name = $ctx['name'] ?? $ctx['service'] ?? '03-seller';
        unset($ctx['name'], $ctx['service']);

        $doc = [
            'asctime'   => $record->datetime->format('Y-m-d H:i:s,v'),
            'name'      => (string) $name,
            'levelname' => $this->levelname($record->level->getName()),
            'message'   => $record->message,
        ];
        foreach ($ctx as $k => $v) {
            $doc[$k] = $v;
        }
        return $doc;
    }

    private function levelname(string $m): string
    {
        return match (strtoupper($m)) {
            'DEBUG'          => 'DEBUG',
            'INFO', 'NOTICE' => 'INFO',
            'WARNING'        => 'WARNING',
            default          => 'ERROR',
        };
    }
}
