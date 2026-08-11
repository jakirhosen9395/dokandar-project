package buildinfo

import "testing"

// The values are stamped at link time; here we only assert the vars exist and are non-empty so a
// bad default (empty string) can never ship silently.
func TestBuildInfoDefaultsNonEmpty(t *testing.T) {
	if Version == "" || GitSha == "" || BuildTime == "" {
		t.Fatalf("buildinfo vars must be non-empty: version=%q sha=%q time=%q", Version, GitSha, BuildTime)
	}
}
