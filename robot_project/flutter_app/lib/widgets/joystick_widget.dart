import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Virtual joystick — maps drag to linear speed + rotation (cmd_vel).
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
  static const _paintInterval = Duration(milliseconds: 33);
  static const _moveInterval = Duration(milliseconds: 80);

  DateTime? _lastPaintAt;
  DateTime? _lastMoveAt;
  Timer? _moveTimer;
  double _pendingLinear = 0;
  double _pendingAngular = 0;

  @override
  void dispose() {
    _moveTimer?.cancel();
    super.dispose();
  }

  void _emitMove(double linear, double angular) {
    _pendingLinear = linear;
    _pendingAngular = angular;
    final now = DateTime.now();
    if (_lastMoveAt != null && now.difference(_lastMoveAt!) < _moveInterval) {
      _moveTimer ??= Timer(_moveInterval, _flushMove);
      return;
    }
    _flushMove();
  }

  void _flushMove() {
    _moveTimer?.cancel();
    _moveTimer = null;
    _lastMoveAt = DateTime.now();
    widget.onMove(_pendingLinear, _pendingAngular);
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
    final knobMoved = (delta - _knob).distance > 1.5;
    final shouldPaint = knobMoved &&
        (_lastPaintAt == null || now.difference(_lastPaintAt!) >= _paintInterval);
    if (shouldPaint) {
      _lastPaintAt = now;
      setState(() => _knob = delta);
    } else if (knobMoved) {
      _knob = delta;
    }

    final linear = (-delta.dy / radius) * _maxLinear;
    final angular = (-delta.dx / radius) * _maxAngular;
    _emitMove(linear, angular);
  }

  void _reset() {
    _moveTimer?.cancel();
    _moveTimer = null;
    _lastMoveAt = null;
    _pendingLinear = 0;
    _pendingAngular = 0;
    if (_knob != Offset.zero) {
      setState(() => _knob = Offset.zero);
    }
    widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
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
                    painter: _JoystickPainter(knob: _knob, enabled: widget.enabled),
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
                onPressed: () => _emitMove(_maxLinear, 0),
                onReleased: _reset,
              ),
              _QuickBtn(
                icon: Icons.arrow_downward,
                label: 'Back',
                enabled: widget.enabled,
                onPressed: () => _emitMove(-_maxLinear, 0),
                onReleased: _reset,
              ),
              _QuickBtn(
                icon: Icons.rotate_left,
                label: 'Left',
                enabled: widget.enabled,
                onPressed: () => _emitMove(0, _maxAngular),
                onReleased: _reset,
              ),
              _QuickBtn(
                icon: Icons.rotate_right,
                label: 'Right',
                enabled: widget.enabled,
                onPressed: () => _emitMove(0, -_maxAngular),
                onReleased: _reset,
              ),
              _QuickBtn(
                icon: Icons.stop_circle,
                label: 'Stop',
                enabled: widget.enabled,
                onPressed: _reset,
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
    _holdTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (widget.enabled) widget.onPressed();
    });
  }

  void _up() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (widget.enabled) widget.onReleased();
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

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = enabled ? AppColors.navy.withValues(alpha: 0.08) : Colors.grey.shade200
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = enabled ? AppColors.navy.withValues(alpha: 0.3) : Colors.grey.shade400
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final knobCenter = center + knob;
    canvas.drawCircle(
      knobCenter,
      28,
      Paint()..color = enabled ? AppColors.navy : Colors.grey,
    );

    final cross = Paint()
      ..color = AppColors.textSecondary.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), cross);
    canvas.drawLine(Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), cross);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter old) =>
      old.knob != knob || old.enabled != enabled;
}
