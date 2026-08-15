import 'package:flutter/material.dart';

/// Delivery Robot Controller — EAII logo
class AppLogo extends StatelessWidget {
  final double size;
  final bool circular;

  const AppLogo({super.key, this.size = 120, this.circular = true});

  static const _asset = 'assets/images/robot_controller_logo.png';

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      _asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) =>
          Icon(Icons.precision_manufacturing, size: size * 0.6),
    );
    if (!circular) return image;
    return ClipOval(
      child: SizedBox(width: size, height: size, child: image),
    );
  }
}
