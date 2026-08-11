package app

import (
	"bytes"
	"encoding/json"
)

// prettyJSONEncoder renders JSON with 2-space indent and ensure_ascii=false
// (SetEscapeHTML(false) keeps Bangla literal UTF-8). Wired as the Fiber
// JSONEncoder so every c.JSON(...) response is pretty. The encoder appends a
// trailing newline (json.Encoder.Encode already does).
func prettyJSONEncoder(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
