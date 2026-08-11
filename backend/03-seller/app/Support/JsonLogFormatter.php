<?php

namespace App\Support;

use Monolog\Formatter\FormatterInterface;
use Monolog\LogRecord;

/**
 * DOKANDAR-canonical stdout log shape — identical to auth (Python
 * python-json-logger) and profile (Go slog): pretty JSON, field order
 *   asctime → name → levelname → message → elasticapm_* → extras
 * so Kibana / Mongo queries stay portable across the polyglot fleet.
 *
 * - `asctime` uses Python's "Y-m-d H:i:s,mmm" form (comma before millis).
 * - `levelname` uses Python casing: DEBUG / INFO / WARNING / ERROR.
 * - `name` comes from the log context (`name` or legacy `service` key),
 *   else defaults to "shop"; callers pass e.g. ['name' => 'shop.kafka'].
 * - elasticapm_* are emitted only when an APM transaction is active.
 */
class JsonLogFormatter implements FormatterInterface
{
    public function format(LogRecord $record): string
    {
        $ctx = $record->context;

        $name = $ctx['name'] ?? $ctx['service'] ?? '03-seller';
        unset($ctx['name'], $ctx['service']);

        $out = [
            'asctime'   => $record->datetime->format('Y-m-d H:i:s,v'),
            'name'      => (string) $name,
            'levelname' => $this->levelname($record->level->getName()),
            'message'   => $record->message,
        ];

        if (($apm = $this->apm()) !== null) {
            $out['elasticapm_transaction_id']      = $apm['tx'];
            $out['elasticapm_trace_id']            = $apm['trace'];
            $out['elasticapm_service_name']        = $apm['svc'];
            $out['elasticapm_service_environment'] = $apm['env'];
            $out['elasticapm_labels']              = [
                'transaction.id'      => $apm['tx'],
                'trace.id'            => $apm['trace'],
                'span.id'             => null,
                'service.name'        => $apm['svc'],
                'service.environment' => $apm['env'],
            ];
        }

        foreach ($ctx as $k => $v) {
            $out[$k] = $v;
        }

        return json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
    }

    public function formatBatch(array $records): string
    {
        $s = '';
        foreach ($records as $r) {
            $s .= $this->format($r);
        }
        return $s;
    }

    private function levelname(string $monolog): string
    {
        return match (strtoupper($monolog)) {
            'DEBUG'          => 'DEBUG',
            'INFO', 'NOTICE' => 'INFO',
            'WARNING'        => 'WARNING',
            default          => 'ERROR', // ERROR / CRITICAL / ALERT / EMERGENCY
        };
    }

    /** Best-effort current Elastic APM ids; null when no agent / no tx. */
    private function apm(): ?array
    {
        if (! class_exists('\Elastic\Apm\ElasticApm')) {
            return null;
        }
        try {
            $tx = \Elastic\Apm\ElasticApm::getCurrentTransaction();
            if (! $tx) {
                return null;
            }
            $trace = method_exists($tx, 'getTraceId') ? (string) $tx->getTraceId() : '';
            $id    = method_exists($tx, 'getId') ? (string) $tx->getId() : '';
            if ($trace === '' && $id === '') {
                return null;
            }
            return [
                'tx'    => $id,
                'trace' => $trace,
                'svc'   => getenv('APM_SERVICE_NAME') ?: '03-seller',
                'env'   => getenv('APP_ENV') ?: 'dev',
            ];
        } catch (\Throwable $e) {
            return null;
        }
    }
}
