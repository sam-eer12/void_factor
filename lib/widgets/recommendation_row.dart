import 'package:flutter/material.dart';

import '../models/recommendation.dart';
import '../theme/monolith_theme.dart';

/// One recommendation, in the row shape the screen has always used.
///
/// The layout is lifted from the hardcoded `_buildProtocol` this replaces — icon
/// block, title against a headline figure, a line of explanation — so the section
/// looks the same and now says something true.
///
/// The one addition is that an on-target card is drawn differently: its icon
/// block is outlined rather than filled. Three identical black blocks would give
/// "keep doing this" the same visual weight as "you are 500 kcal over", and the
/// user would have to read all three bodies to find out which is which.
class RecommendationRow extends StatelessWidget {
  const RecommendationRow({super.key, required this.recommendation});

  final Recommendation recommendation;

  @override
  Widget build(BuildContext context) {
    final onTarget = recommendation.onTarget;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: onTarget ? MonolithTheme.surface : MonolithTheme.primary,
            border: Border.all(
              color: MonolithTheme.primary,
              width: MonolithTheme.borderWidth,
            ),
          ),
          child: Icon(
            iconFor(recommendation.kind),
            color: onTarget ? MonolithTheme.primary : MonolithTheme.surface,
            size: 18,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Expanded, unlike the mock's bare `Text`: a title can be
                  // written by the on-device model, and an unconstrained one
                  // would overflow the row rather than wrap.
                  Expanded(
                    child: Text(
                      recommendation.title,
                      style: MonolithTheme.labelLarge,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    recommendation.value,
                    style: MonolithTheme.headlineMedium,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                recommendation.body,
                style: MonolithTheme.bodyMedium.copyWith(
                  color: MonolithTheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The icon for a kind.
  ///
  /// Chosen here rather than carried on the model, so the ranking engine stays a
  /// pure-Dart file with no Flutter import — and so the same candidate can be
  /// rendered by any widget without the engine having an opinion about glyphs.
  static IconData iconFor(RecommendationKind kind) {
    switch (kind) {
      case RecommendationKind.calorieGap:
        return Icons.restaurant;
      case RecommendationKind.loggingAdherence:
        return Icons.edit_note;
      case RecommendationKind.exerciseVolume:
        return Icons.directions_run;
      case RecommendationKind.proteinFloor:
        return Icons.fitness_center;
      case RecommendationKind.weighInCadence:
        return Icons.monitor_weight;
    }
  }
}
