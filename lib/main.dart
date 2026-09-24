import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'app/app.dart';
import 'features/food_log/pending_scan.dart';
import 'features/health/health_background_service.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The theme's fonts ship in assets/google_fonts, so the network is never the
  // thing between launch and legible text. Off rather than merely unneeded: a
  // style that asks for a weight not bundled should fail in development, not
  // quietly download on a user's first launch.
  GoogleFonts.config.allowRuntimeFetching = false;
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Space Grotesk'],
      await rootBundle.loadString('assets/google_fonts/OFL.txt'),
    );
  });
  // Only what the first frame needs, and side by side: neither waits on the
  // other. Auth needs Firebase before AuthGate can decide anything, and the
  // glass shaders have to be on disk before a glass surface paints or it
  // flashes white.
  await Future.wait([
    Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform),
    LiquidGlassWidgets.initialize(),
  ]);
  runApp(
    const ProviderScope(
      child: MonolithApp(),
    ),
  );
  // Nothing on screen depends on these, so they wait for the first frame
  // instead of holding it back.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    // The background health refresh is only scheduled when the user turns
    // health sync on, and scheduling waits for this itself — and retries it,
    // so a failure here has nowhere useful to go.
    initHealthBackground().ignore();
    // Photos a crash or a kill left behind, from before scans were kept in
    // their own directory. The live scan is never in this path.
    PendingScanStore.sweepStrayTempImages();
  });
}
