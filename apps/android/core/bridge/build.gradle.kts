plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android {
    namespace = "dev.lekis.core.bridge"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
        ndk {
            // 和 tools/build-android-core.sh 编译的 ABI 保持一致
            abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { buildConfig = true }   // RustCoreBridge 用 BuildConfig.DEBUG 决定核心日志级别
    // 生成的绑定代码在 src/main/kotlin/uniffi/（tools/gen-bindings.sh），.so 在 src/main/jniLibs/（tools/build-android-core.sh）
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    // UniFFI 的 Kotlin 绑定通过 JNA 加载 .so；Android 上必须用 aar 版本
    implementation("${libs.jna.get().module}:${libs.versions.jna.get()}@aar")
    testImplementation(libs.junit)
}
