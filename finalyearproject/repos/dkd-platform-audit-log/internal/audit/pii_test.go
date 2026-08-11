package audit

import "testing"

func TestScanPII(t *testing.T) {
	cases := []struct {
		name         string
		payload      string
		wantFlagged  bool
		wantContains string
	}{
		{"clean canonical ids", `{"did":"did:dokandar:abc","gpid":"GP-CAT-1","amountPoisha":1500,"ingestedAtMs":1719800000000,"eventId":"e1","previousHash":"","eventName":"CustodyTransferred"}`, false, ""},
		{"timestamps and counts are not pii", `{"ts":1719800000000,"count":13,"offset":4200000000000}`, false, ""},
		{"phone key", `{"customerPhone":"+8801712345678"}`, true, "key:customerPhone"},
		{"email value", `{"contact":"a.b@example.com"}`, true, "value:contact(email)"},
		{"raw nid key", `{"rawNid":"1990123456789"}`, true, "key:rawNid"},
		{"person name key", `{"name":"Rahim"}`, true, "key:name"},
		{"nidHash allowed", `{"nidHash":"deadbeef"}`, false, ""},
		{"eventName/productName not flagged", `{"eventName":"Foo","productName":"Rice","serviceName":"svc"}`, false, ""},
		{"nested full name", `{"party":{"fullName":"X Y"}}`, true, "key:party.fullName"},
		{"non-json falls back to phone value scan", `plain +8801712345678 text`, true, "value:(phone)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			flagged, fields := ScanPII([]byte(tc.payload))
			if flagged != tc.wantFlagged {
				t.Fatalf("flagged=%v want %v (fields=%v)", flagged, tc.wantFlagged, fields)
			}
			if tc.wantContains != "" {
				found := false
				for _, f := range fields {
					if f == tc.wantContains {
						found = true
					}
				}
				if !found {
					t.Fatalf("fields=%v want to contain %q", fields, tc.wantContains)
				}
			}
		})
	}
}
