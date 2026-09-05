import java.util.Properties

plugins {
    id("com.android.application")
    kotlin("plugin.compose")
    kotlin("plugin.serialization")
}

// 版本号唯一权威是仓库根的 VERSION(docs/VERSIONING.md)。写死字面量害过三次:
// 版本一退,更新检查判「已是最新」并**静默**卡死所有老用户。
val repoRoot = rootDir.parentFile.parentFile
val lpVersion = File(repoRoot, "VERSION").readText().trim()

// 签名材料从**不进版本库**的 keystore.properties 读(全局红线)。
// ★ 「写了 ≠ 用了」:下面 buildTypes.release 必须真的挂上 signingConfig,
//   不挂的话 release 变体静默出 -unsigned.apk,用户装的时候报「安装包无效」。
val keystoreProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasKeystore = keystoreProps.getProperty("storeFile") != null

// 生成的 Kotlin 绑定(bindings/kotlin/Commands.g.kt)拉进来编。
//
// ★ 为什么是「拷进 build/」而不是直接把 bindings/kotlin 当 srcDir:
//   那个目录里还住着一个独立的小 Gradle 工程(build.gradle.kts / settings.gradle.kts),
//   整目录当源码会把它们也编一遍,报一堆 Unresolved reference;
//   而 AGP 9 的 sourceSets 已经不支持 exclude 了。
// ★ 是**拷贝不是改写**:改了它 check-bindings.sh 第 4 关会红。
val bindingsDir = layout.buildDirectory.dir("generated/bindings").get().asFile
val syncBindings = tasks.register<Copy>("syncCoreBindings") {
    from(File(repoRoot, "bindings/kotlin")) { include("Commands.g.kt") }
    into(bindingsDir)
}
tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(syncBindings) }

android {
    namespace = "xyz.linplayer.app"
    compileSdk = 37

    defaultConfig {
        applicationId = "xyz.linplayer.app"
        minSdk = 24
        targetSdk = 36
        versionName = lpVersion
        // versionCode 从版本号算:1.2.3 -> 10203。手写会忘,忘了就是更新装不上
        versionCode = lpVersion.split("-")[0].split(".").let {
            it.getOrElse(0) { "0" }.toInt() * 10000 +
                it.getOrElse(1) { "0" }.toInt() * 100 +
                it.getOrElse(2) { "0" }.toInt()
        }
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // ★ ABI 名单只写在下面的 splits 里一处。两处都写 AGP 直接拒绝构建
        //   (Conflicting configuration),而这是**对的** —— 两份名单必然漂移
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                // minSdk ≥ 24 时 AGP 默认**只**签 v2/v3(v1 不再必要)。
                // 这里显式把 v1 也打开:侧载到某些老 ROM / 第三方安装器上,
                // 它们仍然只认 META-INF 里的那张证书,而「装不上」这件事
                // 在用户那头没有任何线索。多一份签名的代价是几 KB。
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // ★ 没有 keystore 时退回 debug 签名而**不是不签名**:
            //   不签名出的是 -unsigned.apk,而它长得和正常包一模一样,直到用户去装
            signingConfig = if (hasKeystore) signingConfigs.getByName("release")
                            else signingConfigs.getByName("debug")
        }
        debug {
            applicationIdSuffix = ".debug"
            isMinifyEnabled = false
        }
    }

    // 生成的 Kotlin 绑定直接拉进 sourceSet,**不拷贝改写** ——
    // 它是生成物,改了 check-bindings.sh 第 4 关会红
    sourceSets["main"].kotlin.directories.add(bindingsDir.absolutePath)

    packaging {
        jniLibs {
            // .so 已经由 build-core-android.sh strip 过。压缩它会让安装后占两份空间
            // (APK 里一份 + 解压出来一份),而现代 Android 直接从 APK 里 mmap
            useLegacyPackaging = false
        }
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    /* ABI 拆包。
       ★ 一个 ABI 的 native 就有 34MB(liblpcore 18.4 + libmpv 16.1,已 strip),
         两个塞进一个 APK 是 103MB —— 而任何一台设备只用得上其中一半。
       ★ isUniversalApk = false:不出那个「什么都有」的包。留着它的下场是
         发布时手一滑传的就是它,用户下 103MB 用 34MB。 */
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = false
        }
    }

    buildFeatures { compose = true; buildConfig = true }
    lint { abortOnError = false }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.08.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material3:material3-window-size-class")
    debugImplementation("androidx.compose.ui:ui-tooling")

    implementation("androidx.core:core-ktx:1.19.0")
    implementation("androidx.core:core-splashscreen:1.2.0")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.navigation:navigation-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.11.0")
    // ★ 用 androidx.media 的 MediaSessionCompat,不用 media3-session。
    //   理由:media3 的 MediaSession 要求一个 androidx.media3.common.Player 实现,
    //   而我们的播放器**不在 Java 侧**(解码渲染全在核心层的 libmpv 里)。
    //   接 SimpleBasePlayer 只是为了让 media3 帮我们画一遍通知,代价是把 mpv 的状态
    //   映射成 Player 的二十几个方法 —— 那是一层纯翻译的债。
    implementation("androidx.media:media:1.8.0")
    implementation("androidx.window:window:1.5.1")
    implementation("androidx.profileinstaller:profileinstaller:1.4.1")

    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")

    implementation("io.coil-kt.coil3:coil-compose:3.6.2")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.6.2")

    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
