plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.mactv.receiver"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.mactv.receiver"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "0.1"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Sideload convenience: sign release with the debug key so `adb install` just works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Deliberately empty: plain Android framework APIs only (MediaCodec, SurfaceView, NsdManager),
    // so there is no library resolution to fail on when building for an older TV.
}
