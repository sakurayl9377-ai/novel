package sakuragm

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

const testSecret = "0123456789abcdef0123456789abcdef"
const testCatalogSHA256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

type backendStub struct {
	calls int
}

func (b *backendStub) Deliver(request DeliveryRequest) (DeliveryResult, error) {
	b.calls++
	return DeliveryResult{Reference: "64a000000000000000000099"}, nil
}

func TestHandlerDeliversCatalogItem(t *testing.T) {
	backend := &backendStub{}
	handler := NewHandler(testSecret, testCatalog(), backend)
	now := time.Unix(1700000000, 0)
	handler.now = func() time.Time { return now }
	request := validRequest()
	response := performSigned(t, handler, now, "11111111-1111-4111-8111-111111111111", request)
	if response.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", response.Code, response.Body.String())
	}
	if backend.calls != 1 {
		t.Fatalf("unexpected backend calls: %d", backend.calls)
	}
	var body map[string]interface{}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body["delivered"] != true || body["requestId"] != request.RequestID {
		t.Fatalf("unexpected response: %#v", body)
	}
}

func TestHandlerRejectsUnknownItemAndQuantity(t *testing.T) {
	handler := NewHandler(testSecret, testCatalog(), &backendStub{})
	now := time.Unix(1700000000, 0)
	handler.now = func() time.Time { return now }
	request := validRequest()
	request.ItemID = 999
	response := performSigned(t, handler, now, "22222222-2222-4222-8222-222222222222", request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("unexpected unknown-item status: %d", response.Code)
	}
	request = validRequest()
	request.Quantity = 6
	response = performSigned(t, handler, now, "33333333-3333-4333-8333-333333333333", request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("unexpected quantity status: %d", response.Code)
	}
}

func TestHandlerRejectsWrongServerAndCatalog(t *testing.T) {
	handler := NewHandler(testSecret, testCatalog(), &backendStub{})
	now := time.Unix(1700000000, 0)
	handler.now = func() time.Time { return now }
	request := validRequest()
	request.ServerKey = "game.cn.2"
	response := performSigned(t, handler, now, "55555555-5555-4555-8555-555555555555", request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("unexpected server status: %d", response.Code)
	}
	request = validRequest()
	request.CatalogSHA256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	response = performSigned(t, handler, now, "66666666-6666-4666-8666-666666666666", request)
	if response.Code != http.StatusConflict {
		t.Fatalf("unexpected catalog status: %d", response.Code)
	}
}

func TestHandlerRejectsReplayAndUnsignedRequests(t *testing.T) {
	handler := NewHandler(testSecret, testCatalog(), &backendStub{})
	now := time.Unix(1700000000, 0)
	handler.now = func() time.Time { return now }
	nonce := "44444444-4444-4444-8444-444444444444"
	first := performSigned(t, handler, now, nonce, validRequest())
	if first.Code != http.StatusOK {
		t.Fatalf("unexpected first status: %d", first.Code)
	}
	replay := performSigned(t, handler, now, nonce, validRequest())
	if replay.Code != http.StatusConflict {
		t.Fatalf("unexpected replay status: %d", replay.Code)
	}
	unsigned := httptest.NewRequest(http.MethodPost, "/internal/sakura/gm/deliveries", bytes.NewReader([]byte("{}")))
	unsigned.Header.Set("content-type", "application/json")
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, unsigned)
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("unexpected unsigned status: %d", recorder.Code)
	}
}

func testCatalog() Catalog {
	return Catalog{
		SchemaVersion: 1,
		SourceSHA256:  testCatalogSHA256,
		ItemCount:     1,
		Items: []CatalogItem{{
			ID: 11, Name: "甘甜冰水", MaxQuantity: 5,
		}},
	}
}

func validRequest() DeliveryRequest {
	requestID := "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	return DeliveryRequest{
		RequestID: requestID, GameOpenID: "sakura_abcdefghijklmnop",
		AccountID: "64a000000000000000000001",
		RoleID:    "64a000000000000000000002", ServerKey: "game.cn.1",
		CatalogSHA256: testCatalogSHA256,
		ItemID:        11, ItemName: "甘甜冰水", Quantity: 2,
		MailSender: "Sakura 运营", MailSubject: "物品发放",
		MailContent: "管理员已向你发放物品。\n\n发放单号：" + requestID,
	}
}

func performSigned(t *testing.T, handler http.Handler, now time.Time, nonce string, request DeliveryRequest) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	timestamp := strconv.FormatInt(now.UnixNano()/int64(time.Millisecond), 10)
	mac := hmac.New(sha256.New, []byte(testSecret))
	_, _ = mac.Write([]byte(timestamp + "\n" + nonce + "\n"))
	_, _ = mac.Write(body)
	req := httptest.NewRequest(http.MethodPost, "/internal/sakura/gm/deliveries", bytes.NewReader(body))
	req.Header.Set("content-type", "application/json")
	req.Header.Set("x-novel-signature-version", "v1")
	req.Header.Set("x-novel-timestamp", timestamp)
	req.Header.Set("x-novel-nonce", nonce)
	req.Header.Set("x-novel-signature", hex.EncodeToString(mac.Sum(nil)))
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}
