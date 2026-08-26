import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/routes.dart';
import '../../features/auth/auth_provider.dart';
import '../../features/projection/gemma_model_service.dart';
import '../../features/projection/projection_format.dart';
import '../../features/projection/projection_providers.dart';
import '../../features/weight_log/weight_log_providers.dart';
import '../../models/projection.dart';
import '../../models/recommendation.dart';
import '../../theme/monolith_theme.dart';
import '../../widgets/monolith_button.dart';
import '../../widgets/monolith_card.dart';
import '../../widgets/monolith_drawer.dart';
import '../../widgets/recommendation_row.dart';
import '../../widgets/weight_trajectory_chart.dart';
import '../dashboard/monolith_shell.dart';
import 'log_weight_sheet.dart';

/// The trajectory, the goal date, and what to do about them.
///
/// Reads two providers and nothing else: [projectionProvider] for every figure
/// above, [recommendationsProvider] for the three cards below. They are separate
/// on purpose — the projection is pure Dart that resolves immediately, while the
/// recommendations may spend half a minute in on-device inference, and one
/// provider for both would hold the chart hostage to the model.
class ProjectionsScreen extends ConsumerStatefulWidget {
  const ProjectionsScreen({super.key});

  static const String errorProjection = "COULDN'T BUILD YOUR PROJECTION";
  static const String errorRecommendations =
      "COULDN'T WORK OUT YOUR RECOMMENDATIONS.";

  /// Shown when the local write succeeded but the profile mirror did not. The
  /// measurement is safe, which is the part worth stating plainly — the mirror
  /// catches up on the next save.
  static const String warnUnsynced =
      "SAVED ON THIS DEVICE — COULDN'T UPDATE YOUR PROFILE WEIGHT YET";

  /// The section heading the mock established. Kept, because it is now literally
  /// what the section contains.
  static const String protocolsTitle = 'MANDATORY PROTOCOLS';

  static const String narratedOnDevice = 'WORDED ON THIS DEVICE BY GEMMA';
  static const String narratedByTemplate = 'BUILT-IN WORDING';

  @override
  ConsumerState<ProjectionsScreen> createState() => _ProjectionsScreenState();
}

class _ProjectionsScreenState extends ConsumerState<ProjectionsScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final projection = ref.watch(projectionProvider);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: MonolithTheme.background,
      drawer: MonolithDrawer(
        onProfileTap: () {
          Navigator.pop(context);
          MonolithShell.setActiveTab(context, 3, '/settings');
        },
        onDashboardTap: () {
          Navigator.pop(context);
          MonolithShell.setActiveTab(context, 0, '/dashboard');
        },
        onHistoryTap: () {
          Navigator.pop(context);
          Navigator.pushNamed(context, '/food-log');
        },
        onLogoutTap: () => performLogout(context, ref),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Header ──
                    Text('PROJECTIONS', style: MonolithTheme.displayLarge),
                    const SizedBox(height: 4),
                    Text(
                      'ANALYSIS REPORT & TRAJECTORY',
                      style: MonolithTheme.labelMedium.copyWith(
                        color: MonolithTheme.outline,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Trajectory, log button, goal date ──
                    //
                    // `hasValue` before `isLoading`: logging a weight
                    // recomputes the projection, and swapping a drawn chart for
                    // a spinner on every save would flash the screen at exactly
                    // the moment the user wants to see it move.
                    if (projection.hasValue)
                      ..._projectionSection(projection.requireValue)
                    else if (projection.hasError)
                      ..._projectionError()
                    else
                      ..._projectionLoading(),

                    const SizedBox(height: 16),

                    // ── On-device model offer ──
                    ..._modelGate(),

                    // ── Recommendations ──
                    _recommendationsCard(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: const BoxDecoration(
          color: MonolithTheme.surface,
          border: Border(
            bottom: BorderSide(
              color: MonolithTheme.primary,
              width: MonolithTheme.borderWidth,
            ),
          ),
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => _scaffoldKey.currentState?.openDrawer(),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: MonolithTheme.containerDecoration,
                child: const Icon(Icons.menu,
                    color: MonolithTheme.primary, size: 22),
              ),
            ),
            const SizedBox(width: 16),
            Text('MONOLITH', style: MonolithTheme.headlineLarge),
          ],
        ),
      );

  // ──────────────────────────────────────────────
  // Trajectory
  // ──────────────────────────────────────────────

  List<Widget> _projectionSection(Projection projection) => [
        _trajectoryCard(projection),
        const SizedBox(height: 16),
        _logWeightButton(seedKg: projection.currentWeightKg),
        const SizedBox(height: 16),
        _goalCard(projection),
      ];

  Widget _trajectoryCard(Projection projection) {
    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('WEIGHT TRAJECTORY',
                    style: MonolithTheme.headlineMedium),
              ),
              const SizedBox(width: 8),
              _statusChip(projection.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            // The mock's caption said only 'PROJECTION STATUS'. It now carries
            // where the status came from, because a measured slope and a
            // population energy model deserve different amounts of trust.
            'PROJECTION STATUS · ${projectionBasisLabel(projection)}',
            style: MonolithTheme.labelSmall.copyWith(
              color: MonolithTheme.outline,
            ),
          ),
          const SizedBox(height: 20),
          WeightTrajectoryChart(projection: projection),
          const SizedBox(height: 20),
          Container(
            height: MonolithTheme.borderWidth,
            color: MonolithTheme.primary,
          ),
          const SizedBox(height: 16),
          Row(
            // Top-aligned rather than centred, because a narrow phone wraps
            // 'RATE (KG/WK)' onto a second line and the three headline figures
            // have to stay on one line as each other.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _stat('NOW (KG)', _kgOrDash(projection.currentWeightKg)),
              ),
              _statDivider(),
              Expanded(
                child:
                    _stat('TARGET (KG)', _kgOrDash(projection.targetWeightKg)),
              ),
              _statDivider(),
              Expanded(
                child: _stat(
                  'RATE (KG/WK)',
                  // A rate with no basis behind it is not zero, it is unknown.
                  projection.basis == ProjectionBasis.none
                      ? '--'
                      : projectionRateLabel(projection.ratePerWeekKg),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The chip beside the trajectory heading.
  ///
  /// Three treatments, because the seven statuses are not equally urgent. Filled
  /// black is the resting state of this design system, so it carries the states
  /// where nothing is wrong. Outlined pulls back for the states that are waiting
  /// on the user rather than warning them. The one red is reserved for moving
  /// away from the target — the single case where the trend itself contradicts
  /// what the user asked for, and the only place on this screen worth spending
  /// the palette's one accent.
  Widget _statusChip(ProjectionStatus status) {
    final isAlarming = status == ProjectionStatus.wrongDirection;
    final isMuted = switch (status) {
      ProjectionStatus.behind ||
      ProjectionStatus.stalled ||
      ProjectionStatus.insufficientData =>
        true,
      _ => false,
    };

    final background = isAlarming
        ? MonolithTheme.error
        : isMuted
            ? MonolithTheme.surface
            : MonolithTheme.primary;
    final foreground =
        isMuted ? MonolithTheme.primary : MonolithTheme.surface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        border: Border.all(
          color: isAlarming ? MonolithTheme.error : MonolithTheme.primary,
          width: MonolithTheme.borderWidth,
        ),
      ),
      child: Text(
        projectionStatusLabel(status),
        style: MonolithTheme.labelSmall.copyWith(color: foreground),
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      children: [
        Text(value, style: MonolithTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          label,
          textAlign: TextAlign.center,
          style: MonolithTheme.labelSmall.copyWith(
            color: MonolithTheme.outline,
          ),
        ),
      ],
    );
  }

  Widget _statDivider() => Container(
        width: MonolithTheme.borderWidth,
        height: 40,
        color: MonolithTheme.primary,
      );

  /// Same convention as the settings screen: an unset metric is `--`, never `0`.
  String _kgOrDash(double kg) => kg > 0 ? projectionKgLabel(kg) : '--';

  /// A titled card of the same geometry as the real one, so nothing on the screen
  /// moves when the projection arrives.
  List<Widget> _projectionLoading() => [
        MonolithCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('WEIGHT TRAJECTORY', style: MonolithTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'READING YOUR LOGS',
                style: MonolithTheme.labelSmall.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                height: WeightTrajectoryChart.height,
                width: double.infinity,
                decoration: BoxDecoration(
                  border:
                      Border.all(color: MonolithTheme.primary, width: 1),
                ),
                child: const Center(
                  child: SizedBox(
                    height: 32,
                    width: 32,
                    child: CircularProgressIndicator.adaptive(
                      valueColor: AlwaysStoppedAnimation<Color>(
                        MonolithTheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ];

  /// Every source behind the projection is local — a file, secure storage, a
  /// cached profile — so a failure here is not something the user did. It gets a
  /// retry rather than an explanation of a `FileSystemException`.
  List<Widget> _projectionError() => [
        MonolithCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ProjectionsScreen.errorProjection,
                  style: MonolithTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Your profile or your logs could not be read just now. '
                'Nothing has been lost.',
                style: MonolithTheme.bodyMedium.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
              const SizedBox(height: 20),
              MonolithButton(
                label: 'TRY AGAIN',
                style: MonolithButtonStyle.secondary,
                onPressed: () => ref.invalidate(projectionProvider),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Still offered: a weigh-in is stored by a different path than the one
        // that just failed, and it is the thing most likely to fill an empty
        // projection in.
        _logWeightButton(seedKg: 0),
      ];

  Widget _goalCard(Projection projection) {
    final copy = projectionGoalCopy(projection);

    return MonolithCard(
      inverted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'GOAL REACHED IN:',
            style: MonolithTheme.labelMedium.copyWith(
              color: MonolithTheme.surfaceContainerHigh,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            copy.value,
            style: MonolithTheme.displayLarge.copyWith(
              color: MonolithTheme.surface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            copy.caption,
            style: MonolithTheme.labelSmall.copyWith(
              color: MonolithTheme.surfaceContainerHigh,
            ),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────
  // Logging a weight
  // ──────────────────────────────────────────────

  /// Secondary rather than filled: it sits between two heavy black elements, and
  /// a third would leave the section with no focal point at all.
  Widget _logWeightButton({required double seedKg}) => MonolithButton(
        label: 'LOG WEIGHT',
        style: MonolithButtonStyle.secondary,
        icon: Icons.monitor_weight,
        onPressed: () => _logWeight(seedKg),
      );

  Future<void> _logWeight(double seedKg) async {
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await LogWeightSheet.show(context, seedKg: seedKg);

    // A dismissed sheet and a clean save both need nothing said. The save
    // announces itself: the chart gains a point and the date above it moves.
    if (outcome != WeightSaveOutcome.savedWithoutSync) return;

    messenger.showSnackBar(
      const SnackBar(content: Text(ProjectionsScreen.warnUnsynced)),
    );
  }

  // ──────────────────────────────────────────────
  // On-device model
  // ──────────────────────────────────────────────

  /// The download offer, when there is one to make.
  ///
  /// A card the user can ignore, not a gate: the recommendations below are
  /// complete and correct without the model, and blocking them behind half a
  /// gigabyte would be charging for wording. Nothing is shown while the check is
  /// in flight, or if it fails — the recommendations card already states which
  /// voice wrote it, so silence here never leaves the user misinformed.
  List<Widget> _modelGate() {
    final model = ref.watch(gemmaModelProvider).value;
    if (model == null || model.isReady) return const [];

    return [
      MonolithCard(
        // Unshadowed and tighter, exactly as `_buildSettingsTile` renders a
        // subordinate surface: this is an offer about the section below it, not a
        // peer of the cards carrying the user's data.
        hasShadow: false,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.memory,
                    color: MonolithTheme.primary, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('ON-DEVICE WORDING',
                      style: MonolithTheme.labelLarge),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ..._modelGateBody(model),
          ],
        ),
      ),
      const SizedBox(height: 16),
    ];
  }

  /// A progress bar mid-download, an offer otherwise.
  List<Widget> _modelGateBody(GemmaModelState model) {
    void download() => ref.read(gemmaModelProvider.notifier).download();

    switch (model.stage) {
      case GemmaModelStage.downloading:
        return _downloadProgress(model.progress);
      case GemmaModelStage.needsToken:
        return _modelGateOffer(
          body: 'YOUR RECOMMENDATIONS CAN BE WORDED BY A MODEL RUNNING ON '
              'THIS PHONE. IT IS A GATED DOWNLOAD, SO IT NEEDS A HUGGINGFACE '
              'TOKEN ONCE.',
          action: 'ADD TOKEN',
          onPressed: () =>
              Navigator.pushNamed(context, AppRoutes.onDeviceModel),
        );
      case GemmaModelStage.notInstalled:
        return _modelGateOffer(
          body: 'DOWNLOAD THE ON-DEVICE MODEL (ABOUT HALF A GIGABYTE) TO HAVE '
              'YOUR RECOMMENDATIONS WORDED HERE. THE FIGURES ARE COMPUTED BY '
              'THE APP EITHER WAY.',
          action: 'DOWNLOAD MODEL',
          onPressed: download,
        );
      case GemmaModelStage.failed:
        return _modelGateOffer(
          // The service's own message names what failed — no token, no network,
          // no room on the device — and each has a different fix.
          body: model.message ?? GemmaModel.errorDownloadFailed,
          action: 'TRY AGAIN',
          onPressed: download,
        );
      case GemmaModelStage.ready:
        // Returned above. Listed rather than defaulted so a new stage is a
        // compile error instead of a blank card.
        return const [];
    }
  }

  List<Widget> _modelGateOffer({
    required String body,
    required String action,
    required VoidCallback onPressed,
  }) =>
      [
        Text(
          body,
          style: MonolithTheme.labelSmall.copyWith(
            color: MonolithTheme.outline,
          ),
        ),
        const SizedBox(height: 16),
        MonolithButton(
          label: action,
          style: MonolithButtonStyle.secondary,
          onPressed: onPressed,
        ),
      ];

  List<Widget> _downloadProgress(int progress) => [
        Text(
          'DOWNLOADING — $progress%',
          style: MonolithTheme.labelSmall.copyWith(
            color: MonolithTheme.outline,
          ),
        ),
        const SizedBox(height: 8),
        // A framed bar filled from the left, rather than a Material
        // LinearProgressIndicator: this system has no rounded ends and no
        // greys to fade between.
        Container(
          height: 16,
          decoration: MonolithTheme.containerDecoration,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (progress / 100).clamp(0.0, 1.0),
              child: Container(color: MonolithTheme.primary),
            ),
          ),
        ),
      ];

  // ──────────────────────────────────────────────
  // Recommendations
  // ──────────────────────────────────────────────

  Widget _recommendationsCard() {
    final recommendations = ref.watch(recommendationsProvider);
    final caption = _recommendationsCaption(recommendations);

    return MonolithCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ProjectionsScreen.protocolsTitle,
              style: MonolithTheme.headlineMedium),
          // The caption sits in the slot the trajectory card uses for its basis,
          // for the same reason. Trailing it after the last row instead would
          // put a line of small grey type directly under a line of small grey
          // type, and it would read as a fourth recommendation.
          if (caption != null) ...[
            const SizedBox(height: 8),
            Text(
              caption,
              style: MonolithTheme.labelSmall.copyWith(
                color: MonolithTheme.outline,
              ),
            ),
          ],
          const SizedBox(height: 20),
          // Same reasoning as the chart: downloading the model re-narrates cards
          // the user is already reading, and replacing correct copy with a
          // spinner to swap one voice for another is a worse screen than leaving
          // the copy up until the new words arrive.
          if (recommendations.hasValue)
            ..._recommendationRows(recommendations.requireValue)
          else if (recommendations.hasError)
            Text(
              ProjectionsScreen.errorRecommendations,
              style: MonolithTheme.bodyMedium.copyWith(
                color: MonolithTheme.outline,
              ),
            )
          else
            const Center(
              child: SizedBox(
                height: 32,
                width: 32,
                child: CircularProgressIndicator.adaptive(
                  valueColor:
                      AlwaysStoppedAnimation<Color>(MonolithTheme.primary),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Which voice wrote the rows below, or what is happening instead.
  ///
  /// Narration is all-or-nothing by construction — `GemmaNarrator` falls the
  /// whole list back to templates rather than mixing voices — so `every` is a
  /// claim the data can actually support.
  String? _recommendationsCaption(AsyncValue<List<Recommendation>> value) {
    if (value.hasValue) {
      final recommendations = value.requireValue;
      if (recommendations.isEmpty) return null;
      return recommendations.every((card) => card.narratedOnDevice)
          ? ProjectionsScreen.narratedOnDevice
          : ProjectionsScreen.narratedByTemplate;
    }
    // Nothing to say about the source of an error message.
    if (value.hasError) return null;
    return 'WORKING OUT WHAT MATTERS';
  }

  List<Widget> _recommendationRows(List<Recommendation> recommendations) {
    if (recommendations.isEmpty) {
      return [
        Text(
          'NOTHING TO REPORT YET.',
          style: MonolithTheme.bodyMedium.copyWith(
            color: MonolithTheme.outline,
          ),
        ),
      ];
    }

    final rows = <Widget>[];
    for (var i = 0; i < recommendations.length; i++) {
      if (i > 0) {
        rows
          ..add(const SizedBox(height: 16))
          ..add(Container(
            height: MonolithTheme.borderWidth,
            color: MonolithTheme.primary,
          ))
          ..add(const SizedBox(height: 16));
      }
      rows.add(RecommendationRow(recommendation: recommendations[i]));
    }
    return rows;
  }
}
