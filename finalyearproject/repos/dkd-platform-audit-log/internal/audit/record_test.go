package audit

import (
	"bytes"
	"testing"
)

func TestBuildRecordCopiesFieldsAndFlagsPII(t *testing.T) {
	e := RawEvent{
		Topic:     "custody.passport.CustodyTransferred.v1",
		Key:       "PPID-1",
		EventID:   "evt-1",
		Partition: 2,
		Offset:    42,
		Value:     []byte(`{"customerPhone":"+8801712345678"}`),
	}
	rec := BuildRecord(e, 1719800000000)
	if rec.Topic != e.Topic || rec.Key != e.Key || rec.EventID != e.EventID || rec.Partition != e.Partition || rec.Offset != e.Offset {
		t.Fatal("field copy mismatch")
	}
	if !bytes.Equal(rec.Payload, e.Value) {
		t.Fatal("payload not copied verbatim")
	}
	if rec.IngestedAtMs != 1719800000000 {
		t.Fatalf("ingestedAt=%d", rec.IngestedAtMs)
	}
	if !rec.PIIFlagged || len(rec.PIIFields) == 0 {
		t.Fatalf("expected PII flagged, got flagged=%v fields=%v", rec.PIIFlagged, rec.PIIFields)
	}
}

func TestBuildRecordCleanPayloadNotFlagged(t *testing.T) {
	rec := BuildRecord(RawEvent{Value: []byte(`{"did":"did:dokandar:x","amountPoisha":100}`)}, 1)
	if rec.PIIFlagged {
		t.Fatalf("clean payload wrongly flagged: %v", rec.PIIFields)
	}
}
