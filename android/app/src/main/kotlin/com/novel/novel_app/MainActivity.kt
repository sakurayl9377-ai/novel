package com.novel.novel_app

import android.Manifest
import android.app.DownloadManager
import android.app.KeyguardManager
import android.app.Notification
import android.app.PictureInPictureParams
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.StatFs
import android.provider.Settings
import android.util.Rational
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : AudioServiceActivity() {
    private companion object {
        val modaoMergeCoordinatorLock = Any()
        val modaoIoExecutor = Executors.newSingleThreadExecutor()

        @Volatile
        var activeModaoMergeSession: String? = null
    }

    private val updateChannel = "com.novel.novel_app/app_update"
    private val playerChannel = "com.novel.novel_app/player"
    private val readerChannelName = "com.novel.novel_app/reader"
    private val appInfoChannel = "com.novel.novel_app/app_info"
    private val modaoGameChannel = "com.novel.novel_app/modao_game"
    private val ttsNotificationChannel = "com.novel.novel_app.channel.tts"
    private val modaoPackageName = "com.you91.fish.lucky"
    private val modaoSourcePackage = "com.novel.novel_app"
    private val modaoDownloadPreferences = "modao_game_download"
    private val modaoDownloadIdKey = "download_id"
    private val modaoDownloadPathKey = "download_path"
    private val modaoDownloadSchemaKey = "schema"
    private val modaoDownloadSchema = 3
    private val modaoDownloadReleaseKey = "release_key"
    private val modaoDownloadArtifactKey = "artifact_key"
    private val modaoDownloadTotalKey = "total_bytes"
    private val modaoDownloadShaKey = "apk_sha256"
    private val modaoDownloadPartCountKey = "part_count"
    private val modaoDownloadMergeIndexKey = "merge_index"
    private val modaoDownloadMergingKey = "merging"
    private val modaoDownloadErrorKey = "error"
    private var readerChannel: MethodChannel? = null
    private var modaoMethodChannel: MethodChannel? = null
    private var pendingModaoPaymentRequest: Map<String, String>? = null
    private var mangaTileChannel: MangaTileChannel? = null
    private var readerSessionActive = false
    private var readerVolumeKeysEnabled = false
    private var readerKeepScreenOn = false
    private var readerBrightnessOverridden = false

    private data class ModaoDownloadPart(
        val index: Int,
        val url: String,
        val fileName: String,
        val sizeBytes: Long,
        val sha256: String,
        val downloadId: Long = -1L,
    )

    private data class ModaoDownloadRecord(
        val releaseKey: String,
        val artifactKey: String,
        val fileName: String,
        val finalPath: String,
        val totalBytes: Long,
        val apkSha256: String,
        val parts: List<ModaoDownloadPart>,
    )

    private data class ModaoPartSnapshot(
        val status: Int,
        val downloadedBytes: Long,
        val reason: Int,
    )

    private data class ModaoOwnedDownload(
        val downloadId: Long,
        val file: File,
    )

    private class ModaoMergeCancelled : Exception()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureModaoPaymentRequest(intent)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        allowContentInDisplayCutout()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (captureModaoPaymentRequest(intent)) {
            modaoMethodChannel?.invokeMethod("onPaymentRequestAvailable", null)
        }
    }

    private fun allowContentInDisplayCutout() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        val attributes = window.attributes
        attributes.layoutInDisplayCutoutMode =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            } else {
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        window.attributes = attributes
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        ensureTtsNotificationChannel()
        super.configureFlutterEngine(flutterEngine)
        mangaTileChannel?.dispose()
        mangaTileChannel = MangaTileChannel(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "APK path is empty", null)
                    } else {
                        try {
                            installApk(path)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("INSTALL_FAILED", error.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        modaoMethodChannel?.setMethodCallHandler(null)
        modaoMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            modaoGameChannel,
        ).also { channel -> channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledGame" -> {
                    val requestedPackage = call.argument<String>("packageName")
                    if (requestedPackage != modaoPackageName) {
                        result.error("INVALID_PACKAGE", "Unexpected game package", null)
                    } else {
                        result.success(installedGameInfo())
                    }
                }
                "getDeviceEnvironment" -> result.success(gameDeviceEnvironment())
                "getDownloadState" -> result.success(gameDownloadState())
                "startDownload" -> {
                    try {
                        val url = call.argument<String>("url").orEmpty()
                        val fileName = call.argument<String>("fileName").orEmpty()
                        val sizeBytes = call.argument<Number>("sizeBytes")?.toLong() ?: 0L
                        val sha256 = call.argument<String>("sha256").orEmpty()
                        val parts = parseModaoDownloadParts(
                            call.argument<List<*>>("parts").orEmpty(),
                        )
                        val allowMetered = call.argument<Boolean>("allowMetered") == true
                        result.success(
                            startGameDownload(
                                url,
                                fileName,
                                sizeBytes,
                                sha256,
                                parts,
                                allowMetered,
                            ),
                        )
                    } catch (error: Exception) {
                        result.error("DOWNLOAD_FAILED", error.message, null)
                    }
                }
                "clearDownload" -> {
                    clearGameDownload()
                    result.success(null)
                }
                "inspectApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "APK path is empty", null)
                    } else {
                        modaoIoExecutor.execute {
                            try {
                                val inspection = inspectGameApk(path)
                                runOnUiThread { result.success(inspection) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error("APK_INSPECTION_FAILED", error.message, null)
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
                            installApk(requireGameApk(path).absolutePath)
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("INSTALL_FAILED", error.message, null)
                        }
                    }
                }
                "launchGame" -> {
                    val requestedPackage = call.argument<String>("packageName")
                    val ticket = call.argument<String>("ticket").orEmpty()
                    val exchangeUrl = call.argument<String>("exchangeUrl").orEmpty()
                    val allowedSsoHost = call.argument<String>("allowedSsoHost").orEmpty()
                    if (requestedPackage != modaoPackageName ||
                        ticket.isBlank() ||
                        ticket.length > 2048 ||
                        !isTrustedSsoUrl(exchangeUrl, allowedSsoHost)
                    ) {
                        result.error("INVALID_LAUNCH", "Invalid game launch request", null)
                    } else {
                        result.success(launchModaoGame(ticket, exchangeUrl))
                    }
                }
                "takePendingPaymentRequest" -> {
                    val pending = pendingModaoPaymentRequest
                    pendingModaoPaymentRequest = null
                    result.success(pending)
                }
                "returnPaymentToGame" -> {
                    val gameOrderId = call.argument<String>("gameOrderId").orEmpty()
                    val status = call.argument<String>("status").orEmpty()
                    val balance = (call.argument<Number>("balance") ?: 0).toLong()
                    if (!isPaymentIdentifier(gameOrderId) ||
                        !Regex("^[a-z_]{2,32}$").matches(status) ||
                        balance < 0
                    ) {
                        result.error("INVALID_PAYMENT_RESULT", "Invalid payment result", null)
                    } else {
                        result.success(returnPaymentToGame(gameOrderId, status, balance))
                    }
                }
                else -> result.notImplemented()
            }
        } }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, playerChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPictureInPictureSupported" -> {
                    result.success(
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE),
                    )
                }
                "isAutoRotationEnabled" -> {
                    result.success(
                        Settings.System.getInt(
                            contentResolver,
                            Settings.System.ACCELEROMETER_ROTATION,
                            0,
                        ) == 1,
                    )
                }
                "enterPictureInPicture" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                        !packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                    ) {
                        result.success(false)
                    } else {
                        val width = (call.argument<Int>("aspectWidth") ?: 16).coerceAtLeast(1)
                        val height = (call.argument<Int>("aspectHeight") ?: 9).coerceAtLeast(1)
                        val params = PictureInPictureParams.Builder()
                            .setAspectRatio(Rational(width, height))
                            .build()
                        result.success(enterPictureInPictureMode(params))
                    }
                }
                "getScreenBrightness" -> {
                    val brightness = window.attributes.screenBrightness
                    result.success(if (brightness < 0f) 0.5 else brightness.toDouble())
                }
                "setScreenBrightness" -> {
                    val value = (call.argument<Double>("value") ?: 0.5).coerceIn(0.01, 1.0)
                    val attributes = window.attributes
                    attributes.screenBrightness = value.toFloat()
                    window.attributes = attributes
                    if (readerSessionActive) readerBrightnessOverridden = true
                    result.success(null)
                }
                "resetScreenBrightness" -> {
                    val attributes = window.attributes
                    attributes.screenBrightness = -1f
                    window.attributes = attributes
                    if (readerSessionActive) readerBrightnessOverridden = false
                    result.success(null)
                }
                "setFullscreenSystemUi" -> {
                    setFullscreenSystemUi(call.argument<Boolean>("enabled") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        readerChannel?.setMethodCallHandler(null)
        releaseReaderSession(resetBrightness = true)
        readerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            readerChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "configureReaderSession" -> {
                        readerSessionActive = true
                        readerVolumeKeysEnabled =
                            call.argument<Boolean>("volumeKeyTurnPage") == true
                        readerKeepScreenOn = call.argument<Boolean>("keepScreenOn") == true
                        applyReaderKeepScreenOn()
                        result.success(true)
                    }
                    "releaseReaderSession" -> {
                        releaseReaderSession(resetBrightness = true)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, appInfoChannel).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceInfo" -> result.success(
                    mapOf(
                        "platform" to "android",
                        "osVersion" to "Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})",
                        "deviceModel" to deviceModel(),
                    ),
                )
                "areTtsNotificationsEnabled" -> result.success(
                    areTtsNotificationsEnabled(),
                )
                "ensureTtsNotificationChannel" -> {
                    ensureTtsNotificationChannel()
                    result.success(ttsNotificationStatus())
                }
                "getTtsNotificationStatus" -> result.success(
                    ttsNotificationStatus(),
                )
                "openTtsNotificationSettings" -> {
                    result.success(
                        openTtsNotificationSettings(call.argument<String>("target")),
                    )
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mangaTileChannel?.dispose()
        mangaTileChannel = null
        modaoMethodChannel?.setMethodCallHandler(null)
        modaoMethodChannel = null
        readerChannel?.setMethodCallHandler(null)
        readerChannel = null
        releaseReaderSession(resetBrightness = true)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        mangaTileChannel?.dispose()
        mangaTileChannel = null
        modaoMethodChannel?.setMethodCallHandler(null)
        modaoMethodChannel = null
        releaseReaderSession(resetBrightness = true)
        super.onDestroy()
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val readerAction = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> "previous"
            KeyEvent.KEYCODE_VOLUME_DOWN -> "next"
            else -> null
        }
        if (readerSessionActive && readerVolumeKeysEnabled && readerAction != null) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                readerChannel?.invokeMethod(
                    "onVolumeKey",
                    mapOf("action" to readerAction),
                )
            }
            // Consume both key-down and key-up while reader paging owns the
            // volume keys. Repeated key-down events are consumed without
            // triggering a rapid burst of page changes.
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private fun applyReaderKeepScreenOn() {
        window.decorView.keepScreenOn = readerSessionActive && readerKeepScreenOn
    }

    private fun releaseReaderSession(resetBrightness: Boolean) {
        readerSessionActive = false
        readerVolumeKeysEnabled = false
        readerKeepScreenOn = false
        applyReaderKeepScreenOn()
        if (resetBrightness && readerBrightnessOverridden) {
            val attributes = window.attributes
            attributes.screenBrightness = -1f
            window.attributes = attributes
        }
        readerBrightnessOverridden = false
    }

    private fun setFullscreenSystemUi(enabled: Boolean) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.navigationBarColor = Color.TRANSPARENT
        window.statusBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        val controller = WindowInsetsControllerCompat(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LAYOUT_STABLE
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    private fun deviceModel(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        if (manufacturer.isEmpty()) return model
        if (model.startsWith(manufacturer, ignoreCase = true)) return model
        return "$manufacturer $model".trim()
    }

    private fun areTtsNotificationsEnabled(): Boolean {
        val status = ttsNotificationStatus()
        return status["canShowLockScreenCard"] == true
    }

    private fun ensureTtsNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val existing = manager.getNotificationChannel(ttsNotificationChannel)
        val channel = existing ?: android.app.NotificationChannel(
            ttsNotificationChannel,
            "听书播放",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.name = "听书播放"
        channel.description = "小说听书的通知栏与锁屏媒体控制"
        channel.lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        channel.setShowBadge(false)
        if (existing == null) {
            channel.enableVibration(false)
            channel.setSound(null, null)
        }
        manager.createNotificationChannel(channel)
    }

    private fun ttsNotificationStatus(): Map<String, Any?> {
        val sdkInt = Build.VERSION.SDK_INT
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val appNotificationsEnabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
        val runtimePermissionRequired = sdkInt >= Build.VERSION_CODES.TIRAMISU
        val runtimePermissionGranted = !runtimePermissionRequired ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        val notificationsPaused = if (sdkInt >= Build.VERSION_CODES.Q) {
            notificationManager.areNotificationsPaused()
        } else {
            false
        }
        val channelSupported = sdkInt >= Build.VERSION_CODES.O
        val channel = if (channelSupported) {
            notificationManager.getNotificationChannel(ttsNotificationChannel)
        } else {
            null
        }
        val channelExists = !channelSupported || channel != null
        val channelImportance = channel?.importance ?: NotificationManager.IMPORTANCE_DEFAULT
        val channelEnabled = !channelSupported ||
            (channel != null && channelImportance != NotificationManager.IMPORTANCE_NONE)
        val channelImportanceSufficient = !channelSupported ||
            channelImportance >= NotificationManager.IMPORTANCE_LOW
        val channelVisibility = channel?.lockscreenVisibility ?: Notification.VISIBILITY_PUBLIC
        val channelPublic = !channelSupported || channelVisibility == Notification.VISIBILITY_PUBLIC
        val lockScreenNotificationsEnabled = readSecureBoolean("lock_screen_show_notifications")
        val lockScreenPrivateContentAllowed = readSecureBoolean(
            "lock_screen_allow_private_notifications",
        )
        val keyguardManager = getSystemService(KEYGUARD_SERVICE) as KeyguardManager
        val deviceSecure = if (sdkInt >= Build.VERSION_CODES.M) {
            keyguardManager.isDeviceSecure
        } else {
            @Suppress("DEPRECATION")
            keyguardManager.isKeyguardSecure
        }
        val canShowNotification = runtimePermissionGranted &&
            appNotificationsEnabled &&
            !notificationsPaused &&
            channelExists &&
            channelEnabled &&
            channelImportanceSufficient
        val canShowLockScreenCard = canShowNotification &&
            channelPublic &&
            lockScreenNotificationsEnabled != false

        return mapOf(
            "sdkInt" to sdkInt,
            "manufacturer" to Build.MANUFACTURER.orEmpty(),
            "brand" to Build.BRAND.orEmpty(),
            "model" to Build.MODEL.orEmpty(),
            "isVivoOriginOs" to isVivoOriginOs(),
            "runtimePermissionRequired" to runtimePermissionRequired,
            "runtimePermissionGranted" to runtimePermissionGranted,
            "mediaNotificationPermissionExempt" to runtimePermissionRequired,
            "appNotificationsEnabled" to appNotificationsEnabled,
            "notificationsPaused" to notificationsPaused,
            "channelSupported" to channelSupported,
            "channelExists" to channelExists,
            "channelImportance" to channelImportance,
            "channelEnabled" to channelEnabled,
            "channelImportanceSufficient" to channelImportanceSufficient,
            "channelLockscreenVisibility" to channelVisibility,
            "channelPublic" to channelPublic,
            "lockScreenSettingKnown" to (lockScreenNotificationsEnabled != null),
            "lockScreenNotificationsEnabled" to lockScreenNotificationsEnabled,
            "lockScreenPrivateContentAllowed" to lockScreenPrivateContentAllowed,
            "deviceSecure" to deviceSecure,
            "canShowNotification" to canShowNotification,
            "canShowLockScreenCard" to canShowLockScreenCard,
        )
    }

    private fun readSecureBoolean(name: String): Boolean? {
        return try {
            Settings.Secure.getString(contentResolver, name)?.let { value ->
                value != "0"
            }
        } catch (_: SecurityException) {
            null
        }
    }

    private fun openTtsNotificationSettings(target: String?): Boolean {
        val intents = mutableListOf<Intent>()
        if ((target == "channel" || target == "lockScreen") &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            intents += Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, ttsNotificationChannel)
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            intents += Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            intents += Intent("android.settings.APP_NOTIFICATION_SETTINGS").apply {
                putExtra("app_package", packageName)
                putExtra("app_uid", applicationInfo.uid)
            }
        }
        if (isVivoOriginOs()) {
            intents += vivoNotificationSettingsIntents()
        }
        if (target == "lockScreen" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            intents += Intent("android.settings.NOTIFICATION_SETTINGS")
        }
        if (target == "background" && isVivoOriginOs()) {
            intents += vivoBackgroundSettingsIntents()
        }
        intents += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }

        for (intent in intents) {
            try {
                if (intent.resolveActivity(packageManager) == null) continue
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                // Try the next standard settings destination.
            } catch (_: SecurityException) {
                // Some OEM builds expose an intent that cannot actually be opened.
            }
        }
        return false
    }

    private fun isVivoOriginOs(): Boolean {
        val manufacturer = Build.MANUFACTURER.orEmpty().lowercase()
        val brand = Build.BRAND.orEmpty().lowercase()
        return manufacturer.contains("vivo") ||
            manufacturer.contains("iqoo") ||
            brand.contains("vivo") ||
            brand.contains("iqoo")
    }

    private fun vivoNotificationSettingsIntents(): List<Intent> {
        return listOf(
            Intent("secure.intent.action.softPermissionDetail").apply {
                setPackage("com.vivo.permissionmanager")
                putExtra("packagename", packageName)
                putExtra("packageName", packageName)
            },
            Intent().apply {
                component = ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.SoftPermissionDetailActivity",
                )
                putExtra("packagename", packageName)
                putExtra("packageName", packageName)
            },
            Intent().apply {
                component = ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.PurviewTabActivity",
                )
                putExtra("packagename", packageName)
                putExtra("packageName", packageName)
            },
        )
    }

    private fun vivoBackgroundSettingsIntents(): List<Intent> {
        return listOf(
            Intent().apply {
                component = ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
                )
            },
            Intent().apply {
                component = ComponentName(
                    "com.iqoo.secure",
                    "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager",
                )
            },
            Intent().apply {
                component = ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                )
            },
        )
    }

    private fun captureModaoPaymentRequest(sourceIntent: Intent?): Boolean {
        if (sourceIntent == null) return false
        val data = sourceIntent.data
        val isDeepLink = sourceIntent.action == Intent.ACTION_VIEW &&
            data?.scheme == "sakura-novel" &&
            data.host == "modao-payment" &&
            data.path == "/pay"
        val isExplicitAction = sourceIntent.action == "com.novel.novel_app.MODAO_PAYMENT" ||
            sourceIntent.action == "$packageName.MODAO_PAYMENT"
        if (!isDeepLink && !isExplicitAction) return false
        val gameOrderId = (
            data?.getQueryParameter("gameOrderId")
                ?: sourceIntent.getStringExtra("gameOrderId")
                ?: sourceIntent.getStringExtra("sakura_game_order_id")
            ).orEmpty().trim()
        val productId = (
            data?.getQueryParameter("productId")
                ?: sourceIntent.getStringExtra("productId")
                ?: sourceIntent.getStringExtra("sakura_product_id")
            ).orEmpty().trim()
        if (!isPaymentIdentifier(gameOrderId) || !isPaymentIdentifier(productId)) {
            return false
        }
        pendingModaoPaymentRequest = mapOf(
            "gameOrderId" to gameOrderId,
            "productId" to productId,
        )
        return true
    }

    private fun isPaymentIdentifier(value: String): Boolean {
        return value.length in 1..128 &&
            Regex("^[A-Za-z0-9._:-]+$").matches(value)
    }

    private fun returnPaymentToGame(
        gameOrderId: String,
        status: String,
        balance: Long,
    ): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(modaoPackageName)
            ?: return false
        intent.apply {
            putExtra("sakura_payment_order_id", gameOrderId)
            putExtra("sakura_payment_status", status)
            putExtra("sakura_payment_balance", balance)
            putExtra("sakura_sso_source", modaoSourcePackage)
            // Compatibility for older game bridge builds.
            putExtra("sakura_payment_source", modaoSourcePackage)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun installedGameInfo(): Map<String, Any?> {
        val packageInfo = try {
            packageInfoWithSignatures(modaoPackageName)
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
                "signingCertificateSha256s" to signingCertificateDigests(packageInfo),
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfoWithSignatures(packageName: String): PackageInfo {
        val flag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(flag.toLong()),
            )
        } else {
            packageManager.getPackageInfo(packageName, flag)
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
            packageManager.getPackageArchiveInfo(
                path,
                PackageManager.PackageInfoFlags.of(flag.toLong()),
            )
        } else {
            packageManager.getPackageArchiveInfo(path, flag)
        }
    }

    @Suppress("DEPRECATION")
    private fun signingCertificateDigests(packageInfo: PackageInfo): List<String> {
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
        return signatures
            .orEmpty()
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

    private fun gameDeviceEnvironment(): Map<String, Any?> {
        val directory = gameDownloadDirectory()
        val freeBytes = StatFs(directory.absolutePath).availableBytes
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork
        val capabilities = network?.let(connectivity::getNetworkCapabilities)
        val connected = capabilities?.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_INTERNET,
        ) == true
        val validated = capabilities?.hasCapability(
            NetworkCapabilities.NET_CAPABILITY_VALIDATED,
        ) == true
        val networkType = when {
            capabilities == null -> "none"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            else -> "other"
        }
        return mapOf(
            "freeBytes" to freeBytes,
            "networkType" to networkType,
            "connected" to connected,
            "validated" to validated,
            "metered" to connectivity.isActiveNetworkMetered,
        )
    }

    private fun startGameDownload(
        url: String,
        fileName: String,
        sizeBytes: Long,
        sha256: String,
        requestedParts: List<ModaoDownloadPart>,
        allowMetered: Boolean,
    ): Map<String, Any?> {
        if (requestedParts.isEmpty()) {
            return startLegacyGameDownload(url, fileName, allowMetered)
        }
        val normalizedSha256 = sha256.lowercase()
        if (!isTrustedGameDownloadUrl(url) ||
            !Regex("^modao-[0-9]+-[0-9a-f]{12}\\.apk$").matches(fileName) ||
            sizeBytes <= 0L ||
            sizeBytes > 4L * 1024L * 1024L * 1024L ||
            !Regex("^[0-9a-f]{64}$").matches(normalizedSha256) ||
            requestedParts.size !in 2..16
        ) {
            throw IllegalArgumentException("Invalid game download request")
        }
        val apkStem = fileName.removeSuffix(".apk")
        requestedParts.forEachIndexed { index, part ->
            val expectedFile = "$apkStem.part-${index.toString().padStart(3, '0')}.apk"
            if (part.index != index ||
                part.fileName != expectedFile ||
                part.sizeBytes <= 0L ||
                !Regex("^[0-9a-f]{64}$").matches(part.sha256) ||
                !isTrustedGamePartUrl(part.url, part.fileName)
            ) {
                throw IllegalArgumentException("Invalid game download part")
            }
        }
        if (requestedParts.sumOf { it.sizeBytes } != sizeBytes) {
            throw IllegalArgumentException("Game download part size mismatch")
        }

        val artifactKey =
            "$fileName:$normalizedSha256:${modaoPartsFingerprint(requestedParts)}"
        val existing = loadModaoDownload()
        if (existing?.artifactKey == artifactKey) {
            val state = gameDownloadState()
            if (state["status"] != "failed" && state["status"] != "none") {
                return state
            }
            if (canRetryFailedModaoParts(existing)) {
                return retryFailedModaoParts(existing, allowMetered)
            }
        }
        clearGameDownload()
        val releaseKey = "$artifactKey:${UUID.randomUUID()}"
        val destination = File(gameDownloadDirectory(), fileName)
        if (destination.exists() && !destination.delete()) {
            throw IllegalStateException("Unable to replace previous game download")
        }
        File("${destination.absolutePath}.merge").delete()

        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val enqueued = requestedParts.map { it.copy(downloadId = -1L) }.toMutableList()
        var record = ModaoDownloadRecord(
            releaseKey = releaseKey,
            artifactKey = artifactKey,
            fileName = fileName,
            finalPath = destination.absolutePath,
            totalBytes = sizeBytes,
            apkSha256 = normalizedSha256,
            parts = enqueued,
        )
        if (!persistModaoDownload(record)) {
            throw IllegalStateException("Unable to save game download state")
        }
        try {
            requestedParts.forEachIndexed { index, part ->
                val partFile = gameDownloadPartFile(part.fileName)
                if (partFile.exists() && !partFile.delete()) {
                    throw IllegalStateException("Unable to replace game download part")
                }
                enqueued[index] = part.copy(
                    downloadId = enqueueModaoPart(
                        manager,
                        part,
                        index,
                        requestedParts.size,
                        allowMetered,
                    ),
                )
                record = record.copy(parts = enqueued.toList())
                if (!persistModaoDownload(record)) {
                    throw IllegalStateException("Unable to save game download state")
                }
            }
            return gameDownloadState()
        } catch (error: Exception) {
            clearGameDownload()
            throw error
        }
    }

    private fun canRetryFailedModaoParts(record: ModaoDownloadRecord): Boolean {
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        return preferences.getString(modaoDownloadErrorKey, null).orEmpty().isEmpty() &&
            preferences.getInt(modaoDownloadMergeIndexKey, 0) == 0 &&
            !preferences.getBoolean(modaoDownloadMergingKey, false) &&
            !File(record.finalPath).exists() &&
            !File("${record.finalPath}.merge").exists()
    }

    private fun retryFailedModaoParts(
        existing: ModaoDownloadRecord,
        allowMetered: Boolean,
    ): Map<String, Any?> {
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val retryIndexes = existing.parts.mapNotNull { part ->
            val snapshot = queryModaoPart(manager, part)
            if (snapshot.status == DownloadManager.STATUS_SUCCESSFUL) null else part.index
        }.toSet()
        if (retryIndexes.isEmpty()) return gameDownloadState()

        var record = existing.copy(
            releaseKey = "${existing.artifactKey}:${UUID.randomUUID()}",
        )
        if (!persistModaoDownload(record)) {
            throw IllegalStateException("Unable to save game download retry state")
        }
        retryIndexes.sorted().forEach { index ->
            val part = record.parts[index]
            removeOwnedModaoDownloadsForFiles(
                manager,
                setOf(part.fileName),
                setOf(part.downloadId),
            )
            val partFile = gameDownloadPartFile(part.fileName)
            if (partFile.exists() && !partFile.delete()) {
                throw IllegalStateException("Unable to replace failed game download part")
            }
            val retriedPart = part.copy(
                downloadId = enqueueModaoPart(
                    manager,
                    part,
                    index,
                    record.parts.size,
                    allowMetered,
                ),
            )
            record = record.copy(
                parts = record.parts.map { current ->
                    if (current.index == index) retriedPart else current
                },
            )
            if (!persistModaoDownload(record)) {
                throw IllegalStateException("Unable to save retried game download part")
            }
        }
        return gameDownloadState()
    }

    private fun enqueueModaoPart(
        manager: DownloadManager,
        part: ModaoDownloadPart,
        index: Int,
        partCount: Int,
        allowMetered: Boolean,
    ): Long {
        val request = DownloadManager.Request(Uri.parse(part.url)).apply {
            setTitle("魔道修仙 (${index + 1}/$partCount)")
            setDescription("游戏安装包分片下载中")
            setMimeType("application/octet-stream")
            setAllowedOverMetered(allowMetered)
            setAllowedOverRoaming(false)
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
            )
            setDestinationInExternalFilesDir(
                this@MainActivity,
                Environment.DIRECTORY_DOWNLOADS,
                part.fileName,
            )
        }
        return manager.enqueue(request)
    }

    private fun parseModaoDownloadParts(values: List<*>): List<ModaoDownloadPart> {
        return values.mapIndexed { position, raw ->
            val value = raw as? Map<*, *>
                ?: throw IllegalArgumentException("Invalid game download part")
            ModaoDownloadPart(
                index = (value["index"] as? Number)?.toInt() ?: -1,
                url = value["url"]?.toString().orEmpty(),
                fileName = value["fileName"]?.toString().orEmpty(),
                sizeBytes = (value["sizeBytes"] as? Number)?.toLong() ?: 0L,
                sha256 = value["sha256"]?.toString().orEmpty().lowercase(),
            ).also { part ->
                if (part.index != position) {
                    throw IllegalArgumentException("Invalid game download part order")
                }
            }
        }
    }

    private fun modaoPartsFingerprint(parts: List<ModaoDownloadPart>): String {
        val digest = MessageDigest.getInstance("SHA-256")
        parts.forEach { part ->
            val value = listOf(
                part.index.toString(),
                part.url,
                part.fileName,
                part.sizeBytes.toString(),
                part.sha256,
            ).joinToString("\n", postfix = "\n")
            digest.update(value.toByteArray(Charsets.UTF_8))
        }
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun persistModaoDownload(record: ModaoDownloadRecord): Boolean {
        val editor = getSharedPreferences(modaoDownloadPreferences, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .putInt(modaoDownloadSchemaKey, modaoDownloadSchema)
            .putString(modaoDownloadReleaseKey, record.releaseKey)
            .putString(modaoDownloadArtifactKey, record.artifactKey)
            .putString(modaoDownloadPathKey, record.finalPath)
            .putString("file_name", record.fileName)
            .putLong(modaoDownloadTotalKey, record.totalBytes)
            .putString(modaoDownloadShaKey, record.apkSha256)
            .putInt(modaoDownloadPartCountKey, record.parts.size)
            .putInt(modaoDownloadMergeIndexKey, 0)
            .putBoolean(modaoDownloadMergingKey, false)
            .putString(modaoDownloadErrorKey, "")
        record.parts.forEach { part ->
            val prefix = "part_${part.index}_"
            editor
                .putString("${prefix}url", part.url)
                .putString("${prefix}file", part.fileName)
                .putLong("${prefix}size", part.sizeBytes)
                .putString("${prefix}sha256", part.sha256)
                .putLong("${prefix}id", part.downloadId)
        }
        return editor.commit()
    }

    private fun loadModaoDownload(): ModaoDownloadRecord? {
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        if (preferences.getInt(modaoDownloadSchemaKey, 0) != modaoDownloadSchema) {
            return null
        }
        val releaseKey = preferences.getString(modaoDownloadReleaseKey, null).orEmpty()
        val artifactKey = preferences.getString(modaoDownloadArtifactKey, null).orEmpty()
        val finalPath = preferences.getString(modaoDownloadPathKey, null).orEmpty()
        val fileName = preferences.getString("file_name", null).orEmpty()
        val totalBytes = preferences.getLong(modaoDownloadTotalKey, 0L)
        val apkSha256 = preferences.getString(modaoDownloadShaKey, null).orEmpty()
        val count = preferences.getInt(modaoDownloadPartCountKey, 0)
        if (releaseKey.isBlank() ||
            artifactKey.isBlank() ||
            finalPath.isBlank() ||
            !Regex("^modao-[0-9]+-[0-9a-f]{12}\\.apk$").matches(fileName) ||
            totalBytes <= 0L ||
            !Regex("^[0-9a-f]{64}$").matches(apkSha256) ||
            count !in 2..16
        ) {
            return null
        }
        val parts = (0 until count).map { index ->
            val prefix = "part_${index}_"
            ModaoDownloadPart(
                index = index,
                url = preferences.getString("${prefix}url", null).orEmpty(),
                fileName = preferences.getString("${prefix}file", null).orEmpty(),
                sizeBytes = preferences.getLong("${prefix}size", 0L),
                sha256 = preferences.getString("${prefix}sha256", null).orEmpty(),
                downloadId = preferences.getLong("${prefix}id", -1L),
            )
        }
        if (parts.any { part ->
                part.sizeBytes <= 0L ||
                    part.downloadId <= 0L ||
                    !Regex("^[0-9a-f]{64}$").matches(part.sha256)
            } || parts.sumOf { it.sizeBytes } != totalBytes
        ) {
            return null
        }
        return ModaoDownloadRecord(
            releaseKey = releaseKey,
            artifactKey = artifactKey,
            fileName = fileName,
            finalPath = finalPath,
            totalBytes = totalBytes,
            apkSha256 = apkSha256,
            parts = parts,
        )
    }

    private fun startLegacyGameDownload(
        url: String,
        fileName: String,
        allowMetered: Boolean,
    ): Map<String, Any?> {
        if (!isTrustedGameDownloadUrl(url) ||
            !Regex("^modao-[0-9]+-[0-9a-f]{12}\\.apk$").matches(fileName)
        ) {
            throw IllegalArgumentException("Invalid game download request")
        }
        clearGameDownload()
        val destination = File(gameDownloadDirectory(), fileName)
        if (destination.exists() && !destination.delete()) {
            throw IllegalStateException("Unable to replace previous game download")
        }
        val request = DownloadManager.Request(Uri.parse(url)).apply {
            setTitle("魔道修仙")
            setDescription("游戏安装包下载中")
            setMimeType("application/vnd.android.package-archive")
            setAllowedOverMetered(allowMetered)
            setAllowedOverRoaming(false)
            setNotificationVisibility(
                DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
            )
            setDestinationInExternalFilesDir(
                this@MainActivity,
                Environment.DIRECTORY_DOWNLOADS,
                fileName,
            )
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val downloadId = manager.enqueue(request)
        getSharedPreferences(modaoDownloadPreferences, Context.MODE_PRIVATE)
            .edit()
            .putLong(modaoDownloadIdKey, downloadId)
            .putString(modaoDownloadPathKey, destination.absolutePath)
            .apply()
        return gameDownloadState()
    }

    private fun gameDownloadState(): Map<String, Any?> {
        val record = loadModaoDownload() ?: return legacyGameDownloadState()
        val destination = File(record.finalPath)
        if (destination.exists()) {
            return if (destination.length() == record.totalBytes) {
                modaoDownloadState(
                    status = "completed",
                    downloadedBytes = record.totalBytes,
                    totalBytes = record.totalBytes,
                    localPath = record.finalPath,
                    partCount = record.parts.size,
                    retainedBytes = record.totalBytes,
                )
            } else {
                modaoDownloadState(
                    status = "failed",
                    downloadedBytes = 0L,
                    totalBytes = record.totalBytes,
                    localPath = record.finalPath,
                    reason = "游戏安装包大小无效，请重新下载",
                    partCount = record.parts.size,
                )
            }
        }
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        val storedError = preferences.getString(modaoDownloadErrorKey, null).orEmpty()
        if (storedError.isNotEmpty()) {
            return modaoDownloadState(
                status = "failed",
                downloadedBytes = 0L,
                totalBytes = record.totalBytes,
                localPath = record.finalPath,
                reason = storedError,
                partCount = record.parts.size,
            )
        }
        val mergeIndex = preferences
            .getInt(modaoDownloadMergeIndexKey, 0)
            .coerceIn(0, record.parts.size)
        val mergeFile = File("${record.finalPath}.merge")
        if (preferences.getBoolean(modaoDownloadMergingKey, false) ||
            mergeIndex > 0 ||
            mergeFile.exists()
        ) {
            val checkpointBytes = record.parts.take(mergeIndex).sumOf { it.sizeBytes }
            ensureModaoMergeStarted(record)
            return modaoDownloadState(
                status = "merging",
                downloadedBytes = record.totalBytes,
                totalBytes = record.totalBytes,
                localPath = record.finalPath,
                reason = "正在合并安装包",
                partCount = record.parts.size,
                retainedBytes = checkpointBytes,
            )
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        var downloadedBytes = 0L
        var retainedBytes = 0L
        var allCompleted = true
        var anyRunning = false
        var anyPaused = false
        var anyPending = false
        var failureReason = 0
        record.parts.forEach { part ->
            if (part.index < mergeIndex) {
                downloadedBytes += part.sizeBytes
                return@forEach
            }
            val snapshot = queryModaoPart(manager, part)
            downloadedBytes += snapshot.downloadedBytes.coerceIn(0L, part.sizeBytes)
            when (snapshot.status) {
                DownloadManager.STATUS_SUCCESSFUL -> retainedBytes += part.sizeBytes
                DownloadManager.STATUS_RUNNING -> {
                    allCompleted = false
                    anyRunning = true
                }
                DownloadManager.STATUS_PAUSED -> {
                    allCompleted = false
                    anyPaused = true
                }
                DownloadManager.STATUS_PENDING -> {
                    allCompleted = false
                    anyPending = true
                }
                else -> {
                    allCompleted = false
                    if (failureReason == 0) failureReason = snapshot.reason
                }
            }
        }
        if (allCompleted) {
            ensureModaoMergeStarted(record)
            return modaoDownloadState(
                status = "merging",
                downloadedBytes = record.totalBytes,
                totalBytes = record.totalBytes,
                localPath = record.finalPath,
                reason = "正在合并安装包",
                partCount = record.parts.size,
            )
        }
        val status = when {
            failureReason != 0 -> "failed"
            anyRunning -> "downloading"
            anyPaused -> "paused"
            anyPending -> "queued"
            else -> "failed"
        }
        return modaoDownloadState(
            status = status,
            downloadedBytes = downloadedBytes,
            totalBytes = record.totalBytes,
            localPath = record.finalPath,
            reason = when {
                failureReason != 0 -> "游戏下载失败（错误码 $failureReason）"
                anyPaused -> "下载已暂停，等待系统继续"
                else -> ""
            },
            partCount = record.parts.size,
            retainedBytes = retainedBytes,
        )
    }

    private fun queryModaoPart(
        manager: DownloadManager,
        part: ModaoDownloadPart,
    ): ModaoPartSnapshot {
        val partFile = gameDownloadPartFile(part.fileName)
        val cursor = manager.query(
            DownloadManager.Query().setFilterById(part.downloadId),
        )
        cursor?.use {
            if (it.moveToFirst()) {
                val status = it.getInt(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                )
                val reason = it.getInt(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
                )
                val downloaded = it.getLong(
                    it.getColumnIndexOrThrow(
                        DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                    ),
                ).coerceAtLeast(0L)
                if (status == DownloadManager.STATUS_SUCCESSFUL &&
                    (!partFile.exists() || partFile.length() != part.sizeBytes)
                ) {
                    return ModaoPartSnapshot(
                        DownloadManager.STATUS_FAILED,
                        downloaded,
                        DownloadManager.ERROR_FILE_ERROR,
                    )
                }
                return ModaoPartSnapshot(status, downloaded, reason)
            }
        }
        return if (partFile.exists() && partFile.length() == part.sizeBytes) {
            ModaoPartSnapshot(
                DownloadManager.STATUS_SUCCESSFUL,
                part.sizeBytes,
                0,
            )
        } else {
            ModaoPartSnapshot(
                DownloadManager.STATUS_FAILED,
                partFile.takeIf(File::exists)?.length() ?: 0L,
                DownloadManager.ERROR_FILE_ERROR,
            )
        }
    }

    private fun modaoDownloadState(
        status: String,
        downloadedBytes: Long,
        totalBytes: Long,
        localPath: String,
        reason: String = "",
        partCount: Int,
        retainedBytes: Long = 0L,
    ): Map<String, Any?> {
        return mapOf(
            "status" to status,
            "downloadedBytes" to downloadedBytes,
            "totalBytes" to totalBytes,
            "localPath" to localPath,
            "reason" to reason,
            "segmented" to true,
            "partCount" to partCount,
            "retainedBytes" to retainedBytes,
        )
    }

    private fun ensureModaoMergeStarted(record: ModaoDownloadRecord) {
        synchronized(modaoMergeCoordinatorLock) {
            if (activeModaoMergeSession == record.releaseKey) return
            activeModaoMergeSession = record.releaseKey
        }
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        if (preferences.getString(modaoDownloadReleaseKey, null) != record.releaseKey) {
            synchronized(modaoMergeCoordinatorLock) {
                if (activeModaoMergeSession == record.releaseKey) {
                    activeModaoMergeSession = null
                }
            }
            return
        }
        if (!preferences.edit().putBoolean(modaoDownloadMergingKey, true).commit()) {
            synchronized(modaoMergeCoordinatorLock) {
                if (activeModaoMergeSession == record.releaseKey) {
                    activeModaoMergeSession = null
                }
            }
            throw IllegalStateException("Unable to save merge state")
        }
        try {
            modaoIoExecutor.execute {
                try {
                    mergeModaoDownload(record)
                } catch (_: ModaoMergeCancelled) {
                    // Cancellation or a newer release owns the persisted state.
                } catch (_: Exception) {
                    val preferences = getSharedPreferences(
                        modaoDownloadPreferences,
                        Context.MODE_PRIVATE,
                    )
                    if (preferences.getString(modaoDownloadReleaseKey, null) ==
                        record.releaseKey
                    ) {
                        preferences.edit()
                            .putBoolean(modaoDownloadMergingKey, false)
                            .putString(
                                modaoDownloadErrorKey,
                                "安装包分片合并失败，请重新下载",
                            )
                            .commit()
                    }
                } finally {
                    synchronized(modaoMergeCoordinatorLock) {
                        if (activeModaoMergeSession == record.releaseKey) {
                            activeModaoMergeSession = null
                        }
                    }
                }
            }
        } catch (error: Exception) {
            if (preferences.getString(modaoDownloadReleaseKey, null) == record.releaseKey) {
                preferences.edit().putBoolean(modaoDownloadMergingKey, false).commit()
            }
            synchronized(modaoMergeCoordinatorLock) {
                if (activeModaoMergeSession == record.releaseKey) {
                    activeModaoMergeSession = null
                }
            }
            throw error
        }
    }

    private fun mergeModaoDownload(record: ModaoDownloadRecord) {
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        var mergeIndex = preferences
            .getInt(modaoDownloadMergeIndexKey, 0)
            .coerceIn(0, record.parts.size)
        var checkpoint = record.parts
            .take(mergeIndex)
            .sumOf { it.sizeBytes }
        val destination = File(record.finalPath)
        val mergeFile = File("${record.finalPath}.merge")
        RandomAccessFile(mergeFile, "rw").use { output ->
            if (output.length() < checkpoint) {
                throw IllegalStateException("Merge checkpoint is incomplete")
            }
            if (output.length() != checkpoint) {
                output.setLength(checkpoint)
                output.fd.sync()
            }
            record.parts.take(mergeIndex).forEach { completedPart ->
                val stalePart = gameDownloadPartFile(completedPart.fileName)
                if (stalePart.exists() && !stalePart.delete()) {
                    throw IllegalStateException("Unable to remove merged game part")
                }
            }
            while (mergeIndex < record.parts.size) {
                ensureModaoReleaseIsCurrent(record.releaseKey)
                val part = record.parts[mergeIndex]
                val partFile = gameDownloadPartFile(part.fileName)
                if (!partFile.exists() || partFile.length() != part.sizeBytes) {
                    throw IllegalStateException("Game download part is incomplete")
                }
                output.seek(checkpoint)
                val digest = MessageDigest.getInstance("SHA-256")
                partFile.inputStream().buffered(1024 * 1024).use { input ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        ensureModaoReleaseIsCurrent(record.releaseKey)
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count > 0) {
                            digest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                    }
                }
                val actualSha256 = digest.digest().joinToString("") { byte ->
                    "%02x".format(byte.toInt() and 0xff)
                }
                if (actualSha256 != part.sha256) {
                    output.setLength(checkpoint)
                    output.fd.sync()
                    throw IllegalStateException("Game download part checksum mismatch")
                }
                checkpoint += part.sizeBytes
                output.fd.sync()
                if (!preferences.edit()
                        .putInt(modaoDownloadMergeIndexKey, mergeIndex + 1)
                        .commit()
                ) {
                    throw IllegalStateException("Unable to save merge checkpoint")
                }
                if (!partFile.delete()) {
                    throw IllegalStateException("Unable to remove merged game part")
                }
                mergeIndex++
            }
            if (output.length() != record.totalBytes) {
                throw IllegalStateException("Merged game APK size mismatch")
            }
            output.fd.sync()
        }
        ensureModaoReleaseIsCurrent(record.releaseKey)
        if (destination.exists() && !destination.delete()) {
            throw IllegalStateException("Unable to replace game APK")
        }
        if (!mergeFile.renameTo(destination)) {
            throw IllegalStateException("Unable to publish merged game APK")
        }
        try {
            ensureModaoReleaseIsCurrent(record.releaseKey)
        } catch (cancelled: ModaoMergeCancelled) {
            destination.delete()
            throw cancelled
        }
        if (!preferences.edit().putBoolean(modaoDownloadMergingKey, false).commit()) {
            throw IllegalStateException("Unable to save completed merge state")
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        record.parts.forEach { part ->
            try {
                manager.remove(part.downloadId)
            } catch (_: Exception) {
                // The verified merged APK is independent from stale task records.
            }
        }
    }

    private fun ensureModaoReleaseIsCurrent(releaseKey: String) {
        val current = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        ).getString(modaoDownloadReleaseKey, null)
        if (current != releaseKey) throw ModaoMergeCancelled()
    }

    private fun legacyGameDownloadState(): Map<String, Any?> {
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        val downloadId = preferences.getLong(modaoDownloadIdKey, -1L)
        val localPath = preferences.getString(modaoDownloadPathKey, null).orEmpty()
        if (downloadId <= 0L) {
            return mapOf(
                "status" to "none",
                "downloadedBytes" to 0L,
                "totalBytes" to 0L,
                "localPath" to localPath,
                "reason" to "",
                "segmented" to false,
                "partCount" to 0,
            )
        }
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val cursor = manager.query(
            DownloadManager.Query().setFilterById(downloadId),
        )
        cursor?.use {
            if (it.moveToFirst()) {
                val status = it.getInt(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                )
                val reason = it.getInt(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON),
                )
                val downloaded = it.getLong(
                    it.getColumnIndexOrThrow(
                        DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                    ),
                ).coerceAtLeast(0L)
                val total = it.getLong(
                    it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                ).coerceAtLeast(0L)
                val state = when (status) {
                    DownloadManager.STATUS_PENDING -> "queued"
                    DownloadManager.STATUS_RUNNING -> "downloading"
                    DownloadManager.STATUS_PAUSED -> "paused"
                    DownloadManager.STATUS_SUCCESSFUL -> "completed"
                    DownloadManager.STATUS_FAILED -> "failed"
                    else -> "none"
                }
                val resolvedState = if (
                    state == "completed" && (localPath.isEmpty() || !File(localPath).exists())
                ) {
                    "failed"
                } else {
                    state
                }
                return mapOf(
                    "status" to resolvedState,
                    "downloadedBytes" to downloaded,
                    "totalBytes" to total,
                    "localPath" to localPath,
                    "reason" to downloadReason(status, reason),
                    "segmented" to false,
                    "partCount" to 0,
                )
            }
        }
        val cachedFile = localPath.takeIf(String::isNotEmpty)?.let(::File)
        return if (cachedFile?.exists() == true) {
            mapOf(
                "status" to "completed",
                "downloadedBytes" to cachedFile.length(),
                "totalBytes" to cachedFile.length(),
                "localPath" to localPath,
                "reason" to "",
                "segmented" to false,
                "partCount" to 0,
            )
        } else {
            mapOf(
                "status" to "failed",
                "downloadedBytes" to 0L,
                "totalBytes" to 0L,
                "localPath" to localPath,
                "reason" to "下载任务不存在",
                "segmented" to false,
                "partCount" to 0,
            )
        }
    }

    private fun downloadReason(status: Int, reason: Int): String {
        if (status == DownloadManager.STATUS_PAUSED) {
            return when (reason) {
                DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "等待网络连接"
                DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "等待 Wi-Fi 连接"
                DownloadManager.PAUSED_WAITING_TO_RETRY -> "等待自动重试"
                else -> "下载已暂停"
            }
        }
        return if (status == DownloadManager.STATUS_FAILED) {
            "下载失败（错误码 $reason）"
        } else {
            ""
        }
    }

    private fun queryOwnedModaoDownloads(
        manager: DownloadManager,
    ): List<ModaoOwnedDownload> {
        val downloads = mutableListOf<ModaoOwnedDownload>()
        val cursor = manager.query(DownloadManager.Query()) ?: return downloads
        cursor.use {
            val idColumn = it.getColumnIndex(DownloadManager.COLUMN_ID)
            val localUriColumn = it.getColumnIndex(DownloadManager.COLUMN_LOCAL_URI)
            if (idColumn < 0 || localUriColumn < 0) return downloads
            while (it.moveToNext()) {
                if (it.isNull(localUriColumn)) continue
                val localUri = Uri.parse(it.getString(localUriColumn))
                if (localUri.scheme != "file") continue
                val path = localUri.path ?: continue
                val file = try {
                    File(path).canonicalFile
                } catch (_: Exception) {
                    continue
                }
                if (isOwnedModaoArtifactFile(file)) {
                    downloads.add(
                        ModaoOwnedDownload(
                            downloadId = it.getLong(idColumn),
                            file = file,
                        ),
                    )
                }
            }
        }
        return downloads
    }

    private fun removeOwnedModaoDownloadsForFiles(
        manager: DownloadManager,
        fileNames: Set<String>,
        knownIds: Set<Long> = emptySet(),
    ) {
        val ids = knownIds.filterTo(mutableSetOf()) { it > 0L }
        val discovered = try {
            queryOwnedModaoDownloads(manager)
        } catch (_: Exception) {
            emptyList()
        }
        discovered
            .filter { it.file.name in fileNames }
            .mapTo(ids) { it.downloadId }
        ids.forEach { downloadId ->
            try {
                manager.remove(downloadId)
            } catch (_: Exception) {
                // A stale task may disappear between the query and removal.
            }
        }
    }

    private fun isOwnedModaoArtifactFile(file: File): Boolean {
        val root = gameDownloadDirectory().canonicalFile
        val candidate = try {
            file.canonicalFile
        } catch (_: Exception) {
            return false
        }
        if (candidate.parentFile != root) return false
        return Regex("^modao-[0-9]+-[0-9a-f]{12}\\.apk(?:\\.merge)?$")
            .matches(candidate.name) ||
            Regex("^modao-[0-9]+-[0-9a-f]{12}\\.part-[0-9]{3}\\.apk$")
                .matches(candidate.name)
    }

    private fun clearGameDownload() {
        val preferences = getSharedPreferences(
            modaoDownloadPreferences,
            Context.MODE_PRIVATE,
        )
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val downloadIds = mutableSetOf<Long>()
        preferences.getLong(modaoDownloadIdKey, -1L)
            .takeIf { it > 0L }
            ?.let(downloadIds::add)
        val localPath = preferences.getString(modaoDownloadPathKey, null)
        val partFiles = mutableListOf<File>()
        val partCount = preferences.getInt(modaoDownloadPartCountKey, 0)
            .coerceIn(0, 16)
        repeat(partCount) { index ->
            val prefix = "part_${index}_"
            preferences.getLong("${prefix}id", -1L)
                .takeIf { it > 0L }
                ?.let(downloadIds::add)
            try {
                val partName = preferences.getString("${prefix}file", null).orEmpty()
                if (partName.isNotEmpty()) partFiles.add(gameDownloadPartFile(partName))
            } catch (_: Exception) {
                // Ignore malformed stale state while clearing all trusted paths.
            }
        }
        val orphanDownloads = try {
            queryOwnedModaoDownloads(manager)
        } catch (_: Exception) {
            emptyList()
        }
        orphanDownloads.mapTo(downloadIds) { it.downloadId }
        val artifactFiles = gameDownloadDirectory()
            .listFiles()
            .orEmpty()
            .filter(::isOwnedModaoArtifactFile)
            .toMutableList()
        artifactFiles.addAll(orphanDownloads.map { it.file })
        preferences.edit().clear().commit()
        downloadIds.forEach { downloadId ->
            try {
                manager.remove(downloadId)
            } catch (_: Exception) {
                // Local files are removed below even if a task record is stale.
            }
        }
        (partFiles + artifactFiles).distinctBy { it.absolutePath }.forEach { it.delete() }
        if (!localPath.isNullOrBlank()) {
            try {
                val apk = requireGameApk(localPath)
                apk.delete()
                File("${apk.absolutePath}.merge").delete()
            } catch (_: Exception) {
                // Best-effort cleanup of a stale or already removed destination.
            }
        }
    }

    private fun inspectGameApk(path: String): Map<String, Any?> {
        val file = requireGameApk(path)
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
            "signingCertificateSha256s" to signingCertificateDigests(packageInfo),
        )
    }

    private fun gameDownloadDirectory(): File {
        val directory = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?: throw IllegalStateException("External app storage is unavailable")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Unable to create game download directory")
        }
        return directory
    }

    private fun requireGameApk(path: String): File {
        val root = gameDownloadDirectory().canonicalFile
        val file = File(path).canonicalFile
        if (!file.path.startsWith("${root.path}${File.separator}") ||
            !file.name.lowercase().endsWith(".apk")
        ) {
            throw SecurityException("APK path is outside the game download directory")
        }
        return file
    }

    private fun gameDownloadPartFile(fileName: String): File {
        if (!Regex("^modao-[0-9]+-[0-9a-f]{12}\\.part-[0-9]{3}\\.apk$")
                .matches(fileName)
        ) {
            throw SecurityException("Invalid game download part name")
        }
        val root = gameDownloadDirectory().canonicalFile
        val file = File(root, fileName).canonicalFile
        if (!file.path.startsWith("${root.path}${File.separator}")) {
            throw SecurityException("Game download part is outside the download directory")
        }
        return file
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
        return digest.digest().joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun sha256Hex(bytes: ByteArray): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    private fun canInstallPackages(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()
    }

    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                data = Uri.parse("package:$packageName")
            }
            if (intent.resolveActivity(packageManager) == null) return false
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun launchModaoGame(ticket: String, exchangeUrl: String): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(modaoPackageName)
            ?: return false
        intent.apply {
            putExtra("sakura_sso_ticket", ticket)
            putExtra("sakura_sso_exchange_url", exchangeUrl)
            putExtra("sakura_sso_source", modaoSourcePackage)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        return try {
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun isTrustedGameDownloadUrl(value: String): Boolean {
        val uri = Uri.parse(value)
        return uri.scheme == "https" &&
            uri.host == "novel.kxhub.xyz" &&
            uri.userInfo.isNullOrEmpty() &&
            uri.fragment.isNullOrEmpty() &&
            uri.path.orEmpty().startsWith("/games/modao/") &&
            uri.path.orEmpty().lowercase().endsWith(".apk")
    }

    private fun isTrustedGamePartUrl(value: String, fileName: String): Boolean {
        return try {
            val uri = Uri.parse(value)
            uri.scheme == "https" &&
                uri.host == "novel.kxhub.xyz" &&
                (uri.port == -1 || uri.port == 443) &&
                uri.userInfo.isNullOrEmpty() &&
                uri.fragment.isNullOrEmpty() &&
                uri.path == "/games/modao/$fileName"
        } catch (_: Exception) {
            false
        }
    }

    private fun isTrustedSsoUrl(value: String, allowedHost: String): Boolean {
        return try {
            val uri = Uri.parse(value)
            uri.scheme == "https" &&
                !uri.host.isNullOrEmpty() &&
                allowedHost.isNotBlank() && uri.host == allowedHost &&
                (uri.port == -1 || uri.port == 443) &&
                uri.userInfo.isNullOrEmpty() &&
                uri.fragment.isNullOrEmpty() &&
                uri.path == "/sakura/sso/exchange"
        } catch (_: Exception) {
            false
        }
    }


    private fun installApk(path: String) {
        val apkFile = File(path)
        if (!apkFile.exists()) {
            throw IllegalArgumentException("APK file does not exist")
        }

        val uri: Uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            apkFile,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }
}
