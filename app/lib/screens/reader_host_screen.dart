import 'package:flutter/material.dart';

import '../models.dart';
import '../platform_adaptive.dart';
import 'desktop_video_player.dart';
import 'reader_screen.dart';
import 'split_divider.dart';
import 'video_picker_sheet.dart';
import 'video_player_screen.dart';

/// Genis ekran esigi: VideoPlayerScreen._kSplitMinWidth ile ayni deger.
const double _kSplitMinWidth = 720;
const double _kSplitMinHeight = 720;

/// PDF okuyucuyu barindirir ve genis ekranda PDF + video bolunmus gorunumunu
/// yonetir (VideoPlayerScreen'in aynasi: orada video acilip yanina PDF
/// geliyordu, burada PDF acik ve yanina video gelir). Kutuphane ekranlari
/// ReaderScreen yerine bunu acar.
class ReaderHostScreen extends StatefulWidget {
  final PdfDoc doc;
  final int? initialPage;

  const ReaderHostScreen({super.key, required this.doc, this.initialPage});

  @override
  State<ReaderHostScreen> createState() => _ReaderHostScreenState();
}

class _ReaderHostScreenState extends State<ReaderHostScreen> {
  VideoDoc? _video;
  double _mainFraction = 0.5;
  // GlobalKey: video acilip kapaninca okuyucu agacta yer degistirse de
  // state (sayfa, zoom, isaretlemeler) korunur.
  final GlobalKey _readerKey = GlobalKey();
  final GlobalKey _videoKey = GlobalKey();

  Future<void> _pickVideo() async {
    final video = await showVideoPicker(context, relatedPdf: widget.doc);
    if (video != null && mounted) setState(() => _video = video);
  }

  void _closeVideo() => setState(() => _video = null);

  Widget _buildReader({VoidCallback? onOpenVideo}) {
    return ReaderScreen(
      key: _readerKey,
      doc: widget.doc,
      initialPage: widget.initialPage,
      onOpenVideo: onOpenVideo,
    );
  }

  Widget _buildVideoPane() {
    final video = _video!;
    if (PlatformAdaptive.isDesktop) {
      return DesktopVideoPlayer(
        key: _videoKey,
        doc: video,
        onClose: _closeVideo,
      );
    }
    return MobileVideoPlayer(
      key: _videoKey,
      doc: video,
      paneMode: true,
      onClose: _closeVideo,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final splitAxis = size.width >= size.height
        ? Axis.horizontal
        : Axis.vertical;
    final canSplit = splitAxis == Axis.horizontal
        ? size.width >= _kSplitMinWidth
        : size.height >= _kSplitMinHeight;

    // Ekran cok dar/kisa moda donunce bolunmus gorunum sigmaz; video panelini
    // kapat.
    if (_video != null && !canSplit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _video != null) setState(() => _video = null);
      });
    }

    if (_video == null || !canSplit) {
      return _buildReader(onOpenVideo: canSplit ? _pickVideo : null);
    }

    // Video acik: yatayda solda okuyucu/sagda video, dikeyde ustte okuyucu/altta
    // video, ortada suruklenebilir ayrac.
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
            final minFirst = horizontal ? 220.0 : 240.0;
            final minSecond = horizontal ? 160.0 : 180.0;
            final firstExtent = ((total - dividerSize) * _mainFraction)
                .clamp(minFirst, total - minSecond)
                .toDouble();
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
                  SizedBox(width: firstExtent, child: _buildReader()),
                  SplitDragDivider(
                    thickness: dividerSize,
                    onDelta: updateFraction,
                  ),
                  Expanded(child: _buildVideoPane()),
                ],
              );
            }
            return Column(
              children: [
                SizedBox(height: firstExtent, child: _buildReader()),
                SplitDragDivider(
                  axis: Axis.vertical,
                  thickness: dividerSize,
                  onDelta: updateFraction,
                ),
                Expanded(child: _buildVideoPane()),
              ],
            );
          },
        ),
      ),
    );
  }
}
