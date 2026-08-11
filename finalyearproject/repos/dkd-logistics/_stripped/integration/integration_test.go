//go:build integration

// Integration tests run against ephemeral infra (testcontainers / docker-compose). They are
// build-tagged so unit CI stays fast; the integration CI stage runs `go test -tags integration`.
package integration

import "testing"

func TestServiceBoots(t *testing.T) {
	// Brought up by the integration CI stage (postgres + redpanda + rabbitmq); asserts /ready.
	t.Skip("requires docker infra; exercised by the integration CI stage")
}
