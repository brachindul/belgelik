import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../app_services.dart';
import '../models.dart';

/// Masaustu (Windows/Linux/macOS) video oynatici - media_kit/libmpv tabanli.
/// Sunucudan akis (HTTP Range) ile oynatir; kaldigi yer /position'da saklanir.
class DesktopVideoPlayer extends StatefulWidget {
  final VideoDoc doc;
  // Saglanirsa appbar'da "yanda PDF ac" butonu gosterilir.
  final VoidCallback? onOpenPdf;
  // PDF yanindaki panelde saglanir: geri yerine kapat butonu gosterir ve
  // rotayi pop etmek yerine paneli kapatir.
  final VoidCallback? onClose;

  const DesktopVideoPlayer({
    super.key,
    required this.doc,
    this.onOpenPdf,
    this.onClose,
  });

  @override
  State<DesktopVideoPlayer> createState() => _DesktopVideoPlayerState();
}

class _DesktopVideoPlayerState extends State<DesktopVideoPlayer> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  Timer? _saveTimer;
  bool _seekedToStart = false;
  StreamSubscription<Duration>? _durSub;
  double _speed = 1.0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    int startSec = 0;
    try {
      final pos = await AppServices.instance.api.getPosition(widget.doc.id);
      if (pos != null) startSec = pos.page;
    } catch (_) {}

    // Sure hazir olunca bir kez kaldigi yere atla.
    _durSub = _player.stream.duration.listen((d) async {
      if (_seekedToStart || d.inSeconds <= 0) return;
      _seekedToStart = true;
      if (startSec > 0 && startSec < d.inSeconds - 2) {
        await _player.seek(Duration(seconds: startSec));
      }
    });

    await _player.open(
      Media(
        AppServices.instance.api.videoStreamUrl(widget.doc.id).toString(),
        httpHeaders: AppServices.instance.api.videoHeaders,
      ),
    );

    _saveTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _savePosition(),
    );
  }

  void _savePosition() {
    final sec = _player.state.position.inSeconds;
    if (sec <= 0) return;
    AppServices.instance.api.putPosition(widget.doc.id, sec).catchError((_) {});
  }

  void _setSpeed(double s) {
    _player.setRate(s);
    setState(() => _speed = s);
  }

  // Alt kontrol barindaki ileri/geri sarma butonlari icin: konumu [seconds]
  // kadar kaydirir (video sinirlarina kirpar).
  void _seekBy(int seconds) {
    final dur = _player.state.duration;
    var target = _player.state.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    _player.seek(target);
  }

  // Varsayilan media_kit alt barina 10 sn geri/ileri sarma butonlari ekler.
  MaterialDesktopVideoControlsThemeData _controlsTheme() {
    return MaterialDesktopVideoControlsThemeData(
      // Oynatilan konum cizgisini temanin birincil rengine cek (varsayilan
      // kirmizi yerine), uygulamayla uyumlu dursun.
      seekBarPositionColor: Theme.of(context).colorScheme.primary,
      seekBarThumbColor: Theme.of(context).colorScheme.primary,
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.replay_10),
          onPressed: () => _seekBy(-10),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.forward_10),
          onPressed: () => _seekBy(10),
        ),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        const MaterialDesktopFullscreenButton(),
      ],
    );
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _savePosition();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        // Panel modunda otomatik geri butonu tum rotayi kapatirdi; onun
        // yerine paneli kapatan acik bir kapat butonu goster.
        automaticallyImplyLeading: widget.onClose == null,
        leading: widget.onClose == null
            ? null
            : IconButton(
                tooltip: 'Video panelini kapat',
                icon: const Icon(Icons.close),
                onPressed: widget.onClose,
              ),
        title: Text(
          widget.doc.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          PopupMenuButton<double>(
            tooltip: 'Oynatma hızı',
            color: Colors.grey[900],
            icon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.speed, color: Colors.white, size: 20),
                const SizedBox(width: 2),
                Text(
                  '${_speed % 1 == 0 ? _speed.toInt() : _speed}x',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ],
            ),
            onSelected: _setSpeed,
            itemBuilder: (_) => _speeds
                .map(
                  (s) => PopupMenuItem<double>(
                    value: s,
                    child: Text(
                      '${s % 1 == 0 ? s.toInt() : s}x',
                      style: TextStyle(
                        color: s == _speed
                            ? Colors.lightBlueAccent
                            : Colors.white,
                        fontWeight:
                            s == _speed ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          if (widget.onOpenPdf != null)
            IconButton(
              tooltip: 'Yanda PDF aç',
              icon: const Icon(Icons.vertical_split),
              onPressed: widget.onOpenPdf,
            ),
        ],
      ),
      body: Center(
        child: MaterialDesktopVideoControlsTheme(
          normal: _controlsTheme(),
          fullscreen: _controlsTheme(),
          child: Video(
            controller: _controller,
            controls: MaterialDesktopVideoControls,
          ),
        ),
      ),
    );
  }
}
