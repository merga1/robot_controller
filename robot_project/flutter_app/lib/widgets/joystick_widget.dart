import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Virtual joystick — maps drag to linear speed + rotation (cmd_vel).
///
/// Performance notes (2026-09):
///  • No rate-limiter inside the widget — the parent's 60 ms _cmdVelTimer
///    is the sole HTTP send loop. The widget emits onMove on every gesture
///    update so the parent always has the latest position.
///  • Paint threshold lowered to 0.5 px and repaint interval to 16 ms (≈60 fps)
///    so the knob tracks the finger without visual lag.
class JoystickWidget extends StatefulWidget {
  final bool enabled;
  final void Function(double linear, double angular) onMove;
  final VoidCallback onRelease;

  const JoystickWidget({
    super.key,
    required this.enabled,
    required this.onMove,
    required this.onRelease,
  });

  @override
  State<JoystickWidget> createState() => _JoystickWidgetState();
}

class _JoystickWidgetState extends State<JoystickWidget> {
  Offset _knob = Offset.zero;
  static const _maxLinear = 0.5;
  static const _maxAngular = 1.0;
  // 60 fps repaint — knob tracks finger without visual lag.
  static const _paintInterval = Duration(milliseconds: 16);

  DateTime? _lastPaintAt;

  @override
  void dispose() {
    super.dispose();
  }

  void _update(Offset local, Size size) {
    if (!widget.enabled) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 24;
    var delta = local - center;
    final dist = delta.distance;
    if (dist > radius) {
      delta = delta / dist * radius;
    }

    final now = DateTime.now();
    // Lower threshold (0.5 px) so tiny corrections are detected.
    final knobMoved = (delta - _knob).distance > 0.5;
    final shouldPaint = knobMoved &&
        (_lastPaintAt == null ||
            now.difference(_lastPaintAt!) >= _paintInterval);
    if (shouldPaint) {
      _lastPaintAt = now;
      setState(() => _knob = delta);
    } else if (knobMoved) {
      _knob = delta;
    }

    final linear = (-delta.dy / radius) * _maxLinear;
    final angular = (-delta.dx / radius) * _maxAngular;

    // Emit the new position — the parent's _cmdVelTimer is the sole send loop.
    widget.onMove(linear, angular);
  }

  void _reset() {
    _lastPaintAt = null;
    if (_knob != Offset.zero) {
      setState(() => _knob = Offset.zero);
    }
    widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary prevents joystick repaints from propagating up the tree.
    return RepaintBoundary(
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  onPanStart: (d) => _update(d.localPosition, size),
                  onPanUpdate: (d) => _update(d.localPosition, size),
                  onPanEnd: (_) => _reset(),
                  onPanCancel: _reset,
                  child: CustomPaint(
                    size: size,
                    painter: _JoystickPainter(
                      knob: _knob,
                      enabled: widget.enabled,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _QuickBtn(
                icon: Icons.arrow_upward,
                label: 'Forward',
                enabled: widget.enabled,
                onPressed: () => widget.onMove(_maxLinear, 0),
                onReleased: widget.onRelease,
              ),
              _QuickBtn(
                icon: Icons.arrow_downward,
                label: 'Back',
                enabled: widget.enabled,
                onPressed: () => widget.onMove(-_maxLinear, 0),
                onReleased: widget.onRelease,
              ),
              _QuickBtn(
                icon: Icons.rotate_left,
                label: 'Left',
                enabled: widget.enabled,
                onPressed: () => widget.onMove(0, _maxAngular),
                onReleased: widget.onRelease,
              ),
              _QuickBtn(
                icon: Icons.rotate_right,
                label: 'Right',
                enabled: widget.enabled,
                onPressed: () => widget.onMove(0, -_maxAngular),
                onReleased: widget.onRelease,
              ),
              _QuickBtn(
                icon: Icons.stop_circle,
                label: 'Stop',
                enabled: widget.enabled,
                onPressed: widget.onRelease,
                onReleased: () {},
                color: AppColors.red,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            widget.enabled
                ? 'Drag pad or hold buttons — releases send stop'
                : 'Start robot and tap JOYSTICK to enable',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _QuickBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final VoidCallback onReleased;
  final Color? color;

  const _QuickBtn({
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    required this.onReleased,
    this.color,
  });

  @override
  State<_QuickBtn> createState() => _QuickBtnState();
}

class _QuickBtnState extends State<_QuickBtn> {
  Timer? _holdTimer;

  void _down() {
    if (!widget.enabled) return;
    widget.onPressed();
    // Keep re-emitting while held so drive stays continuous.
    _holdTimer?.cancel();
    _holdTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (widget.enabled) widget.onPressed();
    });
  }

  void _up() {
    // Always cancel — even if disabled — so a mid-hold state change
    // (e.g. robot disconnects) never leaves the timer running.
    _holdTimer?.cancel();
    _holdTimer = null;
    if (widget.enabled) widget.onReleased();
  }

  /// If the widget becomes disabled while a button is being held
  /// (e.g. robot disconnects, mode switch), stop the repeat timer
  /// immediately so the last direction command is not looped forever.
  @override
  void didUpdateWidget(covariant _QuickBtn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled) {
      _holdTimer?.cancel();
      _holdTimer = null;
      // Do NOT call onReleased() here — the parent will send a stop
      // command as part of its own disabling flow.
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: widget.enabled ? (_) => _down() : null,
      onPointerUp: widget.enabled ? (_) => _up() : null,
      onPointerCancel: widget.enabled ? (_) => _up() : null,
      child: Column(
        children: [
          Icon(
            widget.icon,
            color: widget.enabled
                ? (widget.color ?? AppColors.navy)
                : Colors.grey,
            size: 28,
          ),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: 10,
              color: widget.enabled ? AppColors.textSecondary : Colors.grey,
            ),
          ),
        ],
      ),
    );
  }
}

class _JoystickPainter extends CustomPainter {
  final Offset knob;
  final bool enabled;

  _JoystickPainter({required this.knob, required this.enabled});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;

    // Outer base circle.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = enabled
            ? AppColors.navy.withValues(alpha: 0.08)
            : Colors.grey.shade200
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = enabled
            ? AppColors.navy.withValues(alpha: 0.3)
            : Colors.grey.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Direction indicator ring — glows when knob is displaced.
    final displacement = knob.distance;
    final maxRadius = size.width / 2 - 24;
    if (displacement > 2 && enabled) {
      final t = math.min(displacement / maxRadius, 1.0);
      canvas.drawCircle(
        center + knob,
        30,
        Paint()
          ..color = AppColors.orange.withValues(alpha: 0.25 * t)
          ..style = PaintingStyle.fill,
      );
    }

    // Knob.
    final knobCenter = center + knob;
    canvas.drawCircle(
      knobCenter,
      28,
      Paint()..color = enabled ? AppColors.navy : Colors.grey,
    );

    // Cross-hair guide lines.
    final cross = Paint()
      ..color = AppColors.textSecondary.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    canvas.drawLine(
        Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius),
        cross);
    canvas.drawLine(
        Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy),
        cross);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter old) =>
      old.knob != knob || old.enabled != enabled;
}
