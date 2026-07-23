package com.novel.novel_app

internal object ModaoExternalRequestContract {
    const val androidViewAction = "android.intent.action.VIEW"
    const val novelScheme = "sakura-novel"
    const val paymentHost = "modao-payment"
    const val paymentPath = "/pay"
    const val authorizationHost = "modao-auth"
    const val authorizationPath = "/request"
    const val gamePackageName = "com.you91.fish.lucky"
    const val ssoCallbackAction = "com.you91.fish.lucky.SAKURA_SSO_CALLBACK"

    data class Link(
        val action: String?,
        val scheme: String?,
        val host: String?,
        val path: String?,
        val port: Int = -1,
        val userInfo: String? = null,
        val fragment: String? = null,
        val queryParameterNames: Set<String> = emptySet(),
    )

    data class PaymentRequest(
        val gameOrderId: String,
        val productId: String,
    )

    data class SsoAuthorizationRequest(
        val requestId: String,
    )

    fun recognizesPayment(link: Link, appPackageName: String): Boolean {
        val isDeepLink = isViewLink(
            link,
            host = paymentHost,
            path = paymentPath,
        )
        val isExplicitAction = link.action == "com.novel.novel_app.MODAO_PAYMENT" ||
            link.action == "$appPackageName.MODAO_PAYMENT"
        return isDeepLink || isExplicitAction
    }

    fun parsePayment(
        link: Link,
        appPackageName: String,
        gameOrderId: String?,
        productId: String?,
    ): PaymentRequest? {
        if (!recognizesPayment(link, appPackageName)) return null
        if (
            link.action == androidViewAction &&
            link.queryParameterNames != setOf("gameOrderId", "productId")
        ) {
            return null
        }
        val normalizedOrderId = gameOrderId.orEmpty().trim()
        val normalizedProductId = productId.orEmpty().trim()
        if (!isPaymentIdentifier(normalizedOrderId) ||
            !isPaymentIdentifier(normalizedProductId)
        ) {
            return null
        }
        return PaymentRequest(
            gameOrderId = normalizedOrderId,
            productId = normalizedProductId,
        )
    }

    fun recognizesSsoAuthorization(link: Link): Boolean = isViewLink(
        link,
        host = authorizationHost,
        path = authorizationPath,
    )

    fun parseSsoAuthorization(
        link: Link,
        requestId: String?,
    ): SsoAuthorizationRequest? {
        if (!recognizesSsoAuthorization(link) ||
            link.queryParameterNames != setOf("requestId")
        ) {
            return null
        }
        val normalizedRequestId = requestId.orEmpty().trim()
        if (!isSsoRequestId(normalizedRequestId)) return null
        return SsoAuthorizationRequest(normalizedRequestId)
    }

    fun isPaymentIdentifier(value: String): Boolean =
        value.length in 1..128 && Regex("^[A-Za-z0-9._:-]+$").matches(value)

    fun isSsoRequestId(value: String): Boolean =
        value.length in 32..128 && Regex("^[A-Za-z0-9_-]+$").matches(value)

    fun isSsoTicket(value: String): Boolean =
        value.length in 32..256 && Regex("^[A-Za-z0-9_-]+$").matches(value)

    fun matchesPaymentAcknowledgement(
        storedGameOrderId: String?,
        storedProductId: String?,
        gameOrderId: String,
        productId: String,
    ): Boolean = isPaymentIdentifier(gameOrderId) &&
        isPaymentIdentifier(productId) &&
        storedGameOrderId == gameOrderId &&
        storedProductId == productId

    fun matchesSsoAcknowledgement(
        storedRequestId: String?,
        requestId: String,
    ): Boolean = isSsoRequestId(requestId) && storedRequestId == requestId

    private fun isViewLink(
        link: Link,
        host: String,
        path: String,
    ): Boolean = link.action == androidViewAction &&
        link.scheme.equals(novelScheme, ignoreCase = true) &&
        link.host.equals(host, ignoreCase = true) &&
        link.path == path &&
        link.port == -1 &&
        link.userInfo.isNullOrEmpty() &&
        link.fragment.isNullOrEmpty()
}
