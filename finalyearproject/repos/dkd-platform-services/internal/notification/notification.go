// Package notification — NotificationJob fabric (DM ctx #13; R8/ADR-012 channel parity).
// Every citizen-facing event enqueues BOTH an SMS and a USSD job with a Bangla body ≤160
// chars (R8). Jobs are idempotent on idempotencyKey, never silently dropped; the RabbitMQ
// queue platform.notification-dispatch (intra-context, R6) fans out to channel adapters —
// the dev-sink adapter marks SENT. Produces ZERO Kafka topics (SA §16.7 names are
// non-registry errata; registry lists no notification producer).
package notification

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"log/slog"

	"github.com/jackc/pgx/v5"
	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/platform-services/internal/consumer"
	"gitlab.com/final-year-project3354127/platform-services/internal/scheduler"
	"gitlab.com/final-year-project3354127/platform-services/internal/store"
)

const (
	MetricEnqueued  = "notification_jobs_enqueued_total"
	MetricSent      = "notification_jobs_sent_total"
	MaxUSSDChars    = 160 // R8: USSD ≤160 chars Bangla
	DefaultLocale   = "bn-BD"
	ChannelSMS      = "SMS"
	ChannelUSSD     = "USSD"
	ChannelEmail    = "EMAIL"
	ChannelPush     = "PUSH"
)

// Topics: PartyRegistered/KYCRejected list 13 in the frozen registry; OrderDelivered is a
// registry GAP (consumers exclude 13) consumed per operator directive — additive ADR owed.
func Topics() []string {
	return []string{
		dkd.TopicIdentityPartyPartyRegisteredV1,
		dkd.TopicIdentityPartyKYCRejectedV1,
		dkd.TopicB2cOrderOrderDeliveredV1,
	}
}

// Bangla templates (R8). Bodies are templated server-side; params carry canonical IDs only.
var templates = map[string]string{
	"party-registered": "ডোকানদারে স্বাগতম! আপনার নিবন্ধন সম্পন্ন হয়েছে।",
	"kyc-rejected":     "দুঃখিত, আপনার কেওয়াইসি যাচাই ব্যর্থ হয়েছে। আবার চেষ্টা করুন।",
	"order-delivered":  "আপনার অর্ডার %s সফলভাবে ডেলিভারি হয়েছে। ধন্যবাদ!",
}

func RenderBody(templateID string, param string) (string, error) {
	tpl, ok := templates[templateID]
	if !ok {
		return "", fmt.Errorf("notification: unknown templateId %q", templateID)
	}
	body := tpl
	if strings.Contains(tpl, "%s") {
		body = fmt.Sprintf(tpl, param)
	}
	if utf8.RuneCountInString(body) > MaxUSSDChars {
		runes := []rune(body)
		body = string(runes[:MaxUSSDChars]) // R8 hard cap — never exceed a USSD frame
	}
	return body, nil
}

type Publisher interface{ PublishDispatch(ntfID string) error }

type Metrics interface{ Inc(name string) }

type Service struct {
	st     *store.Store
	pub    Publisher
	log    *slog.Logger
	m      Metrics
	now    func() int64
	b2cURL string
	http   *http.Client
}

func New(st *store.Store, pub Publisher, log *slog.Logger, m Metrics, now func() int64,
	b2cURL string) *Service {
	return &Service{st: st, pub: pub, log: log, m: m, now: now, b2cURL: b2cURL,
		http: &http.Client{Timeout: 8 * time.Second}}
}

// resolveBuyer fetches the recipient via b2c's internal seam (the event payload is
// R6-clean IDs only). Runs BEFORE any DB transaction; errors replay the record.
func (s *Service) resolveBuyer(ctx context.Context, ord string) (string, error) {
	if s.b2cURL == "" {
		return "", nil
	}
	if !strings.HasPrefix(ord, "ORD-") {
		return "", nil // canonical prefix only — never build URLs from arbitrary payload text
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		s.b2cURL+"/internal/orders/"+ord, nil)
	if err != nil {
		return "", err
	}
	res, err := s.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("notification: b2c seam: %w", err)
	}
	defer func() { _ = res.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("notification: read b2c body: %w", err)
	}
	if res.StatusCode == http.StatusNotFound {
		return "", nil // unknown order — business-final skip
	}
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("notification: b2c seam status %d", res.StatusCode)
	}
	var env struct {
		Data struct {
			BuyerDid string `json:"buyerDid"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return "", fmt.Errorf("notification: b2c envelope: %w", err)
	}
	return env.Data.BuyerDid, nil
}

// Enqueue creates one job (idempotent on idemKey) and notifies the dispatch queue post-commit.
func (s *Service) Enqueue(ctx context.Context, recipientDid, channel, templateID, param,
	idemKey string) (store.Job, bool, error) {
	body, err := RenderBody(templateID, param)
	if err != nil {
		return store.Job{}, false, err
	}
	params, mErr := json.Marshal(map[string]string{"ref": param})
	if mErr != nil {
		return store.Job{}, false, fmt.Errorf("notification: marshal params: %w", mErr)
	}
	job := store.Job{
		NtfID: "NTF-" + scheduler.NewUUID7(), RecipientDid: recipientDid, Channel: channel,
		TemplateID: templateID, Params: params, Locale: DefaultLocale, Body: body,
		Status: "QUEUED", CreatedAt: s.now(),
	}
	fresh, err := s.st.InsertJob(ctx, job, idemKey)
	if err != nil {
		return store.Job{}, false, err
	}
	if fresh {
		s.m.Inc(MetricEnqueued)
		if err := s.pub.PublishDispatch(job.NtfID); err != nil {
			// The QUEUED row is the durable work item; the queue is the wake-up signal.
			s.log.Warn("dispatch publish failed (job row persists)", "ntf", job.NtfID, "err", err)
		}
	}
	return job, fresh, nil
}

// Handle consumes citizen-facing spine events → SMS + USSD job pairs (R8 parity).
func (s *Service) Handle(ctx context.Context, ev consumer.RawEvent) error {
	var p struct {
		Did        string `json:"did"`
		PartyDid   string `json:"partyDid"`
		Ord        string `json:"ord"`
		OrderID    string `json:"orderId"`
		BuyerDid   string `json:"buyerDid"`
		OccurredAt int64  `json:"occurredAt"`
	}
	if err := json.Unmarshal(ev.Value, &p); err != nil {
		s.log.Info("skip malformed event", "topic", ev.Topic)
		return nil
	}
	recipient, templateID, param := "", "", ""
	switch ev.Topic {
	case dkd.TopicIdentityPartyPartyRegisteredV1:
		recipient, templateID = first(p.Did, p.PartyDid), "party-registered"
	case dkd.TopicIdentityPartyKYCRejectedV1:
		recipient, templateID = first(p.Did, p.PartyDid), "kyc-rejected"
	case dkd.TopicB2cOrderOrderDeliveredV1:
		templateID, param = "order-delivered", first(p.Ord, p.OrderID)
		recipient = p.BuyerDid
		if recipient == "" && param != "" {
			resolved, rErr := s.resolveBuyer(ctx, param) // pre-tx outbound HTTP (fleet rule)
			if rErr != nil {
				return rErr // infra: replay
			}
			recipient = resolved
		}
	}
	if recipient == "" {
		s.log.Info("skip — no recipient DID", "topic", ev.Topic)
		return nil
	}
	now := s.now()
	var pending []string
	done, err := s.st.ConsumeOnceIn(ctx, "notification_inbox", ev.EventID, ev.Topic, now,
		func(tx pgx.Tx) error {
			for _, channel := range []string{ChannelSMS, ChannelUSSD} { // R8 parity pair
				body, rErr := RenderBody(templateID, param)
				if rErr != nil {
					return rErr
				}
				params, mErr := json.Marshal(map[string]string{"ref": param})
				if mErr != nil {
					return fmt.Errorf("notification: marshal params: %w", mErr)
				}
				job := store.Job{
					NtfID: "NTF-" + scheduler.NewUUID7(), RecipientDid: recipient,
					Channel: channel, TemplateID: templateID, Params: params,
					Locale: DefaultLocale, Body: body, Status: "QUEUED", CreatedAt: now,
				}
				idemKey := fmt.Sprintf("%s:%s:%s", ev.EventID, templateID, channel)
				fresh, iErr := s.st.InsertJobTx(ctx, tx, job, idemKey)
				if iErr != nil {
					return iErr
				}
				if fresh {
					pending = append(pending, job.NtfID)
				}
			}
			return nil
		})
	if err != nil {
		return err
	}
	if done {
		s.m.Inc(MetricEnqueued)
		for _, ntf := range pending { // post-commit wake-ups; rows are the durable queue
			if pErr := s.pub.PublishDispatch(ntf); pErr != nil {
				s.log.Warn("dispatch publish failed (job row persists)", "ntf", ntf, "err", pErr)
			}
		}
	}
	return nil
}

// Park (PLAT-06): called only after the consumer's bounded inline retries are exhausted — quarantine
// the poison record to the DLQ and advance; a DLQ-insert failure keeps it (never a silent drop).
func (s *Service) Park(ev consumer.RawEvent, cause error) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if perr := s.st.ParkDLQ(ctx, ev.EventID, ev.Topic, ev.Key, ev.Value, cause.Error(), s.now()); perr != nil {
		s.log.Error("DLQ park FAILED — keep replaying (never drop)", "event_id", ev.EventID, "err", perr)
		return false
	}
	s.log.Error("notification poison event PARKED to DLQ after bounded retries — partition advancing",
		"topic", ev.Topic, "event_id", ev.EventID, "err", cause)
	return true
}

// MarkFailed parks a job after exhausted delivery retries.
func (s *Service) MarkFailed(ctx context.Context, ntfID string) error {
	return s.st.MarkFailed(ctx, ntfID, s.now())
}

// Dispatch is the channel adapter seam: the dev-sink "delivers" by logging (SA §16.2's
// aggregator adapters replace this in production) and flips QUEUED -> SENT.
func (s *Service) Dispatch(ctx context.Context, ntfID string) error {
	job, found, err := s.st.GetJob(ctx, ntfID)
	if err != nil || !found {
		return err
	}
	if job.Status != "QUEUED" {
		return nil // replay
	}
	s.log.Info("dev-sink delivery", "ntf", ntfID, "channel", job.Channel,
		"recipient", job.RecipientDid, "body", job.Body)
	sent, err := s.st.MarkSent(ctx, ntfID, s.now())
	if err != nil {
		return err
	}
	if sent {
		s.m.Inc(MetricSent)
	}
	return nil
}

func first(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
