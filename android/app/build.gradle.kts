import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
// Release automation can keep signing material outside the source checkout.
val externalKeystorePropertiesPath = providers.environmentVariable("NOVEL_ANDROID_KEY_PROPERTIES")
    .orNull
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
val externalKeystoreFilePath = providers.environmentVariable("NOVEL_ANDROID_KEYSTORE_FILE")
    .orNull
    ?.trim()
    ?.takeIf { it.isNotEmpty() }
val keystorePropertiesFile = externalKeystorePropertiesPath
    ?.let { File(it) }
    ?: rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val releaseKeystoreFilePath = externalKeystoreFilePath
    ?: keystoreProperties.getProperty("storeFile")
val releaseSigningPropertyNames = listOf(
    "keyAlias",
    "keyPassword",
    "storePassword",
)
val releaseSigningConfigured = keystorePropertiesFile.exists() &&
    !releaseKeystoreFilePath.isNullOrBlank() &&
    releaseSigningPropertyNames.all { !keystoreProperties.getProperty(it).isNullOrBlank() }

val readerBetaBuild = providers.gradleProperty("readerBeta")
    .orNull
    ?.equals("true", ignoreCase = true) == true
val readerBetaNumber = providers.gradleProperty("readerBetaNumber")
    .orNull
    ?.trim()
    ?.takeIf { it.matches(Regex("[0-9]+")) }
    ?: "1"

gradle.taskGraph.whenReady {
    val releaseArtifactTask = Regex(
        "^(assemble|package|bundle).*release$",
        RegexOption.IGNORE_CASE,
    )
    val releaseBuildRequested = allTasks.any { task ->
        task.project == project && releaseArtifactTask.matches(task.name)
    }
    if (releaseBuildRequested && !releaseSigningConfigured) {
        throw GradleException(
            "Release signing is not configured. Add android/key.properties or set the external signing paths.",
        )
    }
}

android {
    namespace = "com.novel.novel_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (readerBetaBuild) {
            "com.novel.novel_app.beta"
        } else {
            "com.novel.novel_app"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = if (readerBetaBuild) {
            "${flutter.versionName}-beta.$readerBetaNumber"
        } else {
            flutter.versionName
        }
        resValue(
            "string",
            "app_name",
            if (readerBetaBuild) "Sakura 测试版" else "Sakura",
        )
        manifestPlaceholders["updateInstallPermission"] = if (readerBetaBuild) {
            "com.novel.novel_app.beta.permission.UPDATES_DISABLED"
        } else {
            "android.permission.REQUEST_INSTALL_PACKAGES"
        }
        ndk {
            // Self-hosted release APKs target physical Android devices only.
            // Debug adds x86_64 below so emulator builds remain available.
            // Flutter configures ABI splits itself for the independent reader
            // beta. Keeping ndk.abiFilters alongside splits makes AGP reject
            // the build as a conflicting configuration.
            if (!readerBetaBuild) {
                abiFilters += setOf("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(requireNotNull(releaseKeystoreFilePath))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        debug {
            ndk {
                if (!readerBetaBuild) {
                    abiFilters += setOf("arm64-v8a", "armeabi-v7a", "x86_64")
                }
            }
        }
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
            ndk {
                if (!readerBetaBuild) {
                    abiFilters += setOf("arm64-v8a", "armeabi-v7a")
                }
            }
        }
    }
}

androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        // Flutter's Gradle plugin restores its default fat-APK ABI list after
        // DSL evaluation. Apply the physical-device release policy at the
        // variant packaging layer so debug x86_64 emulators keep working.
        variant.packaging.jniLibs.excludes.add("lib/x86_64/**")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
