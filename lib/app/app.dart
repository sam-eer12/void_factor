import 'package:flutter/material.dart';
import '../theme/monolith_theme.dart';
import 'routes.dart';

class MonolithApp extends StatelessWidget {
  const MonolithApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MONOLITH',
      debugShowCheckedModeBanner: false,
      theme: MonolithTheme.themeData,
      initialRoute: AppRoutes.login,
      routes: AppRoutes.routes,
    );
  }
}
