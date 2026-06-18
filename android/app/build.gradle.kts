plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val ciTargetAbis = providers.gradleProperty("linplayerTargetAbis")
    .orNull
    ?.split(",")
    ?.map(String::trim)
    ?.filter(String::isNotEmpty)
    ?: emptyList()
val isSplitPerAbiBuild = providers.gradleProperty("split-per-abi")
    .orNull
    ?.toBoolean() == true
val knownNativeAbis = listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
val excludedCiAbis = if (ciTargetAbis.isNotEmpty()) {
    knownNativeAbis.filterNot(ciTargetAbis::contains)
} else {
    emptyList()
}

android {
    namespace = "com.example.linplayer_mobile"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.linplayer_mobile"
        minSdk = 24  // Vulkan 支持需要 API 24+ (Android 7.0+)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                // Keep the JNI bridge self-contained so packaging does not
                // collide with the shared STL shipped by prebuilt native libs.
                arguments += "-DANDROID_STL=c++_static"
            }
        }

        ndk {
            // Flutter configures ABI splits itself for --split-per-abi builds.
            if (ciTargetAbis.isNotEmpty() && !isSplitPerAbiBuild) {
                abiFilters.addAll(ciTargetAbis)
            }
        }

    }

    flavorDimensions += "device"

    productFlavors {
        create("mobile") {
            dimension = "device"
        }
        create("tv") {
            dimension = "device"
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packagingOptions {
        excludes += excludedCiAbis.map { "lib/$it/**" }
        // Prefer a single shared STL copy when prebuilt dependencies bundle it.
        pickFirsts += listOf(
            "lib/arm64-v8a/libc++_shared.so",
            "lib/armeabi-v7a/libc++_shared.so",
            "lib/x86/libc++_shared.so",
            "lib/x86_64/libc++_shared.so"
        )
        // 优先使用 jniLibs 中的 libmpv.so（支持 PGS 的版本）
        // 覆盖 media_kit 内置的 libmpv.so
        pickFirsts += listOf(
            "lib/arm64-v8a/libmpv.so",
            "lib/armeabi-v7a/libmpv.so",
            "lib/x86/libmpv.so",
            "lib/x86_64/libmpv.so"
        )
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
        // TV 专属：mihomo 内核(libmihomo.so) 与 zashboard 面板仅打包进 tv flavor，
        // mobile/iOS/desktop 不含。内核以 lib*.so 命名放入 jniLibs，安装时会被
        // 解压到 nativeLibraryDir 并具备可执行权限（Android 10+ 仅允许从此目录执行二进制）。
        getByName("tv") {
            jniLibs.srcDirs("src/tv/jniLibs")
            assets.srcDirs("src/tv/assets")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    val media3Version = "1.8.0"

    // Media3 ExoPlayer（原生播放器内核）
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-exoplayer-dash:$media3Version")

    // Mature ASS integration for Media3/ExoPlayer.
    implementation("io.github.peerless2012:ass-media:0.4.0")


}

flutter {
    source = "../.."
}
