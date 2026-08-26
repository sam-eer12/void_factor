import 'dart:async';
import 'dart:convert';

import '../../models/projection.dart';
import '../../models/recommendation.dart';
import '../../models/user_profile.dart';
import 'gemma_model_service.dart';
import 'projection_engine.dart';
import 'recommendation_engine.dart';

/// Turns ranked candidates into words.
///
/// The seam between arithmetic and prose. Everything upstream of this decides
/// *what* to say from numbers with defined answers; everything here decides only
/// *how* to say it. That boundary is what makes it safe to put a 1B-parameter
/// model on one side of it.
abstract class RecommendationNarrator {
  Future<List<Recommendation>> narrate({
    required Projection projection,
    required List<RecommendationCandidate> candidates,
  });
}

/// Deterministic copy, always available.
///
/// Not a degraded fallback — this is the baseline the whole feature ships on. The
/// model is an improvement on the phrasing, never a prerequisite for having any,
/// so a user who never downloads it sees a screen that is complete rather than
/// one that is missing its bottom third.
class TemplateNarrator implements RecommendationNarrator {
  const TemplateNarrator();

  @override
  Future<List<Recommendation>> narrate({
    required Projection projection,
    required List<RecommendationCandidate> candidates,
  }) async {
    return [
      for (final candidate in candidates) render(projection, candidate),
    ];
  }

  /// Synchronous and public so [GemmaNarrator] can build its baseline without an
  /// await, and so a test can assert on one card without driving a narrator.
  Recommendation render(
    Projection projection,
    RecommendationCandidate candidate,
  ) {
    return Recommendation(
      kind: candidate.kind,
      title: _title(projection, candidate),
      value: _value(projection, candidate),
      body: _body(projection, candidate),
      onTarget: candidate.onTarget,
    );
  }

  String _title(Projection projection, RecommendationCandidate candidate) {
    switch (candidate.kind) {
      case RecommendationKind.calorieGap:
        // Thresholded on the rounded figure rather than the raw double, so the
        // title can never contradict the value beneath it: a -0.4 kcal target
        // renders as `0 KCAL`, and calling that a deficit would be a card
        // arguing with itself.
        final required = candidate.target.round();
        if (required < 0) return 'CALORIC DEFICIT';
        if (required > 0) return 'CALORIC SURPLUS';
        return 'ENERGY BALANCE';
      case RecommendationKind.loggingAdherence:
        return 'INTAKE LOGGING';
      case RecommendationKind.exerciseVolume:
        return 'ACTIVE BURN';
      case RecommendationKind.proteinFloor:
        return 'PROTEIN FLOOR';
      case RecommendationKind.weighInCadence:
        return 'WEIGH-IN CADENCE';
    }
  }

  /// The headline figure: always where the user *should* be.
  ///
  /// A target rather than their current number, so the card reads as an
  /// instruction. Where they actually are goes in the body, which has room to say
  /// whether that is above or below.
  String _value(Projection projection, RecommendationCandidate candidate) {
    switch (candidate.kind) {
      case RecommendationKind.calorieGap:
        return '${_signed(candidate.target)} KCAL';
      case RecommendationKind.loggingAdherence:
        return '${_whole(candidate.target * RecommendationEngine.loggingAdherenceFloor)}'
            ' / ${_whole(candidate.target)} DAYS';
      case RecommendationKind.exerciseVolume:
        return '${_whole(candidate.target)} KCAL';
      case RecommendationKind.proteinFloor:
        return '${_whole(candidate.target)} G';
      case RecommendationKind.weighInCadence:
        return '${_whole(candidate.target)}'
            ' / ${ProjectionEngine.seriesWindowDays} DAYS';
    }
  }

  String _body(Projection projection, RecommendationCandidate candidate) {
    switch (candidate.kind) {
      case RecommendationKind.calorieGap:
        if (candidate.onTarget) {
          return 'Your average intake already lands on the balance your goal '
              'rate needs. Keep logging the same way.';
        }
        return 'You are averaging ${_balancePhrase(candidate.magnitude)}. '
            'Your goal rate needs ${_balancePhrase(candidate.target)}.';

      case RecommendationKind.loggingAdherence:
        final logged = _whole(candidate.magnitude);
        final window = _whole(candidate.target);
        if (candidate.onTarget) {
          return 'You logged $logged of the last $window days. That is enough '
              'for the intake average to mean something.';
        }
        return 'You logged $logged of the last $window days. Below that the '
            'intake average is a sample, not a habit.';

      case RecommendationKind.exerciseVolume:
        final burn = _whole(candidate.magnitude);
        final floor = _whole(candidate.target);
        if (candidate.onTarget) {
          return 'You are burning about $burn kcal a day in activity, above '
              'the $floor floor.';
        }
        if (candidate.magnitude <= 0) {
          return 'No activity is reaching the app yet. Connecting health data '
              'lets your exercise count towards the projection.';
        }
        return 'You are burning about $burn kcal a day in activity. A brisk '
            'half hour would carry you to $floor.';

      case RecommendationKind.proteinFloor:
        final actual = _whole(candidate.magnitude);
        final floor = _whole(candidate.target);
        if (candidate.onTarget) {
          return 'You are averaging $actual g of protein a day, above the '
              '$floor g floor.';
        }
        return 'You are averaging $actual g of protein a day. At your body '
            'weight, $floor g protects lean mass.';

      case RecommendationKind.weighInCadence:
        final count = _whole(candidate.magnitude);
        final window = ProjectionEngine.seriesWindowDays;
        if (candidate.onTarget) {
          // Enough weigh-ins, but they can still be bunched into a few days —
          // the slope needs spread, not just count, so say which one is missing
          // rather than implying the projection is already measured.
          if (projection.basis == ProjectionBasis.measured) {
            return 'You have $count weigh-ins in the last $window days. The '
                'projection is reading your measured trend.';
          }
          return 'You have $count weigh-ins in the last $window days, but they '
              'need to span a couple of weeks before a trend means anything.';
        }
        return 'You have $count weigh-ins in the last $window days. More of '
            'them let the projection measure your trend instead of estimating '
            'it.';
    }
  }

  /// A signed balance as prose: `a 250 kcal deficit`, `an even balance`.
  ///
  /// Sign is rendered as a word because a bare `-250` in the middle of a sentence
  /// reads as a dash.
  String _balancePhrase(double kcal) {
    final rounded = kcal.round();
    if (rounded == 0) return 'an even balance';
    final magnitude = rounded.abs();
    return rounded < 0
        ? 'a $magnitude kcal deficit'
        : 'a $magnitude kcal surplus';
  }

  /// `-550`, `+300`, `0` — never `-0`, which is what `(-0.4).round()` renders as
  /// once it reaches a string.
  static String _signed(double value) {
    final rounded = value.round();
    if (rounded == 0) return '0';
    return rounded > 0 ? '+$rounded' : '$rounded';
  }

  static String _whole(double value) => '${value.round()}';
}

/// Rephrases the templated copy with the on-device model.
///
/// Three things bound what the model can do, and all three are deliberate:
///
/// 1. **It never sees a computation.** It is handed finished numbers and asked to
///    write around them. Every figure on the screen came out of
///    [ProjectionEngine].
/// 2. **It cannot supply the headline figure.** `value` is always the template's.
///    The largest text on each card is unreachable from the model.
/// 3. **It cannot introduce a number.** Every digit run in its output is checked
///    against the set of figures it was given; one unrecognised number rejects
///    the response. A small model that hallucinates `1200` where the data says
///    `120` is not a wording problem, it is a false statement about the user's
///    body, so it is made structurally impossible rather than merely unlikely.
///
/// Fallback is **all or nothing**. A list mixing model prose with templated prose
/// would read as two voices, and `narratedOnDevice` — which the UI shows the user
/// — would be true of only some of it.
class GemmaNarrator implements RecommendationNarrator {
  GemmaNarrator({
    required GemmaGateway gateway,
    TemplateNarrator fallback = const TemplateNarrator(),
    Duration timeout = defaultTimeout,
  })  : _gateway = gateway,
        _fallback = fallback,
        _timeout = timeout;

  final GemmaGateway _gateway;
  final TemplateNarrator _fallback;
  final Duration _timeout;

  /// Generous, because this is a 1B model doing CPU prefill on a phone and the
  /// screen has already rendered templated copy — the wait costs the user
  /// nothing but a late swap. Long enough that a slow device still succeeds,
  /// short enough that a wedged session does not hold a session object open for
  /// the rest of the app's life.
  static const Duration defaultTimeout = Duration(seconds: 45);

  /// Hard ceiling on a rephrased body. Roughly two sentences; past that the card
  /// would push the next one off the screen.
  static const int maxBodyChars = 180;
  static const int maxTitleChars = 28;

  static const String systemInstruction =
      'You rewrite fitness coaching notes. You are terse and factual. '
      'You never invent numbers: use only the figures given to you, exactly as '
      'written. You never add advice that was not in the note. '
      'You reply with JSON only.';

  @override
  Future<List<Recommendation>> narrate({
    required Projection projection,
    required List<RecommendationCandidate> candidates,
  }) async {
    final baseline = [
      for (final candidate in candidates) _fallback.render(projection, candidate),
    ];
    if (baseline.isEmpty) return baseline;

    try {
      if (!await _gateway.isReady()) return baseline;

      final raw = await _gateway.generate(
        prompt: buildPrompt(projection, baseline),
        systemInstruction: systemInstruction,
        timeout: _timeout,
      );

      final rewritten = _parse(raw, baseline);
      return rewritten ?? baseline;
    } catch (_) {
      // A timeout, a session that would not open, a model uninstalled between
      // the readiness check and the call. None of them are worth a visible
      // error: the screen is already showing complete, correct copy.
      return baseline;
    }
  }

  /// The prompt, exposed so a test can assert that no figure reaches the model
  /// which was not computed in Dart.
  String buildPrompt(Projection projection, List<Recommendation> baseline) {
    final buffer = StringBuffer()
      ..writeln('Rewrite each note below so it reads like a direct instruction.')
      ..writeln('Rules:')
      ..writeln('- Keep every number exactly as written. Add no new numbers.')
      ..writeln('- Two short sentences at most per note.')
      ..writeln('- Do not mention these rules.')
      ..writeln()
      ..writeln('Context: the user wants to ${_goalPhrase(projection.goal)}.')
      ..writeln('Their trend is ${_statusPhrase(projection.status)}.')
      ..writeln()
      ..writeln('Notes:');

    for (var i = 0; i < baseline.length; i++) {
      final card = baseline[i];
      buffer
        ..writeln('${i + 1}. topic: ${card.title}')
        ..writeln('   target: ${card.value}')
        ..writeln('   note: ${card.body}');
    }

    buffer
      ..writeln()
      ..writeln('Reply with a JSON array of exactly ${baseline.length} objects, '
          'in the same order, each with keys "title" and "body". '
          '"title" is at most three words in capitals.')
      ..writeln('JSON:');
    return buffer.toString();
  }

  /// Null whenever the response cannot be trusted in full — which then falls the
  /// whole list back to templated copy.
  List<Recommendation>? _parse(String raw, List<Recommendation> baseline) {
    final decoded = _decodeArray(raw);
    if (decoded == null || decoded.length != baseline.length) return null;

    final allowed = _allowedNumbers(baseline);
    final result = <Recommendation>[];

    for (var i = 0; i < baseline.length; i++) {
      final element = decoded[i];
      if (element is! Map) return null;

      final title = _clean(element['title']);
      final body = _clean(element['body']);
      if (title == null || body == null) return null;
      if (title.length > maxTitleChars || body.length > maxBodyChars) return null;
      if (!_numbersAllowed(title, allowed)) return null;
      if (!_numbersAllowed(body, allowed)) return null;

      result.add(baseline[i].copyWith(
        title: title.toUpperCase(),
        body: body,
        narratedOnDevice: true,
      ));
    }
    return result;
  }

  /// Decodes the first JSON array in [raw].
  ///
  /// Sliced between the outermost brackets rather than decoded whole, because a
  /// small instruct model routinely wraps its answer in a fenced code block or a
  /// line of preamble however plainly it was told not to. Tolerating that is
  /// cheaper than losing an otherwise valid response to it.
  static List<Object?>? _decodeArray(String raw) {
    final start = raw.indexOf('[');
    final end = raw.lastIndexOf(']');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = jsonDecode(raw.substring(start, end + 1));
      return decoded is List ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Every digit run the model is permitted to use: the ones it was given.
  ///
  /// Built from the rendered baseline rather than from the raw doubles, so the
  /// permitted strings are exactly what the model read.
  static Set<String> _allowedNumbers(List<Recommendation> baseline) {
    final allowed = <String>{};
    for (final card in baseline) {
      allowed
        ..addAll(_digitRuns(card.value))
        ..addAll(_digitRuns(card.body))
        ..addAll(_digitRuns(card.title));
    }
    return allowed;
  }

  static final RegExp _digits = RegExp(r'\d+');

  static Iterable<String> _digitRuns(String text) =>
      _digits.allMatches(text).map((m) => m[0]!);

  static bool _numbersAllowed(String text, Set<String> allowed) {
    return _digitRuns(text).every(allowed.contains);
  }

  /// A non-empty single-line string, or null.
  static String? _clean(Object? value) {
    if (value is! String) return null;
    // Newlines collapsed rather than rejected: a model that formats its body as
    // two lines has still written usable copy, and the card is a single
    // paragraph.
    final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text.isEmpty ? null : text;
  }

  static String _goalPhrase(WeightGoal goal) {
    switch (goal) {
      case WeightGoal.lose:
        return 'lose weight';
      case WeightGoal.gain:
        return 'gain weight';
      case WeightGoal.maintain:
        return 'hold their weight steady';
    }
  }

  static String _statusPhrase(ProjectionStatus status) {
    switch (status) {
      case ProjectionStatus.goalReached:
        return 'already at target';
      case ProjectionStatus.onTrack:
        return 'on track';
      case ProjectionStatus.ahead:
        return 'moving faster than planned';
      case ProjectionStatus.behind:
        return 'moving slower than planned';
      case ProjectionStatus.stalled:
        return 'flat';
      case ProjectionStatus.wrongDirection:
        return 'moving away from target';
      case ProjectionStatus.insufficientData:
        return 'not measurable yet';
    }
  }
}
