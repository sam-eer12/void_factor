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
      ),
    );
  }
}
