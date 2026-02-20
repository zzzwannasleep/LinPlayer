plugins {
    id("com.android.application")
}

android {
    namespace = "com.linplayer.tvlegacy"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.linplayer.tvlegacy"
        minSdk = 19
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

dependencies {
    // UI (Java + XML/View)
    implementation("androidx.appcompat:appcompat:1.7.1")
    implementation("androidx.recyclerview:recyclerview:1.3.2")

    // Networking (API 19 compatible)
    implementation("com.squareup.okhttp3:okhttp:3.12.13")

    // Playback (legacy ExoPlayer 2, API 19 compatible)
    implementation("com.google.android.exoplayer:exoplayer:2.19.1")
    implementation("com.google.android.exoplayer:extension-okhttp:2.19.1")

    // QR code (Android 4.4 compatible)
    implementation("com.google.zxing:core:3.5.3")
}
