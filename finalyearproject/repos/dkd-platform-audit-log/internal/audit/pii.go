package audit

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// The spine's Published Language (R6) mandates that cross-context payloads carry canonical IDs
// only — never PII (consumers resolve PII via the Identity OHS). PII-clean is therefore a PRODUCER
// contract. The audit sink does not enforce that contract by rejecting data (that would lose the
// audit record and violate append-all/WORM). It OBSERVES: it flags PII-shaped fields, quarantines
// a copy, and raises a metric/alert — while still appending the full record. See CORRECTION 1.

// piiSubstr are lowercased, separator-stripped key substrings that strongly indicate PII.
var piiSubstr = []string{
	"phone", "msisdn", "mobile", "email", "rawnid", "passport", "password",
	"dateofbirth", "fullname", "firstname", "lastname", "givenname", "surname",
	"streetaddress", "homeaddress",
}

// piiExact are normalized keys that indicate PII only when matched exactly (too generic as a
// substring — e.g. "name" must not flag "eventName"/"productName").
var piiExact = map[string]bool{
	"nid": true, "name": true, "address": true, "dob": true,
	"lat": true, "lng": true, "latitude": true, "longitude": true, "gps": true,
}

// piiAllow are normalized keys that look PII-ish but are explicitly canonical/allowed.
var piiAllow = map[string]bool{
	"nidhash": true, "eventname": true, "topicname": true, "namespace": true,
	"productname": true, "servicename": true, "aggregatename": true,
	"displayname": true, "eventid": true, "hostname": true,
}

var (
	reEmail = regexp.MustCompile(`[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}`)
	rePhone = regexp.MustCompile(`\+8801\d{9}`) // Bangladeshi E.164 mobile
)

func normKey(k string) string {
	k = strings.ToLower(k)
	k = strings.ReplaceAll(k, "_", "")
	k = strings.ReplaceAll(k, "-", "")
	return k
}

func isPIIKey(rawKey string) bool {
	n := normKey(rawKey)
	if piiAllow[n] {
		return false
	}
	for _, h := range piiSubstr {
		if strings.Contains(n, h) {
			return true
		}
	}
	return piiExact[n]
}

// ScanPII walks a JSON payload and returns whether any PII-shaped field was found, plus a stable,
// de-duplicated list of the offending paths. Detection is keyed on FIELD NAMES (so numeric IDs and
// millisecond timestamps never false-positive) plus unambiguous value patterns (email, +880 phone).
func ScanPII(payload []byte) (bool, []string) {
	var v any
	if err := json.Unmarshal(payload, &v); err != nil {
		// Non-JSON payload: fall back to scanning the raw text for unambiguous value patterns.
		found, hs := scanText("", string(payload))
		return found, dedupeSorted(hs)
	}
	var hits []string
	walk("", v, &hits)
	if len(hits) == 0 {
		return false, nil
	}
	return true, dedupeSorted(hits)
}

func walk(path string, v any, hits *[]string) {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			if isPIIKey(k) {
				*hits = append(*hits, "key:"+joinPath(path, k))
			}
			walk(joinPath(path, k), val, hits)
		}
	case []any:
		for i, val := range t {
			walk(fmt.Sprintf("%s[%d]", path, i), val, hits)
		}
	case string:
		if found, hs := scanText(path, t); found {
			*hits = append(*hits, hs...)
		}
	}
}

func scanText(path, s string) (bool, []string) {
	var hits []string
	if reEmail.MatchString(s) {
		hits = append(hits, "value:"+path+"(email)")
	}
	if rePhone.MatchString(s) {
		hits = append(hits, "value:"+path+"(phone)")
	}
	return len(hits) > 0, hits
}

func joinPath(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func dedupeSorted(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, s := range in {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	sort.Strings(out)
	return out
}
