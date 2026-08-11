// Package buildinfo carries provenance stamped at build time via `-ldflags -X` from a SINGLE
// source (the `docker build --build-arg` set, threaded into ldflags and the OCI image labels).
// Nothing here is derived at runtime; the values are frozen into the binary at link time.
package buildinfo

var (
	// Version is the release version — the git tag at build time, e.g. "0.1.0".
	Version = "0.0.0-dev"
	// GitSha is the exact commit SHA the binary was built from (== OCI image revision).
	GitSha = "unknown"
	// BuildTime is the RFC-3339 UTC build timestamp (== OCI image created).
	BuildTime = "unknown"
)
