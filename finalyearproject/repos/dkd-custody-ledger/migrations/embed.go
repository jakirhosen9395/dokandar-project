// Package migrations embeds the catalog-svc SQL migrations.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
