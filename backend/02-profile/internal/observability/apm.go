// APM wiring with explicit runtime detection (docker / kubernetes / native).
// Mirrors dokandar-auth/app/observability/apm.py — the labels and
// service.node.name semantics are identical.
package observability

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"strings"
	"time"

	"go.elastic.co/apm/v2"
)

// SetupAPM configures the default APM tracer with explicit runtime context.
// Must run BEFORE chi.Use(apmchiv5.Middleware(...)) so the tracer sees the
// labels on every transaction.
func SetupAPM(serviceName, serviceVersion, environment, serverURL, secretToken string) error {
	// Reconfigure the global tracer to talk to our APM server.
	if serverURL != "" {
		_ = os.Setenv("ELASTIC_APM_SERVER_URL", serverURL)
	}
	if secretToken != "" {
		_ = os.Setenv("ELASTIC_APM_SECRET_TOKEN", secretToken)
	}
	_ = os.Setenv("ELASTIC_APM_SERVICE_NAME", serviceName)
	_ = os.Setenv("ELASTIC_APM_SERVICE_VERSION", serviceVersion)
	_ = os.Setenv("ELASTIC_APM_ENVIRONMENT", environment)

	runtimeKind, nodeName, labels := DetectRuntime()
	_ = os.Setenv("ELASTIC_APM_SERVICE_NODE_NAME", nodeName)

	// Build the GLOBAL_LABELS env-string the agent reads (comma-separated k=v).
	kv := []string{}
	for k, v := range labels {
		kv = append(kv, fmt.Sprintf("%s=%s", k, v))
	}
	if len(kv) > 0 {
		_ = os.Setenv("ELASTIC_APM_GLOBAL_LABELS", strings.Join(kv, ","))
	}

	// Recreate the default tracer so the new env vars take effect.
	t, err := apm.NewTracerOptions(apm.TracerOptions{
		ServiceName:        serviceName,
		ServiceVersion:     serviceVersion,
		ServiceEnvironment: environment,
	})
	if err != nil {
		return fmt.Errorf("apm tracer: %w", err)
	}
	apm.SetDefaultTracer(t)

	_ = runtimeKind // logged by the caller
	return nil
}

// DetectRuntime returns (runtime_kind, service_node_name, labels). Same
// detection order as the Python apm.py: kubernetes → docker → native.
func DetectRuntime() (string, string, map[string]string) {
	labels := map[string]string{}

	if os.Getenv("KUBERNETES_SERVICE_HOST") != "" {
		pod := firstNonEmpty(os.Getenv("POD_NAME"), os.Getenv("HOSTNAME"), getHostname())
		ns := os.Getenv("POD_NAMESPACE")
		node := os.Getenv("NODE_NAME")
		labels["runtime"] = "kubernetes"
		if pod != "" {
			labels["k8s_pod_name"] = pod
		}
		if ns != "" {
			labels["k8s_namespace"] = ns
		}
		if node != "" {
			labels["k8s_node_name"] = node
		}
		return "kubernetes", pod, labels
	}

	if _, err := os.Stat("/.dockerenv"); err == nil {
		cid := readDockerContainerID()
		labels["runtime"] = "docker"
		labels["container_id"] = cid
		labels["container_runtime"] = "docker"
		return "docker", cid, labels
	}

	labels["runtime"] = "native"
	return "native", getHostname(), labels
}

func readDockerContainerID() string {
	if b, err := os.ReadFile("/etc/hostname"); err == nil {
		return strings.TrimSpace(string(b))
	}
	return getHostname()
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

// APMServerReachable — TCP-probes the APM server URL for /health.
func APMServerReachable(serverURL string, timeout time.Duration) (bool, string) {
	u, err := url.Parse(serverURL)
	if err != nil {
		return false, err.Error()
	}
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	addr := net.JoinHostPort(u.Hostname(), port)
	c, err := net.DialTimeout("tcp", addr, timeout)
	if err != nil {
		return false, err.Error()
	}
	_ = c.Close()
	return true, fmt.Sprintf("%s tcp-ok", addr)
}
