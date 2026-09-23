import 'package:flutter_test/flutter_test.dart';
import 'package:belgelik/platform_adaptive.dart';

void main() {
  group('PlatformAdaptive', () {
    test('desktopBreakpoint is 900', () {
      expect(PlatformAdaptive.desktopBreakpoint, 900);
    });

    test('isWide returns true at and above breakpoint', () {
      expect(PlatformAdaptive.isWide(900), isTrue);
      expect(PlatformAdaptive.isWide(899), isFalse);
      expect(PlatformAdaptive.isWide(1280), isTrue);
    });
  });
}
