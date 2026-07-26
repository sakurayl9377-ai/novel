package com.novel.novel_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KdjxExternalRequestContractTest {
    @Test
    fun acceptsOwnedAuthorizationAndPaymentFields() {
        assertTrue(
            KdjxExternalRequestContract.isDeviceCode(
                "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ),
        )
        assertTrue(KdjxExternalRequestContract.isIdentifier("game.cn.1"))
        assertTrue(KdjxExternalRequestContract.isCanonicalUserId("42"))
        assertFalse(KdjxExternalRequestContract.isCanonicalUserId("042"))
        assertTrue(
            KdjxExternalRequestContract.isPaymentReturnNonce(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            ),
        )
        assertEquals(
            "ABCD-2345",
            KdjxExternalRequestContract.normalizeUserCode("abcd2345"),
        )
        assertTrue(KdjxExternalRequestContract.isPaymentStatus("fulfilled"))
        assertTrue(KdjxExternalRequestContract.isPaymentStatus("processing"))
        assertEquals(
            mapOf(
                "sakura_device_code" to
                    "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "sakura_authorization_status" to "denied",
            ),
            KdjxExternalRequestContract.authorizationReturnPayload(
                "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "denied",
            ),
        )
    }

    @Test
    fun rejectsPathTraversalAndUnrecognizedResults() {
        assertFalse(KdjxExternalRequestContract.isIdentifier("../order"))
        assertFalse(
            KdjxExternalRequestContract.isDeviceCode("kdjx_device_short"),
        )
        assertFalse(
            KdjxExternalRequestContract.isPaymentReturnNonce("short"),
        )
        assertFalse(KdjxExternalRequestContract.isPaymentStatus("approved"))
    }

    @Test
    fun keepsAnIdenticalAuthorizationUntilItsDeadline() {
        assertEquals(
            KdjxAuthorizationCaptureAction.KEEP_IDENTICAL,
            KdjxExternalRequestContract.authorizationCaptureAction(
                existingDeviceCode =
                    "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                existingUserCode = "ABCD-2345",
                existingDeadlineMillis = 700_000L,
                incomingDeviceCode =
                    "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                incomingUserCode = "abcd2345",
                nowMillis = 200_000L,
            ),
        )
    }

    @Test
    fun refusesToOverwriteAnUnexpiredAuthorization() {
        assertEquals(
            KdjxAuthorizationCaptureAction.KEEP_CONFLICTING,
            KdjxExternalRequestContract.authorizationCaptureAction(
                existingDeviceCode =
                    "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                existingUserCode = "ABCD-2345",
                existingDeadlineMillis = 700_000L,
                incomingDeviceCode =
                    "kdjx_device_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                incomingUserCode = "WXYZ-6789",
                nowMillis = 200_000L,
            ),
        )
    }

    @Test
    fun allowsAReplacementAfterTheAuthorizationDeadline() {
        assertEquals(
            KdjxAuthorizationCaptureAction.STORE_INCOMING,
            KdjxExternalRequestContract.authorizationCaptureAction(
                existingDeviceCode =
                    "kdjx_device_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                existingUserCode = "ABCD-2345",
                existingDeadlineMillis = 700_000L,
                incomingDeviceCode =
                    "kdjx_device_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                incomingUserCode = "WXYZ-6789",
                nowMillis = 700_000L,
            ),
        )
    }

    @Test
    fun keepsAnIdenticalPaymentUntilItsDeadline() {
        assertEquals(
            KdjxPaymentCaptureAction.KEEP_IDENTICAL,
            KdjxExternalRequestContract.paymentCaptureAction(
                existingGameOrderId = "order-1001",
                existingReturnNonce =
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                existingDeadlineMillis = 1_000_000L,
                incomingGameOrderId = "order-1001",
                incomingReturnNonce =
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                nowMillis = 200_000L,
            ),
        )
    }

    @Test
    fun refusesToOverwriteAnUnexpiredPayment() {
        assertEquals(
            KdjxPaymentCaptureAction.KEEP_CONFLICTING,
            KdjxExternalRequestContract.paymentCaptureAction(
                existingGameOrderId = "order-1001",
                existingReturnNonce =
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                existingDeadlineMillis = 1_000_000L,
                incomingGameOrderId = "order-2002",
                incomingReturnNonce =
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                nowMillis = 200_000L,
            ),
        )
    }

    @Test
    fun allowsAPaymentReplacementAfterItsDeadline() {
        assertEquals(
            KdjxPaymentCaptureAction.STORE_INCOMING,
            KdjxExternalRequestContract.paymentCaptureAction(
                existingGameOrderId = "order-1001",
                existingReturnNonce =
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                existingDeadlineMillis = 1_000_000L,
                incomingGameOrderId = "order-2002",
                incomingReturnNonce =
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                nowMillis = 1_000_000L,
            ),
        )
    }
}
