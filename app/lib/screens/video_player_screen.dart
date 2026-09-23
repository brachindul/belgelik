import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../app_services.dart';
import '../models.dart';
import '../platform_adaptive.dart';
import 'desktop_video_player.dart';
import 'pdf_picker_sheet.dart';
import 'reader_screen.dart';
import 'split_divider.dart';

/// Genis ekran (tablet yatay / masaustu) esigi: bu genislikten itibaren
/// video yaninda PDF acma (bolunmus gorunum) ozelligi sunulur.
const double _kSplitMinWidth = 720;
const double _kSplitMinHeight = 720;

/// Platforma gore dogru oynaticiyi secer ve genis ekranda video + PDF
/// bolunmus gorunumunu yonetir (ortadaki ayrac suruklenebilir).
class VideoPlayerScreen extends StatefulWidget {
  final VideoDoc doc;

  const VideoPlayerScreen({super.key, required this.doc});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  PdfDoc? _pdf;
  double _mainFraction = 0.5;
  // GlobalKey: PDF acilip kapaninca oynatici agacta yer degistirse de
  // state (oynatma konumu) korunur, video bastan baslamaz.
  final GlobalKey _playerKey = GlobalKey();

  Widget _buildPlayer({required bool paneMode, VoidCallback? onOpenPdf}) {
    if (PlatformAdaptive.isDesktop) {
      return DesktopVideoPlayer(
        key: _playerKey,
        doc: widget.doc,
        onOpenPdf: onOpenPdf,
      );
    }
    return MobileVideoPlayer(
      key: _playerKey,
      doc: widget.doc,
      onOpenPdf: onOpenPdf,
      paneMode: paneMode,
    );
  }

  Future<void> _pickPdf() async {
    final pdf = await showPdfPicker(context, relatedVideo: widget.doc);
    if (pdf != null && mounted) setState(() => _pdf = pdf);
  }

  void _closePdf() => setState(() => _pdf = null);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final splitAxis = size.width >= size.height
        ? Axis.horizontal
        : Axis.vertical;
    final canSplit = splitAxis == Axis.horizontal
        ? size.width >= _kSplitMinWidth
        : size.height >= _kSplitMinHeight;

    // Ekran cok dar/kisa moda donunce bolunmus gorunum sigmaz; PDF panelini
    // otomatik kapatip videoyu tam ekrana al.
    if (_pdf != null && !canSplit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pdf != null) setState(() => _pdf = null);
      });
    }

    // PDF kapaliyken (veya dar ekranda): normal tam oynatici.
    if (_pdf == null || !canSplit) {
      return _buildPlayer(
        paneMode: false,
        onOpenPdf: canSplit ? _pickPdf : null,
      );
    }

    // PDF acik: yatayda solda video/sagda okuyucu, dikeyde ustte video/altta
    // okuyucu, ortada suruklenebilir ayrac.
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            const dividerSize = 10.0;
            final horizontal = splitAxis == Axis.horizontal;
            final total = horizontal
                ? constraints.maxWidth
                : constraints.maxHeight;
            final minFirst = horizontal ? 160.0 : 180.0;
            final minSecond = horizontal ? 220.0 : 240.0;
            final firstExtent = ((total - dividerSize) * _mainFraction)
                .clamp(minFirst, total - minSecond)
                .toDouble();
            final reader = ReaderScreen(
              key: ValueKey('split-reader-${_pdf!.id}'),
              doc: _pdf!,
              onClose: _closePdf,
            );
            void updateFraction(double delta) {
              setState(() {
                _mainFraction = ((firstExtent + delta) / (total - dividerSize))
                    .clamp(0.2, 0.8)
                    .toDouble();
              });
            }

            if (horizontal) {
              return Row(
                children: [
                  SizedBox(
                    width: firstExtent,
                    child: _buildPlayer(paneMode: true),
                  ),
                  SplitDragDivider(
                    thickness: dividerSize,
                    onDelta: updateFraction,
                  ),
                  Expanded(child: reader),
                ],
              );
            }
            return Column(
              children: [
                SizedBox(
                  height: firstExtent,
                  child: _buildPlayer(paneMode: true),
                ),
                SplitDragDivider(
                  axis: Axis.vertical,
                  thickness: dividerSize,
                  onDelta: updateFraction,
                ),
                Expanded(child: reader),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Tam ekran hisli, otomatik gizlenen kontrollu video oynatici (mobil).
/// - Sunucudan akis (HTTP Range) ile oynatir, indirme yapmaz.
/// - Kontroller (ust bar + orta butonlar + alt seek bari) videonun uzerinde
///   overlay olarak durur ve ~3.5 sn sonra otomatik gizlenir; dokununca acilir.
/// - Yatayda status bar gizlenir (immersive), dikeyde normal.
/// - Kaldigi yer /position endpoint'inde saniye olarak saklanir.
class MobileVideoPlayer extends StatefulWidget {
  final VideoDoc doc;
  // Genis ekranda ust barda "yanda PDF ac" butonu gosterilir.
  final VoidCallback? onOpenPdf;
  // Bolunmus gorunumde (yanda PDF) true: tam ekran immersive devre disi.
  final bool paneMode;
  // PDF yanindaki panelde saglanir: geri yerine kapat butonu gosterir ve
  // rotayi pop etmek yerine paneli kapatir.
  final VoidCallback? onClose;

  const MobileVideoPlayer({
    super.key,
    required this.doc,
    this.onOpenPdf,
    this.paneMode = false,
    this.onClose,
  });

  @override
  State<MobileVideoPlayer> createState() => _MobileVideoPlayerState();
}

class _MobileVideoPlayerState extends State<MobileVideoPlayer> {
  static const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  static const _channel = MethodChannel(
    'com.belgelik.app/media_control',
  );

  VideoPlayerController? _controller;
  String? _error;
  Timer? _saveTimer;
  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _scrubbing = false;
  Duration _scrubTarget = Duration.zero;
  double _speed = 1.0;
  bool _wasLandscape = false;

  // UI yeniden çizim eşiği (saniye çözünürlüğü). Oynatma sırasında her frame'de
  // (~20-60/sn) listener tetiklense de setState yalnızca saniye veya isPlaying
  // değiştiğinde çağrılır; böylece gereksiz widget yeniden çizimi önlenir.
  int _lastUiSec = -1;
  bool? _lastUiIsPlaying;

  // Native bildirim servisine gönderim eşiği. Oynatma sırasında servis her
  // saniye baştan kuruluyordu (NotificationManager wake lock al-bırak).
  // isPlaying/duration değişimi ANINDA gönderilir; pozisyon ise ya >=1500ms
  // süre geçtiyse ya da position delta >=1500ms ise (seek tespiti).
  int _lastSentPositionMs = -1;
  bool? _lastSentIsPlaying;
  int _lastSentDurationMs = -1;
  DateTime? _lastSentAt;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_handleNativeMethod);
    // Bu ekranda yatay yon serbest (sadece mobil; masaustunde pencere serbest).
    if (!PlatformAdaptive.isDesktop) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _init();
  }

  Future<void> _handleNativeMethod(MethodCall call) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    switch (call.method) {
      case 'onAction':
        final action = call.arguments as String;
        if (action == 'play') {
          if (!c.value.isPlaying) {
            _togglePlay();
          }
        } else if (action == 'pause') {
          if (c.value.isPlaying) {
            _togglePlay();
          }
        } else if (action == 'rewind') {
          _seekBy(-10);
        } else if (action == 'forward') {
          _seekBy(10);
        }
        break;
    }
  }

  // Native bildirim servisine güncelleme gönderir; ancak yalnızca anlamlı bir
  // değişim varsa. Oynatma sırasında her saniye startForegroundService çağrısı
  // yapılıyordu (lastStartId saniyede 1 artıyordu); bu sürümde:
  //  - isPlaying değiştiyse veya duration değiştiyse -> anında gönder
  //  - yoksa >=1500ms geçtiyse veya pozisyon delta >=1500ms ise -> gönder
  //  - aksi halde atla (pause durumunda oynatıcı sabit kaldığı için gereksiz)
  void _updateNativeService({bool force = false}) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    final positionMs = c.value.position.inMilliseconds;
    final isPlaying = c.value.isPlaying;
    final durationMs = c.value.duration.inMilliseconds;
    final now = DateTime.now();

    if (!force) {
      final isPlayingChanged = _lastSentIsPlaying != isPlaying;
      final durationChanged = _lastSentDurationMs != durationMs;
      final elapsed = _lastSentAt == null
          ? const Duration(seconds: 60)
          : now.difference(_lastSentAt!);
      final positionDelta = (positionMs - _lastSentPositionMs).abs();

      final shouldSkip =
          !isPlayingChanged &&
          !durationChanged &&
          elapsed.inMilliseconds < 1500 &&
          positionDelta < 1500;
      if (shouldSkip) return;
    }

    _lastSentPositionMs = positionMs;
    _lastSentIsPlaying = isPlaying;
    _lastSentDurationMs = durationMs;
    _lastSentAt = now;

    _channel.invokeMethod('updateService', {
      'title': widget.doc.name,
      'isPlaying': isPlaying,
      'position': positionMs,
      'duration': durationMs,
    });
  }

  Future<void> _init() async {
    try {
      final c = VideoPlayerController.networkUrl(
        AppServices.instance.api.videoStreamUrl(widget.doc.id),
        httpHeaders: AppServices.instance.api.videoHeaders,
        videoPlayerOptions: VideoPlayerOptions(
          allowBackgroundPlayback: true,
          mixWithOthers: true,
        ),
      );
      _controller = c;
      await c.initialize();

      int startSec = 0;
      try {
        final pos = await AppServices.instance.api.getPosition(widget.doc.id);
        if (pos != null) startSec = pos.page;
      } catch (_) {}
      final dur = c.value.duration.inSeconds;
      if (startSec > 0 && startSec < dur - 2) {
        await c.seekTo(Duration(seconds: startSec));
      }

      c.addListener(_onTick);
      await c.play();
      // İlk bildirimi deterministic biçimde hemen post et (throttle'a takılmadan).
      _updateNativeService(force: true);

      _saveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _savePosition(),
      );
      _scheduleHide();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _onTick() {
    if (!mounted || _scrubbing) return;

    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    final currentSec = c.value.position.inSeconds;
    final currentIsPlaying = c.value.isPlaying;

    // UI yeniden çizimi: yalnızca saniye çözünürlüğü veya isPlaying değiştiyse.
    // Oynatma sırasında listener her frame'de tetiklendiği için (~20-60/sn),
    // bu eşik olmadan saniyede onlarca kez widget ağacı yeniden çizilirdi.
    if (currentSec != _lastUiSec || currentIsPlaying != _lastUiIsPlaying) {
      _lastUiSec = currentSec;
      _lastUiIsPlaying = currentIsPlaying;
      setState(() {});
    }

    // Native bildirim servisi: yalnızca anlamlı değişimde (throttle _updateNativeService içinde).
    _updateNativeService();
  }

  void _savePosition() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final sec = c.value.position.inSeconds;
    if (sec <= 0) return;
    AppServices.instance.api.putPosition(widget.doc.id, sec).catchError((_) {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _keepControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      if (c.value.isPlaying) {
        c.pause();
        _hideTimer?.cancel();
        _controlsVisible = true;
      } else {
        c.play();
        _scheduleHide();
      }
    });
    // Play/pause anında bildirime yansımalı (throttle'a takılmamalı).
    _updateNativeService(force: true);
  }

  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null) return;
    final dur = c.value.duration;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > dur) target = dur;
    c.seekTo(target);
    _keepControls();
    // Sarma anında bildirim konumunu güncellemeli.
    _updateNativeService(force: true);
  }

  void _setSpeed(double s) {
    _controller?.setPlaybackSpeed(s);
    setState(() => _speed = s);
    _keepControls();
  }

  // Ekran otomatik dondurme kapaliyken elle yon degistirmek icin: verilen yonu
  // zorlar. Ekrandan cikilinca dispose'ta serbest birakilir.
  void _forceOrientation(bool landscape) {
    if (PlatformAdaptive.isDesktop) return;
    SystemChrome.setPreferredOrientations(
      landscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
    _keepControls();
  }

  @override
  void dispose() {
    _channel.invokeMethod('stopService');
    _channel.setMethodCallHandler(null);
    _saveTimer?.cancel();
    _hideTimer?.cancel();
    _savePosition();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    if (!PlatformAdaptive.isDesktop) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        final landscape = orientation == Orientation.landscape;
        if (landscape != _wasLandscape) {
          _wasLandscape = landscape;
          // Bolunmus gorunumde (yanda PDF) tam ekran immersive kapali; iki
          // panel de normal sistem cubuklariyla gorunur.
          if (!PlatformAdaptive.isDesktop && !widget.paneMode) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              SystemChrome.setEnabledSystemUIMode(
                landscape
                    ? SystemUiMode.immersiveSticky
                    : SystemUiMode.edgeToEdge,
              );
            });
          }
        }
        return Scaffold(backgroundColor: Colors.black, body: _body(landscape));
      },
    );
  }

  Widget _body(bool landscape) {
    if (_error != null) {
      return SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 4,
              left: 4,
              child: IconButton(
                icon: Icon(
                  widget.onClose != null ? Icons.close : Icons.arrow_back,
                  color: Colors.white,
                ),
                onPressed: widget.onClose ?? () => Navigator.pop(context),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      color: Colors.redAccent,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Video açılamadı\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
          if (c.value.isBuffering)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          _controlsOverlay(c, landscape),
        ],
      ),
    );
  }

  Widget _controlsOverlay(VideoPlayerController c, bool landscape) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedOpacity(
      opacity: _controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0x99000000),
                Color(0x22000000),
                Color(0x00000000),
                Color(0x22000000),
                Color(0xB3000000),
              ],
              stops: [0.0, 0.2, 0.5, 0.8, 1.0],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                _topBar(),
                Expanded(child: _centerButtons(c)),
                _bottomBar(c, scheme),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        IconButton(
          tooltip: widget.onClose != null ? 'Video panelini kapat' : null,
          icon: Icon(
            widget.onClose != null ? Icons.close : Icons.arrow_back,
            color: Colors.white,
          ),
          onPressed: widget.onClose ?? () => Navigator.pop(context),
        ),
        Expanded(
          child: Text(
            widget.doc.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (widget.onOpenPdf != null)
          IconButton(
            tooltip: 'Yanda PDF aç',
            icon: const Icon(Icons.vertical_split, color: Colors.white),
            onPressed: widget.onOpenPdf,
          ),
        if (!PlatformAdaptive.isDesktop && !widget.paneMode)
          IconButton(
            tooltip: _wasLandscape ? 'Dikey çevir' : 'Yatay çevir',
            icon: Icon(
              _wasLandscape
                  ? Icons.stay_current_portrait
                  : Icons.stay_current_landscape,
              color: Colors.white,
            ),
            onPressed: () => _forceOrientation(!_wasLandscape),
          ),
        PopupMenuButton<double>(
          tooltip: 'Hız',
          color: const Color(0xFF1E1E1E),
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
                      fontWeight: s == _speed
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _centerButtons(VideoPlayerController c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _roundButton(Icons.replay_10, 34, () => _seekBy(-10)),
        const SizedBox(width: 28),
        _roundButton(
          c.value.isPlaying ? Icons.pause : Icons.play_arrow,
          52,
          _togglePlay,
        ),
        const SizedBox(width: 28),
        _roundButton(Icons.forward_10, 34, () => _seekBy(10)),
      ],
    );
  }

  Widget _roundButton(IconData icon, double size, VoidCallback onTap) {
    return Material(
      color: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }

  Widget _bottomBar(VideoPlayerController c, ColorScheme scheme) {
    final dur = c.value.duration;
    final pos = _scrubbing ? _scrubTarget : c.value.position;
    final maxMs = dur.inMilliseconds
        .toDouble()
        .clamp(1, double.infinity)
        .toDouble();
    final valMs = pos.inMilliseconds.toDouble().clamp(0, maxMs).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: [
          Text(
            _fmt(pos),
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: scheme.primary,
                inactiveTrackColor: Colors.white30,
                thumbColor: scheme.primary,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: Slider(
                min: 0,
                max: maxMs,
                value: valMs,
                onChangeStart: (v) {
                  _scrubbing = true;
                  _scrubTarget = Duration(milliseconds: v.round());
                  _hideTimer?.cancel();
                },
                onChanged: (v) {
                  setState(
                    () => _scrubTarget = Duration(milliseconds: v.round()),
                  );
                },
                onChangeEnd: (v) async {
                  final t = Duration(milliseconds: v.round());
                  await c.seekTo(t);
                  _scrubbing = false;
                  _scheduleHide();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
          Text(
            _fmt(dur),
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
