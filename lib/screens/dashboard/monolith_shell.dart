import 'package:flutter/material.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_bottom_nav.dart';
import 'dashboard_screen.dart';
import '../vision/ai_vision_screen.dart';
import '../stats/projections_screen.dart';
import '../settings/settings_screen.dart';

class MonolithShell extends StatefulWidget {
  final int initialIndex;

  const MonolithShell({
    super.key,
    this.initialIndex = 0,
  });

  static void setActiveTab(BuildContext context, int index, String fallbackRoute) {
    final state = context.findAncestorStateOfType<MonolithShellState>();
    if (state != null) {
      state.setIndex(index);
    } else {
      Navigator.pushReplacementNamed(context, fallbackRoute);
    }
  }

  @override
  State<MonolithShell> createState() => MonolithShellState();
}

class MonolithShellState extends State<MonolithShell> {
  late int _currentIndex;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void didUpdateWidget(MonolithShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialIndex != oldWidget.initialIndex &&
        widget.initialIndex != _currentIndex) {
      setIndex(widget.initialIndex);
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void setIndex(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _currentIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      body: PageView(
        controller: _pageController,
        physics: const NeverScrollableScrollPhysics(),
        children: const [
          DashboardScreen(),
          AiVisionScreen(),
          ProjectionsScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: MonolithBottomNav(
        currentIndex: _currentIndex,
        onTap: setIndex,
      ),
    );
  }
}
