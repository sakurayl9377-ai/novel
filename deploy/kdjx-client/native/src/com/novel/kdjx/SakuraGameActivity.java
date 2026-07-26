package com.novel.kdjx;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.security.KeyPairGeneratorSpec;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.cocos2dx.lua.AppActivity;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.math.BigInteger;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.Charset;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.util.Calendar;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import javax.security.auth.x500.X500Principal;

import www.tianji.finalsdk.CallInfo;
import www.tianji.finalsdk.MessageHandler;

/**
 * Replaces the legacy launch activity with a narrow Sakura bridge. It never
 * contains the server-to-server SSO secret and never accepts credentials from
 * a deep link. The only long-lived value is encrypted in this APK's Android
 * Keystore namespace after the public device authorization flow completes.
 */
public final class SakuraGameActivity extends AppActivity {
    private static final Charset UTF_8 = Charset.forName("UTF-8");
    private static final String SAKURA_PACKAGE = "com.novel.novel_app";
    private static final String API_ORIGIN = "__KDJX_API_ORIGIN__";
    private static final String DEVICE_CREATE_URL =
            API_ORIGIN + "/games/kdjx/device-authorizations";
    private static final String DEVICE_TOKEN_URL =
            API_ORIGIN + "/games/kdjx/device-authorizations/token";
    private static final String LOGIN_TICKET_URL =
            API_ORIGIN + "/games/kdjx/sessions/login-ticket";
    private static final long MAX_DEVICE_WAIT_MS = 10L * 60L * 1000L;
    private static final long MAX_PAYMENT_WAIT_MS = 15L * 60L * 1000L;
    private static final SecureRandom RANDOM = new SecureRandom();

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Object loginLock = new Object();
    private final Object paymentLock = new Object();

    private volatile PendingLogin pendingLogin;
    private volatile PendingPayment pendingPayment;
    private volatile String expectedUserId = "";
    private volatile boolean destroyed;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        captureExpectedUserId(getIntent());
        handleSakuraReturn(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        captureExpectedUserId(intent);
        handleSakuraReturn(intent);
    }

    @Override
    protected void onDestroy() {
        synchronized (loginLock) {
            destroyed = true;
            pendingLogin = null;
            main.removeCallbacksAndMessages(null);
        }
        io.shutdownNow();
        super.onDestroy();
    }

    /** Invoked by app.sdk.none through the existing MessageHandler bridge. */
    public void sakuraLogin(final CallInfo callInfo) {
        if (callInfo == null || destroyed) return;
        final PendingLogin request;
        synchronized (loginLock) {
            if (pendingLogin != null) {
                reply(
                        callInfo,
                        loginReply("error", "", "login_in_progress"));
                return;
            }
            request = new PendingLogin(callInfo, expectedUserId);
            pendingLogin = request;
        }
        final String credential = SessionVault.read(this);
        if (isCredential(credential)) {
            exchangeLoginTicket(request, credential);
            return;
        }
        final String pendingDeviceCode = pendingDeviceCode();
        if (isDeviceCode(pendingDeviceCode) &&
                System.currentTimeMillis() < pendingDeviceDeadline()) {
            pollForCredential(pendingDeviceCode, request);
            return;
        }
        beginDeviceAuthorization(request);
    }

    private void captureExpectedUserId(Intent intent) {
        if (intent == null) {
            expectedUserId = "";
            return;
        }
        if (intent.hasExtra("sakura_expected_user_id")) {
            String value = nonNull(
                    intent.getStringExtra("sakura_expected_user_id"));
            expectedUserId = isCanonicalUserId(value) ? value : "";
            return;
        }
        boolean sakuraReturn =
                intent.hasExtra("sakura_device_code") ||
                intent.hasExtra("sakura_payment_order_id");
        if (!sakuraReturn) expectedUserId = "";
    }

    private void exchangeLoginTicket(
            final PendingLogin request,
            final String credential) {
        executeIo(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject payload = new JSONObject();
                    payload.put("credential", credential);
                    HttpReply response = postJson(LOGIN_TICKET_URL, payload);
                    if (!isPendingLogin(request)) return;
                    if (response.status == 401) {
                        SessionVault.clear(SakuraGameActivity.this);
                        beginDeviceAuthorization(request);
                        return;
                    }
                    if (response.status < 200 || response.status >= 300 ||
                            !response.body.optBoolean("ok", false)) {
                        throw new IllegalStateException("login_ticket_unavailable");
                    }
                    String ticket = response.body.optString("ticket", "");
                    if (!isLoginTicket(ticket) ||
                            response.body.optInt("ticketExpiresIn", 0) != 60) {
                        throw new IllegalStateException("login_ticket_invalid");
                    }
                    String credentialUserId = response.body.optString("userId", "");
                    if (!isCanonicalUserId(credentialUserId)) {
                        throw new IllegalStateException("login_ticket_invalid");
                    }
                    String requiredUserId = request.requiredUserId;
                    if (requiredUserId.length() > 0 &&
                            !requiredUserId.equals(credentialUserId)) {
                        SessionVault.clear(SakuraGameActivity.this);
                        beginDeviceAuthorization(request);
                        return;
                    }
                    if (isPendingLogin(request)) {
                        clearPendingLogin(request);
                        reply(
                                request.callback,
                                loginReply("ok", ticket, ""));
                    }
                } catch (Exception ignored) {
                    if (isPendingLogin(request)) {
                        clearPendingLogin(request);
                        reply(
                                request.callback,
                                loginReply(
                                        "error",
                                        "",
                                        "login_ticket_unavailable"));
                    }
                }
            }
        });
    }

    /** Starts Sakura coin payment without changing the game's displayed yuan price. */
    public void sakuraPay(final CallInfo callInfo) {
        if (callInfo == null) return;
        PendingPayment request = null;
        try {
            final JSONObject payload = new JSONObject(nonNull(callInfo.bundle));
            final String orderId = payload.optString("gameOrderId", "");
            final String productId = payload.optString("productId", "");
            final String accountId = payload.optString("accountId", "");
            final String roleId = payload.optString("roleId", "");
            final String serverKey = payload.optString("serverKey", "");
            final String yyId = payload.optString("yyId", "");
            final String csvId = payload.optString("csvId", "");
            if (!isIdentifier(orderId) || !isIdentifier(productId) ||
                    !isIdentifier(accountId) || !isIdentifier(roleId) ||
                    !isIdentifier(serverKey) || !isIdentifier(yyId) ||
                    !isIdentifier(csvId)) {
                reply(callInfo, paymentReply("invalid_request"));
                return;
            }

            final long now = System.currentTimeMillis();
            synchronized (paymentLock) {
                StoredPaymentResult completed = readStoredPaymentResult(now);
                if (completed != null) {
                    if (orderId.equals(completed.orderId)) {
                        if (tryReply(
                                callInfo,
                                paymentReply(completed.status))) {
                            clearStoredPaymentResult(completed);
                        }
                        return;
                    }
                    clearStoredPaymentResult(completed);
                }
                PendingPayment active = pendingPayment;
                if (active != null && !active.isActive(now)) {
                    pendingPayment = null;
                    clearStoredPayment(active);
                    reply(active.callback, paymentReply("payment_expired"));
                    active = null;
                }
                if (active != null) {
                    reply(callInfo, paymentReply("payment_in_progress"));
                    return;
                }

                PendingPayment stored = readStoredPayment(now);
                if (stored != null && !orderId.equals(stored.orderId)) {
                    reply(callInfo, paymentReply("payment_in_progress"));
                    return;
                }
                if (stored == null) {
                    final String nonce = newPaymentReturnNonce();
                    final long deadline = now + MAX_PAYMENT_WAIT_MS;
                    request = new PendingPayment(
                            callInfo,
                            orderId,
                            nonce,
                            now,
                            deadline);
                    if (!writeStoredPayment(request)) {
                        throw new IllegalStateException("payment_state_failed");
                    }
                } else {
                    request = new PendingPayment(
                            callInfo,
                            stored.orderId,
                            stored.returnNonce,
                            stored.capturedAt,
                            stored.deadline);
                }
                pendingPayment = request;
            }

            Uri paymentUri = new Uri.Builder()
                    .scheme("sakura-novel")
                    .authority("game")
                    .appendPath("kdjx")
                    .appendPath("pay")
                    .appendQueryParameter("gameOrderId", orderId)
                    .appendQueryParameter("productId", productId)
                    .appendQueryParameter("accountId", accountId)
                    .appendQueryParameter("roleId", roleId)
                    .appendQueryParameter("serverKey", serverKey)
                    .appendQueryParameter("yyId", yyId)
                    .appendQueryParameter("csvId", csvId)
                    .appendQueryParameter(
                            "returnNonce",
                            request.returnNonce)
                    .build();
            Intent intent = new Intent(Intent.ACTION_VIEW, paymentUri)
                    .setPackage(SAKURA_PACKAGE)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (intent.resolveActivity(getPackageManager()) == null) {
                clearPendingPayment(request);
                reply(callInfo, paymentReply("sakura_app_missing"));
                return;
            }
            startActivity(intent);
        } catch (Exception ignored) {
            if (request != null) clearPendingPayment(request);
            reply(callInfo, paymentReply("invalid_request"));
        }
    }

    /** Allows the game logout path to revoke this device-local session copy. */
    public void sakuraClearSession(final CallInfo callInfo) {
        SessionVault.clear(this);
        reply(callInfo, simpleReply("ok", ""));
    }

    private void beginDeviceAuthorization(final PendingLogin request) {
        executeIo(new Runnable() {
            @Override
            public void run() {
                try {
                    if (!isPendingLogin(request)) return;
                    HttpReply response = postJson(DEVICE_CREATE_URL, new JSONObject());
                    if (!isPendingLogin(request)) return;
                    JSONObject body = response.body;
                    String deviceCode = body.optString("deviceCode", "");
                    String userCode = normalizeUserCode(
                            body.optString("userCode", ""));
                    String verificationUriComplete = body.optString(
                            "verificationUriComplete", "");
                    int expiresIn = body.optInt("expiresIn", 0);
                    if (response.status < 200 || response.status >= 300 ||
                            !isDeviceCode(deviceCode) ||
                            userCode.length() == 0 ||
                            !isAuthorizationUri(
                                    verificationUriComplete,
                                    deviceCode,
                                    userCode) ||
                            expiresIn <= 0 || expiresIn > 900) {
                        throw new IllegalStateException("authorization_start_failed");
                    }
                    long deadline = System.currentTimeMillis() + Math.min(
                            MAX_DEVICE_WAIT_MS, expiresIn * 1000L);
                    launchSakuraAuthorization(
                            request,
                            deviceCode,
                            userCode,
                            deadline,
                            verificationUriComplete);
                } catch (Exception ignored) {
                    if (isPendingLogin(request)) {
                        clearPendingLogin(request);
                        reply(
                                request.callback,
                                loginReply(
                                        "error",
                                        "",
                                        "authorization_start_failed"));
                    }
                }
            }
        });
    }

    private void launchSakuraAuthorization(
            final PendingLogin request,
            final String deviceCode,
            final String userCode,
            final long deadline,
            final String verificationUriComplete) {
        main.post(new Runnable() {
            @Override
            public void run() {
                try {
                    if (!isPendingLogin(request)) return;
                    if (isFinishing()) {
                        throw new IllegalStateException("sakura_app_missing");
                    }
                    new AlertDialog.Builder(SakuraGameActivity.this)
                            .setTitle(
                                    "\u53e3\u888b\u89c9\u9192 Sakura " +
                                    "\u767b\u5f55")
                            .setMessage(
                                    "\u672c\u6b21\u767b\u5f55\u6388\u6743" +
                                    "\u7801\uff1a\n\n" + userCode +
                                    "\n\n\u8bf7\u4ec5\u5728 Sakura App " +
                                    "\u663e\u793a\u76f8\u540c\u6388\u6743" +
                                    "\u7801\u65f6\u5141\u8bb8\u767b\u5f55" +
                                    "\u3002")
                            .setCancelable(false)
                            .setNegativeButton(
                                    "\u53d6\u6d88",
                                    new DialogInterface.OnClickListener() {
                                        @Override
                                        public void onClick(
                                                DialogInterface dialog,
                                                int which) {
                                            clearPendingDeviceCode();
                                            if (!isPendingLogin(request)) return;
                                            clearPendingLogin(request);
                                            reply(
                                                    request.callback,
                                                    loginReply(
                                                            "error",
                                                            "",
                                                            "authorization_cancelled"));
                                        }
                                    })
                            .setPositiveButton(
                                    "\u6253\u5f00 Sakura",
                                    new DialogInterface.OnClickListener() {
                                        @Override
                                        public void onClick(
                                                DialogInterface dialog,
                                                int which) {
                                            if (!isPendingLogin(request)) return;
                                            openSakuraAuthorization(
                                                    request,
                                                    deviceCode,
                                                    deadline,
                                                    verificationUriComplete);
                                        }
                                    })
                            .show();
                } catch (Exception ignored) {
                    clearPendingDeviceCode();
                    if (isPendingLogin(request)) {
                        clearPendingLogin(request);
                        reply(
                                request.callback,
                                loginReply("error", "", "sakura_app_missing"));
                    }
                }
            }
        });
    }

    private void openSakuraAuthorization(
            PendingLogin request,
            String deviceCode,
            long deadline,
            String verificationUriComplete) {
        try {
            if (!isPendingLogin(request)) return;
            Intent intent = new Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse(verificationUriComplete))
                    .setPackage(SAKURA_PACKAGE)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (intent.resolveActivity(getPackageManager()) == null) {
                throw new IllegalStateException("sakura_app_missing");
            }
            if (!isPendingLogin(request)) return;
            boolean saved = pendingPreferences().edit()
                    .putString("device_code", deviceCode)
                    .putLong("device_deadline", deadline)
                    .commit();
            if (!saved) {
                throw new IllegalStateException("authorization_state_failed");
            }
            startActivity(intent);
        } catch (Exception ignored) {
            clearPendingDeviceCode();
            if (isPendingLogin(request)) {
                clearPendingLogin(request);
                reply(
                        request.callback,
                        loginReply("error", "", "sakura_app_missing"));
            }
        }
    }

    private void handleSakuraReturn(Intent intent) {
        if (intent == null) return;
        String deviceCode = nonNull(intent.getStringExtra("sakura_device_code"));
        String authorizationStatus = nonNull(
                intent.getStringExtra("sakura_authorization_status"));
        PendingLogin login = pendingLogin;
        if (login != null && isDeviceCode(deviceCode) &&
                deviceCode.equals(pendingDeviceCode())) {
            if ("approved".equals(authorizationStatus)) {
                // Approval is only a wake-up. The credential still comes from
                // the server-side device-code exchange.
                pollForCredential(deviceCode, login);
            } else if ("denied".equals(authorizationStatus) ||
                    "cancelled".equals(authorizationStatus)) {
                if (isPendingLogin(login)) {
                    clearPendingLogin(login);
                    clearPendingDeviceCode();
                    reply(
                            login.callback,
                            loginReply(
                                    "error",
                                    "",
                                    "denied".equals(authorizationStatus)
                                            ? "authorization_denied"
                                            : "authorization_cancelled"));
                }
            }
        }

        String orderId = nonNull(intent.getStringExtra("sakura_payment_order_id"));
        String paymentStatus = nonNull(intent.getStringExtra("sakura_payment_status"));
        String returnNonce = nonNull(intent.getStringExtra("sakura_payment_return_nonce"));
        PendingPayment payment = null;
        StoredPaymentResult completed = null;
        boolean expired = false;
        synchronized (paymentLock) {
            PendingPayment active = pendingPayment;
            long now = System.currentTimeMillis();
            if (active != null && !active.isActive(now)) {
                pendingPayment = null;
                clearStoredPayment(active);
                payment = active;
                expired = true;
            } else {
                PendingPayment stored = active != null
                        ? active : readStoredPayment(now);
                if (stored != null) {
                    String resolvedStatus = PaymentRecovery.returnedStatus(
                            stored.orderId,
                            stored.returnNonce,
                            stored.capturedAt,
                            stored.deadline,
                            orderId,
                            returnNonce,
                            paymentStatus,
                            now,
                            MAX_PAYMENT_WAIT_MS);
                    if (resolvedStatus.length() > 0) {
                        completed = completeStoredPayment(
                                stored,
                                resolvedStatus);
                        if (completed != null) {
                            if (pendingPayment == active) pendingPayment = null;
                            payment = stored;
                        }
                    }
                }
            }
        }
        if (payment != null) {
            if (expired) {
                reply(payment.callback, paymentReply("payment_expired"));
            } else if (completed != null && tryReply(
                    payment.callback,
                    paymentReply(completed.status))) {
                clearStoredPaymentResult(completed);
            }
        }
    }

    private void pollForCredential(
            final String deviceCode,
            final PendingLogin request) {
        executeIo(new Runnable() {
            @Override
            public void run() {
                try {
                    if (!isPendingLogin(request)) return;
                    if (System.currentTimeMillis() >= pendingDeviceDeadline()) {
                        throw new IllegalStateException("authorization_expired");
                    }
                    JSONObject payload = new JSONObject();
                    payload.put("deviceCode", deviceCode);
                    HttpReply response = postJson(DEVICE_TOKEN_URL, payload);
                    if (!isPendingLogin(request)) return;
                    if (response.status == 202 || "pending".equals(response.body.optString("status"))) {
                        int retryAfter = response.body.optInt("retryAfter", 5);
                        scheduleCredentialPoll(deviceCode, request, retryAfter);
                        return;
                    }
                    String credential = response.body.optString("credential", "");
                    if (response.status < 200 || response.status >= 300 ||
                            !"authorized".equals(response.body.optString("status")) ||
                            !isCredential(credential)) {
                        throw new IllegalStateException("authorization_failed");
                    }
                    if (!isPendingLogin(request)) return;
                    SessionVault.write(SakuraGameActivity.this, credential);
                    clearPendingDeviceCode();
                    exchangeLoginTicket(request, credential);
                } catch (Exception ignored) {
                    if (isPendingLogin(request)) {
                        clearPendingDeviceCode();
                        clearPendingLogin(request);
                        reply(
                                request.callback,
                                loginReply(
                                        "error",
                                        "",
                                        "authorization_failed"));
                    }
                }
            }
        });
    }

    private void scheduleCredentialPoll(
            final String deviceCode,
            final PendingLogin request,
            int retryAfter) {
        int seconds = Math.max(2, Math.min(15, retryAfter));
        synchronized (loginLock) {
            if (destroyed || pendingLogin != request) return;
            main.postDelayed(new Runnable() {
                @Override
                public void run() {
                    if (isPendingLogin(request)) {
                        pollForCredential(deviceCode, request);
                    }
                }
            }, seconds * 1000L);
        }
    }

    private void executeIo(Runnable task) {
        if (destroyed) return;
        try {
            io.execute(task);
        } catch (RejectedExecutionException ignored) {
            // The activity may be destroyed between the gate and submission.
        }
    }

    private boolean isPendingLogin(PendingLogin request) {
        return request != null && !destroyed && pendingLogin == request;
    }

    private void clearPendingLogin(PendingLogin request) {
        synchronized (loginLock) {
            if (pendingLogin == request) pendingLogin = null;
        }
    }

    private HttpReply postJson(String endpoint, JSONObject request) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(endpoint).openConnection();
        connection.setRequestMethod("POST");
        connection.setConnectTimeout(10_000);
        connection.setReadTimeout(15_000);
        connection.setDoOutput(true);
        connection.setInstanceFollowRedirects(false);
        connection.setUseCaches(false);
        connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        connection.setRequestProperty("Accept", "application/json");
        connection.setRequestProperty("Cache-Control", "no-store");
        byte[] bytes = request.toString().getBytes(UTF_8);
        connection.setFixedLengthStreamingMode(bytes.length);
        OutputStream output = null;
        try {
            output = connection.getOutputStream();
            output.write(bytes);
            output.flush();
            int status = connection.getResponseCode();
            InputStream input = status >= 400
                    ? connection.getErrorStream() : connection.getInputStream();
            return new HttpReply(status, readJson(input));
        } finally {
            if (output != null) output.close();
            connection.disconnect();
        }
    }

    private JSONObject readJson(InputStream input) throws Exception {
        if (input == null) return new JSONObject();
        BufferedReader reader = new BufferedReader(new InputStreamReader(input, UTF_8));
        StringBuilder text = new StringBuilder();
        String line;
        while ((line = reader.readLine()) != null) text.append(line);
        reader.close();
        return text.length() == 0 ? new JSONObject() : new JSONObject(text.toString());
    }

    private SharedPreferences pendingPreferences() {
        return getSharedPreferences("sakura_kdjx_pending", Activity.MODE_PRIVATE);
    }

    private String pendingDeviceCode() {
        return pendingPreferences().getString("device_code", "");
    }

    private long pendingDeviceDeadline() {
        return pendingPreferences().getLong("device_deadline", 0L);
    }

    private void clearPendingDeviceCode() {
        pendingPreferences().edit()
                .remove("device_code")
                .remove("device_deadline")
                .apply();
    }

    private PendingPayment readStoredPayment(long now) {
        SharedPreferences preferences = pendingPreferences();
        PendingPayment stored = new PendingPayment(
                null,
                nonNull(preferences.getString("payment_order", "")),
                nonNull(preferences.getString("payment_return_nonce", "")),
                preferences.getLong("payment_captured_at", 0L),
                preferences.getLong("payment_deadline", 0L));
        if (stored.isActive(now)) return stored;
        clearStoredPayment(null);
        return null;
    }

    private boolean writeStoredPayment(PendingPayment payment) {
        return pendingPreferences().edit()
                .remove("payment_result_order")
                .remove("payment_result_status")
                .remove("payment_result_deadline")
                .putString("payment_order", payment.orderId)
                .putString("payment_return_nonce", payment.returnNonce)
                .putLong("payment_captured_at", payment.capturedAt)
                .putLong("payment_deadline", payment.deadline)
                .commit();
    }

    private StoredPaymentResult readStoredPaymentResult(long now) {
        SharedPreferences preferences = pendingPreferences();
        StoredPaymentResult stored = new StoredPaymentResult(
                nonNull(preferences.getString("payment_result_order", "")),
                nonNull(preferences.getString("payment_result_status", "")),
                preferences.getLong("payment_result_deadline", 0L));
        if (stored.isActive(now)) return stored;
        clearStoredPaymentResult(null);
        return null;
    }

    private StoredPaymentResult completeStoredPayment(
            PendingPayment expected,
            String status) {
        if (expected == null || !isPaymentStatus(status)) return null;
        SharedPreferences preferences = pendingPreferences();
        if (!expected.orderId.equals(nonNull(
                preferences.getString("payment_order", ""))) ||
                !expected.returnNonce.equals(nonNull(
                        preferences.getString("payment_return_nonce", ""))) ||
                expected.capturedAt != preferences.getLong(
                        "payment_captured_at", 0L) ||
                expected.deadline != preferences.getLong(
                        "payment_deadline", 0L)) {
            return null;
        }
        StoredPaymentResult completed = new StoredPaymentResult(
                expected.orderId,
                status,
                expected.deadline);
        boolean saved = preferences.edit()
                .remove("payment_order")
                .remove("payment_return_nonce")
                .remove("payment_captured_at")
                .remove("payment_deadline")
                .putString("payment_result_order", completed.orderId)
                .putString("payment_result_status", completed.status)
                .putLong("payment_result_deadline", completed.deadline)
                .commit();
        return saved ? completed : null;
    }

    private void clearPendingPayment(PendingPayment payment) {
        synchronized (paymentLock) {
            if (pendingPayment == payment) pendingPayment = null;
            clearStoredPayment(payment);
        }
    }

    private void clearStoredPayment(PendingPayment expected) {
        SharedPreferences preferences = pendingPreferences();
        if (expected != null &&
                (!expected.orderId.equals(nonNull(
                        preferences.getString("payment_order", ""))) ||
                !expected.returnNonce.equals(nonNull(
                        preferences.getString("payment_return_nonce", ""))))) {
            return;
        }
        preferences.edit()
                .remove("payment_order")
                .remove("payment_return_nonce")
                .remove("payment_captured_at")
                .remove("payment_deadline")
                .commit();
    }

    private void clearStoredPaymentResult(StoredPaymentResult expected) {
        SharedPreferences preferences = pendingPreferences();
        if (expected != null &&
                (!expected.orderId.equals(nonNull(
                        preferences.getString("payment_result_order", ""))) ||
                !expected.status.equals(nonNull(
                        preferences.getString("payment_result_status", ""))) ||
                expected.deadline != preferences.getLong(
                        "payment_result_deadline", 0L))) {
            return;
        }
        preferences.edit()
                .remove("payment_result_order")
                .remove("payment_result_status")
                .remove("payment_result_deadline")
                .commit();
    }

    private void reply(CallInfo callInfo, String payload) {
        tryReply(callInfo, payload);
    }

    private boolean tryReply(CallInfo callInfo, String payload) {
        if (callInfo == null) return false;
        try {
            Field field = AppActivity.class.getDeclaredField("messageHandler");
            field.setAccessible(true);
            MessageHandler handler = (MessageHandler) field.get(this);
            if (handler == null) return false;
            handler.callbackToLua(callInfo.msgID, payload);
            return true;
        } catch (Exception ignored) {
            // The bridge can be torn down while Android switches activities.
            return false;
        }
    }

    private static String loginReply(String status, String ticket, String error) {
        try {
            JSONObject result = new JSONObject();
            result.put("status", status);
            if (!ticket.isEmpty()) result.put("ticket", ticket);
            if (!error.isEmpty()) result.put("error", error);
            return result.toString();
        } catch (Exception ignored) {
            return "{\"status\":\"error\"}";
        }
    }

    private static String paymentReply(String status) {
        return simpleReply(status, "");
    }

    private static String simpleReply(String status, String error) {
        try {
            JSONObject result = new JSONObject();
            result.put("status", status);
            if (!error.isEmpty()) result.put("error", error);
            return result.toString();
        } catch (Exception ignored) {
            return "{\"status\":\"error\"}";
        }
    }

    private static boolean isAuthorizationUri(
            String value,
            String deviceCode,
            String userCode) {
        try {
            Uri uri = Uri.parse(value);
            return "sakura-novel".equals(uri.getScheme()) &&
                    "game".equals(uri.getHost()) &&
                    uri.getPort() == -1 &&
                    uri.getUserInfo() == null &&
                    uri.getFragment() == null &&
                    "/kdjx/authorize".equals(uri.getPath()) &&
                    uri.getQueryParameterNames().size() == 2 &&
                    uri.getQueryParameterNames().contains("device_code") &&
                    uri.getQueryParameterNames().contains("user_code") &&
                    uri.getQueryParameters("device_code").size() == 1 &&
                    uri.getQueryParameters("user_code").size() == 1 &&
                    deviceCode.equals(uri.getQueryParameter("device_code")) &&
                    userCode.equals(normalizeUserCode(
                            uri.getQueryParameter("user_code")));
        } catch (Exception ignored) {
            return false;
        }
    }

    private static String normalizeUserCode(String value) {
        if (value == null) return "";
        String normalized = value.trim().toUpperCase(java.util.Locale.ROOT);
        if (!normalized.matches(
                "(?:[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}|" +
                "[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-" +
                "[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4})")) {
            return "";
        }
        String compact = normalized.replace("-", "");
        return compact.substring(0, 4) + "-" + compact.substring(4);
    }

    private static boolean isDeviceCode(String value) {
        return value != null && value.startsWith("kdjx_device_") &&
                value.length() >= 52 && value.length() <= 140 &&
                value.matches("[A-Za-z0-9_-]+");
    }

    private static boolean isCredential(String value) {
        return value != null && value.startsWith("kdjx_session_") &&
                value.length() >= 53 && value.length() <= 160 &&
                value.matches("[A-Za-z0-9_-]+");
    }

    private static boolean isLoginTicket(String value) {
        return value != null && value.startsWith("kdjx_login_") &&
                value.length() >= 51 && value.length() <= 160 &&
                value.matches("[A-Za-z0-9_-]+");
    }

    private static boolean isIdentifier(String value) {
        return value != null && value.length() >= 1 && value.length() <= 128 &&
                value.matches("[A-Za-z0-9._:-]+");
    }

    private static boolean isCanonicalUserId(String value) {
        if (value == null || !value.matches("[1-9][0-9]{0,18}")) return false;
        try {
            return Long.parseLong(value) > 0L;
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private static boolean isPaymentStatus(String value) {
        return PaymentRecovery.isPaymentStatus(value);
    }

    private static String newPaymentReturnNonce() {
        byte[] bytes = new byte[32];
        RANDOM.nextBytes(bytes);
        return Base64.encodeToString(
                bytes,
                Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static boolean isPaymentReturnNonce(String value) {
        return value != null && value.matches("[A-Za-z0-9_-]{43}");
    }

    private static boolean sameReturnNonce(String actual, String expected) {
        if (!isPaymentReturnNonce(actual) || !isPaymentReturnNonce(expected)) {
            return false;
        }
        return MessageDigest.isEqual(
                actual.getBytes(UTF_8), expected.getBytes(UTF_8));
    }

    private static String nonNull(String value) {
        return value == null ? "" : value;
    }

    private static final class PendingLogin {
        final CallInfo callback;
        final String requiredUserId;

        PendingLogin(CallInfo callback, String requiredUserId) {
            this.callback = callback;
            this.requiredUserId = nonNull(requiredUserId);
        }
    }

    private static final class PendingPayment {
        final CallInfo callback;
        final String orderId;
        final String returnNonce;
        final long capturedAt;
        final long deadline;

        PendingPayment(
                CallInfo callback,
                String orderId,
                String returnNonce,
                long capturedAt,
                long deadline) {
            this.callback = callback;
            this.orderId = nonNull(orderId);
            this.returnNonce = nonNull(returnNonce);
            this.capturedAt = capturedAt;
            this.deadline = deadline;
        }

        boolean isActive(long now) {
            return isIdentifier(orderId) &&
                    isPaymentReturnNonce(returnNonce) &&
                    capturedAt > 0L && capturedAt <= now &&
                    deadline > capturedAt &&
                    deadline - capturedAt == MAX_PAYMENT_WAIT_MS &&
                    deadline > now;
        }
    }

    private static final class StoredPaymentResult {
        final String orderId;
        final String status;
        final long deadline;

        StoredPaymentResult(String orderId, String status, long deadline) {
            this.orderId = nonNull(orderId);
            this.status = nonNull(status);
            this.deadline = deadline;
        }

        boolean isActive(long now) {
            return isIdentifier(orderId) && isPaymentStatus(status) &&
                    deadline > now;
        }
    }

    private static final class HttpReply {
        final int status;
        final JSONObject body;

        HttpReply(int status, JSONObject body) {
            this.status = status;
            this.body = body;
        }
    }

    private static final class SessionVault {
        private static final String PREFS = "sakura_kdjx_session";
        private static final String VALUE = "credential";
        private static final String ALIAS = "novel.kdjx.session.v1";

        static String read(Context context) {
            try {
                String encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                        .getString(VALUE, "");
                if (encoded == null || encoded.isEmpty()) return "";
                if (encoded.startsWith("gcm:")) return decryptGcm(encoded);
                if (encoded.startsWith("rsa:")) return decryptRsa(encoded);
            } catch (Exception ignored) {
                clear(context);
            }
            return "";
        }

        static void write(Context context, String credential) throws Exception {
            if (!isCredential(credential)) throw new IllegalArgumentException("credential_invalid");
            String encrypted;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                encrypted = encryptGcm(credential);
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                encrypted = encryptRsa(context, credential);
            } else {
                throw new IllegalStateException("keystore_unsupported");
            }
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .putString(VALUE, encrypted)
                    .apply();
        }

        static void clear(Context context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                    .remove(VALUE)
                    .apply();
        }

        private static String encryptGcm(String plaintext) throws Exception {
            SecretKey key = gcmKey();
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, key);
            byte[] encrypted = cipher.doFinal(plaintext.getBytes(UTF_8));
            return "gcm:" + Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":" +
                    Base64.encodeToString(encrypted, Base64.NO_WRAP);
        }

        private static String decryptGcm(String encoded) throws Exception {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return "";
            String[] pieces = encoded.split(":", -1);
            if (pieces.length != 3) return "";
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, gcmKey(), new GCMParameterSpec(
                    128, Base64.decode(pieces[1], Base64.NO_WRAP)));
            return new String(cipher.doFinal(Base64.decode(pieces[2], Base64.NO_WRAP)), UTF_8);
        }

        private static SecretKey gcmKey() throws Exception {
            KeyStore store = androidKeyStore();
            java.security.Key existing = store.getKey(ALIAS, null);
            if (existing instanceof SecretKey) return (SecretKey) existing;
            if (existing != null) store.deleteEntry(ALIAS);
            KeyGenerator generator = KeyGenerator.getInstance(
                    KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build());
            return generator.generateKey();
        }

        private static String encryptRsa(Context context, String plaintext) throws Exception {
            KeyPair pair = rsaKeyPair(context);
            Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
            cipher.init(Cipher.ENCRYPT_MODE, pair.getPublic());
            return "rsa:" + Base64.encodeToString(
                    cipher.doFinal(plaintext.getBytes(UTF_8)), Base64.NO_WRAP);
        }

        private static String decryptRsa(String encoded) throws Exception {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.JELLY_BEAN_MR2) return "";
            if (!encoded.startsWith("rsa:")) return "";
            KeyStore store = androidKeyStore();
            java.security.Key key = store.getKey(ALIAS, null);
            if (!(key instanceof PrivateKey)) return "";
            Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
            cipher.init(Cipher.DECRYPT_MODE, (PrivateKey) key);
            return new String(cipher.doFinal(Base64.decode(
                    encoded.substring(4), Base64.NO_WRAP)), UTF_8);
        }

        private static KeyPair rsaKeyPair(Context context) throws Exception {
            KeyStore store = androidKeyStore();
            java.security.Key existing = store.getKey(ALIAS, null);
            if (existing instanceof PrivateKey) {
                Certificate certificate = store.getCertificate(ALIAS);
                return new KeyPair(certificate.getPublicKey(), (PrivateKey) existing);
            }
            if (existing != null) store.deleteEntry(ALIAS);
            Calendar start = Calendar.getInstance();
            Calendar end = Calendar.getInstance();
            end.add(Calendar.YEAR, 20);
            KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA", "AndroidKeyStore");
            generator.initialize(new KeyPairGeneratorSpec.Builder(context)
                    .setAlias(ALIAS)
                    .setSubject(new X500Principal("CN=Sakura KDJX"))
                    .setSerialNumber(BigInteger.ONE)
                    .setStartDate(start.getTime())
                    .setEndDate(end.getTime())
                    .build());
            return generator.generateKeyPair();
        }

        private static KeyStore androidKeyStore() throws Exception {
            KeyStore store = KeyStore.getInstance("AndroidKeyStore");
            store.load(null);
            return store;
        }
    }
}
