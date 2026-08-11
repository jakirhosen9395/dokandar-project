// Package migrations embeds the ordered SQL migrations applied at startup by internal/store.
// Kept at the repo root under migrations/ so the DDL is reviewable without descending into a
// runtime package.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
