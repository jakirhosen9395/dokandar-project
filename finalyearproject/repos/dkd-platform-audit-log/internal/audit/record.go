// Package audit holds the append-only value objects the sink persists, plus the producer-contract
// PII guard. Nothing here talks to Kafka or Postgres — it is pure, dependency-free domain code.
package audit

// RawEvent is a single spine record as consumed from the Kafka log, before persistence.
type RawEvent struct {
	Topic     string
	Key       string
	EventID   string
	Partition int32
	Offset    int64
	Value     []byte
}

// Record is the immutable, append-only value object persisted for every consumed event. Once
// built it is never mutated — WORM at the value level, mirrored by the WORM store. The audit sink
// records EVERY event exactly as received (R6 OHS audit sink); it never rewrites or drops.
type Record struct {
	Topic        string
	Key          string
	EventID      string
	Partition    int32
	Offset       int64
	Payload      []byte
	IngestedAtMs int64
	// PIIFlagged / PIIFields are set by the producer-contract guard. Per the append-all/WORM rule
	// (CORRECTION 1) the record is ALWAYS persisted; these fields only annotate an observation.
	PIIFlagged bool
	PIIFields  []string
}

// BuildRecord constructs the append-only Record from a raw event, running the PII guard. The
// record is always returned in full — PII detection only sets the annotation flags, it never
// alters or withholds the payload.
func BuildRecord(e RawEvent, ingestedAtMs int64) Record {
	flagged, fields := ScanPII(e.Value)
	return Record{
		Topic:        e.Topic,
		Key:          e.Key,
		EventID:      e.EventID,
		Partition:    e.Partition,
		Offset:       e.Offset,
		Payload:      e.Value,
		IngestedAtMs: ingestedAtMs,
		PIIFlagged:   flagged,
		PIIFields:    fields,
	}
}
