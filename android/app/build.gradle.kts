import java.util.Properties

// Release signing credentials, kept out of the repository. Absent on a fresh
// clone and in CI, which is why the release build below falls back to debug
// signing rather than failing: an unsigned-for-store build is still a build
// worth being able to produce.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

// A store upload is always an app bundle. Read from the requested tasks rather
// than a flag, because `flutter build appbundle` is what runs `bundleRelease`
// and nothing else passes a property that says so.
val isBundleBuild = gradle.startParameter.taskNames.any {
    it.contains("bundle", ignoreCase = true)
}
extra["isBundleBuild"] = isBundleBuild

// ── flutter_gemma's native libraries ────────────────────────────────────────
//
// The plugin ships every backend it supports. This app only ever runs a
// `.litertlm` model through LiteRT-LM over Dart FFI, on the GPU with a CPU
// fallback, so most of what it bundles is never loaded:
//
// * MediaPipe's LLM JNI is the `.task` path.
// * The vision and image-generator libraries are image generation.
// * qdrant is the RAG vector store, opened only by its own API.
// * The Qualcomm dispatch and QNN libraries are the NPU backend, which needs a
//   model compiled for one specific SoC. The generic model this app downloads
//   cannot run on it, and the plugin looks for them in the base APK only.
//
// Together that is ~136 MB of the 216.6 MB arm64 download.
val unusedGemmaLibs = listOf(
    "libllm_inference_engine_jni.so",
    "libmediapipe_tasks_vision_jni.so",
    "libmediapipe_tasks_vision_image_generator_jni.so",
    "libimagegenerator_gpu.so",
    "libqdrant_edge_ffi.so",
    "libLiteRtDispatch_Qualcomm.so",
    "libQnnHtp.so",
    "libQnnSystem.so",
    "libQnnHtpV73Stub.so",
    "libQnnHtpV73Skel.so",
    "libQnnHtpV75Stub.so",
    "libQnnHtpV75Skel.so",
    "libQnnHtpV79Stub.so",
    "libQnnHtpV79Skel.so",
    "libQnnHtpV81Stub.so",
    "libQnnHtpV81Skel.so",
)

// What inference actually loads, in the order it has to be loaded when the
// libraries come from an on-demand split rather than the base APK. Each one's
// DT_NEEDED entries are satisfied by those before it: LiteRtLm needs the
// constraint provider, and the two samplers need LiteRtLm. The accelerators are
// dlopen'ed by name at engine creation, which only finds them if they are
// already loaded.
//
// Shared with :gemma_engine, which packages exactly these, and with the
// Kotlin loader through BuildConfig, so the three lists cannot drift.
val gemmaEngineLibs = listOf(
    "libGemmaModelConstraintProvider.so",
    "libLiteRtLm.so",
    "libLiteRtGpuAccelerator.so",
    "libLiteRtOpenClAccelerator.so",
    "libLiteRtWebGpuAccelerator.so",
    "libLiteRtTopKOpenClSampler.so",
    "libLiteRtTopKWebGpuSampler.so",
)
extra["gemmaEngineLibs"] = gemmaEngineLibs

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.voidfactor.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications, which uses java.time to
        // schedule the daily reminder. Without it the release build fails at
        // :app:checkReleaseAarMetadata.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    buildFeatures {
        buildConfig = true
    }

    defaultConfig {
        applicationId = "com.voidfactor.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 26) // Health Connect requires API 26+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        buildConfigField(
            "String",
            "GEMMA_ENGINE_LIBS",
            "\"${gemmaEngineLibs.joinToString(",")}\"",
        )

        // arm64 only. Every phone that can run the on-device model is arm64 —
        // LiteRT-LM ships no other Android ABI — and Play serves each device
        // only its own ABI from the bundle anyway. This replaces the three ABIs
        // the Flutter plugin configures, so 32-bit and x86_64 devices can no
        // longer install the app.
        //
        // Skipped under --split-per-abi, where AGP refuses abiFilters alongside
        // ABI splits; the splits block below narrows those instead.
        if (!project.hasProperty("split-per-abi")) {
            ndk {
                abiFilters.clear()
                abiFilters += "arm64-v8a"
            }
        }
    }

    if (project.hasProperty("split-per-abi")) {
        splits {
            abi {
                reset()
                include("arm64-v8a")
            }
        }
    }

    // The inference engine, delivered on demand. See android/gemma_engine.
    dynamicFeatures += setOf(":gemma_engine")

    packaging {
        jniLibs {
            excludes += unusedGemmaLibs.map { "**/$it" }
            // In a bundle the engine lives only in :gemma_engine, which Play
            // installs when the user downloads the model. An APK has no split to
            // install from — `flutter run`, `flutter build apk`, a sideload — so
            // there it stays in the base, where the plugin finds it on its own.
            if (isBundleBuild) {
                excludes += gemmaEngineLibs.map { "**/$it" }
            }
        }
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            // R8 runs regardless of isMinifyEnabled — the Flutter Gradle plugin
            // turns it on for release. Naming the rules file explicitly is what
            // makes that survivable; without it the build fails in R8 on
            // MediaPipe classes that flutter_gemma does not ship.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )

            // The real key when key.properties is present, debug otherwise.
            // Falling back rather than failing keeps `flutter build apk
            // --release` working for anyone who just cloned the repo; the
            // fallback cannot reach the Play Store, which is the point.
            signingConfig = if (keystoreProperties.isEmpty) {
                signingConfigs.getByName("debug")
            } else {
                signingConfigs.getByName("release")
            }
        }
    }
}

// A bundle is a store upload, and Play rejects one signed with the debug key —
// but only after the upload, which is a slow way to find out. Said here
// instead, without failing: a debug-signed bundle is still what bundletool's
// local testing needs.
if (isBundleBuild) {
    val missing = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .filter { (keystoreProperties[it] as String?).isNullOrBlank() }
    if (missing.isNotEmpty()) {
        // println rather than logger.warn: Flutter runs Gradle with -q, which
        // hides warnings but not a build script's own output.
        println(
            "WARNING: Release bundle is DEBUG-SIGNED — Play will reject it. " +
                "android/key.properties is missing: ${missing.joinToString()}. " +
                "See android/key.properties.example.",
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backports the java.time API to the minSdk, which is what
    // isCoreLibraryDesugaringEnabled above needs to do its job.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // Installs :gemma_engine on demand and makes its libraries loadable in the
    // running process. See GemmaEngineDelivery.kt.
    implementation("com.google.android.play:feature-delivery:2.1.0")
}
