package logistics

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

// TestFitness_HexagonalDependencyRule — EF-HEX-1 architecture-fitness (XC-CI-3): the shipment
// domain core imports NOTHING from adapter/framework layers; dependencies point inward only.
func TestFitness_HexagonalDependencyRule(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", nil, parser.ImportsOnly)
	if err != nil {
		t.Fatalf("parse domain package: %v", err)
	}
	banned := []string{
		"/internal/api", "/internal/store", "/internal/httpx", "/internal/consumer",
		"/internal/outbox", "/internal/clients", "/internal/rabbit", "net/http", "database/sql",
		"github.com/jackc/pgx", "github.com/twmb/franz-go", "github.com/rabbitmq",
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
						t.Errorf("EF-HEX-1 violation: domain file %s imports %q — adapters/frameworks forbidden in the domain core", name, path)
					}
				}
			}
		}
	}
}
