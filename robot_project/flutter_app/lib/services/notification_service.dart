import 'dart:async';
import '../models/robot_state.dart';
import 'prefs_service.dart';

enum AppNotificationSeverity { info, warning, error, success }

class AppNotification {
  final String id;
  final String message;
  final AppNotificationSeverity severity;
  final DateTime timestamp;
  final bool requiresAck;

  const AppNotification({
    required this.id,
    required this.message,
    required this.severity,
    required this.timestamp,
    this.requiresAck = false,
  });
}

class NotificationService {
  final _controller = StreamController<List<AppNotification>>.broadcast();
  Stream<List<AppNotification>> get stream => _controller.stream;

  final List<AppNotification> _items = [];
  RobotState? _lastState;
  String? _lastMessage;
  String? _lastStatus;

  List<AppNotification> get items => List.unmodifiable(_items);

  void dispose() => _controller.close();

  void ack(String id) {
    _items.removeWhere((n) => n.id == id);
    _controller.add(List.unmodifiable(_items));
  }

  Future<void> onStateUpdate(RobotState state) async {
    final prev = _lastState;
    _lastState = state;

    if (prev != null && prev.rosRunning != state.rosRunning) {
      final notify = await PrefsService.getNotifyLaunch();
      if (notify) {
        if (state.rosRunning && state.status == 'running') {
          _push('robotBridge started.', AppNotificationSeverity.success,
              dedupeKey: 'bridge_started');
        } else if (prev.rosRunning && !state.isError) {
          _push('robotBridge stopped.', AppNotificationSeverity.info,
              dedupeKey: 'bridge_stopped');
        }
      }
    }

    if (_lastStatus != state.status) {
      if (state.status == 'ready') {
        _push('Robot is ready for work.', AppNotificationSeverity.success,
            dedupeKey: 'ready');
      } else if (state.status == 'error' && state.message.isNotEmpty) {
        _items.removeWhere((n) => n.id == 'bridge_started');
        _push(state.message, AppNotificationSeverity.error,
            requiresAck: true, dedupeKey: 'error_${state.message}');
      }
      _lastStatus = state.status;
    }

    if (prev?.currentMission != state.currentMission &&
        state.currentMission != null) {
      final notify = await PrefsService.getNotifyMission();
      if (notify) {
        _push('Mission #${state.currentMission} started.',
            AppNotificationSeverity.info);
      }
    }

    if (prev?.currentMission != null &&
        state.currentMission == null &&
        state.message.toLowerCase().contains('completed')) {
      final notify = await PrefsService.getNotifyMission();
      if (notify) {
        _push(state.message, AppNotificationSeverity.success);
      }
    }

    if (state.message != _lastMessage &&
        state.message.toLowerCase().contains('failed')) {
      final notify = await PrefsService.getNotifyMission();
      if (notify) {
        _push(state.message, AppNotificationSeverity.error,
            requiresAck: true, dedupeKey: 'fail_${state.message}');
      }
    }

    // Battery alerts from Pi /robot/status battery_alert field
    if (state.isBatteryCritical) {
      _push(
        'Battery CRITICAL: ${state.battery}% (${state.batteryVoltage.toStringAsFixed(1)} V) — charge immediately!',
        AppNotificationSeverity.error,
        requiresAck: true,
        dedupeKey: 'battery_critical',
      );
    } else if (state.isBatteryLow) {
      _push(
        'Battery low: ${state.battery}% (${state.batteryVoltage.toStringAsFixed(1)} V)',
        AppNotificationSeverity.warning,
        dedupeKey: 'battery_low',
      );
    } else {
      // Clear stale battery alerts when level recovers (e.g., after charging)
      _items.removeWhere((n) => n.id == 'battery_low' || n.id == 'battery_critical');
    }

    _lastMessage = state.message;
  }

  void _push(
    String message,
    AppNotificationSeverity severity, {
    bool requiresAck = false,
    String? dedupeKey,
  }) {
    if (dedupeKey != null && _items.any((n) => n.id == dedupeKey)) return;
    _items.insert(
      0,
      AppNotification(
        id: dedupeKey ?? DateTime.now().microsecondsSinceEpoch.toString(),
        message: message,
        severity: severity,
        timestamp: DateTime.now(),
        requiresAck: requiresAck,
      ),
    );
    if (_items.length > 20) _items.removeRange(20, _items.length);
    _controller.add(List.unmodifiable(_items));
  }
}
