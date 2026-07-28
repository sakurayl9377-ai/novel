package sakuragm

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"io/ioutil"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxRequestBytes  = 16 * 1024
	defaultClockSkew = 5 * time.Minute
)

var (
	identifierPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	objectIDPattern   = regexp.MustCompile(`^[0-9a-f]{24}$`)
	openIDPattern     = regexp.MustCompile(`^sakura_[A-Za-z0-9_-]{16,96}$`)
	requestIDPattern  = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	noncePattern      = requestIDPattern
	signaturePattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type DeliveryRequest struct {
	RequestID     string `json:"requestId"`
	GameOpenID    string `json:"gameOpenId"`
	AccountID     string `json:"accountId"`
	RoleID        string `json:"roleId"`
	ServerKey     string `json:"serverKey"`
	CatalogSHA256 string `json:"catalogSha256"`
	ItemID        int    `json:"itemId"`
	Quantity      int    `json:"quantity"`
	ItemName      string `json:"itemName"`
	MailSender    string `json:"mailSender"`
	MailSubject   string `json:"mailSubject"`
	MailContent   string `json:"mailContent"`
}

type DeliveryResult struct {
	Reference  string
	Reconciled bool
}

type CatalogItem struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	MaxQuantity int    `json:"maxQuantity"`
}

type Catalog struct {
	SchemaVersion int           `json:"schemaVersion"`
	SourceSHA256  string        `json:"sourceSha256"`
	ItemCount     int           `json:"itemCount"`
	Items         []CatalogItem `json:"items"`
}

type Backend interface {
	Deliver(DeliveryRequest) (DeliveryResult, error)
}

type PublicError struct {
	Status int
	Code   string
}

func (e *PublicError) Error() string { return e.Code }

func NewPublicError(status int, code string) error {
	return &PublicError{Status: status, Code: code}
}

type Handler struct {
	secret        []byte
	backend       Backend
	catalog       map[int]CatalogItem
	catalogSHA256 string
	now           func() time.Time
	skew          time.Duration
	nonces        map[string]time.Time
	mu            sync.Mutex
}

func NewHandler(secret string, catalog Catalog, backend Backend) *Handler {
	items := make(map[int]CatalogItem, len(catalog.Items))
	catalogSHA256 := strings.ToLower(strings.TrimSpace(catalog.SourceSHA256))
	if catalog.SchemaVersion == 1 && signaturePattern.MatchString(catalogSHA256) &&
		catalog.ItemCount == len(catalog.Items) {
		for _, item := range catalog.Items {
			if item.ID > 0 && item.Name != "" && item.MaxQuantity > 0 {
				items[item.ID] = item
			}
		}
	}
	return &Handler{
		secret:        []byte(strings.TrimSpace(secret)),
		backend:       backend,
		catalog:       items,
		catalogSHA256: catalogSHA256,
		now:           time.Now,
		skew:          defaultClockSkew,
		nonces:        make(map[string]time.Time),
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		return
	}
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(r.Header.Get("Content-Type"), ";")[0]))
	if contentType != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type")
		return
	}
	if h.backend == nil || len(h.secret) < 32 || len(h.catalog) == 0 ||
		!signaturePattern.MatchString(h.catalogSHA256) {
		writeError(w, http.StatusServiceUnavailable, "gm_delivery_unavailable")
		return
	}
	body, err := h.authenticatedBody(w, r)
	if err != nil {
		writePublicError(w, err)
		return
	}
	request := DeliveryRequest{}
	decoder := json.NewDecoder(strings.NewReader(string(body)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	if err := requireJSONEOF(decoder); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_json")
		return
	}
	item, ok := h.catalog[request.ItemID]
	if err := validateRequest(request, item, ok, h.catalogSHA256); err != nil {
		writePublicError(w, err)
		return
	}
	result, err := h.backend.Deliver(request)
	if err != nil {
		writePublicError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, struct {
		OK         bool   `json:"ok"`
		Delivered  bool   `json:"delivered"`
		RequestID  string `json:"requestId"`
		Reference  string `json:"reference"`
		Reconciled bool   `json:"reconciled"`
	}{
		OK: true, Delivered: true, RequestID: request.RequestID,
		Reference: result.Reference, Reconciled: result.Reconciled,
	})
}

func validateRequest(request DeliveryRequest, item CatalogItem, itemFound bool, catalogSHA256 string) error {
	if !requestIDPattern.MatchString(strings.ToLower(request.RequestID)) ||
		!openIDPattern.MatchString(request.GameOpenID) ||
		!objectIDPattern.MatchString(request.AccountID) ||
		!objectIDPattern.MatchString(request.RoleID) ||
		request.ServerKey != "game.cn.1" {
		return NewPublicError(http.StatusBadRequest, "invalid_delivery_identity")
	}
	if request.CatalogSHA256 != catalogSHA256 {
		return NewPublicError(http.StatusConflict, "gm_catalog_version_mismatch")
	}
	if !itemFound || request.ItemName != item.Name ||
		request.Quantity <= 0 || request.Quantity > item.MaxQuantity {
		return NewPublicError(http.StatusBadRequest, "invalid_delivery_item")
	}
	if !validText(request.MailSender, 1, 32) ||
		!validText(request.MailSubject, 1, 64) ||
		!validText(request.MailContent, 1, 1000) ||
		!strings.Contains(request.MailContent, request.RequestID) {
		return NewPublicError(http.StatusBadRequest, "invalid_delivery_mail")
	}
	return nil
}

func validText(value string, minimum, maximum int) bool {
	value = strings.TrimSpace(value)
	return len([]rune(value)) >= minimum && len([]rune(value)) <= maximum &&
		!strings.ContainsAny(value, "\x00\r")
}

func (h *Handler) authenticatedBody(w http.ResponseWriter, r *http.Request) ([]byte, error) {
	timestampText := strings.TrimSpace(r.Header.Get("x-novel-timestamp"))
	nonce := strings.ToLower(strings.TrimSpace(r.Header.Get("x-novel-nonce")))
	signature := strings.ToLower(strings.TrimSpace(r.Header.Get("x-novel-signature")))
	if r.Header.Get("x-novel-signature-version") != "v1" ||
		!noncePattern.MatchString(nonce) || !signaturePattern.MatchString(signature) {
		return nil, NewPublicError(http.StatusUnauthorized, "invalid_signature")
	}
	timestamp, err := strconv.ParseInt(timestampText, 10, 64)
	if err != nil {
		return nil, NewPublicError(http.StatusUnauthorized, "invalid_signature")
	}
	now := h.now()
	delta := now.Sub(time.Unix(0, timestamp*int64(time.Millisecond)))
	if delta < -h.skew || delta > h.skew {
		return nil, NewPublicError(http.StatusUnauthorized, "stale_request")
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequestBytes)
	body, err := ioutil.ReadAll(r.Body)
	if err != nil {
		return nil, NewPublicError(http.StatusRequestEntityTooLarge, "request_too_large")
	}
	mac := hmac.New(sha256.New, h.secret)
	_, _ = io.WriteString(mac, timestampText)
	_, _ = io.WriteString(mac, "\n")
	_, _ = io.WriteString(mac, nonce)
	_, _ = io.WriteString(mac, "\n")
	_, _ = mac.Write(body)
	provided, err := hex.DecodeString(signature)
	if err != nil || !hmac.Equal(mac.Sum(nil), provided) {
		return nil, NewPublicError(http.StatusUnauthorized, "invalid_signature")
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for key, expires := range h.nonces {
		if !expires.After(now) {
			delete(h.nonces, key)
		}
	}
	if _, exists := h.nonces[nonce]; exists {
		return nil, NewPublicError(http.StatusConflict, "replayed_request")
	}
	h.nonces[nonce] = now.Add(h.skew)
	return body, nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var extra interface{}
	if err := decoder.Decode(&extra); err != io.EOF {
		return NewPublicError(http.StatusBadRequest, "invalid_json")
	}
	return nil
}

func writePublicError(w http.ResponseWriter, err error) {
	if public, ok := err.(*PublicError); ok {
		writeError(w, public.Status, public.Code)
		return
	}
	writeError(w, http.StatusServiceUnavailable, "delivery_outcome_unknown")
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}{OK: false, Error: code})
}

func writeJSON(w http.ResponseWriter, status int, value interface{}) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
