package consumer

import (
	"context"
	"io"
	"testing"

	"log/slog"

	"github.com/twmb/franz-go/pkg/kgo"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
)

func testLog() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func noopHandler(context.Context, audit.RawEvent) error { return nil }
func noopPark(audit.RawEvent, error) bool               { return true }

func TestNewValidation(t *testing.T) {
	cases := []struct {
		name    string
		cfg     Config
		wantErr bool
	}{
		{"no brokers", Config{Group: "g", Topics: []string{"t"}}, true},
		{"no topics", Config{Brokers: []string{"b:9092"}, Group: "g"}, true},
		{"no group", Config{Brokers: []string{"b:9092"}, Topics: []string{"t"}}, true},
		{"ok", Config{Brokers: []string{"b:9092"}, Group: "g", Topics: []string{"t"}}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, err := New(tc.cfg, testLog(), noopHandler, noopPark)
			if tc.wantErr {
				if err == nil {
					t.Fatal("want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if c == nil {
				t.Fatal("nil consumer")
			}
			c.Close()
		})
	}
}

func TestNewRejectsNilHandlerAndPark(t *testing.T) {
	base := Config{Brokers: []string{"b:9092"}, Group: "g", Topics: []string{"t"}}
	if _, err := New(base, testLog(), nil, noopPark); err == nil {
		t.Fatal("want error for nil handler")
	}
	if _, err := New(base, testLog(), noopHandler, nil); err == nil {
		t.Fatal("want error for nil park func")
	}
}

func TestToRawEventEventIDResolution(t *testing.T) {
	hdr := &kgo.Record{
		Topic: "t", Partition: 1, Offset: 5, Key: []byte("k"),
		Value:   []byte(`{"eventId":"payload-eid"}`),
		Headers: []kgo.RecordHeader{{Key: "event_id", Value: []byte("hdr-eid")}},
	}
	if got := toRawEvent(hdr).EventID; got != "hdr-eid" {
		t.Fatalf("header must win: %s", got)
	}
	got := toRawEvent(hdr)
	if got.Topic != "t" || got.Key != "k" || got.Partition != 1 || got.Offset != 5 {
		t.Fatalf("field copy: %+v", got)
	}

	payload := &kgo.Record{Topic: "t", Value: []byte(`{"eventId":"payload-eid"}`)}
	if got := toRawEvent(payload).EventID; got != "payload-eid" {
		t.Fatalf("payload eventId: %s", got)
	}

	snake := &kgo.Record{Topic: "t", Value: []byte(`{"event_id":"snake-eid"}`)}
	if got := toRawEvent(snake).EventID; got != "snake-eid" {
		t.Fatalf("snake event_id: %s", got)
	}

	synth := &kgo.Record{Topic: "topic-x", Partition: 3, Offset: 9, Value: []byte(`{"no":"id"}`)}
	if got := toRawEvent(synth).EventID; got != "topic-x/3/9" {
		t.Fatalf("synthesized id: %s", got)
	}
}
