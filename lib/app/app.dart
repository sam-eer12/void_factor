import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../theme/monolith_theme.dart';
import 'routes.dart';
import '../features/auth/link_verification_service.dart';
import '../features/health/health_providers.dart';

class MonolithApp extends ConsumerStatefulWidget {
  const MonolithApp({super.key});

  @override
  ConsumerState<MonolithApp> createState() => _MonolithAppState();
}

class _MonolithAppState extends ConsumerState<MonolithApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(linkVerificationServiceProvider).init(_navigatorKey);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-read health metrics whenever the app returns to the foreground.
    if (state == AppLifecycleState.resumed) {
      ref.read(healthMetricsProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      child: MaterialApp(
        title: 'void_factor',
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        theme: MonolithTheme.themeData,
        initialRoute: AppRoutes.authGate,
        routes: AppRoutes.routes,
        builder: (context, child) {
          return Listener(
            onPointerDown: (event) {
              final focus = FocusManager.instance.primaryFocus;
              if (focus != null && focus.context != null) {
                final RenderBox? renderBox =
                    focus.context!.findRenderObject() as RenderBox?;
                if (renderBox != null) {
                  final position = renderBox.localToGlobal(Offset.zero);
                  final size = renderBox.size;
                  final rect = position & size;
                  if (!rect.contains(event.position)) {
                    focus.unfocus();
                  }
                }
              }
            },
            child: child,
          );
        },
      ),
    );
  }
}
