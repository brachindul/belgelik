import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../local_store.dart';

const _gold = Color(0xFFC5A880);
const _fireAmber = Color(0xFFFFB347);
const _fireOrange = Color(0xFFE65C00);

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late Future<_StatsData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  String _dateKey(DateTime d) => d.toIso8601String().substring(0, 10);

  Future<_StatsData> _load() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(const Duration(days: 60));
    final sessions = await LocalStore.listPomodoroSessions(
      fromDate: _dateKey(from),
      toDate: _dateKey(today),
    );
    final work = sessions.where((s) => s.phase == 'work').toList();
    final byDate = <String, int>{};
    final bySubject = <String, int>{};
    var total = 0;
    for (final s in work) {
      total += s.minutes;
      byDate[s.date] = (byDate[s.date] ?? 0) + s.minutes;
      bySubject[s.subject] = (bySubject[s.subject] ?? 0) + s.minutes;
    }
    final week = <_DayStat>[];
    var weekTotal = 0;
    for (var i = 6; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key = _dateKey(d);
      final minutes = byDate[key] ?? 0;
      weekTotal += minutes;
      week.add(_DayStat(key.substring(5), minutes));
    }
    var streak = 0;
    for (var i = 0; i < 365; i++) {
      final key = _dateKey(today.subtract(Duration(days: i)));
      if ((byDate[key] ?? 0) <= 0) break;
      streak++;
    }
    return _StatsData(
      todayMinutes: byDate[_dateKey(today)] ?? 0,
      weekMinutes: weekTotal,
      totalMinutes: total,
      pagesToday: await LocalStore.pagesReadOn(today),
      week: week,
      bySubject: bySubject.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)),
      streak: streak,
    );
  }

  String _hours(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '$m dk';
    if (m == 0) return '$h sa';
    return '$h sa $m dk';
  }

  Widget _metric(String title, String value, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _gold.withAlpha(85)),
          boxShadow: [
            BoxShadow(
              color: _gold.withAlpha(24),
              blurRadius: 22,
              spreadRadius: -8,
              offset: const Offset(0, 12),
            ),
            BoxShadow(
              color: scheme.shadow.withAlpha(10),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _gold.withAlpha(34),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 20, color: _gold),
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: GoogleFonts.outfit(
                fontSize: 16,
                fontWeight: FontWeight.w900,
                color: scheme.onSurface,
                letterSpacing: 0,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: GoogleFonts.outfit(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant.withAlpha(160),
                letterSpacing: 0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Çalışma İstatistikleri')),
      body: FutureBuilder<_StatsData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) return Center(child: Text('Hata: ${snap.error}'));
          final data = snap.data!;
          if (data.totalMinutes == 0) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bar_chart_rounded,
                    size: 64,
                    color: scheme.outline,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Henüz çalışma kaydı yok',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              Row(
                children: [
                  _metric(
                    'Bugün',
                    _hours(data.todayMinutes),
                    Icons.today_rounded,
                  ),
                  const SizedBox(width: 12),
                  _metric(
                    'Bu Hafta',
                    _hours(data.weekMinutes),
                    Icons.date_range_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _metric(
                    'Toplam Süre',
                    _hours(data.totalMinutes),
                    Icons.timer_rounded,
                  ),
                  const SizedBox(width: 12),
                  _metric(
                    'Bugün Sayfa',
                    '${data.pagesToday} sf',
                    Icons.menu_book_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 28),

              if (data.streak > 0) ...[
                Card(
                  elevation: 0,
                  color: Colors.transparent,
                  shadowColor: _gold.withAlpha(120),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _fireOrange.withAlpha(238),
                          _gold.withAlpha(232),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white.withAlpha(70)),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withAlpha(92),
                          blurRadius: 28,
                          spreadRadius: -6,
                          offset: const Offset(0, 12),
                        ),
                        BoxShadow(
                          color: _fireOrange.withAlpha(44),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(46),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: _fireAmber.withAlpha(110),
                                blurRadius: 20,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.local_fire_department_rounded,
                            color: _fireAmber,
                            size: 30,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${data.streak} Günlük Harika Seri!',
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Hiç ara vermeden çalışmaya devam ediyorsun.',
                                style: GoogleFonts.outfit(
                                  color: Colors.white.withAlpha(215),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 28),
              ],

              // Weekly Chart
              Text(
                'Son 7 Günlük İlerleme',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                height: 220,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: _WeekChart(days: data.week),
              ),
              const SizedBox(height: 28),

              // Subject Breakdown
              Text(
                'Derslere Göre Dağılım',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: scheme.primary,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  children: [
                    for (final e in data.bySubject)
                      _SubjectBar(
                        subject: e.key,
                        minutes: e.value,
                        maxMinutes: data.bySubject.first.value,
                        label: _hours(e.value),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StatsData {
  final int todayMinutes;
  final int weekMinutes;
  final int totalMinutes;
  final int pagesToday;
  final List<_DayStat> week;
  final List<MapEntry<String, int>> bySubject;
  final int streak;

  _StatsData({
    required this.todayMinutes,
    required this.weekMinutes,
    required this.totalMinutes,
    required this.pagesToday,
    required this.week,
    required this.bySubject,
    required this.streak,
  });
}

class _DayStat {
  final String label;
  final int minutes;
  _DayStat(this.label, this.minutes);
}

class _WeekChart extends StatelessWidget {
  final List<_DayStat> days;
  const _WeekChart({required this.days});

  @override
  Widget build(BuildContext context) {
    final maxValue = max(1, days.map((d) => d.minutes).fold(0, max));
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 20,
                    child: Center(
                      child: days[i].minutes > 0
                          ? Text(
                              days[i].minutes >= 60
                                  ? '${(days[i].minutes / 60).toStringAsFixed(1)}s'
                                  : '${days[i].minutes}d',
                              style: GoogleFonts.outfit(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurfaceVariant,
                                letterSpacing: 0,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Container(
                            width: 18,
                            decoration: BoxDecoration(
                              color: scheme.surfaceContainerHighest.withAlpha(
                                120,
                              ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: scheme.outlineVariant.withAlpha(120),
                              ),
                            ),
                          ),
                          FractionallySizedBox(
                            heightFactor: days[i].minutes / maxValue,
                            child: Container(
                              width: 18,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    i.isEven ? scheme.primary : _gold,
                                    (i.isEven ? scheme.primary : _gold)
                                        .withAlpha(86),
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: [
                                  BoxShadow(
                                    color: (i.isEven ? scheme.primary : _gold)
                                        .withAlpha(44),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    days[i].label,
                    style: GoogleFonts.outfit(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurfaceVariant.withAlpha(185),
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SubjectBar extends StatelessWidget {
  final String subject;
  final int minutes;
  final int maxMinutes;
  final String label;

  const _SubjectBar({
    required this.subject,
    required this.minutes,
    required this.maxMinutes,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = maxMinutes == 0 ? 0.0 : minutes / maxMinutes;
    final progress = value.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  subject,
                  style: GoogleFonts.outfit(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0,
                  ),
                ),
              ),
              Text(
                label,
                style: GoogleFonts.outfit(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest.withAlpha(150),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    height: 6,
                    width: constraints.maxWidth * progress,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [scheme.primary, _gold]),
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withAlpha(45),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
