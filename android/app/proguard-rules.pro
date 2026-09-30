# R8 runs on every Flutter release build — the Flutter Gradle plugin enables it
# whether or not this module sets isMinifyEnabled. These rules are what make
# `flutter build apk --release` complete.

# ── flutter_gemma / MediaPipe ────────────────────────────────────────────────
# MediaPipe references generated protobuf classes that are not on the compile
# classpath, and R8 treats a missing class as a hard error. Suppressed rather
# than kept: nothing reachable calls them, and the alternative is a build that
# fails on a dependency's packaging decision.
-dontwarn com.google.mediapipe.proto.CalculatorProfileProto$CalculatorProfile
-dontwarn com.google.mediapipe.proto.GraphTemplateProto$CalculatorGraphTemplate
-dontwarn com.google.auto.value.extension.memoized.Memoized

# The inference classes themselves are loaded by name through JNI, which R8
# cannot see.
-keep class com.google.mediapipe.** { *; }
-keep class org.tensorflow.** { *; }

# ── flutter_local_notifications ──────────────────────────────────────────────
# Pending notifications are serialised with GSON and rebuilt after a reboot.
# Stripping these loses every scheduled reminder, silently and only on release
# builds.
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.TypeAdapter

# background_downloader can include a URL in native connection exceptions.
# Remove native logging from release APKs so signed capabilities and provider
# credentials cannot enter logcat through this or another native dependency.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}
