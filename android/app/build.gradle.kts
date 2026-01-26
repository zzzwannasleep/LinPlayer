import java.io.FileInputStream
import java.util.Properties

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
            signingConfig =
                releaseSigningConfig ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
