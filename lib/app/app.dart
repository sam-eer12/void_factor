import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../theme/monolith_theme.dart';
import 'routes.dart';

class MonolithApp extends StatelessWidget {
  const MonolithApp({super.key});

  @override
  Widget build(BuildContext context) {
    return LiquidGlassWidgets.wrap(
      adaptiveQuality: true,
      child: MaterialApp(
        title: 'void_factor',
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
