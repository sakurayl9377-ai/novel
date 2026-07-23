package com.cocos.game;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.text.TextUtils;

import java.util.HashMap;
import java.util.Map;

/**
 * Keeps the short-lived novel-app launch ticket available until Cocos consumes it.
 * The reusable game session is owned by the JavaScript login flow, not this bridge.
 */
public final class SakuraBridge {
    private static final String PREFS = "sakura_modao_bridge";
    private static final String KEY_TICKET = "sso_ticket";
    private static final String KEY_EXCHANGE_URL = "sso_exchange_url";
    private static final String KEY_SOURCE = "sso_source";

    public static final String EXTRA_SSO_TICKET = "sakura_sso_ticket";
    public static final String EXTRA_SSO_EXCHANGE_URL = "sakura_sso_exchange_url";
    public static final String EXTRA_SSO_SOURCE = "sakura_sso_source";
    public static final String EXTRA_PAYMENT_ORDER_ID = "sakura_payment_order_id";
    public static final String EXTRA_PAYMENT_STATUS = "sakura_payment_status";
    public static final String EXTRA_PAYMENT_BALANCE = "sakura_payment_balance";
    public static final String EXTRA_PAYMENT_SOURCE = "sakura_payment_source";

    private SakuraBridge() {
    }

    public static void captureLaunchIntent(Activity activity) {
        if (activity != null) {
            captureLaunchIntent(activity, activity.getIntent());
        }
    }

    public static void captureLaunchIntent(Activity activity, Intent intent) {
        if (activity == null || intent == null) {
            return;
        }

        String ticket = readValue(intent, EXTRA_SSO_TICKET, "ticket");
        if (TextUtils.isEmpty(ticket)) {
            return;
        }
        String exchangeUrl = readValue(intent, EXTRA_SSO_EXCHANGE_URL, "exchangeUrl");
        String source = readValue(intent, EXTRA_SSO_SOURCE, "source");
        if (!isTicket(ticket) || !isExchangeUrl(exchangeUrl)) {
            return;
        }

        SharedPreferences.Editor editor = prefs(activity).edit()
                .putString(KEY_TICKET, ticket)
                .putString(KEY_EXCHANGE_URL, exchangeUrl)
                .putString(KEY_SOURCE, source);
        editor.apply();
    }

    public static void augmentGameConfig(Activity activity, Map<String, Object> config) {
        if (activity == null || config == null) {
            return;
        }

        captureLaunchIntent(activity);
        SharedPreferences preferences = prefs(activity);
        String ticket = preferences.getString(KEY_TICKET, "");
        String exchangeUrl = preferences.getString(KEY_EXCHANGE_URL, "");
        String source = preferences.getString(KEY_SOURCE, "");
        config.put("sakura_sso_available", TextUtils.isEmpty(ticket) ? "0" : "1");
        config.put("sakura_sso_ticket", ticket);
        config.put("sakura_sso_exchange_url", exchangeUrl);
        config.put("sakura_sso_source", source);
    }

    public static Map<String, Object> createLoginEvent(Activity activity) {
        if (activity == null) {
            return null;
        }

        captureLaunchIntent(activity);
        SharedPreferences preferences = prefs(activity);
        String ticket = preferences.getString(KEY_TICKET, "");
        if (TextUtils.isEmpty(ticket)) {
            return null;
        }

        Map<String, Object> event = new HashMap<>();
        event.put("name", "loginok");
        event.put("action", "sakura_sso");
        event.put("sso_ticket", ticket);
        event.put("sso_exchange_url", preferences.getString(KEY_EXCHANGE_URL, ""));
        event.put("sso_source", preferences.getString(KEY_SOURCE, ""));
        return event;
    }

    /**
     * Reads and consumes the payment result returned by the novel app.
     * The game JavaScript layer owns the actual fulfillment acknowledgement.
     */
    public static Map<String, Object> takePaymentResult(Activity activity) {
        if (activity == null) {
            return null;
        }
        Intent intent = activity.getIntent();
        if (intent == null) {
            return null;
        }
        String orderId = intent.getStringExtra(EXTRA_PAYMENT_ORDER_ID);
        if (!isIdentifier(orderId)) {
            return null;
        }
        Map<String, Object> result = new HashMap<>();
        result.put("gameOrderId", orderId);
        result.put("status", intent.getStringExtra(EXTRA_PAYMENT_STATUS));
        result.put("balance", String.valueOf(intent.getLongExtra(EXTRA_PAYMENT_BALANCE, 0L)));
        String source = intent.getStringExtra(EXTRA_PAYMENT_SOURCE);
        if (TextUtils.isEmpty(source)) {
            source = intent.getStringExtra(EXTRA_SSO_SOURCE);
        }
        result.put("source", source);
        intent.removeExtra(EXTRA_PAYMENT_ORDER_ID);
        intent.removeExtra(EXTRA_PAYMENT_STATUS);
        intent.removeExtra(EXTRA_PAYMENT_BALANCE);
        intent.removeExtra(EXTRA_PAYMENT_SOURCE);
        return result;
    }

    public static boolean isExchangeUrl(String value) {
        if (TextUtils.isEmpty(value)) {
            return false;
        }
        try {
            Uri uri = Uri.parse(value);
            return "https".equalsIgnoreCase(uri.getScheme())
                    && TextUtils.isEmpty(uri.getUserInfo())
                    && TextUtils.isEmpty(uri.getFragment())
                    && "/sakura/sso/exchange".equals(uri.getPath())
                    && (uri.getPort() == -1 || uri.getPort() == 443);
        } catch (RuntimeException ignored) {
            return false;
        }
    }

    public static boolean isPaymentLaunchUrl(String value) {
        if (TextUtils.isEmpty(value)) {
            return false;
        }
        try {
            Uri uri = Uri.parse(value);
            return "sakura-novel".equalsIgnoreCase(uri.getScheme())
                    && "modao-payment".equalsIgnoreCase(uri.getHost())
                    && "/pay".equals(uri.getPath())
                    && isIdentifier(uri.getQueryParameter("gameOrderId"))
                    && isIdentifier(uri.getQueryParameter("productId"));
        } catch (RuntimeException ignored) {
            return false;
        }
    }

    public static void clearSsoTicket(Activity activity) {
        if (activity == null) {
            return;
        }

        prefs(activity).edit()
                .remove(KEY_TICKET)
                .remove(KEY_EXCHANGE_URL)
                .remove(KEY_SOURCE)
                .apply();
        Intent intent = activity.getIntent();
        if (intent != null) {
            intent.removeExtra(EXTRA_SSO_TICKET);
            intent.removeExtra(EXTRA_SSO_EXCHANGE_URL);
            intent.removeExtra(EXTRA_SSO_SOURCE);
            Uri data = intent.getData();
            if (data != null && !TextUtils.isEmpty(data.getQueryParameter("ticket"))) {
                intent.setData(null);
            }
        }
    }

    private static SharedPreferences prefs(Activity activity) {
        return activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE);
    }

    private static String readValue(Intent intent, String extraName, String queryName) {
        String value = intent.getStringExtra(extraName);
        if (!TextUtils.isEmpty(value)) {
            return value;
        }
        Uri data = intent.getData();
        return data == null ? "" : data.getQueryParameter(queryName);
    }

    private static boolean isTicket(String value) {
        return !TextUtils.isEmpty(value) && value.matches("[A-Za-z0-9_-]{32,256}");
    }

    private static boolean isIdentifier(String value) {
        return !TextUtils.isEmpty(value)
                && value.length() <= 128
                && value.matches("[A-Za-z0-9._:-]+");
    }
}
