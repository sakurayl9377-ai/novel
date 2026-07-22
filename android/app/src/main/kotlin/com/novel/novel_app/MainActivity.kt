package com.novel.novel_app

import android.Manifest
import android.app.KeyguardManager
import android.app.Notification
import android.app.PictureInPictureParams
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
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

class MainActivity : AudioServiceActivity() {
    private val updateChannel = "com.novel.novel_app/app_update"
    private val playerChannel = "com.novel.novel_app/player"
    private val readerChannelName = "com.novel.novel_app/reader"
    private val appInfoChannel = "com.novel.novel_app/app_info"
    private val ttsNotificationChannel = "com.novel.novel_app.channel.tts"
    private var readerChannel: MethodChannel? = null
    private var mangaTileChannel: MangaTileChannel? = null
    private var readerSessionActive = false
    private var readerVolumeKeysEnabled = false
    private var readerKeepScreenOn = false
    private var readerBrightnessOverridden = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        allowContentInDisplayCutout()
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
        readerChannel?.setMethodCallHandler(null)
        readerChannel = null
        releaseReaderSession(resetBrightness = true)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onDestroy() {
        mangaTileChannel?.dispose()
        mangaTileChannel = null
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
