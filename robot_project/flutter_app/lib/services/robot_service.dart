import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/robot_state.dart';

/// REST client for the Pi. Polling is intentional: it keeps the app useful on
/// lab Wi-Fi where a WebSocket connection is frequently interrupted.
class RobotService {
  final String baseUrl;
  String? _token;
  String? role;
  Timer? _poller;
  final _states = StreamController<RobotState>.broadcast();
  Stream<RobotState> get stateStream => _states.stream;

  RobotService({required this.baseUrl});

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Future<Map<String, dynamic>> _request(String method, String path, {Object? body}) async {
    final uri = Uri.parse('$baseUrl$path');
    final encoded = body == null ? null : jsonEncode(body);
    late http.Response response;
    try {
      response = switch (method) {
        'GET' => await http.get(uri, headers: _headers).timeout(const Duration(seconds: 15)),
        'DELETE' => await http.delete(uri, headers: _headers).timeout(const Duration(seconds: 15)),
        _ => await http.post(uri, headers: _headers, body: encoded).timeout(const Duration(seconds: 75)),
      };
    } catch (e) {
      throw Exception('Cannot reach robot API: $e');
    }
    Map<String, dynamic> data = {};
    if (response.body.isNotEmpty) {
      try {
        final value = jsonDecode(response.body);
        if (value is Map<String, dynamic>) data = value;
      } on FormatException {
        // Reverse proxies and an unhealthy Pi backend can return plain text
        // (for example, "Internal Server Error").  Preserve it for the user
        // instead of masking the actual server failure with a JSON exception.
        data = {'detail': response.body.trim()};
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(data['detail'] ?? 'Robot API returned HTTP ${response.statusCode}');
    }
    return data;
  }

  Future<void> login(String username, String password) async {
    final data = await _request('POST', '/auth/login', body: {'username': username, 'password': password});
    _token = data['access_token']?.toString();
    role = data['role']?.toString();
  }

  void connect() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    // Pi exposes /robot/status (not /state)
    try { _states.add(RobotState.fromJson(await _request('GET', '/robot/status'))); } catch (_) {}
  }

  void disconnect() { _poller?.cancel(); _poller = null; }
  void logout() { disconnect(); _token = null; role = null; }

  Future<void> startRobot() async { await _request('POST', '/robot/start'); }
  Future<void> stopRobot() async { await _request('POST', '/robot/stop'); }
  Future<Map<String, dynamic>> setReady() => _request('POST', '/robot/ready');

  // Pi endpoint is /robot/link-check, not /robot/real1-link
  Future<Map<String, dynamic>> checkReal1Link() => _request('GET', '/robot/link-check');
  Future<Map<String, dynamic>> getBridgeStatus() => _request('GET', '/robot/bridge-status');

  // Pi endpoint is /teleop/enable (not /robot/teleop)
  Future<Map<String, dynamic>> enableTeleop(bool enabled) =>
      _request('POST', '/teleop/enable', body: {'enabled': enabled});

  // Pi endpoint is /teleop/cmd_vel (not /robot/cmd-vel)
  Future<Map<String, dynamic>> sendCmdVel(double linear, double angular) =>
      _request('POST', '/teleop/cmd_vel', body: {'linear': linear, 'angular': angular});

  Future<Map<String, dynamic>> enableMotors() => _request('POST', '/robot/enable-motors');

  // Pi endpoint is /teleop/test-drive (not /robot/test-drive)
  Future<Map<String, dynamic>> testDrive() => _request('POST', '/teleop/test-drive');

  // Pi endpoint is /teleop/debug (not /robot/teleop-debug)
  Future<Map<String, dynamic>> getTeleopDebug() => _request('GET', '/teleop/debug');

  // Pi endpoint is /teleop/connection (not /robot/teleop-connection)
  Future<Map<String, dynamic>> getTeleopConnection() => _request('GET', '/teleop/connection');

  // Pi endpoint is /teleop/stop (not /teleop/enable with false, to keep motor keepalive)
  Future<void> stopTeleop() async { await _request('POST', '/teleop/stop'); }

  // Pi endpoint is /navigation/cancel (not /robot/cancel-navigation)
  Future<void> cancelNavigation() async { await _request('POST', '/navigation/cancel'); }

  // Pi endpoint is POST /navigation/goal with body {"destination": name}
  // (not /robot/goal/{name})
  Future<void> sendGoal(String name) async {
    await _request('POST', '/navigation/goal', body: {'destination': name});
  }

  // Pi returns {"destinations": [...]} where destinations is a List<String>
  Future<List<String>> getDestinations() async {
    final raw = (await _request('GET', '/destinations'))['destinations'];
    if (raw is List) {
      final names = raw.map((e) => e.toString()).toList();
      names.sort();
      return names;
    }
    // Fallback: if a Map is returned, use its keys
    if (raw is Map) {
      final names = raw.keys.map((e) => e.toString()).toList();
      names.sort();
      return names;
    }
    return [];
  }

  // Pi endpoint is POST /destinations with body {name, x, y, theta}
  // (not /destinations/{name})
  Future<void> addDestination(String name, double x, double y, double theta) async =>
      _request('POST', '/destinations', body: {'name': name, 'x': x, 'y': y, 'theta': theta});

  // Pi endpoint is DELETE /destinations/{name} — correct as-is
  Future<void> deleteDestination(String name) async =>
      _request('DELETE', '/destinations/${Uri.encodeComponent(name)}');

  Future<Map<String, dynamic>> createMission(List<String> destinations) =>
      _request('POST', '/missions', body: {'destinations': destinations});
  Future<Map<String, dynamic>> getMission(int id) => _request('GET', '/missions/$id');

  // Fetch event logs from Pi /logs endpoint
  Future<Map<String, dynamic>> getLogs({String? severity, int limit = 100}) {
    final params = <String>[];
    if (severity != null) params.add('severity=$severity');
    params.add('limit=$limit');
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    return _request('GET', '/logs$query');
  }
}
