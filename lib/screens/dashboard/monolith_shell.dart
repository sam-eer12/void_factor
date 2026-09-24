import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/food_log/food_analysis_client.dart';
import '../../features/food_log/food_log_providers.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_bottom_nav.dart';
import '../food_log/food_log_actions.dart';
import 'dashboard_screen.dart';
import '../vision/ai_vision_screen.dart';
import '../stats/projections_screen.dart';
import '../settings/settings_screen.dart';

class MonolithShell extends ConsumerStatefulWidget {
  final int initialIndex;

  const MonolithShell({
    super.key,
    this.initialIndex = 0,
  });

  /// The vision tab, where a scan is started and where it resumes.
  static const int visionTab = 1;

  static void setActiveTab(BuildContext context, int index, String fallbackRoute) {
    final state = context.findAncestorStateOfType<MonolithShellState>();
    if (state != null) {
      state.setIndex(index);
    } else {
      Navigator.restorablePushReplacementNamed(context, fallbackRoute);
    }
  }

  @override
  ConsumerState<MonolithShell> createState() => MonolithShellState();
}

class MonolithShellState extends ConsumerState<MonolithShell>
    with RestorationMixin {
  // Restorable so a relaunch after the app was killed opens on the tab the
  // user left, not on the dashboard.
  late final RestorableInt _index = RestorableInt(widget.initialIndex);
  PageController? _pageController;

  int get _currentIndex => _index.value;

  @override
  String? get restorationId => 'monolith_shell';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_index, 'tab');
    final controller = _pageController;
    if (controller == null) {
      _pageController = PageController(initialPage: _index.value);
    } else if (controller.hasClients) {
      controller.jumpToPage(_index.value);
    }
  }

  @override
  void initState() {
    super.initState();
    // After the first frame: the shell only exists once AuthGate has settled
    // the session, which is exactly when a scan can be sent again.
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeScan());
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
    _pageController?.dispose();
    _index.dispose();
    super.dispose();
  }

  void setIndex(int index) {
    if (index == _currentIndex) return;
    setState(() {
      _index.value = index;
    });
    _pageController?.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  /// Finishes a scan an earlier process left unfinished.
  ///
  /// The app can be killed with the camera in front of it, or while the photo
  /// is uploading and the user is elsewhere. Either way the photo was kept, and
  /// here the scan picks up where it stopped: back on the vision tab with the
  /// same spinner, then the same form, as if nothing had happened between.
  Future<void> _resumeScan() async {
    final vision = ref.read(visionAnalysisProvider.notifier);
    if (!await vision.hasPendingScan() || !mounted) return;

    setIndex(MonolithShell.visionTab);
    // Resolved now, for the reason AiVisionScreen resolves it before a scan:
    // the root navigator outlives anything that rebuilds under it meanwhile.
    final navigator = Navigator.of(context, rootNavigator: true);
    final FoodAnalysis? draft;
    try {
      draft = await vision.resumePending();
    } catch (_) {
      // Already in the controller's error state, which the vision tab shows.
      return;
    }
    if (draft == null || !navigator.mounted) return;
    openScanResult(navigator, draft);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MonolithTheme.background,
      extendBody: true,
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
