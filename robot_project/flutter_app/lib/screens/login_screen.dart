import 'package:flutter/material.dart';
import '../models/discovered_pi.dart';
import '../services/pi_discovery_service.dart';
import '../services/pi_remote_service.dart';
import '../services/prefs_service.dart';
import '../services/robot_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_logo.dart';
import 'home_screen.dart';

/// Connect to Pi on the same Wi‑Fi: auto discover → SSH → start backend → sign in.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _piPassCtrl = TextEditingController();
  final _manualIpCtrl = TextEditingController();
  final _apiUserCtrl = TextEditingController(text: 'admin');
  final _apiPassCtrl = TextEditingController(text: 'admin');

  bool _loading = false;
  bool _discovering = false;
  bool _obscurePi = true;
  bool _obscureApi = true;
  bool _showAdvanced = false;
  String? _error;
  String? _status;

  List<DiscoveredPi> _devices = [];
  DiscoveredPi? _selected;
  String? _tabletIp;
  String? _subnetHint;

  final _discovery = PiDiscoveryService();
  final _remote = PiRemoteService();

  @override
  void initState() {
    super.initState();
    _initConnection();
  }

  Future<void> _initConnection() async {
    _tabletIp = await _discovery.tabletIp();
    _subnetHint = await _discovery.subnetPrefix();
    await PrefsService.clearStaleConnection(tabletSubnetPrefix: _subnetHint);
    await _scanForPi();
  }

  bool _subnetMismatch(DiscoveredPi pi) {
    if (_subnetHint == null || _subnetHint!.isEmpty) return false;
    final parts = pi.ip.split('.');
    if (parts.length != 4) return false;
    final piPrefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    return piPrefix != _subnetHint;
  }

  String? _subnetMismatchMessage(DiscoveredPi pi) {
    if (!_subnetMismatch(pi)) return null;
    return 'Pi is on ${pi.ip.split('.').take(3).join('.')}.x but tablet is on '
        '$_subnetHint.x — put both on the same Wi‑Fi.\n'
        'On Pi run: hostname -I';
  }

  DiscoveredPi? _preferDevice(List<DiscoveredPi> devices) {
    if (devices.isEmpty) return null;
    if (_subnetHint != null) {
      for (final d in devices) {
        if (PiDiscoveryService.isAllowedPiUser(d.username) &&
            !_subnetMismatch(d)) {
          return d;
        }
      }
    }
    for (final d in devices) {
      if (PiDiscoveryService.isAllowedPiUser(d.username)) return d;
    }
    return devices.first;
  }

  Future<void> _scanForPi() async {
    setState(() {
      _discovering = true;
      _error = null;
      _selected = null;
      _devices = [];
      _status = 'Searching for Raspberry Pi (delv or abpi)...';
    });
    try {
      _tabletIp = await _discovery.tabletIp();
      _subnetHint = await _discovery.subnetPrefix();
      if (mounted && _tabletIp != null) {
        setState(() {
          _status =
              'Tablet $_tabletIp — auto-scanning Wi‑Fi (UDP beacon + API)...';
        });
      }
      final devices = await _discovery.discover();
      if (!mounted) return;
      final preferred = _preferDevice(devices);
      setState(() {
        _devices = devices;
        _selected = preferred;
        if (devices.isEmpty) {
          _status = 'No Pi found automatically.';
          _error =
              'Start on the Pi:\n'
              '  cd ~/raspberry_pi\n'
              '  bash run_server_ros.sh\n'
              '  python3 ~/raspberry_pi/pi_beacon.py\n'
              'Then tap Scan again. Both must be on same Wi‑Fi as tablet '
              '($_subnetHint.x).';
        } else if (preferred != null && _subnetMismatch(preferred)) {
          _status = 'Found ${preferred.username}@${preferred.ip} (wrong subnet)';
          _error = _subnetMismatchMessage(preferred);
        } else {
          _status =
              'Found ${preferred!.username}@${preferred.ip} via ${preferred.source}';
        }
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  DiscoveredPi? _targetPi() {
    final manual = _manualIpCtrl.text.trim();
    if (manual.isNotEmpty) {
      final user = PiDiscoveryService.normalizePiUser(
        _selected?.username ?? 'abpi',
      );
      return DiscoveredPi(
        username: user,
        hostname: 'manual',
        ip: manual,
        apiPort: PiDiscoveryService.defaultApiPort,
        source: 'manual',
      );
    }
    return _selected;
  }

  Future<DiscoveredPi?> _resolveManualPi() async {
    final manual = _manualIpCtrl.text.trim();
    if (manual.isEmpty) return null;
    setState(() => _status = 'Checking http://$manual:8000/health ...');
    final info = await PiDiscoveryService.probeApiInfo(
      manual,
      timeout: const Duration(seconds: 4),
    );
    if (info == null) {
      setState(() => _error =
          'No robot API at http://$manual:8000/health.\n'
          'On Pi run: hostname -I  then  bash ~/raspberry_pi/run_server_ros.sh');
      return null;
    }
    final user = PiDiscoveryService.normalizePiUser(
      (info['user'] ?? info['pi_user'] ?? _selected?.username ?? 'abpi')
          .toString(),
    );
    return DiscoveredPi(
      username: user,
      hostname: (info['host'] ?? info['hostname'] ?? 'pi').toString(),
      ip: manual,
      apiPort: PiDiscoveryService.defaultApiPort,
      source: 'manual',
    );
  }

  Future<void> _connect() async {
    DiscoveredPi? pi = _targetPi();
    if (_manualIpCtrl.text.trim().isNotEmpty) {
      pi = await _resolveManualPi();
      if (pi == null) return;
      setState(() => _selected = pi);
    }
    if (pi == null) {
      setState(() => _error = 'No Pi found — tap Scan or enter Pi IP below.');
      return;
    }

    final subnetErr = _manualIpCtrl.text.trim().isEmpty
        ? _subnetMismatchMessage(pi)
        : null;
    if (subnetErr != null) {
      setState(() => _error = subnetErr);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _status = 'Checking http://${pi!.ip}:${pi.apiPort}/health ...';
    });

    try {
      if (await _remote.isBackendUp(pi.ip, pi.apiPort)) {
        setState(() => _status = 'Backend already running — signing in...');
      } else {
        final reachErr = await _remote.checkApiReachable(pi);
        if (reachErr != null && reachErr.contains('Network unreachable')) {
          throw Exception(reachErr);
        }
        if (_piPassCtrl.text.isEmpty) {
          setState(() => _error =
              'Backend not running. Enter Pi password (SSH) to start it,\n'
              'or on the Pi run: cd ~/raspberry_pi && bash run_server_ros.sh');
          return;
        }
        setState(
          () => _status = 'Starting backend via SSH (${pi!.username}@${pi.ip})...',
        );
        await _remote.ensureBackendRunning(pi: pi, password: _piPassCtrl.text);
      }

      await PrefsService.saveConnection(pi.ip, pi.apiPort.toString());
      await PrefsService.savePiUsername(pi.username);

      setState(() => _status = 'Signing in to robot API...');
      final service = RobotService(baseUrl: 'http://${pi.ip}:${pi.apiPort}');
      await service.login(_apiUserCtrl.text.trim(), _apiPassCtrl.text);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen(service: service)),
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _piPassCtrl.dispose();
    _manualIpCtrl.dispose();
    _apiUserCtrl.dispose();
    _apiPassCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pi = _targetPi();
    final manualFilled = _manualIpCtrl.text.trim().isNotEmpty;
    final canConnect =
        (pi != null && (!_subnetMismatch(pi) || manualFilled)) && !_discovering;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              children: [
                const AppLogo(size: 120),
                const SizedBox(height: 16),
                const Text(
                  'Delivery Robot Controller',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Ethiopian Artificial Intelligence Institute',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Same Wi‑Fi as the Pi — auto discovery, no manual IP',
                  style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
                ),
                if (_tabletIp != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Tablet: $_tabletIp'
                    '${_subnetHint != null ? ' · scanning $_subnetHint.x + beacon' : ''}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'RASPBERRY PI',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.textSecondary,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _discovering ? null : _scanForPi,
                              icon: _discovering
                                  ? const SizedBox(
                                      width: 14,
                                      height: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.radar, size: 18),
                              label: Text(_discovering ? 'Scanning...' : 'Scan'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_discovering)
                          const Text(
                            'Looking for delv or abpi Pi (UDP + mDNS + API)...',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          )
                        else if (_devices.isEmpty)
                          const Text(
                            'No Pi detected yet. Tap Scan after starting backend + beacon on the Pi.',
                            style: TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary,
                            ),
                          )
                        else
                          DropdownButtonFormField<DiscoveredPi>(
                            isExpanded: true,
                            initialValue: _selected,
                            decoration: const InputDecoration(
                              labelText: 'Discovered Pi (auto)',
                              prefixIcon: Icon(Icons.memory),
                            ),
                            items: _devices
                                .map(
                                  (d) => DropdownMenuItem(
                                    value: d,
                                    child: Text(
                                      '${d.username} @ ${d.ip} (${d.source})',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: _loading
                                ? null
                                : (v) => setState(() => _selected = v),
                          ),
                        if (pi != null) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Icon(
                                _subnetMismatch(pi)
                                    ? Icons.warning_amber_rounded
                                    : Icons.check_circle,
                                color: _subnetMismatch(pi)
                                    ? AppColors.orange
                                    : AppColors.green,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${pi.username}@${pi.ip} · ${pi.hostname}',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        TextField(
                          controller: _manualIpCtrl,
                          enabled: !_loading,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Pi IP (manual override)',
                            hintText: 'e.g. 192.168.10.50 — from: hostname -I',
                            prefixIcon: Icon(Icons.edit_location_alt_outlined),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _piPassCtrl,
                          obscureText: _obscurePi,
                          enabled: !_loading,
                          decoration: InputDecoration(
                            labelText: 'Pi password (SSH, if backend not running)',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePi
                                    ? Icons.visibility_off
                                    : Icons.visibility,
                              ),
                              onPressed: () =>
                                  setState(() => _obscurePi = !_obscurePi),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _showAdvanced ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: AppColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _showAdvanced
                            ? 'Hide app login'
                            : 'Advanced (app login only)',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showAdvanced) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          TextField(
                            controller: _apiUserCtrl,
                            decoration: const InputDecoration(
                              labelText: 'App username',
                              prefixIcon: Icon(
                                Icons.admin_panel_settings_outlined,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _apiPassCtrl,
                            obscureText: _obscureApi,
                            decoration: InputDecoration(
                              labelText: 'App password',
                              prefixIcon: const Icon(Icons.key_outlined),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscureApi
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                                onPressed: () =>
                                    setState(() => _obscureApi = !_obscureApi),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _status!,
                    style: const TextStyle(color: AppColors.navy, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: AppColors.red.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: AppColors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: AppColors.red,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: (_loading || !canConnect) ? null : _connect,
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Text(
                            pi == null ? 'Scan for Pi first' : 'Connect & Start',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
