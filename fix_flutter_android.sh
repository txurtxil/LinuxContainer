#!/bin/bash
set -e

echo "Fix Flutter Android full stack"

# 1. settings.gradle (CRÍTICO: incluye flutter plugin loader correctamente)
cat > android/settings.gradle << 'EOF2'
pluginManagement {
    def flutterSdkPath = {
        def properties = new Properties()
        file("local.properties").withInputStream { properties.load(it) }
        def flutterSdkPath = properties.getProperty("flutter.sdk")
        assert flutterSdkPath != null, "flutter.sdk not set in local.properties"
        return flutterSdkPath
    }()

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    plugins {
        id "dev.flutter.flutter-plugin-loader" version "1.0.0"
        id "com.android.application" version "8.6.1" apply false
        id "com.android.library" version "8.6.1" apply false
        id "org.jetbrains.kotlin.android" version "2.0.0" apply false
    }
}

include ":app"
EOF2


# 2. build.gradle (raíz limpio)
cat > android/build.gradle << 'EOF2'
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = "../build"

subprojects {
    project.buildDir = "${rootProject.buildDir}/${project.name}"
    project.evaluationDependsOn(":app")
}

tasks.register("clean", Delete) {
    delete rootProject.buildDir
}
EOF2


# 3. app/build.gradle (Flutter moderno correcto)
cat > android/app/build.gradle << 'EOF2'
plugins {
    id "com.android.application"
    id "org.jetbrains.kotlin.android"
    id "dev.flutter.flutter-gradle-plugin"
}

android {
    namespace "com.example.linuxcontainer"
    compileSdk 34

    defaultConfig {
        applicationId "com.example.linuxcontainer"
        minSdk 21
        targetSdk 34
        versionCode 1
        versionName "1.0"
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

flutter {
    source "../.."
}
EOF2

echo "Flutter Android fixed"
