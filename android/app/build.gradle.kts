import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.Properties
import java.util.zip.GZIPInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.lin_player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val isCi = System.getenv("CI")?.trim()?.lowercase() == "true"
    val allowCiDebugSigning =
        System.getenv("LINPLAYER_ALLOW_CI_DEBUG_SIGNING")?.trim()?.lowercase()
            ?.let { it == "1" || it == "true" || it == "yes" } ?: false

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
    }

    fun propOrEnv(propName: String, envName: String): String? {
        val env = System.getenv(envName)?.trim()
        if (!env.isNullOrEmpty()) return env
        val prop = keystoreProperties.getProperty(propName)?.trim()
        return prop?.takeIf { it.isNotEmpty() }
    }

    val releaseKeystoreFile = propOrEnv("storeFile", "ANDROID_KEYSTORE_FILE")
    val releaseStorePassword =
        propOrEnv("storePassword", "ANDROID_KEYSTORE_PASSWORD")
    val releaseKeyAlias = propOrEnv("keyAlias", "ANDROID_KEY_ALIAS")
    val releaseKeyPassword = propOrEnv("keyPassword", "ANDROID_KEY_PASSWORD")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.lin_player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val releaseSigningConfig =
        if (
            releaseKeystoreFile != null &&
                releaseStorePassword != null &&
                releaseKeyAlias != null &&
                releaseKeyPassword != null &&
                file(releaseKeystoreFile).exists()
        ) {
            signingConfigs.create("release") {
                storeFile = file(releaseKeystoreFile)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        } else {
            null
        }

    buildTypes {
        release {
            if (isCi && releaseSigningConfig == null && !allowCiDebugSigning) {
                throw GradleException(
                    "Android release signing is not configured. " +
                        "OTA upgrades require a stable signing key; configure ANDROID_KEYSTORE_* secrets/env vars " +
                        "or set LINPLAYER_ALLOW_CI_DEBUG_SIGNING=true to force debug signing (not OTA-safe).",
                )
            }
            signingConfig = releaseSigningConfig ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

// Bundle mihomo as a native library executable (libmihomo.so) so it can run on ROMs that mount
// app-private storage as "noexec" (executing binaries from filesDir will fail with Permission denied).
val repoRootDir = project.rootDir.parentFile
val mihomoAssetsDir = File(repoRootDir, "assets/tv_proxy/mihomo/android")
val generatedMihomoJniLibsDir = File(project.buildDir, "generated/mihomoJniLibs")

tasks.register("prepareMihomoJniLibs") {
    inputs.dir(mihomoAssetsDir)
    outputs.dir(generatedMihomoJniLibsDir)
    doLast {
        val mappings =
            listOf(
                "arm64-v8a",
                "armeabi-v7a",
                "x86_64",
                "x86",
            )
        for (abi in mappings) {
            val src = File(mihomoAssetsDir, "$abi/mihomo.gz")
            if (!src.exists()) continue
            val dst = File(generatedMihomoJniLibsDir, "$abi/libmihomo.so")
            dst.parentFile.mkdirs()
            GZIPInputStream(FileInputStream(src)).use { input ->
                FileOutputStream(dst).use { output ->
                    input.copyTo(output)
                }
            }
        }
    }
}

android.sourceSets.getByName("main").jniLibs.srcDir(generatedMihomoJniLibsDir)
tasks.named("preBuild").configure { dependsOn("prepareMihomoJniLibs") }
