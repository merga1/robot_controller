import 'package:flutter/material.dart';

class ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool loading;
  final VoidCallback? onPressed;
  const ActionButton({super.key, required this.label, required this.icon, required this.color, this.loading = false, this.onPressed});
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: ElevatedButton.icon(
      style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
      onPressed: loading ? null : onPressed,
      icon: loading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Icon(icon),
      label: Text(label),
    ),
  );
}
