plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.asite.field_capture"
    compileSdk = flutter.compileSdkVersion

    // A literal rather than `flutter.ndkVersion`, and it must stay equal to
    // `packages/sphere_view/spikes/spike_a_opencv/config.sh`: the OpenCV static
    // libraries sphere_view links were built with this NDK, and mixing two NDK
    // versions in one link is a libc++ ABI mismatch. Flutter's own default
    // happens to be the same version today — pinning it here is what stops a
    // Flutter upgrade from moving it silently.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.asite.field_capture"
        // sphere_view's floor is API 24 (two Camera2 intrinsics keys it wants
        // are 28+ and are version-guarded down to it). Flutter's own default is
        // 24, so the delegation already satisfies it and is left in place —
        // pinning 24 here would only serve to *lower* the floor if Flutter
        // later raises its default.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
