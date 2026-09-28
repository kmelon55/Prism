import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val releaseVersion = Properties().apply {
    rootProject.file("version.properties").inputStream().use { load(it) }
}
val signingNames = listOf("ANDROID_KEYSTORE_PATH", "ANDROID_KEYSTORE_PASSWORD", "ANDROID_KEY_ALIAS", "ANDROID_KEY_PASSWORD")
val signingValues = signingNames.associateWith { System.getenv(it).orEmpty() }
val hasReleaseSigning = signingValues.values.all { it.isNotBlank() }
require(signingValues.values.all { it.isBlank() } || hasReleaseSigning) {
    "Provide all four Android release signing variables, or none for debug builds."
}

android {
    namespace = "app.prism.launcher"
    compileSdk = 35
    defaultConfig {
        applicationId = "app.prism.launcher"
        minSdk = 28
        targetSdk = 35
        versionCode = releaseVersion.getProperty("versionCode").toInt()
        versionName = releaseVersion.getProperty("versionName")
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        if (hasReleaseSigning) create("release") {
            storeFile = file(signingValues.getValue("ANDROID_KEYSTORE_PATH"))
            storePassword = signingValues.getValue("ANDROID_KEYSTORE_PASSWORD")
            keyAlias = signingValues.getValue("ANDROID_KEY_ALIAS")
            keyPassword = signingValues.getValue("ANDROID_KEY_PASSWORD")
        }
    }
    buildTypes {
        getByName("release") {
            isDebuggable = false
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

// Never silently produce an unsigned release or substitute the debug certificate.
tasks.configureEach {
    if (name == "validateSigningRelease" || name == "packageRelease" || name == "packageReleaseBundle") {
        doFirst { check(hasReleaseSigning) { "Android release signing is required. See apps/android/distribution.md." } }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2025.05.01"))
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.0")
    implementation("androidx.core:core-ktx:1.16.0")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.05.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
