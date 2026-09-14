/// Uses monotonic elapsed time, with no timers or rebuilds on individual taps.
final class TapSequence {
  static const maxGap = Duration(seconds: 2);
  Duration? _lastTap;
  int _count = 0;

  bool register(Duration elapsed) {
    final last = _lastTap;
    if (last == null || elapsed - last > maxGap || elapsed < last) {
      _count = 0;
    }
    _lastTap = elapsed;
    _count++;
    if (_count < 6) return false;
    reset();
    return true;
  }

  void reset() {
    _count = 0;
    _lastTap = null;
  }
}
