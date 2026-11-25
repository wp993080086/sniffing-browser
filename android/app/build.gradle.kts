plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.wp.sniffingbrowser"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.wp.sniffingbrowser"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ffmpeg-kit AAR 只发布 arm64-v8a / x86_64。32 位包里没有 libffmpegkit.so，
    // 装上能启动、一用转码就崩 —— 比装不上更糟，用户会以为是代码 bug。
    // 这里直接剔掉 32 位目录，让 32 位设备在安装阶段就报 NO_MATCHING_ABIS。
    //
    // 不要改回 defaultConfig.ndk.abiFilters：`flutter build apk` 会把
    // -Ptarget-platform 透传给 Gradle 并覆盖它，那样的配置实际不生效（本文件
    // 曾经就这么写着，直到打了 118MB 的包才发现 armeabi-v7a 还在里面）。
    packaging {
        jniLibs {
            excludes += setOf("lib/armeabi-v7a/**", "lib/x86/**")
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
