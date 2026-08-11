// REST surface (SA §16.5 subset): POST /v1/notifications (NotificationOHS.Enqueue REST
// stand-in; Idempotency-Key required) + GET by id / by recipient.
package notification

import (
	"encoding/json"
	"net/http"
	"strings"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

type API struct{ svc *Service }

func NewAPI(svc *Service) *API { return &API{svc: svc} }

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/notifications", a.enqueue)
	mux.HandleFunc("GET /v1/notifications/{ntf}", a.get)
	mux.HandleFunc("GET /v1/notifications", a.list)
}

func code(category, reason string) string {
	c, err := dkd.ErrorCode("platform", category, reason)
	if err != nil {
		return "dokandar.platform.internal.bad_code"
	}
	return c
}

func writeJSON(w http.ResponseWriter, status int, ct string, body any) {
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeData(w http.ResponseWriter, status int, data any) {
	writeJSON(w, status, "application/json",
		map[string]any{"success": true, "data": data, "error": nil})
}

func writeProblem(w http.ResponseWriter, status int, codeStr, title, detail string) {
	writeJSON(w, status, "application/problem+json", map[string]any{
		"type": "about:blank", "title": title, "status": status, "code": codeStr, "detail": detail,
	})
}

func (a *API) enqueue(w http.ResponseWriter, r *http.Request) {
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "idempotency_key_required"),
			"Idempotency-Key required", "notification enqueue is an idempotent command")
		return
	}
	var req struct {
		RecipientDid string `json:"recipientDid"`
		Channel      string `json:"channel"`
		TemplateID   string `json:"templateId"`
		Param        string `json:"param"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"),
			"invalid JSON", err.Error())
		return
	}
	if req.RecipientDid == "" || req.TemplateID == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "required_fields"),
			"recipientDid and templateId are required", "")
		return
	}
	channel := req.Channel
	if channel == "" {
		channel = ChannelSMS
	}
	switch channel {
	case ChannelSMS, ChannelUSSD, ChannelEmail, ChannelPush: // DM channel enum
	default:
		writeProblem(w, http.StatusBadRequest, code("validation", "channel"),
			"channel must be SMS|EMAIL|PUSH|USSD", channel)
		return
	}
	job, fresh, err := a.svc.Enqueue(r.Context(), req.RecipientDid, channel, req.TemplateID,
		req.Param, idemKey)
	if err != nil {
		if strings.Contains(err.Error(), "unknown templateId") {
			writeProblem(w, http.StatusBadRequest, code("validation", "template"),
				"enqueue rejected", err.Error())
			return
		}
		// infrastructure failures are 503 and never leak internals (EF 7.7.3)
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"),
			"enqueue unavailable", "try again")
		return
	}
	status := http.StatusAccepted
	if !fresh {
		status = http.StatusOK // replay of the same idempotency key
	}
	writeData(w, status, job)
}

func (a *API) get(w http.ResponseWriter, r *http.Request) {
	job, found, err := a.svc.st.GetJob(r.Context(), r.PathValue("ntf"))
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"),
			"store failure", err.Error())
		return
	}
	if !found {
		writeProblem(w, http.StatusNotFound, code("not_found", "notification"),
			"no such notification job", r.PathValue("ntf"))
		return
	}
	writeData(w, http.StatusOK, job)
}

func (a *API) list(w http.ResponseWriter, r *http.Request) {
	did := r.URL.Query().Get("recipientDid")
	if did == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "recipient_did"),
			"recipientDid query param required", "")
		return
	}
	jobs, err := a.svc.st.JobsByRecipient(r.Context(), did, 50)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"),
			"store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, map[string]any{"items": jobs})
}
