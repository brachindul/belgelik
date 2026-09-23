import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../study_program.dart';
import 'subject_pdfs_screen.dart';

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFC5A880);
  static const _deepGold = Color(0xFF8F6F3D);

  late final AnimationController _pulseController;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOutCubic,
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeIndex = activeProgramIndex(DateTime.now());

    return Scaffold(
      appBar: AppBar(title: const Text('Ders Programı')),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 18, 20, 32),
        itemCount: studyProgramDays.length,
        itemBuilder: (context, index) {
          final day = studyProgramDays[index];
          final active = index == activeIndex;

          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 54,
                  child: _TimelineBadge(
                    dayNumber: day.number,
                    isActive: active,
                    isFirst: index == 0,
                    isLast: index == studyProgramDays.length - 1,
                    colorScheme: scheme,
                    pulse: _pulse,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _StudyDayCard(
                      day: day,
                      isActive: active,
                      colorScheme: scheme,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                SubjectPdfsScreen(subject: day.subject),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TimelineBadge extends StatelessWidget {
  const _TimelineBadge({
    required this.dayNumber,
    required this.isActive,
    required this.isFirst,
    required this.isLast,
    required this.colorScheme,
    required this.pulse,
  });

  final int dayNumber;
  final bool isActive;
  final bool isFirst;
  final bool isLast;
  final ColorScheme colorScheme;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final lineColor = isActive
        ? _ScheduleScreenState._gold.withAlpha(180)
        : colorScheme.outlineVariant.withAlpha(170);

    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final glow = isActive ? pulse.value : 0.0;

        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: 2,
                        color: isFirst ? Colors.transparent : lineColor,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        width: 2,
                        color: isLast ? Colors.transparent : lineColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              width: 38 + (glow * 7),
              height: 38 + (glow * 7),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? _ScheduleScreenState._gold.withAlpha(
                        35 + (glow * 40).round(),
                      )
                    : Colors.transparent,
              ),
            ),
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: isActive
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFE8D7B7),
                          _ScheduleScreenState._gold,
                          _ScheduleScreenState._deepGold,
                        ],
                      )
                    : null,
                color: isActive ? null : colorScheme.surfaceContainerLowest,
                border: Border.all(
                  color: isActive
                      ? const Color(0xFFFFE5B0)
                      : colorScheme.outlineVariant,
                  width: isActive ? 1.4 : 1,
                ),
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: _ScheduleScreenState._gold.withAlpha(
                            80 + (glow * 55).round(),
                          ),
                          blurRadius: 14 + (glow * 8),
                          spreadRadius: 1 + (glow * 2),
                        ),
                      ]
                    : [
                        BoxShadow(
                          color: colorScheme.shadow.withAlpha(10),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
              ),
              child: Text(
                '$dayNumber',
                style: GoogleFonts.outfit(
                  color: isActive
                      ? const Color(0xFF2D2110)
                      : colorScheme.onSurfaceVariant,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StudyDayCard extends StatelessWidget {
  const _StudyDayCard({
    required this.day,
    required this.isActive,
    required this.colorScheme,
    required this.onTap,
  });

  final ProgramDay day;
  final bool isActive;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: isActive
            ? Color.alphaBlend(
                _ScheduleScreenState._gold.withAlpha(22),
                colorScheme.surfaceContainerLowest,
              )
            : colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? _ScheduleScreenState._gold.withAlpha(210)
              : colorScheme.outlineVariant.withAlpha(180),
          width: isActive ? 1.35 : 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: isActive
                ? _ScheduleScreenState._gold.withAlpha(30)
                : colorScheme.shadow.withAlpha(6),
            blurRadius: isActive ? 20 : 10,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            splashColor: _ScheduleScreenState._gold.withAlpha(30),
            highlightColor: _ScheduleScreenState._gold.withAlpha(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 15, 14, 15),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (isActive) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _ScheduleScreenState._gold,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.today_rounded,
                                      size: 11,
                                      color: Color(0xFF2D2110),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'BUGÜN',
                                      style: GoogleFonts.outfit(
                                        color: const Color(0xFF2D2110),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Text(
                                '${day.number}. Gün',
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.outfit(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: isActive
                                      ? _ScheduleScreenState._deepGold
                                      : colorScheme.onSurfaceVariant.withAlpha(
                                          175,
                                        ),
                                  letterSpacing: 0,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        Text(
                          day.subject,
                          style: GoogleFonts.outfit(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: colorScheme.onSurface,
                            letterSpacing: 0,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          day.weekday,
                          style: GoogleFonts.outfit(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isActive
                                ? _ScheduleScreenState._deepGold.withAlpha(210)
                                : colorScheme.onSurfaceVariant.withAlpha(155),
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive
                          ? _ScheduleScreenState._gold.withAlpha(45)
                          : colorScheme.outlineVariant.withAlpha(60),
                    ),
                    child: Icon(
                      isActive
                          ? Icons.today_rounded
                          : Icons.chevron_right_rounded,
                      color: isActive
                          ? _ScheduleScreenState._deepGold
                          : colorScheme.onSurfaceVariant.withAlpha(155),
                      size: isActive ? 19 : 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
