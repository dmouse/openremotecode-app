import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'activity_presentation.dart';

/// A single clock, with no ticks unless a running glyph is actually visible.
/// Viewport checks run on layout/scroll/lifecycle changes, never on clock ticks.
class ActivityAnimations extends StatefulWidget {
  const ActivityAnimations({
    super.key,
    required this.enabled,
    required this.child,
  });
  final bool enabled;
  final Widget child;
  @override
  State<ActivityAnimations> createState() => _ActivityAnimationsState();
}

class _ActivityAnimationsState extends State<ActivityAnimations>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController clock = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  final slots = <_ActivityPulseState>{};
  bool scheduled = false, allowed = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state != AppLifecycleState.resumed) {
      allowed = false;
      clock.stop();
    }
    setState(() {});
  }

  void schedule() {
    if (scheduled || !mounted) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (!mounted) return;
      var any = false;
      for (final slot in slots.toList()) {
        if (!slot.mounted) continue;
        final box = slot.context.findRenderObject();
        var visible =
            allowed &&
            slot.widget.running &&
            slot.widget.animate &&
            box is RenderBox &&
            box.attached &&
            box.hasSize;
        if (visible) {
          final rect = box.localToGlobal(Offset.zero) & box.size;
          final viewport = RenderAbstractViewport.maybeOf(box);
          final scope = context.findRenderObject();
          if (scope is RenderBox && scope.hasSize) {
            visible = rect.overlaps(
              scope.localToGlobal(Offset.zero) & scope.size,
            );
          }
          final viewportBox = viewport is RenderBox
              ? viewport as RenderBox
              : null;
          if (viewportBox != null && viewportBox.hasSize) {
            visible =
                visible &&
                rect.overlaps(
                  viewportBox.localToGlobal(Offset.zero) & viewportBox.size,
                );
          }
        }
        slot.visibility(visible);
        any |= visible;
      }
      if (any && !clock.isAnimating) clock.repeat();
      if (!any && clock.isAnimating) clock.stop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    allowed =
        widget.enabled &&
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true) &&
        !MediaQuery.disableAnimationsOf(context) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    if (!allowed) clock.stop();
    schedule();
    return _AnimationScope(
      owner: this,
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          schedule();
          return false;
        },
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            schedule();
            return false;
          },
          child: widget.child,
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    clock.dispose();
    super.dispose();
  }
}

class _AnimationScope extends InheritedWidget {
  const _AnimationScope({required this.owner, required super.child});
  final _ActivityAnimationsState owner;
  @override
  bool updateShouldNotify(_AnimationScope oldWidget) =>
      oldWidget.owner != owner;
}

class ActivitySpinner extends StatelessWidget {
  const ActivitySpinner({
    super.key,
    required this.running,
    required this.color,
    required this.icon,
    this.animate = true,
  });
  final bool running;
  final Color color;
  final Widget icon;
  final bool animate;
  @override
  Widget build(BuildContext context) => ActivityPulse(
    running: running,
    animate: animate,
    color: color,
    icon: icon,
  );
}

enum ActivityPulseKind { spinner, dots }

class ActivityPulse extends StatefulWidget {
  const ActivityPulse({
    super.key,
    required this.running,
    required this.color,
    this.icon = const SizedBox.shrink(),
    this.animate = true,
    this.kind = ActivityPulseKind.spinner,
  });
  final bool running, animate;
  final Color color;
  final Widget icon;
  final ActivityPulseKind kind;
  @override
  State<ActivityPulse> createState() => _ActivityPulseState();
}

class _ActivityPulseState extends State<ActivityPulse> {
  _ActivityAnimationsState? owner;
  bool visible = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context
        .dependOnInheritedWidgetOfExactType<_AnimationScope>()
        ?.owner;
    if (next != owner) {
      owner?.slots.remove(this);
      owner?.schedule();
      owner = next;
      if (widget.running && widget.animate) owner?.slots.add(this);
    }
    owner?.schedule();
  }

  @override
  void didUpdateWidget(ActivityPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.running && widget.animate) {
      owner?.slots.add(this);
    } else {
      owner?.slots.remove(this);
      visible = false;
    }
    owner?.schedule();
  }

  void visibility(bool next) {
    if (visible != next) setState(() => visible = next);
  }

  @override
  Widget build(BuildContext context) {
    final child = SizedBox(
      width:
          ActivityPresentation.scaledIconSize(context) *
          (widget.kind == ActivityPulseKind.dots ? 2 : 1),
      height: ActivityPresentation.scaledIconSize(context),
      child: widget.running
          ? CustomPaint(
              painter: widget.kind == ActivityPulseKind.dots
                  ? _DotsPainter(widget.color, visible ? owner?.clock : null)
                  : _SpinnerPainter(
                      widget.color,
                      visible ? owner?.clock : null,
                    ),
            )
          : widget.icon,
    );
    return widget.running && visible ? RepaintBoundary(child: child) : child;
  }

  @override
  void dispose() {
    owner?.slots.remove(this);
    owner?.schedule();
    super.dispose();
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.color, this.clock) : super(repaint: clock);
  final Color color;
  final Animation<double>? clock;
  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < 3; i++) {
      final pulse = clock == null
          ? 0.4
          : math.max(0.0, math.sin(clock!.value * math.pi * 2 - i * 0.8));
      canvas.drawCircle(
        Offset(size.width * (i + 0.5) / 3, size.height / 2),
        size.height / 6,
        Paint()..color = color.withValues(alpha: 0.35 + 0.65 * pulse),
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.clock != clock;
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.color, this.clock) : super(repaint: clock);
  final Color color;
  final Animation<double>? clock;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawArc(
      (Offset.zero & size).deflate(size.shortestSide * 0.1),
      (clock?.value ?? 0) * math.pi * 2,
      math.pi * 1.4,
      false,
      Paint()
        ..color = color
        ..strokeWidth = size.shortestSide * 0.1
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.clock != clock;
}
