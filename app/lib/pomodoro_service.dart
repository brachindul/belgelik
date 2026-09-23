import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'local_store.dart';
import 'models.dart';
import 'notifications.dart';
import 'study_program.dart';
import 'sync_service.dart';

enum PomodoroPhase { work, brk }

class PomodoroState {
  final PomodoroPhase phase;
  final bool running;
  final Duration remaining;
  final int phaseMinutes;

  const PomodoroState({
    required this.phase,
    required this.running,
    required this.remaining,
    required this.phaseMinutes,
  });

  bool get isWork => phase == PomodoroPhase.work;
}

class PomodoroService {
  static Timer? _ticker;
  static DateTime? _endTime;
  static DateTime? _phaseStartedAt;
  // Duraklatmalar haric fiilen calisilan sure; istatistige bu yazilir
  // (duvar saati farki duraklatilan sureyi de sayardi).
  static int _activeSeconds = 0;
  static DateTime? _runStartedAt;
  static PomodoroPhase _phase = PomodoroPhase.work;
  static bool _running = false;
  static Duration _remaining = Duration(minutes: AppConfig.workMinutes);

  static final ValueNotifier<PomodoroState> state = ValueNotifier(
    PomodoroState(
      phase: _phase,
      running: _running,
      remaining: _remaining,
      phaseMinutes: AppConfig.workMinutes,
    ),
  );

  static int get _phaseMinutes => _phase == PomodoroPhase.work
      ? AppConfig.workMinutes
      : AppConfig.breakMinutes;

  static void init() {
    _remaining = Duration(minutes: _phaseMinutes);
    _emit();
  }

  static void _emit() {
    state.value = PomodoroState(
      phase: _phase,
      running: _running,
      remaining: _remaining,
      phaseMinutes: _phaseMinutes,
    );
  }

  static void start() {
    _phaseStartedAt ??= DateTime.now();
    _runStartedAt = DateTime.now();
    _endTime = DateTime.now().add(_remaining);
    _running = true;
    Notifications.scheduleAt(
      _endTime!,
      _phase == PomodoroPhase.work ? 'Çalışma bitti!' : 'Mola bitti!',
      _phase == PomodoroPhase.work ? 'Mola zamanı' : 'Çalışmaya dön',
    );
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _emit();
  }

  static void _tick() {
    final end = _endTime;
    if (end == null) return;
    final left = end.difference(DateTime.now());
    if (left.inSeconds <= 0) {
      _finish();
    } else {
      _remaining = left;
      _emit();
    }
  }

  static int _elapsedActiveSeconds() {
    final running = _runStartedAt;
    return _activeSeconds +
        (running == null ? 0 : DateTime.now().difference(running).inSeconds);
  }

  static Future<void> _recordCurrentPhase({required bool completed}) async {
    final started = _phaseStartedAt;
    if (started == null || _phase != PomodoroPhase.work) return;
    final elapsedSeconds = completed
        ? _phaseMinutes * 60
        : _elapsedActiveSeconds();
    final minutes = (elapsedSeconds / 60).floor();
    if (!completed && minutes < 5) return;
    if (minutes <= 0) return;
    final now = DateTime.now();
    final session = PomodoroSession(
      sessionUuid:
          'pom-${now.microsecondsSinceEpoch}-${LocalStore.deviceId.hashCode}',
      date: started.toIso8601String().substring(0, 10),
      subject: todaysSubject(started),
      phase: 'work',
      minutes: minutes,
      startedAtMs: started.millisecondsSinceEpoch,
      updatedAtMs: now.millisecondsSinceEpoch,
      updatedByDevice: LocalStore.deviceId,
    );
    await LocalStore.upsertPomodoroSession(session, dirty: true);
    SyncService.syncNow();
  }

  static void _finish() {
    _ticker?.cancel();
    HapticFeedback.heavyImpact();
    _recordCurrentPhase(completed: true);
    _running = false;
    _endTime = null;
    _phaseStartedAt = null;
    _activeSeconds = 0;
    _runStartedAt = null;
    _phase = _phase == PomodoroPhase.work
        ? PomodoroPhase.brk
        : PomodoroPhase.work;
    _remaining = Duration(minutes: _phaseMinutes);
    _emit();
  }

  static Future<void> pause() async {
    _ticker?.cancel();
    Notifications.cancel();
    final running = _runStartedAt;
    if (running != null) {
      _activeSeconds += DateTime.now().difference(running).inSeconds;
      _runStartedAt = null;
    }
    final end = _endTime;
    if (end != null) {
      _remaining = end.difference(DateTime.now());
      if (_remaining.isNegative) _remaining = Duration.zero;
    }
    _running = false;
    _endTime = null;
    _emit();
  }

  static Future<void> reset() async {
    _ticker?.cancel();
    Notifications.cancel();
    await _recordCurrentPhase(completed: false);
    _running = false;
    _endTime = null;
    _phaseStartedAt = null;
    _activeSeconds = 0;
    _runStartedAt = null;
    _remaining = Duration(minutes: _phaseMinutes);
    _emit();
  }

  static void switchPhase(PomodoroPhase phase) {
    if (_running) return;
    _phase = phase;
    _phaseStartedAt = null;
    _activeSeconds = 0;
    _runStartedAt = null;
    _remaining = Duration(minutes: _phaseMinutes);
    _emit();
  }

  static void extend(Duration duration) {
    _remaining += duration;
    if (_running) {
      _endTime = DateTime.now().add(_remaining);
      Notifications.scheduleAt(
        _endTime!,
        _phase == PomodoroPhase.work ? 'Çalışma bitti!' : 'Mola bitti!',
        _phase == PomodoroPhase.work ? 'Mola zamanı' : 'Çalışmaya dön',
      );
    }
    _emit();
  }

  static void dispose() {
    _ticker?.cancel();
  }
}
