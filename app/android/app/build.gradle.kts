import java.io.File
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---- Release 签名 ----
// 优先级：环境变量（CI）> app/android/key.properties（本机，不提交）> debug 签名（带警告）。
//   key.properties：storeFile / storePassword / keyAlias / keyPassword，storeFile 可写绝对路径
//                  或相对 app/android/ 的路径。keystore 放在仓库外。
//   CI：LEKIS_KEYSTORE_BASE64（keystore 的 base64）/ LEKIS_KEYSTORE_PASSWORD /
//       LEKIS_KEY_ALIAS / LEKIS_KEY_PASSWORD。
data class ReleaseSigning(
    val storeFile: File,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
    val source: String,
)

fun loadReleaseSigning(): ReleaseSigning? {
    val envKeystore = System.getenv("LEKIS_KEYSTORE_BASE64")?.trim().orEmpty()
    if (envKeystore.isNotEmpty()) {
        val storePassword = System.getenv("LEKIS_KEYSTORE_PASSWORD").orEmpty()
        val alias = System.getenv("LEKIS_KEY_ALIAS").orEmpty()
        val keyPassword = System.getenv("LEKIS_KEY_PASSWORD")?.takeIf { it.isNotEmpty() } ?: storePassword
        if (storePassword.isEmpty() || alias.isEmpty()) {
            logger.warn("w: LEKIS_KEYSTORE_BASE64 is set but LEKIS_KEYSTORE_PASSWORD / LEKIS_KEY_ALIAS are missing; ignoring it.")
        } else {
            val out = layout.buildDirectory.file("signing/release.jks").get().asFile
            out.parentFile.mkdirs()
            // GitHub secrets 里粘的 base64 可能带换行，MIME 解码器会忽略它们。
            out.writeBytes(Base64.getMimeDecoder().decode(envKeystore))
            return ReleaseSigning(out, storePassword, alias, keyPassword, "environment (LEKIS_KEYSTORE_BASE64)")
        }
    }

    val propsFile = rootProject.file("key.properties")
    if (propsFile.isFile) {
        val props = Properties().apply { propsFile.inputStream().use { load(it) } }
        val storeFilePath = props.getProperty("storeFile")?.trim().orEmpty()
        val storePassword = props.getProperty("storePassword").orEmpty()
        val alias = props.getProperty("keyAlias")?.trim().orEmpty()
        val keyPassword = props.getProperty("keyPassword")?.takeIf { it.isNotEmpty() } ?: storePassword
        val storeFile = if (storeFilePath.isEmpty()) null else rootProject.file(storeFilePath)
        when {
            storeFile == null || storePassword.isEmpty() || alias.isEmpty() ->
                logger.warn("w: key.properties is incomplete (need storeFile, storePassword, keyAlias, keyPassword); ignoring it.")
            !storeFile.isFile ->
                logger.warn("w: key.properties points to a keystore that does not exist: ${storeFile.path}; ignoring it.")
            else -> return ReleaseSigning(storeFile, storePassword, alias, keyPassword, "key.properties")
        }
    }
    return null
}

val releaseSigning = loadReleaseSigning()

android {
    namespace = "dev.lekis.lekis"
    // permission_handler_android 要求调用方 compileSdk >= 37；Flutter 默认的 36 会
    // 让构建直接失败。targetSdk 仍是 36（运行行为），只是编译时用新 SDK。
    compileSdk = 37
    // 和 Flutter 默认值（以及 jni 插件用的 flutter.ndkVersion）保持一致，
    // 否则同一个工程会用两个 NDK，体积和构建时间都翻倍。
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    dependenciesInfo {
        // Omit Google's encrypted DependencyInfoBlock for F-Droid / FOSS reproducible builds.
        includeInApk = false
        includeInBundle = false
    }

    signingConfigs {
        releaseSigning?.let { rs ->
            create("release") {
                storeFile = rs.storeFile
                storePassword = rs.storePassword
                keyAlias = rs.keyAlias
                keyPassword = rs.keyPassword
            }
        }
    }

    defaultConfig {
        applicationId = "dev.lekis.music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (releaseSigning != null) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // 没有 release keystore 时退回 debug 签名，保证 `flutter run --release` 能用；
                // 这样的 APK 不能用来发布（和正式包签名不同，用户无法覆盖升级）。
                signingConfig = signingConfigs.getByName("debug")
            }
            // Rust 用 JNI 按类名调用 CredentialCipher，必须保住类名和 native 方法。
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    testImplementation("junit:junit:4.13.2")
}

val signingSource = releaseSigning?.source
if (signingSource != null) {
    logger.lifecycle("Lekis: release builds are signed with the release key from $signingSource.")
} else {
    gradle.taskGraph.whenReady {
        if (allTasks.any { it.project == project && it.name.contains("Release") }) {
            logger.warn(
                "w: Lekis: no release keystore found (app/android/key.properties or LEKIS_KEYSTORE_BASE64). " +
                    "Release build is signed with the DEBUG key; do not publish it.",
            )
        }
    }
}
