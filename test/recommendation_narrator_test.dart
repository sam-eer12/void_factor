import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:void_factor/features/projection/gemma_model_service.dart';
import 'package:void_factor/features/projection/projection_engine.dart';
import 'package:void_factor/features/projection/recommendation_narrator.dart';
import 'package:void_factor/models/projection.dart';
import 'package:void_factor/models/recommendation.dart';
import 'package:void_factor/models/user_profile.dart';

/// A gateway that never touches a platform channel.
///
/// The whole reason [GemmaGateway] exists: without it the paths below — which are
/// what every user without a half-gigabyte model downloaded actually sees — would
/// be the only untestable part of the feature.
class _FakeGemma implements GemmaGateway {
  _FakeGemma({this.ready = true, this.response = '[]', this.error});

  final bool ready;
  final String response;

  /// Thrown from [generate] instead of returning, to stand in for a timeout or a
  /// session that would not open.
  final Object? error;

  int generateCalls = 0;
  String? lastPrompt;
  String? lastSystemInstruction;
  Duration? lastTimeout;

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  }) async {
    generateCalls++;
    lastPrompt = prompt;
    lastSystemInstruction = systemInstruction;
    lastTimeout = timeout;
    if (error != null) throw error!;
    return response;
  }

  @override
  Future<void> install({
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
  }) async =>
      throw UnsupportedError('not exercised by the narrator');

  @override
  Future<void> uninstall() async =>
      throw UnsupportedError('not exercised by the narrator');
}

/// A gateway whose readiness check itself fails — a model uninstalled underneath
/// a live screen, or a plugin that will not initialize.
class _BrokenGemma implements GemmaGateway {
  @override
  Future<bool> isReady() async => throw StateError('plugin unavailable');

  @override
  Future<String> generate({
    required String prompt,
    required String systemInstruction,
    required Duration timeout,
  }) async =>
      throw StateError('unreachable');

  @override
  Future<void> install({
    required String url,
    required String? token,
    required void Function(int progress) onProgress,
  }) async =>
      throw UnsupportedError('not exercised by the narrator');

  @override
  Future<void> uninstall() async =>
      throw UnsupportedError('not exercised by the narrator');
}

void main() {
  Projection projectionOf({
    WeightGoal goal = WeightGoal.lose,
    ProjectionBasis basis = ProjectionBasis.measured,
    ProjectionStatus status = ProjectionStatus.behind,
    double currentWeightKg = 80,
  }) {
    return Projection(
      observed: const [],
      projected: const [],
      currentWeightKg: currentWeightKg,
      targetWeightKg: 75,
      goal: goal,
      ratePerWeekKg: -0.2,
      targetRatePerWeekKg: 0.5,
      basis: basis,
      status: status,
      daysToGoal: 70,
      goalDate: DateTime(2026, 11, 4),
      bmrKcal: 1750,
      activeKcal: 150,
      tdeeKcal: 2250,
      intakeKcal: 2450,
      proteinGPerDay: 90,
      balanceKcal: 200,
      loggedDayCount: 4,
      intakeWindowDays: ProjectionEngine.intakeWindowDays,
      weighInDayCount: 9,
      seriesSpanDays: 28,
      activeEnergyFromDevice: true,
    );
  }

  RecommendationCandidate candidateOf({
    RecommendationKind kind = RecommendationKind.exerciseVolume,
    double magnitude = 150,
    double target = 300,
    bool onTarget = false,
  }) {
    return RecommendationCandidate(
      kind: kind,
      priority: 1,
      magnitude: magnitude,
      target: target,
      onTarget: onTarget,
    );
  }

  /// Three cards whose rendered figures are known exactly, so a test can name a
  /// number the model is allowed to quote and a number it is not.
  ///
  /// Renders to the digit runs {300, 150, 10, 14, 4, 550, 200}.
  final threeCandidates = [
    candidateOf(),
    candidateOf(
      kind: RecommendationKind.loggingAdherence,
      magnitude: 4,
      target: 14,
    ),
    candidateOf(
      kind: RecommendationKind.calorieGap,
      magnitude: 200,
      target: -550,
    ),
  ];

  String jsonArray(List<(String, String)> cards) {
    final objects = cards
        .map((c) => '{"title": "${c.$1}", "body": "${c.$2}"}')
        .join(', ');
    return '[$objects]';
  }

  group('TemplateNarrator', () {
    const narrator = TemplateNarrator();

    test('renders one card per candidate, in order', () async {
      final cards = await narrator.narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
      expect(cards.map((c) => c.kind), [
        RecommendationKind.exerciseVolume,
        RecommendationKind.loggingAdherence,
        RecommendationKind.calorieGap,
      ]);
    });

    test('never claims to have been narrated on device', () async {
      final cards = await narrator.narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
      expect(cards.every((c) => !c.narratedOnDevice), isTrue);
    });

    test('the headline figure is the target, not where the user is', () {
      // The user is at a 200 kcal surplus; the card must read as an instruction,
      // so the big text is the -550 they should be at.
      final card = narrator.render(
        projectionOf(),
        candidateOf(
          kind: RecommendationKind.calorieGap,
          magnitude: 200,
          target: -550,
        ),
      );
      expect(card.value, '-550 KCAL');
      expect(card.body, contains('200 kcal surplus'));
      expect(card.body, contains('550 kcal deficit'));
    });

    test('a surplus target carries a plus sign', () {
      final card = narrator.render(
        projectionOf(goal: WeightGoal.gain),
        candidateOf(
          kind: RecommendationKind.calorieGap,
          magnitude: 0,
          target: 275,
        ),
      );
      expect(card.value, '+275 KCAL');
      expect(card.title, 'CALORIC SURPLUS');
    });

    test('a target that rounds to nothing is 0, never -0', () {
      // `(-0.4).round()` is `-0`, which reaches a string as "-0 KCAL" and reads
      // as a typo.
      final card = narrator.render(
        projectionOf(goal: WeightGoal.maintain),
        candidateOf(
          kind: RecommendationKind.calorieGap,
          magnitude: -40,
          target: -0.4,
        ),
      );
      expect(card.value, '0 KCAL');
      expect(card.title, 'ENERGY BALANCE');
    });

    test('the logging value states the floor over the window', () {
      final card = narrator.render(
        projectionOf(),
        candidateOf(
          kind: RecommendationKind.loggingAdherence,
          magnitude: 4,
          target: 14,
        ),
      );
      expect(card.value, '10 / 14 DAYS');
    });

    test('no activity at all names the missing connection, not a shortfall', () {
      // "Burn 300 more kcal" is useless advice to someone whose phone simply is
      // not sending the app any activity.
      final card = narrator.render(
        projectionOf(),
        candidateOf(magnitude: 0),
      );
      expect(card.body, contains('health data'));
      expect(card.body, isNot(contains('brisk')));
    });

    test('an on-target card reads as confirmation, not instruction', () {
      final card = narrator.render(
        projectionOf(),
        candidateOf(magnitude: 400, onTarget: true),
      );
      expect(card.body, contains('above'));
    });

    test('enough weigh-ins on a measured basis says the trend is being read',
        () {
      final card = narrator.render(
        projectionOf(basis: ProjectionBasis.measured),
        candidateOf(
          kind: RecommendationKind.weighInCadence,
          magnitude: 9,
          target: 8,
          onTarget: true,
        ),
      );
      expect(card.body, contains('measured trend'));
    });

    test('enough weigh-ins bunched together says they need to span weeks', () {
      // Nine weigh-ins inside four days clears the count but not the span, and
      // claiming a measured trend there would be a false statement about what the
      // projection is doing.
      final card = narrator.render(
        projectionOf(basis: ProjectionBasis.energyBalance),
        candidateOf(
          kind: RecommendationKind.weighInCadence,
          magnitude: 9,
          target: 8,
          onTarget: true,
        ),
      );
      expect(card.body, contains('span'));
      expect(card.body, isNot(contains('measured trend')));
    });
  });

  group('GemmaNarrator falls back', () {
    Future<List<Recommendation>> narrateWith(GemmaGateway gateway) {
      return GemmaNarrator(gateway: gateway).narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
    }

    Future<void> expectTemplated(GemmaGateway gateway) async {
      final cards = await narrateWith(gateway);
      final templated = await const TemplateNarrator().narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
      expect(cards.map((c) => c.title), templated.map((c) => c.title));
      expect(cards.map((c) => c.body), templated.map((c) => c.body));
      expect(cards.every((c) => !c.narratedOnDevice), isTrue,
          reason: 'templated copy must never be labelled as model-written');
    }

    test('when no model is installed, without asking it anything', () async {
      final gateway = _FakeGemma(ready: false);
      await expectTemplated(gateway);
      expect(gateway.generateCalls, 0);
    });

    test('when the readiness check itself throws', () async {
      await expectTemplated(_BrokenGemma());
    });

    test('when generation times out', () async {
      await expectTemplated(_FakeGemma(error: TimeoutException('too slow')));
    });

    test('when generation throws anything else', () async {
      await expectTemplated(_FakeGemma(error: StateError('session closed')));
    });

    test('on a reply that is not JSON at all', () async {
      await expectTemplated(_FakeGemma(
        response: 'Sure! Here is some advice about your weight loss goals.',
      ));
    });

    test('on malformed JSON', () async {
      await expectTemplated(_FakeGemma(response: '[{"title": "A", "body":}]'));
    });

    test('on an empty reply', () async {
      await expectTemplated(_FakeGemma(response: ''));
    });

    test('on too few objects', () async {
      await expectTemplated(_FakeGemma(
        response: jsonArray([('BURN MORE', 'Walk further.')]),
      ));
    });

    test('on too many objects', () async {
      await expectTemplated(_FakeGemma(
        response: jsonArray([
          ('ONE', 'Walk further.'),
          ('TWO', 'Log your food.'),
          ('THREE', 'Eat less.'),
          ('FOUR', 'Invented.'),
        ]),
      ));
    });

    test('on an array of strings rather than objects', () async {
      await expectTemplated(_FakeGemma(
        response: '["walk further", "log your food", "eat less"]',
      ));
    });

    test('on a missing body key', () async {
      await expectTemplated(_FakeGemma(
        response: '[{"title": "ONE"}, {"title": "TWO"}, {"title": "THREE"}]',
      ));
    });

    test('on a non-string title', () async {
      await expectTemplated(_FakeGemma(
        response: '[{"title": 1, "body": "Walk."}, '
            '{"title": "TWO", "body": "Log."}, '
            '{"title": "THREE", "body": "Eat."}]',
      ));
    });

    test('on a blank body', () async {
      await expectTemplated(_FakeGemma(
        response: jsonArray([
          ('ONE', '   '),
          ('TWO', 'Log your food.'),
          ('THREE', 'Eat less.'),
        ]),
      ));
    });

    test('on a body past the length cap', () async {
      await expectTemplated(_FakeGemma(
        response: jsonArray([
          ('ONE', 'Walk. ' * 60),
          ('TWO', 'Log your food.'),
          ('THREE', 'Eat less.'),
        ]),
      ));
    });

    test('on a title past the length cap', () async {
      await expectTemplated(_FakeGemma(
        response: jsonArray([
          ('A VERY LONG HEADING INDEED THAT RUNS ON', 'Walk further.'),
          ('TWO', 'Log your food.'),
          ('THREE', 'Eat less.'),
        ]),
      ));
    });
  });

  group('GemmaNarrator cannot introduce a number', () {
    Future<List<Recommendation>> narrateResponse(String response) {
      return GemmaNarrator(gateway: _FakeGemma(response: response)).narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
    }

    test('an invented figure in a body rejects the whole reply', () async {
      // 450 was never computed. A small model writing it would be stating
      // something false about the user's body, which is not a wording problem.
      final cards = await narrateResponse(jsonArray([
        ('BURN MORE', 'Push your daily burn to 450 kcal.'),
        ('LOG FOOD', 'Log your food.'),
        ('EAT LESS', 'Eat less.'),
      ]));
      expect(cards.every((c) => !c.narratedOnDevice), isTrue);
    });

    test('an invented figure in a title rejects the whole reply', () async {
      final cards = await narrateResponse(jsonArray([
        ('BURN 999 KCAL', 'Walk further.'),
        ('LOG FOOD', 'Log your food.'),
        ('EAT LESS', 'Eat less.'),
      ]));
      expect(cards.every((c) => !c.narratedOnDevice), isTrue);
    });

    test('one bad card falls the whole list back, never a mixture', () async {
      // Two perfectly good rewrites are discarded with the third. A list carrying
      // two voices reads as broken, and `narratedOnDevice` would be true of only
      // part of what the UI labels.
      final cards = await narrateResponse(jsonArray([
        ('BURN MORE', 'Push your daily burn to 300 kcal.'),
        ('LOG FOOD', 'Log 10 of the next 14 days.'),
        ('EAT LESS', 'Aim for a 1200 kcal deficit.'),
      ]));
      expect(cards.every((c) => !c.narratedOnDevice), isTrue);
      expect(cards.first.body, contains('brisk'));
    });

    test('a digit run that is only a prefix of a real figure is rejected',
        () async {
      // 55 is a substring of 550, so a naive containment check would let it
      // through. It is still a number nobody computed.
      final cards = await narrateResponse(jsonArray([
        ('BURN MORE', 'Walk further.'),
        ('LOG FOOD', 'Log your food.'),
        ('EAT LESS', 'Cut 55 kcal.'),
      ]));
      expect(cards.every((c) => !c.narratedOnDevice), isTrue);
    });

    test('quoting a computed figure is allowed', () async {
      final cards = await narrateResponse(jsonArray([
        ('BURN MORE', 'Push your daily burn from 150 to 300 kcal.'),
        ('LOG FOOD', 'Log 10 of the next 14 days.'),
        ('EAT LESS', 'Trade your 200 surplus for a 550 deficit.'),
      ]));
      expect(cards.every((c) => c.narratedOnDevice), isTrue);
    });
  });

  group('GemmaNarrator on a good reply', () {
    late _FakeGemma gateway;
    late List<Recommendation> cards;

    setUp(() async {
      gateway = _FakeGemma(
        response: jsonArray([
          ('burn more', 'Walk further each day.'),
          ('log food', 'Log every meal.'),
          ('eat less', 'Trim your portions.'),
        ]),
      );
      cards = await GemmaNarrator(gateway: gateway).narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
    });

    test('uses the model prose', () {
      expect(cards.map((c) => c.body), [
        'Walk further each day.',
        'Log every meal.',
        'Trim your portions.',
      ]);
    });

    test('marks the cards as narrated on device', () {
      expect(cards.every((c) => c.narratedOnDevice), isTrue);
    });

    test('uppercases titles into the app voice', () {
      expect(cards.map((c) => c.title), ['BURN MORE', 'LOG FOOD', 'EAT LESS']);
    });

    test('keeps the computed headline figures untouched', () {
      // The model has no route to `value` at all: the largest text on each card
      // is always the number Dart computed.
      expect(cards.map((c) => c.value), ['300 KCAL', '10 / 14 DAYS', '-550 KCAL']);
    });

    test('keeps the kinds and their order', () {
      expect(cards.map((c) => c.kind), [
        RecommendationKind.exerciseVolume,
        RecommendationKind.loggingAdherence,
        RecommendationKind.calorieGap,
      ]);
    });

    test('carries onTarget through from the candidates', () {
      expect(cards.every((c) => !c.onTarget), isTrue);
    });

    test('passes its system instruction and timeout to the gateway', () {
      expect(gateway.lastSystemInstruction, GemmaNarrator.systemInstruction);
      expect(gateway.lastTimeout, GemmaNarrator.defaultTimeout);
    });

    test('asks the model exactly once for the whole list', () {
      // Three separate calls would be three model loads and three prefills for a
      // screen that renders one section.
      expect(gateway.generateCalls, 1);
    });
  });

  group('GemmaNarrator tolerance', () {
    Future<List<Recommendation>> narrateResponse(String response) {
      return GemmaNarrator(gateway: _FakeGemma(response: response)).narrate(
        projection: projectionOf(),
        candidates: threeCandidates,
      );
    }

    test('accepts an array wrapped in a fenced code block', () async {
      // A small instruct model routinely fences its answer however plainly it was
      // told not to. Losing a valid response to that would be a self-inflicted
      // fallback.
      final cards = await narrateResponse(
        'Here you go:\n```json\n${jsonArray([
              ('BURN MORE', 'Walk further.'),
              ('LOG FOOD', 'Log every meal.'),
              ('EAT LESS', 'Trim portions.'),
            ])}\n```\nHope that helps!',
      );
      expect(cards.every((c) => c.narratedOnDevice), isTrue);
    });

    test('collapses a body the model formatted across lines', () async {
      final cards = await narrateResponse(
        '[{"title": "BURN MORE", "body": "Walk further.\\n\\nEvery day."}, '
        '{"title": "LOG FOOD", "body": "Log every meal."}, '
        '{"title": "EAT LESS", "body": "Trim portions."}]',
      );
      expect(cards.first.body, 'Walk further. Every day.');
    });
  });

  group('GemmaNarrator prompt', () {
    test('carries no figure that was not already rounded for display', () async {
      // The model is handed finished strings, never a computation. A raw double
      // like 2013.333 reaching it would be an invitation to arithmetic.
      final projection = projectionOf();
      final baseline = await const TemplateNarrator().narrate(
        projection: projection,
        candidates: threeCandidates,
      );
      final prompt = GemmaNarrator(gateway: _FakeGemma())
          .buildPrompt(projection, baseline);

      expect(prompt, isNot(contains(RegExp(r'\d\.\d'))));
    });

    test('quotes each card verbatim, so the numbers cannot drift', () async {
      final projection = projectionOf();
      final baseline = await const TemplateNarrator().narrate(
        projection: projection,
        candidates: threeCandidates,
      );
      final prompt = GemmaNarrator(gateway: _FakeGemma())
          .buildPrompt(projection, baseline);

      for (final card in baseline) {
        expect(prompt, contains(card.title));
        expect(prompt, contains(card.value));
        expect(prompt, contains(card.body));
      }
    });

    test('states the goal and the trend in words', () async {
      final projection = projectionOf(
        goal: WeightGoal.maintain,
        status: ProjectionStatus.wrongDirection,
      );
      final baseline = await const TemplateNarrator().narrate(
        projection: projection,
        candidates: threeCandidates,
      );
      final prompt = GemmaNarrator(gateway: _FakeGemma())
          .buildPrompt(projection, baseline);

      expect(prompt, contains('hold their weight steady'));
      expect(prompt, contains('moving away from target'));
    });

    test('asks for as many objects as there are cards', () async {
      final projection = projectionOf();
      final baseline = await const TemplateNarrator().narrate(
        projection: projection,
        candidates: threeCandidates,
      );
      final prompt = GemmaNarrator(gateway: _FakeGemma())
          .buildPrompt(projection, baseline);

      expect(prompt, contains('exactly 3 objects'));
    });
  });

  group('GemmaNarrator with nothing to say', () {
    test('returns an empty list without loading the model', () async {
      final gateway = _FakeGemma();
      final cards = await GemmaNarrator(gateway: gateway).narrate(
        projection: projectionOf(),
        candidates: const [],
      );
      expect(cards, isEmpty);
      expect(gateway.generateCalls, 0);
    });
  });
}
