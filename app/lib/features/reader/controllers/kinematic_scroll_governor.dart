import 'dart:async';
import 'package:flutter/foundation.dart';

/// KinematicScrollGovernor enforces high-velocity scrolling protection.
///
/// Skimming or flinging through pages at 120fps must not trigger background
/// SQLite read-aheads or external HTTPS LLM synthesis calls.
///
/// Dwell windows:
/// - 450ms: Local SQLite read-ahead and reading position persistence.
/// - 1500ms: External HTTPS AI card generation and synthesis.
class KinematicScrollGovernor {
  final Duration localDwellDuration;
  final Duration aiDwellDuration;
  final void Function(int index)? onLocalDwell;
  final void Function(int index)? onAiDwell;

  Timer? _localTimer;
  Timer? _aiTimer;
  DateTime? _lastPageTurnTime;
  int? _settledIndex;
  int _consecutiveFastFlings = 0;

  KinematicScrollGovernor({
    this.localDwellDuration = const Duration(milliseconds: 450),
    this.aiDwellDuration = const Duration(milliseconds: 1500),
    this.onLocalDwell,
    this.onAiDwell,
  });

  /// Timestamp of the most recent page turn or scroll change.
  DateTime? get lastPageTurnTime => _lastPageTurnTime;

  /// Index of the currently settled chunk, or null if fast-scrolling.
  int? get settledIndex => _settledIndex;

  /// True if the user is currently flinging or turning pages faster than localDwellDuration.
  bool get isFastScrolling {
    if (_lastPageTurnTime == null) return false;
    return DateTime.now().difference(_lastPageTurnTime!) < localDwellDuration;
  }

  /// Number of consecutive rapid page flips observed without dwelling.
  int get consecutiveFastFlings => _consecutiveFastFlings;

  /// Informs the governor that a page turn occurred.
  /// Cancels any in-flight timers immediately to protect main isolate performance.
  void onPageTurn(int index) {
    final now = DateTime.now();
    if (_lastPageTurnTime != null &&
        now.difference(_lastPageTurnTime!) < localDwellDuration) {
      _consecutiveFastFlings++;
    } else {
      _consecutiveFastFlings = 1;
    }
    _lastPageTurnTime = now;
    _settledIndex = null;

    // Immediately cancel any in-flight dwell timers
    _localTimer?.cancel();
    _aiTimer?.cancel();

    // Schedule local SQLite dwell debouncer (450ms)
    _localTimer = Timer(localDwellDuration, () {
      _settledIndex = index;
      _consecutiveFastFlings = 0;
      try {
        onLocalDwell?.call(index);
      } catch (e, st) {
        debugPrint('[Athena Error] KinematicGovernor local dwell callback failed: $e\n$st');
      }
    });

    // Schedule external HTTPS AI card synthesis debouncer (1500ms)
    _aiTimer = Timer(aiDwellDuration, () {
      try {
        onAiDwell?.call(index);
      } catch (e, st) {
        debugPrint('[Athena Error] KinematicGovernor AI dwell callback failed: $e\n$st');
      }
    });
  }

  /// Cancels all pending timers. Must be called when disposing of the Reader.
  void dispose() {
    _localTimer?.cancel();
    _aiTimer?.cancel();
    _localTimer = null;
    _aiTimer = null;
  }
}

