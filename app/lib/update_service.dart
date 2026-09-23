import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_services.dart';

class UpdateInfo {
  final String version;
  final int build;
  final int? apkSize;
  const UpdateInfo(this.version, this.build, this.apkSize);

  String get sizeText => apkSize == null
      ? ''
      : ' (${(apkSize! / 1024 / 1024).toStringAsFixed(1)} MB)';
}

/// Tailscale uzerindeki sunucudan APK surum denetimi ve kurulumu.
class UpdateService {
  static bool _promptShown = false;

  /// Sunucudaki build numarasi kuruludan buyukse UpdateInfo doner, yoksa null.
  static Future<UpdateInfo?> check() async {
    if (!Platform.isAndroid) return null;
    final info = await AppServices.instance.api.getAppVersion();
    if (info == null) return null;
    final build = info['build'] as int?;
    final version = info['version'] as String?;
    if (build == null || version == null || info['apk_exists'] != true) {
      return null;
    }
    final pkg = await PackageInfo.fromPlatform();
    final current = int.tryParse(pkg.buildNumber) ?? 0;
    if (build <= current) return null;
    return UpdateInfo(version, build, info['apk_size'] as int?);
  }

  /// Acilista sessiz denetim; guncelleme varsa kurulum sorar.
  /// Oturum basina en fazla bir kez sorar.
  static Future<void> checkAndPromptOnce(BuildContext context) async {
    if (_promptShown) return;
    final info = await check();
    if (info == null || !context.mounted) return;
    _promptShown = true;
    await promptAndInstall(context, info);
  }

  static Future<void> promptAndInstall(
    BuildContext context,
    UpdateInfo info,
  ) async {
    final install = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Yeni sürüm hazır'),
        content: Text(
          'Sunucuda ${info.version} (${info.build}) sürümü var${info.sizeText}.\n'
          'İndirip kurmak ister misin?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Sonra'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('İndir ve kur'),
          ),
        ],
      ),
    );
    if (install != true || !context.mounted) return;
    await _downloadAndOpen(context);
  }

  static Future<void> _downloadAndOpen(BuildContext context) async {
    final progress = ValueNotifier<double?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('İndiriliyor…'),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, _) => LinearProgressIndicator(value: v),
        ),
      ),
    );
    try {
      final file = await AppServices.instance.api.downloadApk(
        onProgress: (received, total) {
          if (total > 0) progress.value = received / total;
        },
      );
      if (context.mounted) Navigator.pop(context); // progress dialogu kapat
      // Android paket kurucusunu acar (FileProvider'i open_filex saglar).
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kurulum başlatılamadı: ${result.message}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Güncelleme indirilemedi: $e')));
      }
    }
  }
}
