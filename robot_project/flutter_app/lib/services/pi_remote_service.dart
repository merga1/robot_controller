import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:http/http.dart' as http;

import '../models/discovered_pi.dart';
import 'pi_discovery_service.dart';

/// SSH into the Pi (delv or abpi), start the backend if needed, wait until /health responds.
class PiRemoteService {
  static const _startCmd =
      'bash -lc "chmod +x ~/raspberry_pi/start_backend.sh ~/raspberry_pi/install_pi_services.sh 2>/dev/null; '
      'bash ~/raspberry_pi/start_backend.sh || '
      '(cd ~/raspberry_pi && nohup bash run_server_ros.sh >/tmp/robot-api.log 2>&1 &)"';

  DiscoveredPi _normalize(DiscoveredPi pi) {
    final user = PiDiscoveryService.normalizePiUser(pi.username);
    if (!PiDiscoveryService.isAllowedPiUser(user)) {
      throw Exception(
        'Unknown Pi user "${pi.username}" at ${pi.ip}. '
        'Use delv or abpi.',
      );
    }
    return DiscoveredPi(
      username: user,
      hostname: pi.hostname,
      ip: pi.ip,
      apiPort: pi.apiPort,
      source: pi.source,
    );
  }

  Future<bool> isBackendUp(String ip, int port) async {
    return PiDiscoveryService.probeApiHealth(ip, port: port);
  }

  Future<String?> checkApiReachable(DiscoveredPi pi) async {
    final target = _normalize(pi);
    final url = 'http://${target.ip}:${target.apiPort}/health';
    try {
      final res = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) return null;
      return 'Robot API at $url returned HTTP ${res.statusCode}';
    } on SocketException catch (e) {
      return _socketHint(e, target, forSsh: false);
    } on TimeoutException {
      return 'No response from $url within 5 seconds.\n'
          'On the Pi (${target.username}) run: cd ~/raspberry_pi && bash run_server_ros.sh';
    } catch (e) {
      return 'Cannot reach $url — $e';
    }
  }

  String _socketHint(SocketException e, DiscoveredPi pi, {required bool forSsh}) {
    final msg = e.message.toLowerCase();
    final service = forSsh ? 'SSH (port 22)' : 'robot API (port ${pi.apiPort})';
    final user = pi.username;
    final ip = pi.ip;
    if (msg.contains('network is unreachable') || e.osError?.errorCode == 101) {
      return 'Network unreachable — tablet cannot route to $ip.\n'
          '• Tablet and Pi ($user) must be on the same Wi‑Fi\n'
          '• On Pi run: hostname -I\n'
          '• Disable VPN on the tablet';
    }
    if (msg.contains('connection refused') || e.osError?.errorCode == 111) {
      if (forSsh) {
        return 'SSH refused on $user@$ip:22 — on the Pi run:\n'
            'sudo systemctl enable --now ssh';
      }
      return 'Nothing listening on http://$ip:${pi.apiPort} — on Pi ($user) run:\n'
          'cd ~/raspberry_pi && bash run_server_ros.sh';
    }
    if (msg.contains('timed out') || msg.contains('timeout')) {
      return 'Timed out reaching $service at $ip — check firewall / same Wi‑Fi.';
    }
    return 'Cannot reach $service at $ip — ${e.message}';
  }

  SSHClient _client(SSHSocket socket, DiscoveredPi pi, String password) {
    return SSHClient(
      socket,
      username: pi.username,
      onPasswordRequest: () => password,
      onUserInfoRequest: (request) =>
          List.filled(request.prompts.length, password),
    );
  }

  Future<SSHClient> _connect(DiscoveredPi pi, String password) async {
    final target = _normalize(pi);
    try {
      final socket = await SSHSocket.connect(
        target.ip,
        22,
        timeout: const Duration(seconds: 12),
      );
      final client = _client(socket, target, password);
      await client.authenticated.timeout(const Duration(seconds: 15));
      return client;
    } on SocketException catch (e) {
      throw Exception(_socketHint(e, target, forSsh: true));
    }
  }

  Future<bool> _healthOnPi(SSHClient client) async {
    const cmd =
        "python3 -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)\"";
    try {
      final result = await client.runWithResult(cmd).timeout(
            const Duration(seconds: 8),
          );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String> _fetchPiLog(SSHClient client) async {
    try {
      final out = await client
          .run('tail -30 /tmp/robot-api.log 2>/dev/null || echo "(no log)"')
          .timeout(const Duration(seconds: 8));
      return utf8.decode(out).trim();
    } catch (_) {
      return '(could not read /tmp/robot-api.log)';
    }
  }

  Future<void> ensureBackendRunning({
    required DiscoveredPi pi,
    required String password,
  }) async {
    final target = _normalize(pi);
    if (await isBackendUp(target.ip, target.apiPort)) return;

    final preflight = await checkApiReachable(target);
    if (preflight != null && preflight.contains('Network unreachable')) {
      throw Exception(preflight);
    }

    SSHClient? client;
    try {
      client = await _connect(target, password);

      await client.runWithResult(_startCmd).timeout(
            const Duration(seconds: 90),
          );

      for (var i = 0; i < 60; i++) {
        if (await isBackendUp(target.ip, target.apiPort)) return;
        await Future.delayed(const Duration(seconds: 1));
      }

      if (await _healthOnPi(client)) {
        throw Exception(
          'Backend is running on ${target.username} Pi, but the tablet cannot reach '
          'http://${target.ip}:${target.apiPort}.\n'
          'Use the same Wi‑Fi (not guest/isolated). On the Pi check:\n'
          'sudo ufw allow 8000/tcp',
        );
      }

      final log = await _fetchPiLog(client);
      throw Exception(
        'Backend did not respond on http://${target.ip}:${target.apiPort}/health.\n'
        'On ${target.username} Pi run: cd ~/raspberry_pi && bash run_server_ros.sh\n'
        'Log:\n$log',
      );
    } on TimeoutException {
      throw Exception('SSH timed out connecting to ${target.username}@${target.ip}');
    } on SSHAuthFailError {
      throw Exception(
        'SSH login failed for ${target.username}@${target.ip}. Check password.',
      );
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('SSHAuthFailError') ||
          msg.contains('Authentication') ||
          msg.contains('authentication')) {
        throw Exception(
          'SSH login failed for ${target.username}@${target.ip}. Check password.',
        );
      }
      rethrow;
    } finally {
      client?.close();
    }
  }
}
