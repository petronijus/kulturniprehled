import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing pulls from `android/key.properties` when present (the
// release workflow writes one before invoking gradle, and a developer can
// drop one in locally). When the file is missing we silently fall back to
// the debug key so `flutter run` and contributors without the release
// keystore aren't blocked.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

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

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.kulturniprehled.kp_mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Debug signing fallback keeps `flutter run --release` working
                // for devs without the release keystore on disk.
                signingConfigs.getByName("debug")
            }
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

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
