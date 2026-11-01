import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release 签名放在 android/key.properties（已加入 .gitignore）。
// 没有这份文件时回落到 debug 签名，保证 `flutter run --release` 仍可用。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasReleaseKeystore = keystorePropertiesFile.exists() &&
    keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "app.alighieri.alighieri"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.alighieri.alighieri"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKeystore) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
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

// ---------------------------------------------------------------------------
// Rust 核心（alighieri_core）
// ---------------------------------------------------------------------------
// 每个 ABI 编一个 .so，直接放进 jniLibs —— Flutter 侧通过 ffi 加载
// `libalighieri_core.so`，不需要额外的 JNI 胶水代码。
//
// 前置条件（只需一次）：
//   rustup target add aarch64-linux-android armv7-linux-androideabi \
//                     x86_64-linux-android i686-linux-android
//
// 若本机没装 cargo 或某个 target，任务会直接失败（而不是悄悄打出缺 .so 的包）。
val rustDir = rootProject.file("../rust").absolutePath

// 从 local.properties / 环境变量定位 NDK，把 clang 包装脚本放进 PATH，
// 这样 cargo 里的 linker 配置（rust/.cargo/config.toml）才能解析。
val androidSdkDir: File? =
    run {
        val properties = Properties()
        val localProperties = rootProject.file("local.properties")
        if (localProperties.exists()) {
            localProperties.inputStream().use { properties.load(it) }
        }
        val path =
            properties.getProperty("sdk.dir")
                ?: System.getenv("ANDROID_HOME")
                ?: System.getenv("ANDROID_SDK_ROOT")
        path?.let { file(it) }
    }
val androidNdkDir: File? = androidSdkDir?.resolve("ndk/${flutter.ndkVersion}")
val androidNdkBinDir: File? =
    androidNdkDir
        ?.resolve("toolchains/llvm/prebuilt")
        ?.listFiles()
        ?.firstOrNull { it.isDirectory }
        ?.resolve("bin")

val abiTargets =
    mapOf(
        "arm64-v8a" to "aarch64-linux-android",
        "armeabi-v7a" to "armv7-linux-androideabi",
        "x86_64" to "x86_64-linux-android",
    )

// Windows 的 NDK 把 clang 包装器写成 `.cmd`（无后缀的那份是 Unix shell 脚本），
// 直接传给 cargo 会得到 “不是有效的 Win32 应用程序”。Linux 下则保持无后缀。
val isWindowsHost = System.getProperty("os.name").lowercase().contains("windows")
val clangSuffix = if (isWindowsHost) ".cmd" else ""

abiTargets.forEach { (abi, target) ->
    val taskName = "cargoBuild${abi.replace("-", "_").replaceFirstChar { it.uppercase() }}"
    tasks.register<Exec>(taskName) {
        workingDir(rustDir)
        commandLine("cargo", "build", "--release", "--target", target)
        if (androidNdkBinDir != null) {
            environment("ANDROID_NDK_HOME", androidNdkDir!!.absolutePath)
            environment("ANDROID_NDK_ROOT", androidNdkDir.absolutePath)
            environment(
                "PATH",
                androidNdkBinDir.absolutePath + File.pathSeparator + (System.getenv("PATH") ?: ""),
            )

            // NDK 里 armv7 的 clang 叫 armv7a-...，而 cc-rs 会自动猜成
            // arm-linux-androideabi-clang；显式指定，避免 ring 等 C 依赖找不到编译器。
            val clangName =
                when (target) {
                    "aarch64-linux-android" -> "aarch64-linux-android24-clang"
                    "armv7-linux-androideabi" -> "armv7a-linux-androideabi24-clang"
                    "x86_64-linux-android" -> "x86_64-linux-android24-clang"
                    else -> null
                }
            val clang = clangName?.let { androidNdkBinDir.resolve(it + clangSuffix) }
            if (clang != null && clang.exists()) {
                val targetEnv = target.replace('-', '_')
                environment("CC_$targetEnv", clang.absolutePath)
                environment(
                    "AR_$targetEnv",
                    androidNdkBinDir.resolve(if (isWindowsHost) "llvm-ar.exe" else "llvm-ar").absolutePath,
                )
                environment(
                    "CARGO_TARGET_${target.uppercase().replace('-', '_')}_LINKER",
                    clang.absolutePath,
                )
            }
        } else {
            logger.warn("找不到 NDK ${flutter.ndkVersion}：Rust 链接可能失败，请检查 sdk.dir / ANDROID_HOME。")
        }
        doLast {
            val so = file("$rustDir/target/$target/release/libalighieri_core.so")
            if (so.exists()) {
                val dest = file("src/main/jniLibs/$abi/libalighieri_core.so")
                dest.parentFile.mkdirs()
                so.copyTo(dest, overwrite = true)
            } else {
                logger.warn("跳过 $abi：没有 $so（cargo 或 target $target 未安装）")
            }
        }
    }
    tasks.named("preBuild") { dependsOn(taskName) }
}
