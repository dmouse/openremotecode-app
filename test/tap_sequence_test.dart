import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/ui/core/tap_sequence.dart';

void main() {
  test(
    'only the sixth tap opens settings and a new sequence starts afterward',
    () {
      final sequence = TapSequence();
      for (var tap = 0; tap < 5; tap++) {
        expect(sequence.register(Duration(milliseconds: tap * 200)), isFalse);
      }
      expect(sequence.register(const Duration(milliseconds: 1000)), isTrue);
      expect(sequence.register(const Duration(milliseconds: 1200)), isFalse);
    },
  );

  test('a gap of more than two seconds starts a fresh sequence', () {
    final sequence = TapSequence();
    for (var tap = 0; tap < 5; tap++) {
      sequence.register(Duration(milliseconds: tap * 100));
    }
    expect(sequence.register(const Duration(seconds: 3)), isFalse);
    for (var tap = 1; tap < 5; tap++) {
      expect(
        sequence.register(Duration(milliseconds: 3000 + tap * 100)),
        isFalse,
      );
    }
    expect(sequence.register(const Duration(milliseconds: 3500)), isTrue);
  });

  test(
    'explicit reset discards taps on lifecycle changes and dialog close',
    () {
      final sequence = TapSequence();
      for (var tap = 0; tap < 5; tap++) {
        sequence.register(Duration(milliseconds: tap * 100));
      }
      sequence.reset();
      expect(sequence.register(const Duration(milliseconds: 500)), isFalse);
    },
  );
}
