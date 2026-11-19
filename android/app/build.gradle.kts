plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.sniffing.sniffing_browser"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.sniffing.sniffing_browser"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ffmpeg-kit AAR 只发布 arm64-v8a / x86_64。若不限制，Flutter 会打出
        // 含 32 位 ABI 的 APK，装上后 libffmpegkit.so 缺失会直接崩。
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
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

dependencies {
    // 移动端转码引擎。官方 com.arthenica:ffmpeg-kit-* 已于 2025-04 从 Maven Central
    // 移除，改用社区维护的等价构建（同包名、同 API，LGPL、含 libmp3lame）。
    // full = 音频 + 视频 + https 编码器全集；用 audio 变体会缺 mp4 muxer 依赖的
    // 部分库，且本项目还要跑 ts/m4s -> mp4 的流拷贝。
    // 固定版本，不要用动态版本号。
    implementation("dev.ffmpegkit-maintained:ffmpeg-kit-full:8.1.9")
}
