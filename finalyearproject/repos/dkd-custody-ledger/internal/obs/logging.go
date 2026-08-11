package obs

import (
	"log/slog"
	"os"
)

// NewLogger returns a structured JSON logger (slog). Correlation/trace IDs are attached per-request.
func NewLogger() *slog.Logger {
	return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
}
