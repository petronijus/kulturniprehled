plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing uses the Google Play upload key. `just build-aab` reads it
// from 1Password (`Kulturni Prehled Android upload key`) into a temporary
// directory for the duration of one build and passes it in through the
// environment; it never lives in the repo or in a properties file. Play App
// Signing re-signs the bundle with the app signing key Google holds.
val uploadKeystore: String? = System.getenv("KP_UPLOAD_KEYSTORE")

android {
    namespace = "com.kulturniprehled.kp_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Core library desugaring lets flutter_local_notifications use the
        // java.time / java.util.concurrent APIs on older Android (< API 26).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.kulturniprehled.kp_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (uploadKeystore != null) {
            create("upload") {
                storeFile = file(uploadKeystore)
                storePassword = System.getenv("KP_UPLOAD_STORE_PASSWORD")
                keyAlias = System.getenv("KP_UPLOAD_KEY_ALIAS")
                keyPassword = System.getenv("KP_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Without the upload key, local release builds (`flutter run
            // --release`) fall back to the debug key; bundleRelease refuses.
            signingConfig = signingConfigs.getByName(if (uploadKeystore != null) "upload" else "debug")
            // Disable R8 minification / resource shrinking. The
            // flutter_local_notifications plugin's Gson TypeToken stops
            // working when generic signatures are stripped, and even with
            // the keep-rules in proguard-rules.pro we couldn't get the
            // plugin's internal serialization to round-trip cleanly.
            // We accept the ~5 MB APK size penalty for now; revisit if we
            // need to squeeze the size for Play Store / TestFlight.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

// A bundle for Play must be signed with the upload key, never the debug key.
tasks.configureEach {
    if (name == "bundleRelease" && uploadKeystore == null) {
        doFirst {
            throw GradleException("bundleRelease needs the Play upload key: run `just build-aab`.")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
