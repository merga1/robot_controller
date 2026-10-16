import 'package:flutter/material.dart';
import '../models/robot_state.dart';
import '../theme/app_theme.dart';

/// Live status card — FR-DASH-1/3/4
class StatusCard extends StatelessWidget {
  final RobotState state;
  const StatusCard({super.key, required this.state});

  Color get _connectionColor {
    switch (state.connection) {
      case 'connected':
        return AppColors.green;
      case 'connecting':
        return AppColors.orange;
      default:
        return AppColors.red;
    }
  }

  Color get _statusColor {
    switch (state.status) {
      case 'running':
      case 'ready':
        return AppColors.green;
      case 'navigating':
        return AppColors.navy;
      case 'launching':
        return AppColors.orange;
      case 'error':
        return AppColors.red;
      default:
        return AppColors.textSecondary;
    }
  }

  IconData get _statusIcon {
    switch (state.status) {
      case 'running':
        return Icons.check_circle;
      case 'ready':
        return Icons.task_alt;
      case 'navigating':
        return Icons.navigation;
      case 'launching':
        return Icons.rocket_launch;
      case 'error':
        return Icons.error;
      default:
        return Icons.radio_button_unchecked;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: _connectionColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  state.connection.toUpperCase(),
                  style: TextStyle(
                    color: _connectionColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.0,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    state.rosRunning
                        ? (state.bridgeVerified
                            ? 'robotBridge ON'
                            : 'robotBridge starting…')
                        : 'robotBridge OFF',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: state.rosRunning
                          ? (state.bridgeVerified
                              ? AppColors.green
                              : AppColors.orange)
                          : AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight:
                          state.rosRunning ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                Icon(_statusIcon, color: _statusColor, size: 22),
                const SizedBox(width: 10),
                Text(
                  state.status.toUpperCase(),
                  style: TextStyle(
                    color: _statusColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              state.message,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
            ),
            if (state.isConnected && state.rosRunning) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.my_location,
                        size: 14, color: AppColors.textSecondary),
                    const SizedBox(width: 6),
                    Text(
                      state.pose.toString(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Battery indicator — from Pi /robot/status battery fields
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  state.isBatteryCritical
                      ? Icons.battery_alert
                      : state.isBatteryLow
                          ? Icons.battery_2_bar
                          : Icons.battery_full,
                  size: 16,
                  color: state.isBatteryCritical
                      ? AppColors.red
                      : state.isBatteryLow
                          ? AppColors.orange
                          : AppColors.green,
                ),
                const SizedBox(width: 4),
                Text(
                  '${state.battery}% · ${state.batteryVoltage.toStringAsFixed(1)} V',
                  style: TextStyle(
                    fontSize: 12,
                    color: state.isBatteryCritical
                        ? AppColors.red
                        : state.isBatteryLow
                            ? AppColors.orange
                            : AppColors.textSecondary,
                    fontWeight: state.isBatteryLow ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ],
            ),
            if (state.destination != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(Icons.location_on, size: 16, color: AppColors.navy),
                  const SizedBox(width: 4),
                  Text(
                    'Heading to: ${state.destination}',
                    style: const TextStyle(
                      color: AppColors.navy,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
