// Package migrations exposes the SQL migration files as an embed.FS so the
// running binary contains them — no host-side file-copy needed at deploy.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
