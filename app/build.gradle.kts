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
        versionCode = 10
        versionName = "0.8.2"
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
            isMinifyEnabled = false
            if (hasPermanentSigning) signingConfig = signingConfigs.getByName("tvoicePermanent")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    testImplementation("junit:junit:4.13.2")
}
