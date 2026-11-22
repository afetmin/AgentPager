plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

val communityBuild = providers.gradleProperty("agentpagerCommunity")
    .map { it.toBooleanStrict() }
    .orElse(false)
    .get()
val agentPagerAppId = if (communityBuild) "io.github.ealin1994.agentpager" else "com.agentgrid.mobile"

android {
    namespace = "com.agentgrid.mobile"
    compileSdk = 36

    defaultConfig {
        applicationId = agentPagerAppId
        manifestPlaceholders["agentPagerAppLabel"] = if (communityBuild) "@string/app_name_community" else "@string/app_name"
        manifestPlaceholders["agentPagerTargetPackage"] = agentPagerAppId
        minSdk = 26
        targetSdk = 36
        versionCode = providers.environmentVariable("AGENTPAGER_VERSION_CODE")
            .orNull
            ?.toIntOrNull()
            ?: 7
        versionName = providers.environmentVariable("AGENTPAGER_VERSION_NAME")
            .orNull
            ?: "0.4.3-rc.1"

        testInstrumentationRunner = "com.agentgrid.mobile.DedicatedModeRegressionTest"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    sourceSets {
        getByName("main").resources.srcDir(
            rootProject.projectDir.parentFile.resolve("LICENSES"),
        )
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)

    implementation(libs.kotlinx.serialization.json)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.okhttp)

    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.zxing.core)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
