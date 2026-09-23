import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_services.dart';
import '../config.dart';
import '../models.dart';
import '../update_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl = TextEditingController(
    text: AppConfig.baseUrl,
  );
  late final TextEditingController _tokenCtrl = TextEditingController(
    text: AppConfig.token,
  );
  DateTime? _examDate = DateTime.tryParse(AppConfig.examDate);
  bool _checkingUpdate = false;
  late Future<ServerStatus> _serverStatusFuture;

  @override
  void initState() {
    super.initState();
    _serverStatusFuture = AppServices.instance.api.getServerStatus();
  }

  Future<void> _checkUpdate() async {
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.check();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Uygulama güncel (veya sunucuya ulaşılamadı).'),
        ),
      );
      return;
    }
    await UpdateService.promptAndInstall(context, info);
  }

  void _refreshServerStatus() {
    setState(() { _serverStatusFuture = AppServices.instance.api.getServerStatus(); });
  }

  String _bytes(int? bytes) {
    if (bytes == null) return '-';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  String _duration(int? seconds) {
    if (seconds == null) return '-';
    final d = Duration(seconds: seconds);
    if (d.inDays > 0) return '${d.inDays} gün';
    if (d.inHours > 0) return '${d.inHours} saat';
    return '${d.inMinutes} dk';
  }

  String _backupAge(String? iso) {
    if (iso == null) return 'Yok';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '-';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inDays > 0) return '${diff.inDays} gün önce';
    if (diff.inHours > 0) return '${diff.inHours} saat önce';
    return 'Az önce';
  }

  Widget _serverStatusCard() {
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<ServerStatus>(
      future: _serverStatusFuture,
      builder: (context, snap) {
        final status = snap.data;
        final loading = snap.connectionState != ConnectionState.done;
        final reachable = status?.reachable == true;
        final backupDate = DateTime.tryParse(status?.lastBackup ?? '');
        final backupOld =
            backupDate != null &&
            DateTime.now().difference(backupDate.toLocal()).inDays >= 3;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      reachable ? Icons.check_circle : Icons.error_outline,
                      color: reachable ? Colors.green : scheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        loading
                            ? 'Sunucu durumu yükleniyor'
                            : reachable
                            ? 'Sunucu bağlı (${status!.latencyMs} ms)'
                            : 'Sunucuya ulaşılamıyor',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Yenile',
                      onPressed: _refreshServerStatus,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (reachable) ...[
                  Text(
                    'PDF: ${status!.pdfCount ?? 0} / ${_bytes(status.pdfTotalBytes)}',
                  ),
                  Text('İndeksli PDF: ${status.indexedDocs ?? 0}'),
                  Text('DB boyutu: ${_bytes(status.dbSizeBytes)}'),
                  Text('Çalışma süresi: ${_duration(status.uptimeS)}'),
                  Text(
                    'Son yedek: ${_backupAge(status.lastBackup)}',
                    style: TextStyle(
                      color: backupOld ? Colors.orange.shade800 : null,
                      fontWeight: backupOld ? FontWeight.w700 : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        try {
                          await AppServices.instance.api.triggerBackup();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Yedekleme başlatıldı'),
                            ),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('Hata: $e')));
                        }
                      },
                      icon: const Icon(Icons.backup),
                      label: const Text('Şimdi yedek al'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _serverStatusCard(),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'Sunucu adresi',
              hintText: 'http://localhost:8000',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenCtrl,
            decoration: const InputDecoration(labelText: 'Token'),
          ),
          const SizedBox(height: 24),
          const Align(alignment: Alignment.centerLeft, child: Text('Tema')),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('Sistem')),
              ButtonSegment(value: ThemeMode.light, label: Text('Açık')),
              ButtonSegment(value: ThemeMode.dark, label: Text('Koyu')),
            ],
            selected: {AppConfig.themeNotifier.value},
            onSelectionChanged: (s) {
              AppConfig.setTheme(s.first);
              setState(() {});
            },
          ),
          const SizedBox(height: 24),
          const Align(alignment: Alignment.centerLeft, child: Text('Okuyucu')),
          const SizedBox(height: 8),
          Text(
            AppConfig.panLockPercent == 0
                ? 'Kaydırma yön kilidi: her zaman açık'
                : 'Kaydırma yön kilidi: fit zoom +%${AppConfig.panLockPercent} üzeri',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            'Zoom yapılıyken dikey/yatay kaydırma, jestin baskın eksenine '
            'kilitlenir. Eşik ne kadar düşükse kilit o kadar erken devreye girer.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Slider(
            value: AppConfig.panLockPercent.toDouble(),
            min: 0,
            max: 50,
            divisions: 10,
            label: AppConfig.panLockPercent == 0
                ? 'Her zaman'
                : '%${AppConfig.panLockPercent}',
            onChanged: (v) =>
                setState(() => AppConfig.panLockPercent = v.round()),
            onChangeEnd: (v) => AppConfig.setPanLockPercent(v.round()),
          ),
          const SizedBox(height: 24),
          const Align(alignment: Alignment.centerLeft, child: Text('Sınav')),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  _examDate == null
                      ? 'Tarih seçilmedi'
                      : 'Tarih: ${_examDate!.toIso8601String().substring(0, 10)}',
                ),
              ),
              TextButton(
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _examDate ?? DateTime(now.year, 12, 19),
                    firstDate: DateTime(now.year - 1),
                    lastDate: DateTime(now.year + 5),
                  );
                  if (picked != null) setState(() => _examDate = picked);
                },
                child: const Text('Tarih seç'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Güncelleme'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (_, snap) => Text(
                    snap.hasData
                        ? 'Sürüm: ${snap.data!.version} (${snap.data!.buildNumber})'
                        : 'Sürüm: …',
                  ),
                ),
              ),
              TextButton(
                onPressed: _checkingUpdate ? null : _checkUpdate,
                child: Text(
                  _checkingUpdate ? 'Denetleniyor…' : 'Güncelleme denetle',
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () async {
              await AppConfig.save(_urlCtrl.text, _tokenCtrl.text);
              await AppConfig.setExamDate(
                _examDate == null
                    ? ''
                    : _examDate!.toIso8601String().substring(0, 10),
              );
              if (context.mounted) Navigator.pop(context, true);
            },
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
  }
}
