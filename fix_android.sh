#!/bin/bash
set -e

echo "[ANDROID FIX] rewriting settings.gradle"

cat > android/settings.gradle << 'EOL'
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id "dev.flutter.flutter-plugin-loader" version "1.0.0"
}

include ":app"
EOL

echo "[ANDROID FIX] rewriting top build.gradle"

cat > android/build.gradle << 'EOL'
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.buildDir = "../build"

subprojects {
    project.buildDir = "${rootProject.buildDir}/${project.name}"
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register("clean", Delete) {
    delete rootProject.buildDir
}
EOL

echo "[ANDROID FIX] forcing gradle wrapper compatibility"

sed -i 's/gradle-.*/gradle-8.7-bin.zip/' android/gradle/wrapper/gradle-wrapper.properties || true

