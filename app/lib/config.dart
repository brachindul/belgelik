import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const _kBaseUrl = 'base_url';
  static const _kToken = 'token';
  // Token artik guvenli depoda (Android keystore / iOS keychain / Windows
  // credential store). Eski prefs'teki token ilk acilista buraya tasinir.
  static const _secure = FlutterSecureStorage();

  /// Token'i guvenli depodan okur; yoksa eski prefs'ten tasir. Guvenli depo
  /// erisilemezse (nadir; or. bazi Linux) prefs'e sessiz geri duser.
  static Future<String> _loadToken(SharedPreferences prefs) async {
    try {
      final secure = await _secure.read(key: _kToken);
      if (secure != null && secure.isNotEmpty) return secure;
      final legacy = prefs.getString(_kToken) ?? '';
      if (legacy.isNotEmpty) {
        // Tek yonlu migrasyon: guvenli depoya yaz, prefs'ten sil.
        await _secure.write(key: _kToken, value: legacy);
        await prefs.remove(_kToken);
      }
      return legacy;
    } catch (_) {
      return prefs.getString(_kToken) ?? '';
    }
  }
  static const _kThemeMode = 'theme_mode';
  static final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(
    ThemeMode.system,
  );
  static const _kWorkMin = 'work_min';
  static const _kBreakMin = 'break_min';
  static const _kViewMode = 'view_mode';
  static const _kReadingTargetPages = 'reading_target_pages';
  static const _kExamDate = 'exam_date';
  static const _kNightMode = 'night_mode';
  static const _kDimLevel = 'dim_level';
  static const _kPanLockPercent = 'pan_lock_percent';
  static const _kFeatures = 'profile_features';

  // PDF gorunum modu: 'auto' | 'single' | 'twoVertical'
  static String viewMode = 'auto';

  // Profilin acik ozellikleri (sunucu /profile'dan gelir). Sekme gorunurlugunu
  // belirler. Varsayilan tam liste: tek-profilli/eski kurulumlar etkilenmez.
  static const List<String> allFeatures = [
    'library',
    'videos',
    'program',
    'pomodoro',
  ];
  static final ValueNotifier<List<String>> featuresNotifier = ValueNotifier(
    allFeatures,
  );
  static List<String> get features => featuresNotifier.value;
  static bool hasFeature(String f) => features.contains(f);

  static String baseUrl = 'http://localhost:8000';
  static String token = '';
  static const _kDeviceId = 'device_id';
  static String deviceId = '';
  static int workMinutes = 50;
  static int breakMinutes = 10;
  static int readingTargetPages = 50;
  static String examDate = '2026-12-19';
  static String nightMode = 'off'; // off | dim | sepia | invert
  static double dimLevel = 0.35; // 0.1 - 0.7
  // Kaydirma yon kilidi esigi: fit zoom'un yuzde kac ustunde devreye girsin.
  // 0 = zoom miktarina bakmadan her zaman kilitli.
  static int panLockPercent = 15; // 0 - 50

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = prefs.getString(_kBaseUrl) ?? baseUrl;
    token = await _loadToken(prefs);
    deviceId = prefs.getString(_kDeviceId) ?? '';
    if (deviceId.isEmpty) {
      final suffix = Random()
          .nextInt(0x1000000)
          .toRadixString(16)
          .padLeft(6, '0');
      deviceId = 'cihaz-${DateTime.now().millisecondsSinceEpoch}-$suffix';
      await prefs.setString(_kDeviceId, deviceId);
    }
    workMinutes = prefs.getInt(_kWorkMin) ?? 50;
    breakMinutes = prefs.getInt(_kBreakMin) ?? 10;
    readingTargetPages = prefs.getInt(_kReadingTargetPages) ?? 50;
    final tm = prefs.getString(_kThemeMode) ?? 'system';
    themeNotifier.value = _parseTheme(tm);
    viewMode = prefs.getString(_kViewMode) ?? 'auto';
    examDate = prefs.getString(_kExamDate) ?? examDate;
    nightMode = prefs.getString(_kNightMode) ?? 'off';
    dimLevel = prefs.getDouble(_kDimLevel) ?? 0.35;
    panLockPercent = prefs.getInt(_kPanLockPercent) ?? 15;
    final cachedFeatures = prefs.getStringList(_kFeatures);
    if (cachedFeatures != null && cachedFeatures.isNotEmpty) {
      featuresNotifier.value = cachedFeatures;
    }
  }

  /// Sunucu /profile yanitiyla ozellikleri gunceller ve onbellege alir.
  static Future<void> setFeatures(List<String> f) async {
    if (f.isEmpty) return;
    featuresNotifier.value = List<String>.from(f);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kFeatures, featuresNotifier.value);
  }

  static Future<void> setPanLockPercent(int v) async {
    panLockPercent = v.clamp(0, 50);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kPanLockPercent, panLockPercent);
  }

  static Future<void> setViewMode(String mode) async {
    viewMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kViewMode, mode);
  }

  static Future<void> save(String newBaseUrl, String newToken) async {
    final prefs = await SharedPreferences.getInstance();
    baseUrl = newBaseUrl.trim();
    token = newToken.trim();
    await prefs.setString(_kBaseUrl, baseUrl);
    try {
      await _secure.write(key: _kToken, value: token);
      await prefs.remove(_kToken); // eski konumda kalinti birakma
    } catch (_) {
      await prefs.setString(_kToken, token); // guvenli depo yoksa geri dus
    }
  }

  static Future<void> savePomodoro(int work, int brk) async {
    final prefs = await SharedPreferences.getInstance();
    workMinutes = work;
    breakMinutes = brk;
    await prefs.setInt(_kWorkMin, work);
    await prefs.setInt(_kBreakMin, brk);
  }

  static Future<void> saveReadingTargetPages(int pages) async {
    final prefs = await SharedPreferences.getInstance();
    readingTargetPages = pages < 1 ? 1 : pages;
    await prefs.setInt(_kReadingTargetPages, readingTargetPages);
  }

  static ThemeMode _parseTheme(String s) {
    switch (s) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _themeToString(ThemeMode m) {
    switch (m) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static Future<void> setTheme(ThemeMode mode) async {
    themeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, _themeToString(mode));
  }

  static Future<void> setExamDate(String dateIso) async {
    examDate = dateIso.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kExamDate, examDate);
    // Eski surumlerden kalan sinav adi kaydini temizle (alan kaldirildi).
    await prefs.remove('exam_name');
  }

  static int? examDaysLeft() {
    if (examDate.isEmpty) return null;
    final d = DateTime.tryParse(examDate);
    if (d == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    return target.difference(today).inDays;
  }

  static Future<void> setNightMode(String m) async {
    nightMode = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNightMode, m);
  }

  static Future<void> setDimLevel(double v) async {
    dimLevel = v.clamp(0.1, 0.7);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDimLevel, dimLevel);
  }
}
