import 'package:flutter/material.dart';

/// Bolunmus gorunumde (video+PDF / PDF+video) iki paneli ayiran,
/// ana eksende suruklenebilir ayrac.
class SplitDragDivider extends StatelessWidget {
  /// Panellerin dizildigi eksen. Row icin horizontal, Column icin vertical.
  final Axis axis;
  final double thickness;
  final ValueChanged<double> onDelta;

  const SplitDragDivider({
    super.key,
    this.axis = Axis.horizontal,
    required this.thickness,
    required this.onDelta,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final horizontal = axis == Axis.horizontal;
    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeLeftRight
          : SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: horizontal ? (d) => onDelta(d.delta.dx) : null,
        onVerticalDragUpdate: horizontal ? null : (d) => onDelta(d.delta.dy),
        child: SizedBox(
          width: horizontal ? thickness : double.infinity,
          height: horizontal ? double.infinity : thickness,
          child: Container(
            color: scheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Container(
              width: horizontal ? 3 : 44,
              height: horizontal ? 44 : 3,
              decoration: BoxDecoration(
                color: scheme.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
