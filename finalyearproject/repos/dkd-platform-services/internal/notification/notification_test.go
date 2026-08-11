package notification

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// R8: every template renders Bangla and fits a USSD frame (≤160 chars).
func TestTemplatesAreBanglaAndUSSDSized(t *testing.T) {
	for id := range templates {
		body, err := RenderBody(id, "ORD-019f0000-0000-7000-8000-000000000001")
		if err != nil {
			t.Fatalf("%s: %v", id, err)
		}
		if utf8.RuneCountInString(body) > MaxUSSDChars {
			t.Fatalf("%s exceeds the USSD frame: %d runes", id, utf8.RuneCountInString(body))
		}
		hasBangla := false
		for _, r := range body {
			if r >= 0x0980 && r <= 0x09FF {
				hasBangla = true
				break
			}
		}
		if !hasBangla {
			t.Fatalf("%s is not Bangla-first (R8): %s", id, body)
		}
	}
}

func TestOrderDeliveredInterpolatesTheOrd(t *testing.T) {
	body, err := RenderBody("order-delivered", "ORD-42")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(body, "ORD-42") {
		t.Fatalf("ord missing from body: %s", body)
	}
}

func TestUnknownTemplateRejected(t *testing.T) {
	if _, err := RenderBody("no-such-template", ""); err == nil {
		t.Fatal("unknown templateId must be rejected, never silently sent")
	}
}

func TestStaticTemplateIgnoresParam(t *testing.T) {
	body, err := RenderBody("party-registered", "ignored")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(body, "ignored") || strings.Contains(body, "%!") {
		t.Fatalf("static template corrupted by param: %s", body)
	}
}
