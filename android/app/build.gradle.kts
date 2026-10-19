plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingStoreFile = System.getenv("TVOICE_SIGNING_STORE_FILE")
val signingStorePassword = System.getenv("TVOICE_SIGNING_STORE_PASSWORD")
val signingKeyAlias = System.getenv("TVOICE_SIGNING_KEY_ALIAS")
val signingKeyPassword = System.getenv("TVOICE_SIGNING_KEY_PASSWORD")
val hasPermanentSigning = listOf(
    signingStoreFile,
    signingStorePassword,
    signingKeyAlias,
    signingKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "tj.tvoice.app"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "tj.tvoice.app"
        minSdk = 24
        // Google Play requires API 36 for new apps and updates from 31 August 2026.
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasPermanentSigning) {
            create("tvoicePermanent") {
                storeFile = file(checkNotNull(signingStoreFile))
                storePassword = signingStorePassword
                keyAlias = signingKeyAlias
                keyPassword = signingKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (!hasPermanentSigning) {
                throw GradleException(
                    "Release signing is not configured. Set the four TVOICE_SIGNING_* environment variables.",
                )
            }
            signingConfig = signingConfigs.getByName("tvoicePermanent")
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
    implementation("androidx.core:core-ktx:1.15.0")
}
