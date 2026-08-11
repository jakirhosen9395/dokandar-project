<?php

namespace App\Support;

/**
 * Runtime detection — docker / kubernetes / native — used to stamp APM
 * labels and the service.node.name. Mirrors the Go and Python equivalents
 * in dokandar-profile / dokandar-auth.
 */
class Runtime
{
    /**
     * @return array{kind:string, node_name:string, labels:array<string,string>}
     */
    public static function detect(): array
    {
        $labels = [];
        if (getenv('KUBERNETES_SERVICE_HOST')) {
            $pod = getenv('POD_NAME') ?: getenv('HOSTNAME') ?: gethostname();
            $ns = getenv('POD_NAMESPACE') ?: '';
            $node = getenv('NODE_NAME') ?: '';
            $labels['runtime'] = 'kubernetes';
            if ($pod) $labels['k8s_pod_name'] = $pod;
            if ($ns) $labels['k8s_namespace'] = $ns;
            if ($node) $labels['k8s_node_name'] = $node;
            return ['kind' => 'kubernetes', 'node_name' => (string) $pod, 'labels' => $labels];
        }
        if (file_exists('/.dockerenv')) {
            $cid = @trim((string) file_get_contents('/etc/hostname'));
            if ($cid === '') $cid = gethostname() ?: 'unknown';
            $labels['runtime'] = 'docker';
            $labels['container_id'] = $cid;
            $labels['container_runtime'] = 'docker';
            return ['kind' => 'docker', 'node_name' => $cid, 'labels' => $labels];
        }
        $labels['runtime'] = 'native';
        return ['kind' => 'native', 'node_name' => gethostname() ?: 'unknown', 'labels' => $labels];
    }

    /**
     * TCP-only reachability probe for /health.checks.apm.
     * Returns [bool ok, string detail].
     */
    public static function probeApm(string $url, float $timeoutSec = 1.5): array
    {
        $u = parse_url($url);
        if ($u === false || empty($u['host'])) {
            return [false, 'invalid url'];
        }
        $port = $u['port'] ?? (($u['scheme'] ?? 'http') === 'https' ? 443 : 80);
        $errno = 0; $errstr = '';
        $sock = @fsockopen($u['host'], (int) $port, $errno, $errstr, $timeoutSec);
        if (! $sock) {
            return [false, $errstr ?: "errno $errno"];
        }
        fclose($sock);
        return [true, "{$u['host']}:{$port} tcp-ok"];
    }
}
