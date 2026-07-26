package com.novel.kdjx;

import java.nio.charset.Charset;
import java.security.MessageDigest;

final class PaymentRecovery {
    private static final Charset UTF_8 = Charset.forName("UTF-8");

    private PaymentRecovery() {}

    static String returnedStatus(
            String storedOrderId,
            String storedReturnNonce,
            long capturedAt,
            long deadline,
            String returnedOrderId,
            String returnedReturnNonce,
            String returnedStatus,
            long now,
            long maximumWaitMs) {
        if (!isIdentifier(storedOrderId) ||
                !isReturnNonce(storedReturnNonce) ||
                capturedAt <= 0L || capturedAt > now ||
                deadline <= capturedAt || deadline - capturedAt != maximumWaitMs ||
                deadline <= now ||
                !storedOrderId.equals(returnedOrderId) ||
                !sameReturnNonce(storedReturnNonce, returnedReturnNonce)) {
            return "";
        }
        return isPaymentStatus(returnedStatus) ? returnedStatus : "cancelled";
    }

    static boolean isPaymentStatus(String value) {
        return "cancelled".equals(value) || "pending".equals(value) ||
                "paid".equals(value) || "processing".equals(value) ||
                "fulfilling".equals(value) ||
                "delivery_failed".equals(value) || "failed".equals(value) ||
                "delivered".equals(value) || "fulfilled".equals(value) ||
                "success".equals(value) || "refunded".equals(value);
    }

    private static boolean isIdentifier(String value) {
        return value != null && value.length() >= 1 && value.length() <= 128 &&
                value.matches("[A-Za-z0-9._:-]+");
    }

    private static boolean isReturnNonce(String value) {
        return value != null && value.matches("[A-Za-z0-9_-]{43}");
    }

    private static boolean sameReturnNonce(String expected, String actual) {
        if (!isReturnNonce(expected) || !isReturnNonce(actual)) return false;
        return MessageDigest.isEqual(
                expected.getBytes(UTF_8),
                actual.getBytes(UTF_8));
    }
}
