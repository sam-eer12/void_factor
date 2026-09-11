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
