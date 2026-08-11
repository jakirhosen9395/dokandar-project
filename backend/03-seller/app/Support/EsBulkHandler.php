<?php

namespace App\Support;

use Monolog\Handler\AbstractProcessingHandler;
use Monolog\Level;
use Monolog\LogRecord;

/**
 * In-process Elasticsearch log sink (ECS-shaped).
 *
 * Posts one record per request via the `_bulk` API to
 * `logs-app-03-seller-default` (the index template auto-rolls daily). This is
 * what populates Kibana → Discover / Logs and the APM per-transaction
 * "Logs" tab — every line carries `service.name`, `trace.id`,
 * `transaction.id`, `span.id` so the join works.
 *
 * Failure mode: non-blocking, fire-and-forget. If ES is unreachable the
 * record is dropped with a single error_log line (NEVER through Monolog —
 * that would feed back on itself). A small bounded send queue is the
 * Python service's pattern; in PHP request-per-process we just POST in the
 * handler and a slow ES eats request latency, so we set a hard 1.5s
 * timeout and silently drop on TCP failure.
 */
class EsBulkHandler extends AbstractProcessingHandler
{
    /** §16-f: index derives from SERVICE_NAME → logs-app-03-seller-default. */
    private function index(): string
    {
        return 'logs-app-' . (getenv('SERVICE_NAME') ?: '03-seller') . '-default';
    }

    public function __construct(
        private readonly string $url,
        private readonly string $user,
        private readonly string $pass,
        int|string|Level $level = Level::Info,
        bool $bubble = true,
    ) {
        parent::__construct($level, $bubble);
    }

    /** Avoid a feedback loop: never let *this* handler log through Monolog. */
    public function isHandling(LogRecord $record): bool
    {
        if (! $this->enabled()) {
            return false;
        }
        return parent::isHandling($record);
    }

    protected function write(LogRecord $record): void
    {
        if (! $this->enabled()) {
            return;
        }
        $doc = $this->toEcs($record);
        $meta = json_encode(['create' => ['_index' => $this->index()]]);
        $body = $meta . "\n" . json_encode($doc) . "\n";
        $this->postBulk($body);
    }

    private function enabled(): bool
    {
        return $this->url !== '';
    }

    /** Build an ECS-shaped document from a Monolog record. */
    private function toEcs(LogRecord $record): array
    {
        $ctx = $record->context;
        $ts = $record->datetime->format('Y-m-d\TH:i:s.v\Z');
        $doc = [
            '@timestamp'    => $ts,
            'log.level'     => strtolower($record->level->getName()),
            'log.logger'    => $record->channel,
            'message'       => $record->message,
            'service.name'  => getenv('SERVICE_NAME') ?: '03-seller',
            'service.environment' => $ctx['env'] ?? (getenv('APP_ENV') ?: 'dev'),
            'host.name'     => gethostname() ?: 'unknown',
            'process.pid'   => getmypid() ?: null,
        ];
        // Join keys — preferred names from APM agent context if present.
        $traceId = $ctx['trace.id'] ?? $ctx['trace_id'] ?? $this->currentApmId('getTraceId');
        $txId    = $ctx['transaction.id'] ?? $this->currentApmId('getId');
        $spanId  = $ctx['span.id'] ?? null;
        if ($traceId) $doc['trace.id'] = $traceId;
        if ($txId)    $doc['transaction.id'] = $txId;
        if ($spanId)  $doc['span.id'] = $spanId;
        // Surface other context fields under labels.* (avoid Elasticsearch
        // dynamic-mapping bombs on nested objects of unknown shape).
        foreach ($ctx as $k => $v) {
            if (in_array($k, ['trace.id', 'trace_id', 'transaction.id', 'span.id', 'env'], true)) continue;
            if (is_scalar($v) || $v === null) {
                $doc['labels.' . $k] = $v;
            }
        }
        return $doc;
    }

    /** Best-effort current Elastic APM identifier (no hard agent dep). */
    private function currentApmId(string $method): ?string
    {
        if (! class_exists('\Elastic\Apm\ElasticApm')) {
            return null;
        }
        try {
            $tx = \Elastic\Apm\ElasticApm::getCurrentTransaction();
            if ($tx && method_exists($tx, $method)) {
                $v = $tx->{$method}();
                return $v ? (string) $v : null;
            }
        } catch (\Throwable $e) {
            // ignore
        }
        return null;
    }

    private function postBulk(string $body): void
    {
        $ch = curl_init(rtrim($this->url, '/') . '/_bulk');
        if (! $ch) return;
        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => $body,
            CURLOPT_HTTPHEADER     => ['Content-Type: application/x-ndjson'],
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT_MS     => 1500,
            CURLOPT_CONNECTTIMEOUT_MS => 800,
            CURLOPT_FAILONERROR    => false,
        ]);
        if ($this->user !== '') {
            curl_setopt($ch, CURLOPT_USERPWD, $this->user . ':' . $this->pass);
        }
        $resp = curl_exec($ch);
        $err  = curl_errno($ch);
        $code = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        if ($err !== 0 || $code >= 400) {
            // CRITICAL: never log via Monolog here (feedback loop).
            @error_log(sprintf(
                '[es-bulk] drop: curl_errno=%d http=%d resp=%s',
                $err, $code, is_string($resp) ? substr($resp, 0, 160) : ''
            ));
        }
    }
}
