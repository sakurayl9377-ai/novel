package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"login/checkin/task"
	"login/sakuragm"
	"tjgame/document"
	"tjgame/server_framework/tj/log"
	"tjgame/server_framework/tj/service"
)

const (
	// The complete retry budget stays below the backend's 20 second deadline.
	gmDeliveryRPCTimeout          = 15 * time.Second
	gmDeliveryRPCReconcileDelay   = 1 * time.Second
	gmDeliveryRPCReconcileTimeout = 3 * time.Second
	gmMailTemplate                = 2
)

type legacyGMDeliveryRPC interface {
	VerifyIdentity(sakuragm.DeliveryRequest) error
	SendMail(sakuragm.DeliveryRequest) (sakuragm.DeliveryResult, error)
}

type sakuraGMDeliveryBridge struct {
	legacy legacyGMDeliveryRPC
	mu     sync.Mutex
	locks  map[string]*deliveryRequestLock
}

type deliveryRequestLock struct {
	mu   sync.Mutex
	refs int
}

func newSakuraGMDeliveryBridge(legacy legacyGMDeliveryRPC) *sakuraGMDeliveryBridge {
	return &sakuraGMDeliveryBridge{
		legacy: legacy,
		locks:  make(map[string]*deliveryRequestLock),
	}
}

func (s *Server) initSakuraGMDelivery() {
	secret := strings.TrimSpace(os.Getenv("KDJX_GM_HMAC_SECRET"))
	catalogPath := strings.TrimSpace(os.Getenv("KDJX_GM_ITEM_CATALOG_FILE"))
	if len(secret) < 32 || catalogPath == "" {
		log.Warning("Sakura GM delivery disabled: secure configuration is incomplete")
		return
	}
	payload, err := ioutil.ReadFile(catalogPath)
	if err != nil {
		log.Warningf("Sakura GM delivery disabled: catalog read failed: %v", err)
		return
	}
	catalog := sakuragm.Catalog{}
	if err := json.Unmarshal(payload, &catalog); err != nil {
		log.Warningf("Sakura GM delivery disabled: catalog parse failed: %v", err)
		return
	}
	bridge := newSakuraGMDeliveryBridge(&serverLegacyGMDeliveryRPC{server: s})
	handler := sakuragm.NewHandler(secret, catalog, bridge)
	s.httpMux.Handle("/internal/sakura/gm/deliveries", handler)
}

func (b *sakuraGMDeliveryBridge) Deliver(request sakuragm.DeliveryRequest) (sakuragm.DeliveryResult, error) {
	lock := b.acquireRequestLock(request.RequestID)
	defer b.releaseRequestLock(request.RequestID, lock)
	if err := b.legacy.VerifyIdentity(request); err != nil {
		return sakuragm.DeliveryResult{}, err
	}
	return b.legacy.SendMail(request)
}

func (b *sakuraGMDeliveryBridge) acquireRequestLock(requestID string) *deliveryRequestLock {
	b.mu.Lock()
	lock := b.locks[requestID]
	if lock == nil {
		lock = &deliveryRequestLock{}
		b.locks[requestID] = lock
	}
	lock.refs++
	b.mu.Unlock()
	lock.mu.Lock()
	return lock
}

func (b *sakuraGMDeliveryBridge) releaseRequestLock(requestID string, lock *deliveryRequestLock) {
	lock.mu.Unlock()
	b.mu.Lock()
	defer b.mu.Unlock()
	lock.refs--
	if lock.refs == 0 && b.locks[requestID] == lock {
		delete(b.locks, requestID)
	}
}

type serverLegacyGMDeliveryRPC struct {
	server *Server
}

func (r *serverLegacyGMDeliveryRPC) VerifyIdentity(request sakuragm.DeliveryRequest) error {
	account, err := (&serverLegacyPaymentRPC{server: r.server}).AccountByName(request.GameOpenID)
	if err != nil {
		return sakuragm.NewPublicError(http.StatusBadGateway, "game_account_lookup_failed")
	}
	if account == nil || account.Name != request.GameOpenID || account.DisableFlag {
		return sakuragm.NewPublicError(http.StatusConflict, "game_account_mismatch")
	}
	accountID, err := idHex(account.ID)
	if err != nil || accountID != request.AccountID {
		return sakuragm.NewPublicError(http.StatusConflict, "game_account_mismatch")
	}
	role, ok := account.RoleInfos[request.ServerKey]
	if !ok {
		return sakuragm.NewPublicError(http.StatusConflict, "game_role_mismatch")
	}
	roleID, err := idHex(role.ID)
	if err != nil || roleID != request.RoleID {
		return sakuragm.NewPublicError(http.StatusConflict, "game_role_mismatch")
	}
	return nil
}

func (r *serverLegacyGMDeliveryRPC) SendMail(request sakuragm.DeliveryRequest) (sakuragm.DeliveryResult, error) {
	game := r.server.Game(request.ServerKey)
	if game == nil {
		return sakuragm.DeliveryResult{}, sakuragm.NewPublicError(http.StatusServiceUnavailable, "game_service_unavailable")
	}
	roleID, err := objectID(request.RoleID)
	if err != nil {
		return sakuragm.DeliveryResult{}, sakuragm.NewPublicError(http.StatusBadRequest, "invalid_delivery_identity")
	}
	attachs := map[document.Integer]int{document.Integer(request.ItemID): request.Quantity}
	call := func(timeout time.Duration, reconcileOnly bool) (interface{}, error) {
		return service.CallWithTimeout(
			game,
			"SakuraGMSendMail",
			timeout,
			task.GameServInternalPassword,
			request.RequestID,
			roleID,
			gmMailTemplate,
			request.MailSender,
			request.MailSubject,
			request.MailContent,
			attachs,
			reconcileOnly,
		)
	}
	response, err := call(gmDeliveryRPCTimeout, false)
	if err == service.ErrTimeout {
		log.Warningf(
			"Sakura GM delivery %s timed out; reconciling the same request",
			request.RequestID,
		)
		time.Sleep(gmDeliveryRPCReconcileDelay)
		response, err = call(gmDeliveryRPCReconcileTimeout, true)
	}
	if err != nil {
		return sakuragm.DeliveryResult{}, errors.New("delivery outcome unknown")
	}
	text, ok := response.(string)
	if !ok {
		return sakuragm.DeliveryResult{}, errors.New("delivery outcome unknown")
	}
	switch {
	case strings.HasPrefix(text, "ok:"):
		return sakuragm.DeliveryResult{Reference: strings.TrimPrefix(text, "ok:")}, nil
	case strings.HasPrefix(text, "existing:"):
		return sakuragm.DeliveryResult{
			Reference: strings.TrimPrefix(text, "existing:"), Reconciled: true,
		}, nil
	case text == "auth_error":
		return sakuragm.DeliveryResult{}, sakuragm.NewPublicError(http.StatusUnauthorized, "game_rpc_auth_failed")
	case text == "request_invalid" || text == "delivery_rejected" || text == "request_conflict":
		return sakuragm.DeliveryResult{}, sakuragm.NewPublicError(http.StatusConflict, text)
	default:
		return sakuragm.DeliveryResult{}, fmt.Errorf("delivery outcome unknown")
	}
}
