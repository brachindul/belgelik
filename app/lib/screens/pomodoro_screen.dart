import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config.dart';
import '../platform_adaptive.dart';
import '../pomodoro_service.dart';
import 'stats_screen.dart';

class PomodoroScreen extends StatelessWidget {
  const PomodoroScreen({super.key});

  static const _gold = Color(0xFFC5A880);
  static const _emerald = Color(0xFF2A5C54);
  static const _presets = [25, 45, 60];

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _openSettings(BuildContext context) async {
    final workCtrl = TextEditingController(
      text: AppConfig.workMinutes.toString(),
    );
    final breakCtrl = TextEditingController(
      text: AppConfig.breakMinutes.toString(),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Süreler (dakika)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: workCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Çalışma'),
            ),
            TextField(
              controller: breakCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Mola'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final w = int.tryParse(workCtrl.text) ?? AppConfig.workMinutes;
      final b = int.tryParse(breakCtrl.text) ?? AppConfig.breakMinutes;
      await AppConfig.savePomodoro(w.clamp(1, 180), b.clamp(1, 60));
      await PomodoroService.reset();
    }
    workCtrl.dispose();
    breakCtrl.dispose();
  }

  Future<void> _setWorkPreset(int minutes) async {
    await AppConfig.savePomodoro(minutes, AppConfig.breakMinutes);
    await PomodoroService.reset();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (!PlatformAdaptive.isDesktop) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.space) {
          if (PomodoroService.state.value.running) {
            PomodoroService.pause();
          } else {
            PomodoroService.start();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ValueListenableBuilder<PomodoroState>(
      valueListenable: PomodoroService.state,
      builder: (context, state, _) {
        final isWork = state.phase == PomodoroPhase.work;
        final totalSeconds = isWork
            ? AppConfig.workMinutes * 60
            : AppConfig.breakMinutes * 60;
        final ratio = totalSeconds > 0
            ? (state.remaining.inSeconds / totalSeconds).clamp(0.0, 1.0)
            : 0.0;
        final phaseColor = isWork ? _emerald : _gold;
        final indicatorColor = state.running ? phaseColor : _gold;
        final trackColor = (isWork ? _emerald : _gold).withAlpha(42);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Pomodoro'),
            actions: [
              IconButton(
                tooltip: 'İstatistik',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const StatsScreen()),
                ),
                icon: const Icon(Icons.bar_chart_outlined),
              ),
              IconButton(
                tooltip: 'Süreler',
                onPressed: state.running ? null : () => _openSettings(context),
                icon: const Icon(Icons.tune_outlined),
              ),
            ],
          ),
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withAlpha(80),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _phaseButton(
                          context: context,
                          label: 'Odaklanma',
                          active: isWork,
                          enabled: !state.running,
                          onTap: () =>
                              PomodoroService.switchPhase(PomodoroPhase.work),
                        ),
                        _phaseButton(
                          context: context,
                          label: 'Mola',
                          active: !isWork,
                          enabled: !state.running,
                          onTap: () =>
                              PomodoroService.switchPhase(PomodoroPhase.brk),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 48),
                  SizedBox(
                    width: 240,
                    height: 240,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 350),
                          width: 214,
                          height: 214,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: scheme.surfaceContainerLowest,
                            boxShadow: [
                              BoxShadow(
                                color: indicatorColor.withAlpha(
                                  state.running ? 36 : 18,
                                ),
                                blurRadius: state.running ? 32 : 18,
                                spreadRadius: state.running ? 4 : 1,
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 240,
                          height: 240,
                          child: CircularProgressIndicator(
                            value: ratio,
                            strokeWidth: 10,
                            strokeCap: StrokeCap.round,
                            backgroundColor: trackColor,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              indicatorColor,
                            ),
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              isWork ? 'ÇALIŞMA' : 'MOLA',
                              style: GoogleFonts.outfit(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.4,
                                color: phaseColor,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _fmt(state.remaining),
                              style: GoogleFonts.outfit(
                                fontSize: 54,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface,
                                height: 1,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              state.running ? 'Seans aktif' : 'Hazır',
                              style: GoogleFonts.outfit(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant.withAlpha(170),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 44),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: state.running
                            ? PomodoroService.pause
                            : PomodoroService.start,
                        style: FilledButton.styleFrom(
                          backgroundColor: indicatorColor,
                          foregroundColor: scheme.surface,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 26,
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        icon: Icon(
                          state.running
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 26,
                        ),
                        label: Text(
                          state.running ? 'Durdur' : 'Başlat',
                          style: GoogleFonts.outfit(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton.filledTonal(
                        tooltip: 'Sıfırla',
                        onPressed: PomodoroService.reset,
                        style: IconButton.styleFrom(
                          backgroundColor: _gold.withAlpha(35),
                          foregroundColor: _gold,
                          fixedSize: const Size(54, 54),
                        ),
                        icon: const Icon(Icons.replay_rounded, size: 22),
                      ),
                    ],
                  ),
                  const SizedBox(height: 40),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final minutes in _presets) ...[
                          ChoiceChip(
                            selected:
                                isWork && AppConfig.workMinutes == minutes,
                            onSelected: state.running
                                ? null
                                : (_) => _setWorkPreset(minutes),
                            selectedColor: _gold.withAlpha(48),
                            backgroundColor: scheme.surfaceContainerHighest
                                .withAlpha(80),
                            disabledColor: scheme.surfaceContainerHighest
                                .withAlpha(45),
                            side: BorderSide(
                              color: AppConfig.workMinutes == minutes
                                  ? _gold
                                  : scheme.outlineVariant.withAlpha(150),
                            ),
                            label: Text(
                              '$minutes dk',
                              style: GoogleFonts.outfit(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppConfig.workMinutes == minutes
                                    ? _gold
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (minutes != _presets.last)
                            const SizedBox(width: 10),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
      ),
    );
  }

  Widget _phaseButton({
    required BuildContext context,
    required String label,
    required bool active,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: active ? scheme.surfaceContainerLowest : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: scheme.shadow.withAlpha(10),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: GoogleFonts.outfit(
              fontSize: 13,
              fontWeight: active ? FontWeight.bold : FontWeight.w600,
              color: active ? _gold : scheme.onSurfaceVariant.withAlpha(180),
            ),
          ),
        ),
      ),
    );
  }
}
