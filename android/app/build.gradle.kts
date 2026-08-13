plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val signingStoreFile = System.getenv("TVOICE_SIGNING_STORE_FILE")
val signingStorePassword = System.getenv("TVOICE_SIGNING_STORE_PASSWORD")
val signingKeyAlias = System.getenv("TVOICE_SIGNING_KEY_ALIAS")
val signingKeyPassword = System.getenv("TVOICE_SIGNING_KEY_PASSWORD")
val hasPermanentSigning = listOf(
    signingStoreFile,
    signingStorePassword,
    signingKeyAlias,
    signingKeyPassword
).all { !it.isNullOrBlank() }

android {
    namespace = "tj.tvoice.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "tj.tvoice.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 25
        versionName = "0.17.3"
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
        debug {
            if (hasPermanentSigning) signingConfig = signingConfigs.getByName("tvoicePermanent")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            if (hasPermanentSigning) signingConfig = signingConfigs.getByName("tvoicePermanent")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        buildConfig = true
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    packaging {
        resources.excludes += setOf("META-INF/AL2.0", "META-INF/LGPL2.1")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("io.livekit:livekit-android:2.27.0")
    testImplementation("junit:junit:4.13.2")
}

// This module is Kotlin-only. Avoid invoking javac with an empty source set:
// on Windows, antivirus file hooks can keep large Android/WebRTC classpath
// archives open while javac closes them and fail an otherwise valid build.
tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
    onlyIf { !source.isEmpty }
}
