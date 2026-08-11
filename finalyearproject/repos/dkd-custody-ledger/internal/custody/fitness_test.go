package custody

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

// TestFitness_HexagonalDependencyRule is an EF-HEX-1 architecture-fitness function (XC-CI-3):
// the domain core must import NOTHING from the adapter/application layers or web/db frameworks —
// dependencies point inward only (domain ← application ← adapters). A violation fails the build.
func TestFitness_HexagonalDependencyRule(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", nil, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("parse domain package: %v", err)
	}
	banned := []string{
		"/internal/api", "/internal/store", "/internal/httpx", "/internal/consumer",
		"/internal/outbox", "/internal/catalogclient", "net/http", "database/sql",
		"github.com/jackc/pgx", "github.com/twmb/franz-go",
	}
	for _, pkg := range pkgs {
		for name, f := range pkg.Files {
			if strings.HasSuffix(name, "_test.go") {
				continue
			}
			for _, imp := range f.Imports {
				path := strings.Trim(imp.Path.Value, `"`)
				for _, b := range banned {
					if strings.Contains(path, b) {
						t.Errorf("EF-HEX-1 violation: domain file %s imports %q — adapters/frameworks are forbidden in the domain core", name, path)
					}
				}
			}
		}
	}
}
