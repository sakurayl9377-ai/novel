package com.novel.kdjx;

import android.app.Activity;
import android.content.Context;
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
    private static final long MAX_DEVICE_WAIT_MS = 10L * 60L * 1000L;
    private static final SecureRandom RANDOM = new SecureRandom();

    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    private volatile CallInfo pendingLogin;
    private volatile CallInfo pendingPayment;
    private volatile String pendingPaymentOrder;
    private volatile String pendingPaymentReturnNonce;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        handleSakuraReturn(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleSakuraReturn(intent);
    }

    @Override
    protected void onDestroy() {
        io.shutdownNow();
        super.onDestroy();
    }

    /** Invoked by app.sdk.none through the existing MessageHandler bridge. */
    public void sakuraLogin(final CallInfo callInfo) {
        if (callInfo == null) return;
        pendingLogin = callInfo;
        final String credential = SessionVault.read(this);
        if (isCredential(credential)) {
            reply(callInfo, loginReply("ok", credential, ""));
            return;
        }
        final String pendingDeviceCode = pendingDeviceCode();
        if (isDeviceCode(pendingDeviceCode) &&
                System.currentTimeMillis() < pendingDeviceDeadline()) {
            pollForCredential(pendingDeviceCode, callInfo);
            return;
        }
        beginDeviceAuthorization(callInfo);
    }

    /** Starts Sakura coin payment without changing the game's displayed yuan price. */
    public void sakuraPay(final CallInfo callInfo) {
        if (callInfo == null) return;
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

            final String returnNonce = newPaymentReturnNonce();
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
                    .appendQueryParameter("returnNonce", returnNonce)
                    .build();
            Intent intent = new Intent(Intent.ACTION_VIEW, paymentUri)
                    .setPackage(SAKURA_PACKAGE)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            if (intent.resolveActivity(getPackageManager()) == null) {
                reply(callInfo, paymentReply("sakura_app_missing"));
                return;
            }
            pendingPayment = callInfo;
            pendingPaymentOrder = orderId;
            pendingPaymentReturnNonce = returnNonce;
            pendingPreferences().edit()
                    .putString("payment_order", orderId)
                    .putString("payment_return_nonce", returnNonce)
                    .apply();
            startActivity(intent);
        } catch (Exception ignored) {
            reply(callInfo, paymentReply("invalid_request"));
        }
    }

    /** Allows the game logout path to revoke this device-local session copy. */
    public void sakuraClearSession(final CallInfo callInfo) {
        SessionVault.clear(this);
        reply(callInfo, simpleReply("ok", ""));
    }

    private void beginDeviceAuthorization(final CallInfo callInfo) {
        io.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    HttpReply response = postJson(DEVICE_CREATE_URL, new JSONObject());
                    JSONObject body = response.body;
                    String deviceCode = body.optString("deviceCode", "");
                    String verificationUriComplete = body.optString(
                            "verificationUriComplete", "");
                    int expiresIn = body.optInt("expiresIn", 0);
                    if (response.status < 200 || response.status >= 300 ||
                            !isDeviceCode(deviceCode) ||
                            !isAuthorizationUri(verificationUriComplete, deviceCode) ||
                            expiresIn <= 0 || expiresIn > 900) {
                        throw new IllegalStateException("authorization_start_failed");
                    }
                    long deadline = System.currentTimeMillis() + Math.min(
                            MAX_DEVICE_WAIT_MS, expiresIn * 1000L);
                    pendingPreferences().edit()
                            .putString("device_code", deviceCode)
                            .putLong("device_deadline", deadline)
                            .apply();
                    launchSakuraAuthorization(callInfo, verificationUriComplete);
                } catch (Exception ignored) {
                    reply(callInfo, loginReply("error", "", "authorization_start_failed"));
                }
            }
        });
    }

    private void launchSakuraAuthorization(
            final CallInfo callInfo,
            final String verificationUriComplete) {
        main.post(new Runnable() {
            @Override
            public void run() {
                try {
                    Intent intent = new Intent(
                            Intent.ACTION_VIEW,
                            Uri.parse(verificationUriComplete))
                            .setPackage(SAKURA_PACKAGE)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    if (intent.resolveActivity(getPackageManager()) == null) {
                        throw new IllegalStateException("sakura_app_missing");
                    }
                    startActivity(intent);
                } catch (Exception ignored) {
                    clearPendingDeviceCode();
                    reply(callInfo, loginReply("error", "", "sakura_app_missing"));
                }
            }
        });
    }

    private void handleSakuraReturn(Intent intent) {
        if (intent == null) return;
        String deviceCode = nonNull(intent.getStringExtra("sakura_device_code"));
        if (pendingLogin != null && isDeviceCode(deviceCode) &&
                deviceCode.equals(pendingDeviceCode())) {
            // The return Intent is only a wake-up. The authorization result
            // always comes from the server-side device-code exchange.
            pollForCredential(deviceCode, pendingLogin);
        }

        String orderId = nonNull(intent.getStringExtra("sakura_payment_order_id"));
        String paymentStatus = nonNull(intent.getStringExtra("sakura_payment_status"));
        String returnNonce = nonNull(intent.getStringExtra("sakura_payment_return_nonce"));
        if (pendingPayment != null && isIdentifier(orderId) &&
                orderId.equals(pendingPaymentOrder) &&
                isPaymentReturnNonce(returnNonce) &&
                sameReturnNonce(returnNonce, pendingPaymentReturnNonce)) {
            CallInfo callback = pendingPayment;
            pendingPayment = null;
            pendingPaymentOrder = null;
            pendingPaymentReturnNonce = null;
            pendingPreferences().edit()
                    .remove("payment_order")
                    .remove("payment_return_nonce")
                    .apply();
            reply(callback, paymentReply(isPaymentStatus(paymentStatus)
                    ? paymentStatus : "cancelled"));
        }
    }

    private void pollForCredential(final String deviceCode, final CallInfo callback) {
        io.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    if (System.currentTimeMillis() >= pendingDeviceDeadline()) {
                        throw new IllegalStateException("authorization_expired");
                    }
                    JSONObject request = new JSONObject();
                    request.put("deviceCode", deviceCode);
                    HttpReply response = postJson(DEVICE_TOKEN_URL, request);
                    if (response.status == 202 || "pending".equals(response.body.optString("status"))) {
                        int retryAfter = response.body.optInt("retryAfter", 5);
                        scheduleCredentialPoll(deviceCode, callback, retryAfter);
                        return;
                    }
                    String credential = response.body.optString("credential", "");
                    if (response.status < 200 || response.status >= 300 ||
                            !"authorized".equals(response.body.optString("status")) ||
                            !isCredential(credential)) {
                        throw new IllegalStateException("authorization_failed");
                    }
                    SessionVault.write(SakuraGameActivity.this, credential);
                    clearPendingDeviceCode();
                    pendingLogin = null;
                    reply(callback, loginReply("ok", credential, ""));
                } catch (Exception ignored) {
                    clearPendingDeviceCode();
                    pendingLogin = null;
                    reply(callback, loginReply("error", "", "authorization_failed"));
                }
            }
        });
    }

    private void scheduleCredentialPoll(final String deviceCode, final CallInfo callback, int retryAfter) {
        int seconds = Math.max(2, Math.min(15, retryAfter));
        main.postDelayed(new Runnable() {
            @Override
            public void run() {
                pollForCredential(deviceCode, callback);
            }
        }, seconds * 1000L);
    }

    private HttpReply postJson(String endpoint, JSONObject request) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(endpoint).openConnection();
        connection.setRequestMethod("POST");
        connection.setConnectTimeout(10_000);
        connection.setReadTimeout(15_000);
        connection.setDoOutput(true);
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

    private void reply(CallInfo callInfo, String payload) {
        if (callInfo == null) return;
        try {
            Field field = AppActivity.class.getDeclaredField("messageHandler");
            field.setAccessible(true);
            MessageHandler handler = (MessageHandler) field.get(this);
            if (handler != null) handler.callbackToLua(callInfo.msgID, payload);
        } catch (Exception ignored) {
            // The bridge can be torn down while Android switches activities.
        }
    }

    private static String loginReply(String status, String credential, String error) {
        try {
            JSONObject result = new JSONObject();
            result.put("status", status);
            if (!credential.isEmpty()) result.put("credential", credential);
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

    private static boolean isAuthorizationUri(String value, String deviceCode) {
        try {
            Uri uri = Uri.parse(value);
            return "sakura-novel".equals(uri.getScheme()) &&
                    "game".equals(uri.getHost()) &&
                    "/kdjx/authorize".equals(uri.getPath()) &&
                    deviceCode.equals(uri.getQueryParameter("device_code"));
        } catch (Exception ignored) {
            return false;
        }
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

    private static boolean isIdentifier(String value) {
        return value != null && value.length() >= 1 && value.length() <= 128 &&
                value.matches("[A-Za-z0-9._:-]+");
    }

    private static boolean isPaymentStatus(String value) {
        return "cancelled".equals(value) || "pending".equals(value) ||
                "paid".equals(value) || "fulfilling".equals(value) ||
                "delivery_failed".equals(value) || "failed".equals(value) ||
                "delivered".equals(value) || "fulfilled".equals(value) ||
                "success".equals(value) || "refunded".equals(value);
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
