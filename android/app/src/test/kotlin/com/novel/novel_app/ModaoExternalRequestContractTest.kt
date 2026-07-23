package com.novel.novel_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ModaoExternalRequestContractTest {
    @Test
    fun parsesStrictPaymentDeepLink() {
        val request = ModaoExternalRequestContract.parsePayment(
            link = paymentLink(),
            appPackageName = "com.novel.novel_app",
            gameOrderId = "order-2001",
            productId = "pack.6",
        )

        assertEquals("order-2001", request?.gameOrderId)
        assertEquals("pack.6", request?.productId)
    }

    @Test
    fun rejectsPaymentLinkWithUnexpectedParameters() {
        val request = ModaoExternalRequestContract.parsePayment(
            link = paymentLink(
                queryNames = setOf("gameOrderId", "productId", "redirect"),
            ),
            appPackageName = "com.novel.novel_app",
            gameOrderId = "order-2001",
            productId = "pack.6",
        )

        assertNull(request)
    }

    @Test
    fun parsesBothSupportedExplicitPaymentActions() {
        for (action in listOf(
            "com.novel.novel_app.MODAO_PAYMENT",
            "release.application.id.MODAO_PAYMENT",
        )) {
            val request = ModaoExternalRequestContract.parsePayment(
                link = ModaoExternalRequestContract.Link(
                    action = action,
                    scheme = null,
                    host = null,
                    path = null,
                ),
                appPackageName = "release.application.id",
                gameOrderId = "order-2001",
                productId = "pack.6",
            )

            assertEquals("order-2001", request?.gameOrderId)
            assertEquals("pack.6", request?.productId)
        }
    }

    @Test
    fun parsesAuthorizationRequestNonce() {
        val requestId = "a".repeat(32)
        val request = ModaoExternalRequestContract.parseSsoAuthorization(
            link = authorizationLink(),
            requestId = requestId,
        )

        assertEquals(requestId, request?.requestId)
    }

    @Test
    fun rejectsSpoofedOrMalformedAuthorizationLinks() {
        assertNull(
            ModaoExternalRequestContract.parseSsoAuthorization(
                link = authorizationLink(host = "other-app"),
                requestId = "a".repeat(32),
            ),
        )
        assertNull(
            ModaoExternalRequestContract.parseSsoAuthorization(
                link = authorizationLink(),
                requestId = "too-short",
            ),
        )
        assertNull(
            ModaoExternalRequestContract.parseSsoAuthorization(
                link = authorizationLink(
                    queryNames = setOf("requestId", "callback"),
                ),
                requestId = "a".repeat(32),
            ),
        )
    }

    @Test
    fun callbackIsPinnedToTheManagedGamePackage() {
        assertEquals(
            "com.you91.fish.lucky",
            ModaoExternalRequestContract.gamePackageName,
        )
        assertEquals(
            "com.you91.fish.lucky.SAKURA_SSO_CALLBACK",
            ModaoExternalRequestContract.ssoCallbackAction,
        )
        assertTrue(
            ModaoExternalRequestContract.isSsoRequestId(
                "request_nonce_1234567890_ABCDEFGHIJ",
            ),
        )
        assertTrue(
            ModaoExternalRequestContract.isSsoTicket(
                "ticket_value_1234567890_ABCDEFGHIJK",
            ),
        )
    }

    @Test
    fun acknowledgementsCannotDeleteAReplacedPendingRequest() {
        assertTrue(
            ModaoExternalRequestContract.matchesPaymentAcknowledgement(
                storedGameOrderId = "order-2001",
                storedProductId = "pack.6",
                gameOrderId = "order-2001",
                productId = "pack.6",
            ),
        )
        assertTrue(
            !ModaoExternalRequestContract.matchesPaymentAcknowledgement(
                storedGameOrderId = "new-order",
                storedProductId = "pack.6",
                gameOrderId = "order-2001",
                productId = "pack.6",
            ),
        )
        assertTrue(
            !ModaoExternalRequestContract.matchesSsoAcknowledgement(
                storedRequestId = "b".repeat(32),
                requestId = "a".repeat(32),
            ),
        )
    }

    private fun paymentLink(
        queryNames: Set<String> = setOf("gameOrderId", "productId"),
    ) = ModaoExternalRequestContract.Link(
        action = ModaoExternalRequestContract.androidViewAction,
        scheme = ModaoExternalRequestContract.novelScheme,
        host = ModaoExternalRequestContract.paymentHost,
        path = ModaoExternalRequestContract.paymentPath,
        queryParameterNames = queryNames,
    )

    private fun authorizationLink(
        host: String = ModaoExternalRequestContract.authorizationHost,
        queryNames: Set<String> = setOf("requestId"),
    ) = ModaoExternalRequestContract.Link(
        action = ModaoExternalRequestContract.androidViewAction,
        scheme = ModaoExternalRequestContract.novelScheme,
        host = host,
        path = ModaoExternalRequestContract.authorizationPath,
        queryParameterNames = queryNames,
    )
}
