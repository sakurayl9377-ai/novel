package com.novel.novel_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors

internal enum class KdjxAuthorizationCaptureAction {
    STORE_INCOMING,
    KEEP_IDENTICAL,
    KEEP_CONFLICTING,
}

internal enum class KdjxPaymentCaptureAction {
    STORE_INCOMING,
    KEEP_IDENTICAL,
    KEEP_CONFLICTING,
}

internal object KdjxExternalRequestContract {
    const val AUTHORIZATION_TTL_MILLIS = 10 * 60 * 1000L
    const val PAYMENT_TTL_MILLIS = 15 * 60 * 1000L

    private val paymentStatuses = setOf(
        "cancelled",
        "pending",
        "paid",
        "processing",
        "fulfilling",
        "delivered",
        "fulfilled",
        "success",
        "delivery_failed",
        "failed",
        "refunded",
    )

    fun isIdentifier(value: String): Boolean =
        value.length in 1..128 && Regex("^[A-Za-z0-9._:-]+$").matches(value)

    fun isCanonicalUserId(value: String): Boolean =
        Regex("^[1-9][0-9]{0,18}$").matches(value) &&
            value.toLongOrNull()?.let { it > 0L && it.toString() == value } == true

    fun isDeviceCode(value: String): Boolean =
        value.length in 52..140 &&
            value.startsWith("kdjx_device_") &&
            Regex("^[A-Za-z0-9_-]+$").matches(value)

    fun normalizeUserCode(value: String): String? {
        val normalized = value.trim().uppercase()
        if (!Regex(
                "^(?:[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{8}|" +
                    "[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-" +
                    "[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4})$",
            ).matches(normalized)
        ) {
            return null
        }
        val compact = normalized.replace("-", "")
        return "${compact.substring(0, 4)}-${compact.substring(4)}"
    }

    fun authorizationCaptureAction(
        existingDeviceCode: String,
        existingUserCode: String,
        existingDeadlineMillis: Long,
        incomingDeviceCode: String,
        incomingUserCode: String,
        nowMillis: Long,
    ): KdjxAuthorizationCaptureAction {
        if (!isDeviceCode(existingDeviceCode) ||
            normalizeUserCode(existingUserCode) == null ||
            existingDeadlineMillis <= nowMillis
        ) {
            return KdjxAuthorizationCaptureAction.STORE_INCOMING
        }
        return if (existingDeviceCode == incomingDeviceCode &&
            normalizeUserCode(existingUserCode) == normalizeUserCode(incomingUserCode)
        ) {
            KdjxAuthorizationCaptureAction.KEEP_IDENTICAL
        } else {
            KdjxAuthorizationCaptureAction.KEEP_CONFLICTING
        }
    }

    fun authorizationReturnPayload(
        deviceCode: String,
        status: String,
    ): Map<String, String>? {
        if (!isDeviceCode(deviceCode) ||
            status !in setOf("approved", "denied", "cancelled")
        ) {
            return null
        }
        return mapOf(
            "sakura_device_code" to deviceCode,
            "sakura_authorization_status" to status,
        )
    }

    fun isPaymentReturnNonce(value: String): Boolean =
        Regex("^[A-Za-z0-9_-]{43}$").matches(value)

    fun paymentCaptureAction(
        existingGameOrderId: String,
        existingReturnNonce: String,
        existingDeadlineMillis: Long,
        incomingGameOrderId: String,
        incomingReturnNonce: String,
        nowMillis: Long,
    ): KdjxPaymentCaptureAction {
        if (!isIdentifier(existingGameOrderId) ||
            !isPaymentReturnNonce(existingReturnNonce) ||
            existingDeadlineMillis <= nowMillis
        ) {
            return KdjxPaymentCaptureAction.STORE_INCOMING
        }
        return if (existingGameOrderId == incomingGameOrderId &&
            existingReturnNonce == incomingReturnNonce
        ) {
            KdjxPaymentCaptureAction.KEEP_IDENTICAL
        } else {
            KdjxPaymentCaptureAction.KEEP_CONFLICTING
        }
    }

    fun isPaymentStatus(value: String): Boolean = value in paymentStatuses
}

/**
 * Native KDJX integration isolated from MainActivity's production Modao bridge.
 *
 * The Flutter layer validates the release manifest. This bridge repeats the
 * trust checks before network, install, and launch operations cross into
 * Android.
 */
internal class KdjxGameBridge(private val activity: Activity) {
    private data class CapturedRequest(
        val authorization: Boolean = false,
        val payment: Boolean = false,
    )

    private data class PendingAuthorization(
        val deviceCode: String,
        val userCode: String,
        val capturedAtMillis: Long,
        val deadlineMillis: Long,
    )

    private data class PendingPayment(
        val values: Map<String, String>,
        val capturedAtMillis: Long,
        val deadlineMillis: Long,
    )

    private data class ApkPart(
        val index: Int,
        val url: String,
        val sizeBytes: Long,
        val sha256: String,
    )

    private data class PreparedDownload(
        val artifactKey: String,
        val releaseKey: String,
        val sha256: String,
        val destination: File,
        val workDirectory: File,
        val parts: List<ApkPart>,
    )

    private val packageName = "com.kd.kdjxcs"
    private val channelName = "com.novel.novel_app/kdjx_game"
    private val trustedDownloadHosts = setOf("novel.kxhub.xyz")
    private val expectedSigningCertificateSha256 = normalizeSha256(
        BuildConfig.KDJX_GAME_SIGNING_CERT_SHA256,
    )
    private val downloadPreferencesName = "kdjx_game_download"
    private val externalRequestPreferencesName = "kdjx_external_requests"
    private val downloadLock = Any()
    private val ioExecutor = Executors.newFixedThreadPool(2)
    private var methodChannel: MethodChannel? = null
    private var preparedDownload: PreparedDownload? = null

    // Generation that owns the single in-flight merge worker; guarded by
    // downloadLock. A merge is active only while this matches
    // downloadGeneration.
    private var activeMergeGeneration: Long? = null

    @Volatile private var downloadGeneration = 0L
    @Volatile private var downloadStatus = "none"
    @Volatile private var downloadedBytes = 0L
    @Volatile private var totalBytes = 0L
    @Volatile private var downloadPath = ""
    @Volatile private var downloadReason = ""
    @Volatile private var downloadSourceUrl = ""
    @Volatile private var downloadSourceIndex = 0
    @Volatile private var downloadArtifactKey = ""
    @Volatile private var downloadReleaseKey = ""
    @Volatile private var downloadPartCount = 0

    init {
        restoreDownloadState()
    }

    fun configure(flutterEngine: FlutterEngine) {
        detachChannel()
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInstalledGame" -> {
                        val requestedPackage = call.argument<String>("packageName")
                        if (requestedPackage != packageName) {
                            result.error(
                                "INVALID_PACKAGE",
                                "Unexpected game package",
                                null,
                            )
                        } else {
                            result.success(installedGameInfo())
                        }
                    }
                    "getDeviceEnvironment" -> result.success(deviceEnvironment())
                    "getDownloadState" -> result.success(downloadState())
                    "prepareAppDownload" -> {
                        try {
                            val urls = (
                                call.argument<List<*>>("urls") ?: emptyList<Any>()
                                ).mapNotNull { it?.toString() }
                            requireRequestedDownloadHosts(
                                call.argument<List<*>>("trustedDownloadHosts")
                                    ?: emptyList<Any>(),
                            )
                            val requestedSigner = normalizeSha256(
                                call.argument<String>(
                                    "signingCertificateSha256",
                                ).orEmpty(),
                            )
                            if (!isSha256(expectedSigningCertificateSha256) ||
                                requestedSigner != expectedSigningCertificateSha256
                            ) {
                                throw IllegalArgumentException(
                                    "KDJX signing certificate mismatch",
                                )
                            }
                            val parts = parseParts(
                                call.argument<List<*>>("parts")
                                    ?: emptyList<Any>(),
                            )
                            result.success(
                                prepareAppDownload(
                                    urls = urls,
                                    parts = parts,
                                    sourceIndex = (
                                        call.argument<Number>("sourceIndex") ?: 0
                                        ).toInt(),
                                    fileName = call.argument<String>(
                                        "fileName",
                                    ).orEmpty(),
                                    expectedSize = (
                                        call.argument<Number>("sizeBytes") ?: 0
                                        ).toLong(),
                                    expectedSha256 = call.argument<String>(
                                        "sha256",
                                    ).orEmpty(),
                                    allowMetered =
                                        call.argument<Boolean>("allowMetered") == true,
                                ),
                            )
                        } catch (error: Exception) {
                            result.error("DOWNLOAD_FAILED", error.message, null)
                        }
                    }
                    "finalizeAppDownload" -> {
                        finalizeAppDownload(
                            artifactKey = call.argument<String>(
                                "artifactKey",
                            ).orEmpty(),
                            releaseKey = call.argument<String>(
                                "releaseKey",
                            ).orEmpty(),
                            result = result,
                        )
                    }
                    "cancelDownloadWork" -> {
                        result.success(cancelDownloadWork())
                    }
                    "clearDownload" -> {
                        try {
                            result.success(clearDownload())
                        } catch (error: Exception) {
                            result.error(
                                "DOWNLOAD_CLEAR_FAILED",
                                error.message,
                                null,
                            )
                        }
                    }
                    "inspectApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "APK path is empty", null)
                        } else {
                            ioExecutor.execute {
                                try {
                                    val inspection = inspectApk(path)
                                    activity.runOnUiThread {
                                        result.success(inspection)
                                    }
                                } catch (error: Exception) {
                                    activity.runOnUiThread {
                                        result.error(
                                            "APK_INSPECTION_FAILED",
                                            error.message,
                                            null,
                                        )
                                    }
                                }
                            }
                        }
                    }
                    "canInstallPackages" -> result.success(canInstallPackages())
                    "openInstallPermissionSettings" -> result.success(
                        openInstallPermissionSettings(),
                    )
                    "installGameApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("INVALID_PATH", "APK path is empty", null)
                        } else {
                            try {
                                installTrustedApk(path)
                                result.success(null)
                            } catch (error: Exception) {
                                result.error("INSTALL_FAILED", error.message, null)
                            }
                        }
                    }
                    "launchGame" -> {
                        val requestedPackage = call.argument<String>("packageName")
                        val expectedUserId = call.argument<String>(
                            "expectedUserId",
                        ).orEmpty()
                        if (requestedPackage != packageName ||
                            !KdjxExternalRequestContract.isCanonicalUserId(
                                expectedUserId,
                            ) ||
                            !hasTrustedInstalledSignature()
                        ) {
                            result.error(
                                "INVALID_LAUNCH",
                                "Invalid game launch request",
                                null,
                            )
                        } else {
                            result.success(launchGame(expectedUserId))
                        }
                    }
                    "takePendingAuthorizationRequest" -> {
                        result.success(pendingAuthorizationRequest())
                    }
                    "ackPendingAuthorizationRequest" -> {
                        result.success(
                            acknowledgeAuthorizationRequest(
                                call.argument<String>("deviceCode").orEmpty(),
                                call.argument<String>("userCode").orEmpty(),
                            ),
                        )
                    }
                    "returnAuthorizationToGame" -> {
                        val deviceCode = call.argument<String>(
                            "deviceCode",
                        ).orEmpty()
                        val status = call.argument<String>("status").orEmpty()
                        val payload =
                            KdjxExternalRequestContract.authorizationReturnPayload(
                                deviceCode,
                                status,
                            )
                        if (payload == null) {
                            result.error(
                                "INVALID_AUTHORIZATION_RESULT",
                                "Invalid authorization result",
                                null,
                            )
                        } else {
                            result.success(returnAuthorizationToGame(payload))
                        }
                    }
                    "takePendingPaymentRequest" -> {
                        result.success(pendingPaymentRequest())
                    }
                    "ackPendingPaymentRequest" -> {
                        result.success(
                            acknowledgePaymentRequest(
                                gameOrderId = call.argument<String>(
                                    "gameOrderId",
                                ).orEmpty(),
                                returnNonce = call.argument<String>(
                                    "returnNonce",
                                ).orEmpty(),
                            ),
                        )
                    }
                    "returnPaymentToGame" -> {
                        val gameOrderId = call.argument<String>(
                            "gameOrderId",
                        ).orEmpty()
                        val status = call.argument<String>("status").orEmpty()
                        val balance = (
                            call.argument<Number>("balance") ?: 0
                            ).toLong()
                        val returnNonce = call.argument<String>(
                            "returnNonce",
                        ).orEmpty()
                        if (!KdjxExternalRequestContract.isIdentifier(gameOrderId) ||
                            !KdjxExternalRequestContract.isPaymentStatus(status) ||
                            balance < 0L ||
                            !KdjxExternalRequestContract.isPaymentReturnNonce(
                                returnNonce,
                            )
                        ) {
                            result.error(
                                "INVALID_PAYMENT_RESULT",
                                "Invalid payment result",
                                null,
                            )
                        } else {
                            result.success(
                                returnPaymentToGame(
                                    gameOrderId,
                                    status,
                                    balance,
                                    returnNonce,
                                ),
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
        notifyPendingRequests()
    }

    fun detachChannel() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
    }

    fun destroy() {
        detachChannel()
        synchronized(downloadLock) {
            downloadGeneration += 1
            activeMergeGeneration = null
        }
        ioExecutor.shutdownNow()
    }

    fun captureExternalRequest(sourceIntent: Intent?): Boolean {
        val captured = try {
            captureExternalRequestUnchecked(sourceIntent)
        } catch (_: Exception) {
            CapturedRequest()
        }
        if (!captured.authorization && !captured.payment) return false
        sourceIntent?.apply {
            data = null
            replaceExtras(android.os.Bundle())
            action = Intent.ACTION_MAIN
        }
        if (captured.authorization) {
            methodChannel?.invokeMethod(
                "onAuthorizationRequestAvailable",
                null,
            )
        }
        if (captured.payment) {
            methodChannel?.invokeMethod("onPaymentRequestAvailable", null)
        }
        return true
    }

    fun notifyPendingRequests() {
        if (pendingAuthorizationRequest() != null) {
            methodChannel?.invokeMethod(
                "onAuthorizationRequestAvailable",
                null,
            )
        }
        if (pendingPaymentRequest() != null) {
            methodChannel?.invokeMethod("onPaymentRequestAvailable", null)
        }
    }

    private fun captureExternalRequestUnchecked(
        sourceIntent: Intent?,
    ): CapturedRequest {
        if (sourceIntent?.action != Intent.ACTION_VIEW) return CapturedRequest()
        val data = sourceIntent.data ?: return CapturedRequest()
        if (data.scheme != "sakura-novel" ||
            data.host != "game" ||
            data.port != -1 ||
            !data.userInfo.isNullOrEmpty() ||
            !data.fragment.isNullOrEmpty()
        ) {
            return CapturedRequest()
        }
        if (data.path == "/kdjx/authorize") {
            val nowMillis = System.currentTimeMillis()
            val existing = pendingAuthorization(nowMillis)
            if (existing != null) {
                val incomingDeviceCode = singleQueryParameter(
                    data,
                    "device_code",
                )
                val incomingUserCode = singleQueryParameter(data, "user_code")
                val action = KdjxExternalRequestContract.authorizationCaptureAction(
                    existingDeviceCode = existing.deviceCode,
                    existingUserCode = existing.userCode,
                    existingDeadlineMillis = existing.deadlineMillis,
                    incomingDeviceCode = incomingDeviceCode,
                    incomingUserCode = incomingUserCode,
                    nowMillis = nowMillis,
                )
                if (action != KdjxAuthorizationCaptureAction.STORE_INCOMING) {
                    return CapturedRequest(authorization = true)
                }
            }
            if (!hasOnlyQueryParameters(data, setOf("device_code", "user_code"))) {
                return CapturedRequest()
            }
            val deviceCode = singleQueryParameter(data, "device_code")
            if (!KdjxExternalRequestContract.isDeviceCode(deviceCode)) {
                return CapturedRequest()
            }
            val userCode = KdjxExternalRequestContract.normalizeUserCode(
                singleQueryParameter(data, "user_code"),
            ) ?: return CapturedRequest()
            val deadlineMillis =
                nowMillis + KdjxExternalRequestContract.AUTHORIZATION_TTL_MILLIS
            val saved = externalRequestPreferences().edit()
                .putString("authorization_device_code", deviceCode)
                .putString("authorization_user_code", userCode)
                .putLong("authorization_captured_at_millis", nowMillis)
                .putLong("authorization_deadline_millis", deadlineMillis)
                .commit()
            return CapturedRequest(authorization = saved)
        }
        if (data.path != "/kdjx/pay") return CapturedRequest()
        val nowMillis = System.currentTimeMillis()
        val existingPayment = pendingPayment(nowMillis)
        if (existingPayment != null) {
            val action = KdjxExternalRequestContract.paymentCaptureAction(
                existingGameOrderId = existingPayment.values["gameOrderId"].orEmpty(),
                existingReturnNonce = existingPayment.values["returnNonce"].orEmpty(),
                existingDeadlineMillis = existingPayment.deadlineMillis,
                incomingGameOrderId = singleQueryParameter(data, "gameOrderId"),
                incomingReturnNonce = singleQueryParameter(data, "returnNonce"),
                nowMillis = nowMillis,
            )
            if (action != KdjxPaymentCaptureAction.STORE_INCOMING) {
                return CapturedRequest(payment = true)
            }
        }
        if (!hasOnlyQueryParameters(
                data,
                setOf(
                    "gameOrderId",
                    "productId",
                    "rechargeId",
                    "accountId",
                    "roleId",
                    "serverKey",
                    "yyId",
                    "csvId",
                    "returnNonce",
                ),
            )
        ) {
            return CapturedRequest()
        }

        val productId = singleQueryParameter(data, "productId").ifEmpty {
            singleQueryParameter(data, "rechargeId")
        }
        val payment = linkedMapOf(
            "gameOrderId" to singleQueryParameter(data, "gameOrderId"),
            "productId" to productId,
            "accountId" to singleQueryParameter(data, "accountId"),
            "roleId" to singleQueryParameter(data, "roleId"),
            "serverKey" to singleQueryParameter(data, "serverKey"),
            "yyId" to singleQueryParameter(data, "yyId"),
            "csvId" to singleQueryParameter(data, "csvId"),
            "returnNonce" to singleQueryParameter(data, "returnNonce"),
        )
        if (payment.filterKeys { it != "returnNonce" }.values.any {
                !KdjxExternalRequestContract.isIdentifier(it)
            } ||
            !KdjxExternalRequestContract.isPaymentReturnNonce(
                payment.getValue("returnNonce"),
            )
        ) {
            return CapturedRequest()
        }
        val editor = externalRequestPreferences().edit()
        for ((key, value) in payment) {
            editor.putString("payment_$key", value)
        }
        editor.putLong("payment_captured_at_millis", nowMillis)
        editor.putLong(
            "payment_deadline_millis",
            nowMillis + KdjxExternalRequestContract.PAYMENT_TTL_MILLIS,
        )
        return CapturedRequest(payment = editor.commit())
    }

    private fun hasOnlyQueryParameters(
        uri: Uri,
        allowed: Set<String>,
    ): Boolean {
        return uri.queryParameterNames.all(allowed::contains)
    }

    private fun singleQueryParameter(uri: Uri, name: String): String {
        val values = uri.getQueryParameters(name)
        if (values.size > 1) return ""
        return values.firstOrNull().orEmpty().trim()
    }

    private fun pendingAuthorizationRequest(): Map<String, String>? {
        val pending = pendingAuthorization() ?: return null
        return mapOf(
            "deviceCode" to pending.deviceCode,
            "userCode" to pending.userCode,
        )
    }

    private fun pendingAuthorization(
        nowMillis: Long = System.currentTimeMillis(),
    ): PendingAuthorization? {
        val preferences = externalRequestPreferences()
        val pending = PendingAuthorization(
            deviceCode = preferences.getString(
                "authorization_device_code",
                "",
            ).orEmpty(),
            userCode = preferences.getString(
                "authorization_user_code",
                "",
            ).orEmpty(),
            capturedAtMillis = preferences.getLong(
                "authorization_captured_at_millis",
                0L,
            ),
            deadlineMillis = preferences.getLong(
                "authorization_deadline_millis",
                0L,
            ),
        )
        val valid =
            KdjxExternalRequestContract.isDeviceCode(pending.deviceCode) &&
                KdjxExternalRequestContract.normalizeUserCode(
                    pending.userCode,
                ) == pending.userCode &&
                pending.capturedAtMillis > 0L &&
                pending.deadlineMillis - pending.capturedAtMillis ==
                KdjxExternalRequestContract.AUTHORIZATION_TTL_MILLIS &&
                pending.deadlineMillis > nowMillis
        if (valid) return pending
        clearPendingAuthorization()
        return null
    }

    private fun acknowledgeAuthorizationRequest(
        deviceCode: String,
        userCode: String,
    ): Boolean {
        val pending = pendingAuthorization() ?: return false
        if (pending.deviceCode != deviceCode ||
            pending.userCode != KdjxExternalRequestContract.normalizeUserCode(userCode)
        ) {
            return false
        }
        return clearPendingAuthorization()
    }

    private fun clearPendingAuthorization(): Boolean =
        externalRequestPreferences().edit()
            .remove("authorization_device_code")
            .remove("authorization_user_code")
            .remove("authorization_captured_at_millis")
            .remove("authorization_deadline_millis")
            .commit()

    private fun pendingPaymentRequest(): Map<String, String>? {
        return pendingPayment()?.values
    }

    private fun pendingPayment(
        nowMillis: Long = System.currentTimeMillis(),
    ): PendingPayment? {
        val preferences = externalRequestPreferences()
        val pending = PendingPayment(
            values = linkedMapOf(
                "gameOrderId" to preferences.getString(
                    "payment_gameOrderId",
                    "",
                ).orEmpty(),
                "productId" to preferences.getString(
                    "payment_productId",
                    "",
                ).orEmpty(),
                "accountId" to preferences.getString(
                    "payment_accountId",
                    "",
                ).orEmpty(),
                "roleId" to preferences.getString(
                    "payment_roleId",
                    "",
                ).orEmpty(),
                "serverKey" to preferences.getString(
                    "payment_serverKey",
                    "",
                ).orEmpty(),
                "yyId" to preferences.getString("payment_yyId", "").orEmpty(),
                "csvId" to preferences.getString("payment_csvId", "").orEmpty(),
                "returnNonce" to preferences.getString(
                    "payment_returnNonce",
                    "",
                ).orEmpty(),
            ),
            capturedAtMillis = preferences.getLong(
                "payment_captured_at_millis",
                0L,
            ),
            deadlineMillis = preferences.getLong(
                "payment_deadline_millis",
                0L,
            ),
        )
        val valid = pending.values.filterKeys { it != "returnNonce" }.values.all {
                KdjxExternalRequestContract.isIdentifier(it)
            } &&
            KdjxExternalRequestContract.isPaymentReturnNonce(
                pending.values.getValue("returnNonce"),
            ) &&
            pending.capturedAtMillis > 0L &&
            pending.deadlineMillis - pending.capturedAtMillis ==
            KdjxExternalRequestContract.PAYMENT_TTL_MILLIS &&
            pending.deadlineMillis > nowMillis
        if (valid) return pending
        clearPendingPayment()
        return null
    }

    private fun clearPendingPayment(): Boolean {
        val editor = externalRequestPreferences().edit()
        for (key in listOf(
            "gameOrderId",
            "productId",
            "accountId",
            "roleId",
            "serverKey",
            "yyId",
            "csvId",
            "returnNonce",
        )) {
            editor.remove("payment_$key")
        }
        return editor
            .remove("payment_captured_at_millis")
            .remove("payment_deadline_millis")
            .commit()
    }

    private fun acknowledgePaymentRequest(
        gameOrderId: String,
        returnNonce: String,
    ): Boolean {
        val pending = pendingPayment() ?: return false
        if (pending.values["gameOrderId"] != gameOrderId ||
            pending.values["returnNonce"] != returnNonce
        ) {
            return false
        }
        return clearPendingPayment()
    }

    private fun externalRequestPreferences() = activity.getSharedPreferences(
        externalRequestPreferencesName,
        Context.MODE_PRIVATE,
    )

    private fun returnAuthorizationToGame(
        payload: Map<String, String>,
    ): Boolean {
        if (!hasTrustedInstalledSignature()) return false
        val intent = activity.packageManager.getLaunchIntentForPackage(
            packageName,
        ) ?: return false
        intent.apply {
            for ((key, value) in payload) putExtra(key, value)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return startActivity(intent)
    }

    private fun returnPaymentToGame(
        gameOrderId: String,
        status: String,
        balance: Long,
        returnNonce: String,
    ): Boolean {
        if (!hasTrustedInstalledSignature()) return false
        val intent = activity.packageManager.getLaunchIntentForPackage(
            packageName,
        ) ?: return false
        intent.apply {
            putExtra("sakura_payment_order_id", gameOrderId)
            putExtra("sakura_payment_status", status)
            putExtra("sakura_payment_balance", balance)
            putExtra("sakura_payment_return_nonce", returnNonce)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return startActivity(intent)
    }

    private fun launchGame(expectedUserId: String): Boolean {
        if (!hasTrustedInstalledSignature()) return false
        val intent = activity.packageManager.getLaunchIntentForPackage(
            packageName,
        ) ?: return false
        intent.apply {
            putExtra("sakura_expected_user_id", expectedUserId)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return startActivity(intent)
    }

    private fun startActivity(intent: Intent): Boolean {
        return try {
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun installedGameInfo(): Map<String, Any?> {
        val packageInfo = try {
            packageInfoWithSignatures(packageName)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
        return if (packageInfo == null) {
            mapOf("installed" to false)
        } else {
            mapOf(
                "installed" to true,
                "packageName" to packageInfo.packageName,
                "versionName" to packageInfo.versionName.orEmpty(),
                "versionCode" to packageVersionCode(packageInfo),
                "signingCertificateSha256s" to signingDigests(packageInfo),
            )
        }
    }

    private fun hasTrustedInstalledSignature(): Boolean {
        if (!isSha256(expectedSigningCertificateSha256)) return false
        return try {
            signingDigests(packageInfoWithSignatures(packageName))
                .contains(expectedSigningCertificateSha256)
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfoWithSignatures(targetPackage: String): PackageInfo {
        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.packageManager.getPackageInfo(
                targetPackage,
                PackageManager.PackageInfoFlags.of(flag.toLong()),
            )
        } else {
            activity.packageManager.getPackageInfo(targetPackage, flag)
        }
    }

    @Suppress("DEPRECATION")
    private fun archiveInfoWithSignatures(path: String): PackageInfo? {
        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.packageManager.getPackageArchiveInfo(
                path,
                PackageManager.PackageInfoFlags.of(flag.toLong()),
            )
        } else {
            activity.packageManager.getPackageArchiveInfo(path, flag)
        }
    }

    @Suppress("DEPRECATION")
    private fun signingDigests(packageInfo: PackageInfo): List<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = packageInfo.signingInfo ?: return emptyList()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            packageInfo.signatures
        }
        return signatures.orEmpty()
            .map { signature -> sha256Hex(signature.toByteArray()) }
            .distinct()
            .sorted()
    }

    @Suppress("DEPRECATION")
    private fun packageVersionCode(packageInfo: PackageInfo): Long {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.longVersionCode
        } else {
            packageInfo.versionCode.toLong()
        }
    }

    private fun parseParts(rawParts: List<*>): List<ApkPart> {
        if (rawParts.size != 5) {
            throw IllegalArgumentException("Exactly five APK parts are required")
        }
        val parts = rawParts.map { raw ->
            val value = raw as? Map<*, *>
                ?: throw IllegalArgumentException("Invalid APK part")
            val index = (value["index"] as? Number)?.toInt() ?: -1
            val url = value["url"]?.toString().orEmpty()
            val sizeBytes = (value["sizeBytes"] as? Number)?.toLong() ?: 0L
            val sha256 = normalizeSha256(value["sha256"]?.toString().orEmpty())
            if (index !in 0..4 ||
                sizeBytes <= 0L ||
                sizeBytes > MAXIMUM_APK_BYTES ||
                !isSha256(sha256) ||
                !isTrustedPartUrl(url, index)
            ) {
                throw IllegalArgumentException("Invalid APK part")
            }
            ApkPart(index, url, sizeBytes, sha256)
        }.sortedBy(ApkPart::index)
        if (parts.map(ApkPart::index) != (0..4).toList()) {
            throw IllegalArgumentException("APK parts are not contiguous")
        }
        val prefixes = parts.map { part ->
            Uri.parse(part.url).path.orEmpty().substringBefore(".part-")
        }.distinct()
        if (prefixes.size != 1) {
            throw IllegalArgumentException("APK parts do not belong together")
        }
        val total = parts.sumOf(ApkPart::sizeBytes)
        if (total <= 0L || total > MAXIMUM_APK_BYTES) {
            throw IllegalArgumentException("APK size is invalid")
        }
        return parts
    }

    private fun prepareAppDownload(
        urls: List<String>,
        parts: List<ApkPart>,
        sourceIndex: Int,
        fileName: String,
        expectedSize: Long,
        expectedSha256: String,
        allowMetered: Boolean,
    ): Map<String, Any?> {
        val normalizedSha256 = normalizeSha256(expectedSha256)
        val calculatedSize = parts.sumOf(ApkPart::sizeBytes)
        if (!Regex("^kdjx-[0-9]+-[0-9a-f]{12}\\.apk$").matches(fileName) ||
            !isSha256(normalizedSha256) ||
            !fileName.endsWith("-${normalizedSha256.take(12)}.apk") ||
            expectedSize != calculatedSize ||
            expectedSize <= 0L ||
            expectedSize > MAXIMUM_APK_BYTES ||
            urls.any { !isTrustedWholeApkUrl(it, fileName) } ||
            (urls.isNotEmpty() && sourceIndex !in urls.indices) ||
            (urls.isEmpty() && sourceIndex != 0)
        ) {
            throw IllegalArgumentException("Invalid KDJX download request")
        }
        val expectedPartPrefix =
            "/games/kdjx/${fileName.removeSuffix(".apk")}.part-"
        if (parts.any {
                !Uri.parse(it.url).path.orEmpty().startsWith(expectedPartPrefix)
            }
        ) {
            throw IllegalArgumentException("APK parts do not match the release")
        }
        val connectivity = activity.getSystemService(
            Context.CONNECTIVITY_SERVICE,
        ) as ConnectivityManager
        if (!allowMetered && connectivity.isActiveNetworkMetered) {
            throw IllegalStateException("Waiting for an unmetered network")
        }

        val root = downloadDirectory()
        val destination = File(root, fileName)
        val workDirectory = File(
            root,
            ".parts-${fileName.removeSuffix(".apk")}",
        )
        val artifactKey = normalizedSha256
        val releaseKey = sha256Hex(
            buildString {
                append(fileName)
                for (part in parts) {
                    append('|')
                    append(part.index)
                    append(':')
                    append(part.sizeBytes)
                    append(':')
                    append(part.sha256)
                }
            }.toByteArray(Charsets.UTF_8),
        )
        val preserveParts: Boolean
        synchronized(downloadLock) {
            downloadGeneration += 1
            preserveParts =
                downloadArtifactKey == artifactKey &&
                downloadReleaseKey == releaseKey &&
                downloadPath == destination.absolutePath
            preparedDownload = null
        }
        if (!preserveParts) {
            root.listFiles()?.forEach(File::deleteRecursively)
        } else {
            destination.delete()
            File(destination.absolutePath + ".assembling").delete()
        }
        if (!workDirectory.exists() && !workDirectory.mkdirs()) {
            throw IllegalStateException("Unable to prepare APK parts")
        }
        val prepared = PreparedDownload(
            artifactKey = artifactKey,
            releaseKey = releaseKey,
            sha256 = normalizedSha256,
            destination = destination,
            workDirectory = workDirectory,
            parts = parts,
        )
        val retainedBytes = retainedPartBytes(prepared)
        synchronized(downloadLock) {
            preparedDownload = prepared
            downloadStatus = "downloading"
            downloadedBytes = retainedBytes
            totalBytes = expectedSize
            downloadPath = destination.absolutePath
            downloadReason = ""
            downloadSourceIndex = sourceIndex
            downloadSourceUrl = parts.firstOrNull()?.url
                ?: urls.getOrNull(sourceIndex).orEmpty()
            downloadArtifactKey = artifactKey
            downloadReleaseKey = releaseKey
            downloadPartCount = parts.size
            persistDownloadStateLocked()
        }
        return preparedDownloadPlan(prepared)
    }

    private fun preparedDownloadPlan(
        prepared: PreparedDownload,
    ): Map<String, Any?> {
        return mapOf(
            "artifactKey" to prepared.artifactKey,
            "releaseKey" to prepared.releaseKey,
            "finalPath" to prepared.destination.absolutePath,
            "totalBytes" to prepared.parts.sumOf(ApkPart::sizeBytes),
            "transport" to "app_http",
            "parts" to prepared.parts.map { part ->
                mapOf(
                    "index" to part.index,
                    "path" to preparedPartFile(prepared, part).absolutePath,
                    "sizeBytes" to part.sizeBytes,
                    "sha256" to part.sha256,
                )
            },
        )
    }

    private fun finalizeAppDownload(
        artifactKey: String,
        releaseKey: String,
        result: MethodChannel.Result,
    ) {
        val prepared: PreparedDownload
        val generation: Long
        try {
            synchronized(downloadLock) {
                if (!isSha256(artifactKey) || !isSha256(releaseKey)) {
                    throw SecurityException("KDJX download plan mismatch")
                }
                val sameRelease =
                    downloadArtifactKey == artifactKey &&
                        downloadReleaseKey == releaseKey
                if (activeMergeGeneration == downloadGeneration &&
                    activeMergeGeneration != null
                ) {
                    // A merge worker for this generation is still running.
                    if (sameRelease && downloadStatus == "merging") {
                        result.success(downloadState())
                        return
                    }
                    throw IllegalStateException(
                        "Another KDJX merge is already active",
                    )
                }
                if (sameRelease && downloadStatus == "completed") {
                    result.success(downloadState())
                    return
                }
                val current = preparedDownload
                    ?: throw IllegalStateException(
                        "KDJX download plan is not prepared",
                    )
                if (current.artifactKey != artifactKey ||
                    current.releaseKey != releaseKey ||
                    !sameRelease
                ) {
                    throw SecurityException("KDJX download plan mismatch")
                }
                prepared = current
                generation = downloadGeneration
                activeMergeGeneration = generation
                downloadStatus = "merging"
                downloadedBytes = totalBytes
                downloadReason = ""
                persistDownloadStateLocked()
            }
        } catch (error: Exception) {
            result.error("DOWNLOAD_FINALIZE_FAILED", error.message, null)
            return
        }
        ioExecutor.execute {
            try {
                assemblePreparedDownload(generation, prepared)
                synchronized(downloadLock) {
                    if (generation != downloadGeneration) {
                        throw InterruptedException("Download cancelled")
                    }
                    downloadedBytes = prepared.destination.length()
                    totalBytes = prepared.destination.length()
                    downloadStatus = "completed"
                    downloadReason = ""
                    preparedDownload = null
                    persistDownloadStateCommittedLocked()
                }
                // Parts may only be removed after the completed state is
                // durably persisted; a crash in between must restore as
                // completed instead of forcing a full re-download.
                prepared.workDirectory.deleteRecursively()
                val state = downloadState()
                activity.runOnUiThread { result.success(state) }
            } catch (error: Throwable) {
                synchronized(downloadLock) {
                    if (generation == downloadGeneration) {
                        downloadStatus = "failed"
                        downloadReason = when (error) {
                            is InterruptedException -> "Download cancelled"
                            else -> error.message?.take(160)
                                ?: "Game download merge failed"
                        }
                        persistDownloadStateLocked()
                    }
                }
                activity.runOnUiThread {
                    result.error(
                        "DOWNLOAD_FINALIZE_FAILED",
                        error.message,
                        null,
                    )
                }
            } finally {
                synchronized(downloadLock) {
                    if (activeMergeGeneration == generation) {
                        activeMergeGeneration = null
                    }
                }
            }
        }
    }

    private fun assemblePreparedDownload(
        generation: Long,
        prepared: PreparedDownload,
    ) {
        val temporary = File(prepared.destination.absolutePath + ".assembling")
        temporary.delete()
        prepared.destination.delete()
        val apkDigest = MessageDigest.getInstance("SHA-256")
        try {
            FileOutputStream(temporary).buffered(1024 * 1024).use { output ->
                val buffer = ByteArray(1024 * 1024)
                for (part in prepared.parts) {
                    if (generation != downloadGeneration) {
                        throw InterruptedException("Download cancelled")
                    }
                    val inputFile = preparedPartFile(prepared, part)
                    if (inputFile.length() != part.sizeBytes) {
                        throw IllegalStateException("APK part is missing")
                    }
                    val partDigest = MessageDigest.getInstance("SHA-256")
                    var partBytes = 0L
                    inputFile.inputStream().buffered(1024 * 1024).use { input ->
                        while (true) {
                            if (generation != downloadGeneration) {
                                throw InterruptedException("Download cancelled")
                            }
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (count == 0) continue
                            partBytes += count
                            if (partBytes > part.sizeBytes) {
                                throw IllegalStateException(
                                    "APK part is too large",
                                )
                            }
                            partDigest.update(buffer, 0, count)
                            apkDigest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                    }
                    if (partBytes != part.sizeBytes ||
                        partDigest.digest().toHex() != part.sha256
                    ) {
                        throw IllegalStateException(
                            "APK part verification failed",
                        )
                    }
                }
            }
            val expectedSize = prepared.parts.sumOf(ApkPart::sizeBytes)
            if (temporary.length() != expectedSize ||
                apkDigest.digest().toHex() != prepared.sha256
            ) {
                throw IllegalStateException("Assembled APK verification failed")
            }
            moveFile(temporary, prepared.destination)
        } finally {
            if (!prepared.destination.exists()) temporary.delete()
        }
    }

    private fun preparedPartFile(
        prepared: PreparedDownload,
        part: ApkPart,
    ): File {
        return File(
            prepared.workDirectory,
            "part-${part.index.toString().padStart(3, '0')}",
        )
    }

    private fun retainedPartBytes(prepared: PreparedDownload): Long {
        return prepared.parts.sumOf { part ->
            val completed = preparedPartFile(prepared, part)
            val partial = File(completed.absolutePath + ".download")
            val retained = when {
                completed.exists() -> completed.length()
                partial.exists() -> partial.length()
                else -> 0L
            }
            retained.coerceIn(0L, part.sizeBytes)
        }
    }

    private fun moveFile(source: File, destination: File) {
        if (!source.renameTo(destination)) {
            source.copyTo(destination, overwrite = true)
            source.delete()
        }
    }

    private fun downloadState(): Map<String, Any?> {
        synchronized(downloadLock) {
            if (downloadStatus in setOf(
                    "queued",
                    "downloading",
                    "paused",
                    "failed",
                )
            ) {
                downloadedBytes = preparedDownload
                    ?.let(::retainedPartBytes)
                    ?: retainedPartBytesFromState()
            }
            return mapOf(
                "status" to downloadStatus,
                "downloadedBytes" to downloadedBytes,
                "totalBytes" to totalBytes,
                "localPath" to downloadPath,
                "reason" to downloadReason,
                "sourceUrl" to downloadSourceUrl,
                "sourceIndex" to downloadSourceIndex,
                "segmented" to (downloadPartCount > 0),
                "partCount" to downloadPartCount,
                "retainedBytes" to downloadedBytes,
                "transport" to if (downloadPartCount > 0) "app_http" else "",
                "artifactKey" to downloadArtifactKey,
                "releaseKey" to downloadReleaseKey,
            )
        }
    }

    private fun retainedPartBytesFromState(): Long {
        if (downloadPath.isBlank() || downloadPartCount !in 1..16) return 0L
        val destination = File(downloadPath)
        if (!Regex("^kdjx-[0-9]+-[0-9a-f]{12}\\.apk$")
                .matches(destination.name)
        ) {
            return 0L
        }
        val workDirectory = File(
            destination.parentFile,
            ".parts-${destination.name.removeSuffix(".apk")}",
        )
        var retained = 0L
        for (index in 0 until downloadPartCount) {
            val completed = File(
                workDirectory,
                "part-${index.toString().padStart(3, '0')}",
            )
            val partial = File(completed.absolutePath + ".download")
            retained += when {
                completed.isFile -> completed.length()
                partial.isFile -> partial.length()
                else -> 0L
            }
            if (retained >= totalBytes) return totalBytes
        }
        return retained.coerceIn(0L, totalBytes)
    }

    private fun cancelDownloadWork(): Boolean {
        synchronized(downloadLock) {
            downloadGeneration += 1
            preparedDownload = null
            activeMergeGeneration = null
        }
        return true
    }

    private fun clearDownload(): Boolean {
        synchronized(downloadLock) {
            downloadGeneration += 1
            preparedDownload = null
            activeMergeGeneration = null
            downloadStatus = "none"
            downloadedBytes = 0L
            totalBytes = 0L
            downloadPath = ""
            downloadReason = ""
            downloadSourceUrl = ""
            downloadSourceIndex = 0
            downloadArtifactKey = ""
            downloadReleaseKey = ""
            downloadPartCount = 0
            val cleared = activity.getSharedPreferences(
                downloadPreferencesName,
                Context.MODE_PRIVATE,
            ).edit().clear().commit()
            if (!cleared) {
                throw IllegalStateException(
                    "Unable to clear KDJX download state",
                )
            }
        }
        downloadDirectory().listFiles()?.forEach(File::deleteRecursively)
        return true
    }

    private fun restoreDownloadState() {
        val preferences = activity.getSharedPreferences(
            downloadPreferencesName,
            Context.MODE_PRIVATE,
        )
        synchronized(downloadLock) {
            downloadStatus = preferences.getString("status", "none") ?: "none"
            downloadedBytes = preferences.getLong("downloadedBytes", 0L)
            totalBytes = preferences.getLong("totalBytes", 0L)
            downloadPath = preferences.getString("localPath", "").orEmpty()
            downloadReason = preferences.getString("reason", "").orEmpty()
            downloadSourceUrl = preferences.getString(
                "sourceUrl",
                "",
            ).orEmpty()
            downloadSourceIndex = preferences.getInt("sourceIndex", 0)
            downloadArtifactKey = preferences.getString(
                "artifactKey",
                "",
            ).orEmpty()
            downloadReleaseKey = preferences.getString(
                "releaseKey",
                "",
            ).orEmpty()
            downloadPartCount = preferences.getInt("partCount", 0)
            if (downloadStatus == "merging") {
                // The process may have died between the atomic APK publish
                // and the committed "completed" state. If the published APK
                // fully verifies against the persisted release, restore it
                // as completed instead of forcing a full re-download.
                val mergedFile = verifiedCompletedMergeFileLocked()
                if (mergedFile != null) {
                    downloadStatus = "completed"
                    downloadedBytes = mergedFile.length()
                    totalBytes = mergedFile.length()
                    downloadReason = ""
                } else {
                    // Parts (when still present) stay on disk so the next
                    // download resumes from the retained offsets.
                    downloadStatus = "failed"
                    downloadReason = "Download interrupted; retry the download"
                    downloadedBytes = retainedPartBytesFromState()
                }
            }
            if (downloadStatus in setOf(
                    "queued",
                    "downloading",
                    "paused",
                )
            ) {
                downloadStatus = "failed"
                downloadReason = "Download interrupted; retry the download"
                downloadedBytes = retainedPartBytesFromState()
            }
            val completedFile = runCatching {
                requireDownloadedApk(downloadPath)
            }.getOrNull()
            if (downloadStatus == "completed" &&
                (completedFile == null || !completedFile.exists())
            ) {
                downloadStatus = "failed"
                downloadReason = "Downloaded APK is missing"
            }
            persistDownloadStateLocked()
        }
    }

    private fun verifiedCompletedMergeFileLocked(): File? {
        val file = runCatching { requireDownloadedApk(downloadPath) }
            .getOrNull() ?: return null
        if (!file.isFile ||
            totalBytes <= 0L ||
            file.length() != totalBytes ||
            !isSha256(downloadArtifactKey) ||
            sha256Hex(file) != downloadArtifactKey
        ) {
            return null
        }
        return file
    }

    private fun downloadStateEditorLocked() = activity.getSharedPreferences(
        downloadPreferencesName,
        Context.MODE_PRIVATE,
    ).edit()
        .putString("status", downloadStatus)
        .putLong("downloadedBytes", downloadedBytes)
        .putLong("totalBytes", totalBytes)
        .putString("localPath", downloadPath)
        .putString("reason", downloadReason)
        .putString("sourceUrl", downloadSourceUrl)
        .putInt("sourceIndex", downloadSourceIndex)
        .putString("artifactKey", downloadArtifactKey)
        .putString("releaseKey", downloadReleaseKey)
        .putInt("partCount", downloadPartCount)

    private fun persistDownloadStateLocked() {
        downloadStateEditorLocked().apply()
    }

    private fun persistDownloadStateCommittedLocked() {
        if (!downloadStateEditorLocked().commit()) {
            throw IllegalStateException(
                "Unable to persist KDJX download state",
            )
        }
    }

    private fun inspectApk(path: String): Map<String, Any?> {
        val file = requireDownloadedApk(path)
        if (!file.exists()) return mapOf("exists" to false)
        val packageInfo = archiveInfoWithSignatures(file.absolutePath)
            ?: throw IllegalArgumentException("APK package metadata is invalid")
        return mapOf(
            "exists" to true,
            "sizeBytes" to file.length(),
            "sha256" to sha256Hex(file),
            "packageName" to packageInfo.packageName.orEmpty(),
            "versionName" to packageInfo.versionName.orEmpty(),
            "versionCode" to packageVersionCode(packageInfo),
            "signingCertificateSha256s" to signingDigests(packageInfo),
        )
    }

    private fun installTrustedApk(path: String) {
        val file = requireDownloadedApk(path)
        val packageInfo = archiveInfoWithSignatures(file.absolutePath)
            ?: throw SecurityException("APK package metadata is invalid")
        if (packageInfo.packageName != packageName ||
            !isSha256(expectedSigningCertificateSha256) ||
            !signingDigests(packageInfo).contains(
                expectedSigningCertificateSha256,
            )
        ) {
            throw SecurityException("APK signature is not trusted")
        }
        val uri = FileProvider.getUriForFile(
            activity,
            "${activity.packageName}.fileprovider",
            file,
        )
        activity.startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            },
        )
    }

    private fun downloadDirectory(): File {
        val parent = activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: activity.filesDir
        val directory = File(parent, "games/kdjx")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Unable to create KDJX download directory")
        }
        return directory
    }

    private fun requireDownloadedApk(path: String): File {
        if (path.isBlank()) throw SecurityException("APK path is empty")
        val root = downloadDirectory().canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith("${root.path}${File.separator}") ||
            !Regex("^kdjx-[0-9]+-[0-9a-f]{12}\\.apk$").matches(file.name)
        ) {
            throw SecurityException(
                "APK path is outside the KDJX download directory",
            )
        }
        return file
    }

    private fun requireRequestedDownloadHosts(rawHosts: List<*>) {
        val requested = rawHosts
            .mapNotNull { it?.toString()?.trim()?.lowercase() }
            .filter(String::isNotEmpty)
            .toSet()
        if (requested != trustedDownloadHosts) {
            throw IllegalArgumentException("KDJX download host policy mismatch")
        }
    }

    private fun isTrustedPartUrl(value: String, index: Int): Boolean {
        return try {
            val uri = Uri.parse(value)
            uri.scheme == "https" &&
                uri.host?.lowercase()?.let(trustedDownloadHosts::contains) == true &&
                (uri.port == -1 || uri.port == 443) &&
                uri.userInfo.isNullOrEmpty() &&
                uri.fragment.isNullOrEmpty() &&
                uri.query.isNullOrEmpty() &&
                Regex(
                    "^/games/kdjx/kdjx-[0-9]+-[0-9a-f]{12}\\.part-" +
                        index.toString().padStart(3, '0') + "\\.apk$",
                ).matches(uri.path.orEmpty())
        } catch (_: Exception) {
            false
        }
    }

    private fun isTrustedWholeApkUrl(value: String, fileName: String): Boolean {
        return try {
            val uri = Uri.parse(value)
            uri.scheme == "https" &&
                uri.host?.lowercase()?.let(trustedDownloadHosts::contains) == true &&
                (uri.port == -1 || uri.port == 443) &&
                uri.userInfo.isNullOrEmpty() &&
                uri.fragment.isNullOrEmpty() &&
                uri.query.isNullOrEmpty() &&
                uri.path == "/games/kdjx/$fileName"
        } catch (_: Exception) {
            false
        }
    }

    private fun deviceEnvironment(): Map<String, Any?> {
        val directory = downloadDirectory()
        val connectivity = activity.getSystemService(
            Context.CONNECTIVITY_SERVICE,
        ) as ConnectivityManager
        val capabilities = connectivity.activeNetwork?.let(
            connectivity::getNetworkCapabilities,
        )
        val connected = capabilities?.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_INTERNET,
        ) == true
        val validated = capabilities?.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_VALIDATED,
        ) == true
        val networkType = when {
            capabilities == null -> "none"
            capabilities.hasTransport(
                NetworkCapabilities.TRANSPORT_WIFI,
            ) -> "wifi"
            capabilities.hasTransport(
                NetworkCapabilities.TRANSPORT_ETHERNET,
            ) -> "ethernet"
            capabilities.hasTransport(
                NetworkCapabilities.TRANSPORT_CELLULAR,
            ) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
        return mapOf(
            "freeBytes" to StatFs(directory.absolutePath).availableBytes,
            "networkType" to networkType,
            "connected" to connected,
            "validated" to validated,
            "metered" to connectivity.isActiveNetworkMetered,
        )
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            activity.packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:${activity.packageName}")
                },
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered(1024 * 1024).use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                if (count > 0) digest.update(buffer, 0, count)
            }
        }
        return digest.digest().toHex()
    }

    private fun sha256Hex(bytes: ByteArray): String {
        return MessageDigest.getInstance("SHA-256").digest(bytes).toHex()
    }

    private fun ByteArray.toHex(): String {
        return joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun normalizeSha256(value: String): String =
        value.replace(":", "").replace(Regex("\\s+"), "").lowercase()

    private fun isSha256(value: String): Boolean =
        Regex("^[0-9a-f]{64}$").matches(value)

    private companion object {
        const val MAXIMUM_APK_BYTES = 4L * 1024L * 1024L * 1024L
    }
}
