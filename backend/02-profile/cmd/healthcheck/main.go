// Tiny static probe for the Dockerfile HEALTHCHECK. Distroless has no
// shell/curl/python, so the only way to call /ready from a HEALTHCHECK
// is to ship a binary.
package main

import (
	"net/http"
	"os"
	"time"
)

func main() {
	port := os.Getenv("SERVICE_PORT")
	if port == "" {
		port = "8000"
	}
	c := &http.Client{Timeout: 2 * time.Second}
	r, err := c.Get("http://127.0.0.1:" + port + "/ready")
	if err != nil {
		os.Exit(1)
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK {
		os.Exit(1)
	}
}
