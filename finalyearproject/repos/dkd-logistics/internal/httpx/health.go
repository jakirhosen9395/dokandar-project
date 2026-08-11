package httpx

import (
	"encoding/json"
	"net/http"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/buildinfo"
	dkdplatform "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{"status": "ok"}})
}

func live(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{"status": "alive"}})
}

func readyHandler(ready func() bool) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		if ready != nil && !ready() {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"success": false, "data": map[string]string{"status": "not-ready"}})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{"status": "ready"}})
	}
}

func version(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"success": true, "data": map[string]string{
		"version":         buildinfo.Version,
		"gitSha":          buildinfo.GitSha,
		"buildTime":       buildinfo.BuildTime,
		"contractVersion": dkdplatform.ContractVersion,
		"sdkGenerator":    dkdplatform.GeneratorVersion,
	}})
}
