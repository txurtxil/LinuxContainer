plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.linux_container"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.linux_container"
        // MediaPipe LLM Inference requiere minSdk >= 24. maxOf evita bajarlo
        // si Flutter ya pide uno mayor.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    
    aaptOptions {
        noCompress += listOf("gz", "tar", "task")
    }
buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            // R8 necesita reglas extra para las clases internas de MediaPipe.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Inferencia LLM on-device en GPU/CPU (motor de la Fase C, como Edge Gallery).
    implementation("com.google.mediapipe:tasks-genai:0.10.27")
    // Servidor HTTP local (OpenAI-compatible) — ligero y compatible con Android.
    implementation("org.nanohttpd:nanohttpd:2.3.1")
}

flutter {
    source = "../.."
}
