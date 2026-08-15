import 'package:flutter/material.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// Slide-down notification panel — FR-NOTIF-1/2/3
class NotificationPanel extends StatelessWidget {
  final List<AppNotification> notifications;
  final void Function(String id) onAck;

  const NotificationPanel({
    super.key,
    required this.notifications,
    required this.onAck,
  });

  Color _color(AppNotificationSeverity s) {
    switch (s) {
      case AppNotificationSeverity.error:
        return AppColors.red;
      case AppNotificationSeverity.warning:
        return AppColors.orange;
      case AppNotificationSeverity.success:
        return AppColors.green;
      case AppNotificationSeverity.info:
        return AppColors.navy;
    }
  }

  IconData _icon(AppNotificationSeverity s) {
    switch (s) {
      case AppNotificationSeverity.error:
        return Icons.error;
      case AppNotificationSeverity.warning:
        return Icons.warning;
      case AppNotificationSeverity.success:
        return Icons.check_circle;
      case AppNotificationSeverity.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (notifications.isEmpty) return const SizedBox.shrink();

    final critical = notifications.where((n) => n.requiresAck).toList();
    final recent = notifications.take(3).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...critical.map((n) => _tile(n, emphasize: true)),
        ...recent.where((n) => !n.requiresAck).map((n) => _tile(n)),
      ],
    );
  }

  Widget _tile(AppNotification n, {bool emphasize = false}) {
    final color = _color(n.severity);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: emphasize ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(_icon(n.severity), color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(n.message,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: emphasize ? FontWeight.w600 : FontWeight.normal,
                  color: AppColors.textPrimary,
                )),
          ),
          if (n.requiresAck)
            TextButton(
              onPressed: () => onAck(n.id),
              child: Text('Dismiss', style: TextStyle(color: color, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
