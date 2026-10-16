import 'dart:async';
import 'package:flutter/material.dart';
import '../models/robot_state.dart';
import '../services/notification_service.dart';
import '../services/prefs_service.dart';
import '../services/robot_service.dart';
import '../theme/app_theme.dart';
import '../widgets/notification_panel.dart';
import '../widgets/status_card.dart';
import '../widgets/action_button.dart';
import '../widgets/app_logo.dart';
import '../widgets/joystick_widget.dart';
import 'login_screen.dart';
import 'missions_screen.dart';
import 'logs_screen.dart';
import 'navigation_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final RobotService service;
  const HomeScreen({super.key, required this.service});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _ControlMode { navigation, joystick }

class _HomeScreenState extends State<HomeScreen> {
  RobotState _state = RobotState.initial();
  List<String> _destinations = [];
  bool _loadingStart = false;
  bool _loadingMotors = false;
  bool _loadingTestDrive = false;
  bool _loadingReady = false;
  String? _actionError;
  _ControlMode _controlMode = _ControlMode.navigation;
  bool _joystickActive = false;
  Timer? _cmdVelTimer;
  Timer? _uiThrottleTimer;
  // Atomic snapshot — written on the UI thread, read by the timer callback.
  double _lastLinear = 0;
  double _lastAngular = 0;
  // How often the periodic timer sends cmd_vel while the joystick is held.
  static const _kCmdVelPeriod = Duration(milliseconds: 60);

  final _notifications = NotificationService();
  List<AppNotification> _notificationItems = [];
  Timer? _idleTimer;
  StreamSubscription<RobotState>? _stateSub;
  StreamSubscription<List<AppNotification>>? _notifSub;
  StreamSubscription<void>? _authExpiredSub;

  @override
  void initState() {
    super.initState();
    widget.service.connect();
    _authExpiredSub = widget.service.authExpiredStream.listen((_) {
      if (!mounted) return;
      widget.service.logout();
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session expired — please sign in again.')),
      );
    });
    _stateSub = widget.service.stateStream.listen((s) {
      final prev = _state;
      _state = s;
      _notifications.onStateUpdate(s);
      // Only rebuild when something the UI actually renders has changed.
      final visiblyChanged =
          prev.status != s.status ||
          prev.rosRunning != s.rosRunning ||
          prev.connection != s.connection ||
          prev.bridgeVerified != s.bridgeVerified ||
          prev.isNavigating != s.isNavigating ||
          prev.destination != s.destination ||
          prev.message != s.message ||
          prev.battery != s.battery ||
          prev.batteryAlert != s.batteryAlert ||
          prev.nodeHealth.length != s.nodeHealth.length ||
          prev.canOperate != s.canOperate;
      if (visiblyChanged) {
        if (mounted) setState(() {});
      } else if (!_joystickActive) {
        // Pose-only updates: defer a 500ms repaint so the pose display
        // stays fresh without hammering the build cycle.
        _scheduleUiRefresh();
      }
    });
    _notifSub = _notifications.stream.listen((items) {
      setState(() => _notificationItems = items);
    });
    _loadDestinations();
    _resetIdleTimer();
  }

  Future<void> _loadDestinations() async {
    try {
      final dests = await widget.service.getDestinations();
      if (mounted) setState(() => _destinations = dests);
    } catch (_) {}
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    PrefsService.getIdleTimeoutMinutes().then((minutes) {
      if (minutes <= 0 || !mounted) return;
      _idleTimer = Timer(Duration(minutes: minutes), _onIdleTimeout);
    });
  }

  void _onIdleTimeout() {
    if (!mounted) return;
    widget.service.logout();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Signed out due to inactivity.')),
    );
  }

  Future<void> _start() async {
    setState(() { _loadingStart = true; _actionError = null; });
    try {
      await widget.service.startRobot();
      await _waitForBridgePopup();
    } catch (e) {
      var msg = e.toString().replaceFirst('Exception: ', '');
      try {
        final link = await widget.service.checkReal1Link();
        if (link['ok'] != true && link['hint'] != null) {
          msg = '${link['hint']}\n$msg';
        }
      } catch (_) {}
      setState(() => _actionError = msg);
      final bridge = await widget.service.getBridgeStatus();
      await _showBridgePopup(bridge, failed: !_bridgeLooksOk(bridge));
    } finally {
      setState(() => _loadingStart = false);
    }
  }

  bool _bridgeLooksOk(Map<String, dynamic> bridge) {
    if (bridge['ok'] == true) return true;
    if (bridge['ros_node_visible'] == true) return true;
    if (bridge['warming_up'] == true && bridge['process_alive'] == true) return true;
    return bridge['process_alive'] == true &&
        bridge['cmd_vel_subscriber'] == true;
  }

  String _formatBridgeDetails(Map<String, dynamic> b) {
    final subs = b['bridge_subscriptions'];
    final lines = <String>[
      b['hint']?.toString() ?? '',
      if (b['launch_command'] != null) 'Command: ${b['launch_command']}',
      if (b['pid'] != null) 'PID: ${b['pid']}',
      'Process alive: ${b['process_alive'] == true}',
      'ROS node robot_bridge: ${b['ros_node_visible'] == true}',
      'cmd_vel subscriber on ${b['cmd_vel_topic'] ?? '/cmd_vel'}: ${b['cmd_vel_subscriber'] == true}',
      if (subs is List && subs.isNotEmpty) 'Bridge subscribes to: ${subs.join(', ')}',
    ];
    return lines.where((l) => l.isNotEmpty).join('\n');
  }

  Future<void> _showBridgePopup(Map<String, dynamic> bridge,
      {bool failed = false}) async {
    if (!mounted) return;
    final ok = _bridgeLooksOk(bridge) && !failed;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          ok ? Icons.check_circle : Icons.warning_amber_rounded,
          color: ok ? AppColors.green : AppColors.red,
          size: 36,
        ),
        title: Text(ok ? 'robotBridge is running' : 'robotBridge NOT verified'),
        content: SingleChildScrollView(
          child: Text(
            _formatBridgeDetails(bridge),
            style: const TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _waitForBridgePopup() async {
    for (var i = 0; i < 65; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      final bridge = await widget.service.getBridgeStatus();
      if (bridge['ros_node_visible'] == true || bridge['ok'] == true) {
        await _showBridgePopup(bridge);
        return;
      }
      if (bridge['warming_up'] == true && i < 64) {
        continue;
      }
      if (_bridgeLooksOk(bridge) && bridge['warming_up'] != true) {
        await _showBridgePopup(bridge);
        return;
      }
    }
    if (mounted) {
      final bridge = await widget.service.getBridgeStatus();
      await _showBridgePopup(bridge, failed: !_bridgeLooksOk(bridge));
    }
  }

  Future<void> _showTeleopPopup(Map<String, dynamic> data,
      {required String title}) async {
    if (!mounted) return;
    // Flatten nested debug payloads for display.
    final flat = Map<String, dynamic>.from(data);
    if (data['teleop'] is Map) {
      flat.addAll(Map<String, dynamic>.from(data['teleop'] as Map));
    }
    if (data['relay'] is Map) {
      final relay = data['relay'] as Map;
      flat['relay_alive'] ??= relay['alive'];
      flat['relay_pid'] ??= relay['pid'];
      flat['relay_stats'] ??= relay['stats'];
      flat['stats_linear'] ??= relay['stats_linear'];
      flat['stats_angular'] ??= relay['stats_angular'];
      flat['state_linear'] ??= relay['state_linear'];
      flat['state_angular'] ??= relay['state_angular'];
    }
    if (data['connection'] is Map) {
      final conn = data['connection'] as Map;
      if (conn['bridge'] is Map) {
        flat.addAll(Map<String, dynamic>.from(conn['bridge'] as Map));
      }
      if (conn['warnings'] is List && (conn['warnings'] as List).isNotEmpty) {
        flat['hint'] = (conn['warnings'] as List).join('\n');
      }
    }
    if (data['bridge'] is Map) {
      flat.addAll(Map<String, dynamic>.from(data['bridge'] as Map));
    }
    if (data['cmd_vel_traffic'] is Map) {
      final t = data['cmd_vel_traffic'] as Map;
      if (t['echo_output'] != null) flat['cmd_vel_echo'] = t['echo_output'];
      if (t['hz_output'] != null) flat['cmd_vel_hz'] = t['hz_output'];
    }
    data = flat;
    final bridgeOk = data['bridge_ok'] == true;
    final hasSub = data['cmd_vel_subscriber'] == true || data['bridge_listening'] == true;
    final relayOk = data['relay_alive'] == true;
    final hubReady = data['hub_ready'] == true;
    final armed = data['teleop_armed'] == true || _joystickActive;
    final publishing = armed && relayOk;
    final ok = bridgeOk && hasSub && publishing;
    final hint = data['hint']?.toString() ?? '';
    final lines = <String>[
      hint,
      if (data['cmd_vel_topic'] != null) 'Topic: ${data['cmd_vel_topic']}',
      if (data['cmd_vel_units'] != null) 'Units: ${data['cmd_vel_units']}',
      if (data['linear_tablet'] != null)
        'Tablet: linear=${data['linear_tablet']}, angular=${data['angular_tablet']}',
      if (data['linear'] != null)
        'ROS /cmd_vel: linear=${data['linear']}, angular=${data['angular']}',
      if (data['publish_via'] != null) 'Publish via: ${data['publish_via']}',
      'ROS hub (rclpy): ${hubReady ? 'YES' : 'NO'}',
      'joystick armed: ${data['teleop_armed'] == true ? 'YES' : 'NO — tap JOYSTICK after READY'}',
      'cmd_vel relay: ${relayOk ? 'YES pid=${data['relay_pid'] ?? '?'}' : 'NO (starts when JOYSTICK enabled)'}',
      'bridge_ok: $bridgeOk',
      'bridge listening: ${data['bridge_listening'] == true}',
      if (data['relay_stats'] != null && '${data['relay_stats']}'.isNotEmpty)
        'Relay stats: ${data['relay_stats']}',
      if (data['stats_linear'] != null)
        'Relay publishing: linear=${data['stats_linear']}, angular=${data['stats_angular'] ?? 0}',
      if (data['state_linear'] != null)
        'State file: linear=${data['state_linear']}, angular=${data['state_angular'] ?? 0}',
      if (data['enable_motors'] != null && '${data['enable_motors']}'.isNotEmpty)
        'Enable motors: ${data['enable_motors']}',
      'cmd_vel subscriber: ${data['cmd_vel_subscriber'] == true}',
      if (data['qos_compatible'] == false)
        'QoS: INCOMPATIBLE — update relay on Pi (RELIABLE required)',
      if (data['publish_count'] != null) 'publish_count: ${data['publish_count']}',
      if (data['linear'] != null)
        'speed: ${data['linear']}, turn: ${data['angular']}',
    ].where((l) => l.isNotEmpty).join('\n');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          ok ? Icons.gamepad : Icons.warning_amber_rounded,
          color: ok ? AppColors.green : AppColors.orange,
          size: 36,
        ),
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(lines, style: const TextStyle(fontSize: 13)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _selectNavigationMode() async {
    if (_controlMode == _ControlMode.navigation) return;
    // Zero velocities FIRST so any in-flight timer tick reads 0.
    _lastLinear = 0;
    _lastAngular = 0;
    _cmdVelTimer?.cancel();
    _cmdVelTimer = null;
    _uiThrottleTimer?.cancel();
    setState(() {
      _controlMode = _ControlMode.navigation;
      _joystickActive = false;
    });
    // Explicitly send a stop command before disabling teleop so the
    // robot doesn't keep moving after the mode switch.
    try { await widget.service.sendCmdVel(0, 0); } catch (_) {}
    try {
      await widget.service.enableTeleop(false);
    } catch (_) {}
  }

  Future<void> _selectJoystickMode() async {
    if (!_state.canOperate) {
      await _showBridgePopup(
        _state.bridgeStatus.isNotEmpty
            ? _state.bridgeStatus
            : await widget.service.getBridgeStatus(),
        failed: true,
      );
      return;
    }
    setState(() {
      _controlMode = _ControlMode.joystick;
      _actionError = null;
    });
    try {
      await widget.service.cancelNavigation();
      final res = await widget.service.enableTeleop(true);
      if (!mounted) return;
      setState(() => _joystickActive = true);
      final qosBad = res['qos_compatible'] == false || res['relay_best_effort'] == true;
      if (qosBad) {
        await _showTeleopPopup(res, title: 'QoS BLOCKED — robot will not move');
      }
    } catch (e) {
      setState(() => _actionError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _scheduleUiRefresh() {
    _uiThrottleTimer ??= Timer(const Duration(milliseconds: 500), () {
      _uiThrottleTimer = null;
      if (mounted) setState(() {});
    });
  }

  void _onJoystickMove(double linear, double angular) {
    // Atomically update so the timer callback always reads the latest values.
    _lastLinear = linear;
    _lastAngular = angular;
    // Do NOT send immediately — only the periodic _cmdVelTimer sends HTTP
    // requests, preventing a flood of requests on every finger-move event.
    _cmdVelTimer ??= Timer.periodic(_kCmdVelPeriod, (_) => _sendCmdVelTick());
  }

  void _sendCmdVelTick() {
    // Capture to locals so the async send uses the values at the moment of
    // invocation, not whatever _lastLinear/_lastAngular become later.
    final linear = _lastLinear;
    final angular = _lastAngular;
    // Fire-and-forget — errors are silently swallowed so a Wi-Fi hiccup on a
    // single cmd_vel tick never surfaces as a UI error.
    () async {
      try { await widget.service.sendCmdVel(linear, angular); } catch (_) {}
    }();
  }

  Future<void> _onJoystickRelease() async {
    // Cancel the periodic timer FIRST and zero the snapshot values so
    // that any tick already in-flight reads (0, 0) if it fires before
    // the timer is fully cancelled.
    _lastLinear = 0;
    _lastAngular = 0;
    _cmdVelTimer?.cancel();
    _cmdVelTimer = null;

    // Retry stop up to 3 times with 50 ms gaps so a single dropped HTTP
    // request on Wi-Fi does not leave the robot moving for 800 ms.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await widget.service.sendCmdVel(0, 0);
        break; // success — no need to retry
      } catch (_) {
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 50));
        }
      }
    }
  }



  Future<void> _enableMotors() async {
    setState(() => _loadingMotors = true);
    try {
      final res = await widget.service.enableMotors();
      if (!mounted) return;
      await _showTeleopPopup(res, title: res['ok'] == true ? 'Motors enabled' : 'Enable motors failed');
    } catch (e) {
      setState(() => _actionError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loadingMotors = false);
    }
  }

  Future<void> _testDrive() async {
    setState(() => _loadingTestDrive = true);
    try {
      final res = await widget.service.testDrive();
      if (!mounted) return;
      await _showTeleopPopup(res, title: 'Test drive sent');
    } catch (e) {
      setState(() => _actionError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loadingTestDrive = false);
    }
  }

  Future<void> _debugJoystick() async {
    try {
      final conn = await widget.service.getTeleopConnection();
      final res = await widget.service.getTeleopDebug();
      if (!mounted) return;
      final merged = Map<String, dynamic>.from(res);
      merged['connection'] = conn;
      if (conn['warnings'] is List && (conn['warnings'] as List).isNotEmpty) {
        merged['hint'] = (conn['warnings'] as List).join('\n');
      }
      await _showTeleopPopup(merged, title: conn['chain_ok'] == true ? 'Connection OK' : 'Connection issue');
    } catch (e) {
      setState(() => _actionError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _ready() async {
    setState(() { _loadingReady = true; _actionError = null; });
    try {
      _cmdVelTimer?.cancel();
      _cmdVelTimer = null;
      if (_joystickActive) {
        await widget.service.enableTeleop(false);
        setState(() => _joystickActive = false);
      }
      await widget.service.setReady();
    } catch (e) {
      setState(() => _actionError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loadingReady = false);
    }
  }

  void _logout() {
    widget.service.logout();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  void dispose() {
    _cmdVelTimer?.cancel();
    _uiThrottleTimer?.cancel();
    if (_joystickActive) widget.service.stopTeleop();
    _idleTimer?.cancel();
    _stateSub?.cancel();
    _notifSub?.cancel();
    _authExpiredSub?.cancel();
    _notifications.dispose();
    widget.service.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _resetIdleTimer(),
      child: Scaffold(
        appBar: AppBar(
          title: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                AppLogo(size: 32, circular: true),
                SizedBox(width: 8),
                Text('Robot Controller'),
              ],
            ),
          ),
          actions: [
            if (_notificationItems.any((n) => n.requiresAck))
              IconButton(
                icon: const Badge(
                  label: Text('!'),
                  child: Icon(Icons.notifications_active),
                ),
                tooltip: 'Notifications',
                onPressed: () {},
              ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Settings',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(service: widget.service),
                ),
              ).then((_) => _loadDestinations()),
            ),
            IconButton(
              icon: const Icon(Icons.article_outlined),
              tooltip: 'Logs',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => LogsScreen(service: widget.service)),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
              onPressed: _logout,
            ),
          ],
        ),
        // Split the body: scrollable status/controls at top, fixed joystick at
        // bottom. This prevents the ScrollView from stealing pan gestures from
        // the joystick when the user drags vertically.
        body: _controlMode == _ControlMode.joystick
            ? Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: Column(
                        children: [
                          NotificationPanel(
                            notifications: _notificationItems,
                            onAck: _notifications.ack,
                          ),
                          StatusCard(state: _state),
                          if (_actionError != null) ...[
                            const SizedBox(height: 10),
                            _ErrorBanner(
                              message: _actionError!,
                              onDismiss: () => setState(() => _actionError = null),
                            ),
                          ],
                          const SizedBox(height: 20),
                          _buildNodeHealth(),
                          const SizedBox(height: 20),
                          _buildControls(),
                          const SizedBox(height: 20),
                          _buildModeSelector(),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                  // Joystick lives OUTSIDE the ScrollView so pan gestures are
                  // never competed over by the scroll physics.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: _buildJoystick(),
                  ),
                ],
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    NotificationPanel(
                      notifications: _notificationItems,
                      onAck: _notifications.ack,
                    ),
                    StatusCard(state: _state),
                    if (_actionError != null) ...[
                      const SizedBox(height: 10),
                      _ErrorBanner(
                        message: _actionError!,
                        onDismiss: () => setState(() => _actionError = null),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _buildNodeHealth(),
                    const SizedBox(height: 20),
                    _buildControls(),
                    const SizedBox(height: 20),
                    _buildModeSelector(),
                    const SizedBox(height: 16),
                    _buildNavigation(),
                  ],
                ),
              ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.route),
          label: const Text('Mission'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MissionsScreen(
                service: widget.service,
                destinations: _destinations,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNodeHealth() {
    if (_state.nodeHealth.isEmpty) return const SizedBox.shrink();
    final allDead = _state.nodeHealth.values.every(
      (v) => v == 'dead' || v == 'stopped' || v == 'unknown',
    );
    if (!_state.rosRunning && allDead && !_state.isError) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Node Health',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _state.nodeHealth.entries.map((e) {
                final ok = e.value == 'running';
                final color = ok
                    ? AppColors.green
                    : e.value == 'stopped'
                        ? AppColors.textSecondary
                        : AppColors.red;
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(ok ? Icons.check_circle : Icons.cancel, color: color, size: 14),
                    const SizedBox(width: 4),
                    Text(
                      e.key.replaceAll('_', ' '),
                      style: TextStyle(fontSize: 12, color: color),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  String _startButtonLabel() {
    if (_state.bridgeVerified) return 'robotBridge OK';
    if (_state.isLaunching || _loadingStart) return 'Starting robotBridge...';
    if (_state.rosRunning) return 'robotBridge NOT ready — tap START';
    return 'START';
  }

  Widget _buildControls() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Robot Controls',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            ActionButton(
              label: _startButtonLabel(),
              icon: Icons.play_circle_fill,
              color: AppColors.navy,
              loading: _loadingStart,
              onPressed: _state.bridgeVerified ? null : _start,
            ),
            const SizedBox(height: 12),
            ActionButton(
              label: 'READY FOR WORK',
              icon: Icons.task_alt,
              color: AppColors.green,
              loading: _loadingReady,
              onPressed: _state.canOperate ? _ready : null,
            ),
            if (_state.rosRunning) ...[
              const SizedBox(height: 12),
              ActionButton(
                label: 'STOP ROBOT',
                icon: Icons.stop_circle,
                color: AppColors.red,
                onPressed: () => widget.service.stopRobot(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Control Mode',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ActionButton(
                    label: 'NAVIGATION',
                    icon: Icons.navigation,
                    color: _controlMode == _ControlMode.navigation
                        ? AppColors.navy
                        : AppColors.textSecondary,
                    onPressed: _state.canOperate ? _selectNavigationMode : null,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ActionButton(
                    label: 'JOYSTICK',
                    icon: Icons.gamepad,
                    color: _controlMode == _ControlMode.joystick
                        ? AppColors.orange
                        : AppColors.textSecondary,
                    onPressed: _state.canOperate ? _selectJoystickMode : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _controlMode == _ControlMode.navigation
                  ? 'Nav2 autonomous navigation to named destinations'
                  : 'Runs gamepad.py on the Pi for manual drive',
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildJoystick() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gamepad, color: AppColors.orange),
                const SizedBox(width: 8),
                const Text('Joystick Control',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_joystickActive)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text('ACTIVE',
                        style: TextStyle(
                            color: AppColors.orange,
                            fontSize: 11,
                            fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            JoystickWidget(
              enabled: _joystickActive && _state.canOperate,
              onMove: _onJoystickMove,
              onRelease: _onJoystickRelease,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _state.canOperate && !_loadingMotors ? _enableMotors : null,
                  icon: _loadingMotors
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.power, size: 18),
                  label: const Text('Enable motors'),
                ),
                OutlinedButton.icon(
                  onPressed: _joystickActive && !_loadingTestDrive ? _testDrive : null,
                  icon: _loadingTestDrive
                      ? const SizedBox(
                          width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.speed, size: 18),
                  label: const Text('Test drive'),
                ),
                OutlinedButton.icon(
                  onPressed: _joystickActive ? _debugJoystick : null,
                  icon: const Icon(Icons.bug_report, size: 18),
                  label: const Text('Debug'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Quick Start: 1. Tap START → 2. Wait for READY → 3. Tap JOYSTICK → 4. Drag pad to drive immediately.',
              style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Navigate To',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_state.isNavigating)
                  TextButton.icon(
                    onPressed: () => widget.service.cancelNavigation(),
                    icon: const Icon(Icons.cancel, size: 16, color: AppColors.orange),
                    label: const Text('Cancel',
                        style: TextStyle(color: AppColors.orange)),
                  ),
              ],
            ),
            // Show current navigation status when in progress
            if (_state.isNavigating) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppColors.navy.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.navy),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _state.destination != null
                            ? 'Navigating → ${_state.destination}'
                            : _state.message,
                        style: const TextStyle(
                            color: AppColors.navy,
                            fontWeight: FontWeight.w600,
                            fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Open the real map navigation screen.
            // Wrap in Tooltip + GestureDetector so disabled taps still give
            // the user feedback explaining what they need to do first.
            Tooltip(
              message: _state.canOperate
                  ? ''
                  : _state.isLaunching
                      ? 'Robot is starting — please wait…'
                      : 'Press START first to launch the robot',
              child: GestureDetector(
                onTap: !_state.canOperate
                    ? () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              _state.isLaunching
                                  ? 'Robot is starting — please wait…'
                                  : 'Press START first to launch the robot.',
                            ),
                            duration: const Duration(seconds: 3),
                          ),
                        );
                      }
                    : null,
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _state.canOperate
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    NavigationScreen(service: widget.service),
                              ),
                            ).then((_) {
                              _loadDestinations();
                            });
                          }
                        : null,
                    icon: const Icon(Icons.map),
                    label: const Text('Open Navigation Map'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.navy,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _state.canOperate
                  ? 'Select a destination on the real map and press GO to navigate.'
                  : _state.isLaunching
                      ? 'Waiting for robot to finish starting…'
                      : 'Robot not running — press START above to begin.',
              style: TextStyle(
                fontSize: 11,
                color: _state.canOperate
                    ? AppColors.textSecondary
                    : _state.isLaunching
                        ? AppColors.orange
                        : AppColors.red,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.red, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: const TextStyle(color: AppColors.red, fontSize: 13)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: AppColors.red),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
