// The LiteRT-LM inference engine, as an on-demand Play Feature Delivery module.
//
// Nothing but native libraries: flutter_gemma's Native Assets build puts them
// into the app's jniLibs, the base module excludes them from bundles, and this
// module packages exactly those files instead. Play then installs it when the
// user downloads the on-device model, so a user who never does never downloads
// the engine either.
//
// The list of libraries is the one :app declares, so the base's exclusions,
// this module's contents and the Kotlin loader's order all come from one place.

import com.android.build.api.dsl.ApplicationExtension

plugins {
    id("com.android.dynamic-feature")
}

val app = project(":app")
val appAndroid = app.extensions.getByType(ApplicationExtension::class.java)

@Suppress("UNCHECKED_CAST")
val gemmaEngineLibs = app.extra["gemmaEngineLibs"] as List<String>
val isBundleBuild = app.extra["isBundleBuild"] as Boolean

android {
    namespace = "com.voidfactor.app.gemma_engine"
    compileSdk = appAndroid.compileSdk
    // Without it AGP cannot find llvm-strip for this module and packages the
    // libraries with their debug sections — 90 MB where stripped they are 52.
    ndkVersion = appAndroid.ndkVersion

    defaultConfig {
        minSdk = appAndroid.defaultConfig.minSdk
    }

    // Every build type the base has — the Flutter plugin adds `profile` — or AGP
    // cannot match this module's variants to the base's.
    buildTypes {
        create("profile") {
            initWith(getByName("debug"))
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":app"))
}

// Copies the engine out of the jniLibs the Flutter plugin assembles for :app.
//
// Taken from there rather than from flutter_gemma's cache so this module holds
// the very files the base was built against, and wired as a dependency of the
// merge so a clean build cannot package an empty directory.
//
// Bundles only. An APK build keeps the engine in the base, and a second copy
// here would collide with it when AGP merges native debug symbols.
val appFlutterJniLibs = app.layout.buildDirectory.dir("intermediates/flutter")
for (variant in if (isBundleBuild) listOf("debug", "profile", "release") else emptyList()) {
    val capitalized = variant.replaceFirstChar { it.uppercase() }
    val engineDir = layout.buildDirectory.dir("gemmaEngineJniLibs/$variant")

    val sync = tasks.register<Sync>("syncGemmaEngineLibs$capitalized") {
        // The Flutter plugin names it with a lowercase "flutterBuild".
        dependsOn(":app:copyJniLibsflutterBuild$capitalized")
        from(appFlutterJniLibs.map { it.dir("$variant/jniLibs") }) {
            include(gemmaEngineLibs.map { "*/$it" })
        }
        into(engineDir)
    }

    android.sourceSets.getByName(variant).jniLibs.srcDir(engineDir)
    tasks.matching { it.name == "merge${capitalized}JniLibFolders" }
        .configureEach { dependsOn(sync) }
}
