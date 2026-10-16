import 'package:flutter/material.dart';
import '../main.dart';
import '../models/map_models.dart';
import '../services/prefs_service.dart';
import '../services/robot_service.dart';
import '../theme/app_theme.dart';
import 'navigation_screen.dart';

/// Settings — FR-SET-1 / FR-SET-2 / FR-SET-3
class SettingsScreen extends StatefulWidget {
  final RobotService service;
  const SettingsScreen({super.key, required this.service});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int _idleTimeout = 30;
  bool _notifyMission = true;
  bool _notifyLaunch = true;
  bool _darkMode = false;
  List<DestinationPose> _destinations = [];
  bool _loading = true;
  String? _error;
  String? _success;

  final _nameCtrl = TextEditingController();
  final _xCtrl = TextEditingController();
  final _yCtrl = TextEditingController();
  final _thetaCtrl = TextEditingController(text: '0');

  bool get _isAdmin => widget.service.role == 'administrator';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _idleTimeout = await PrefsService.getIdleTimeoutMinutes();
      _notifyMission = await PrefsService.getNotifyMission();
      _notifyLaunch = await PrefsService.getNotifyLaunch();
      _darkMode = await PrefsService.getDarkMode();
      _destinations = await widget.service.getDestinationPoses();
    } catch (e) {
      _error = e.toString();
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _addDestination() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() { _error = null; _success = null; });
    try {
      await widget.service.addDestination(
        name,
        double.parse(_xCtrl.text),
        double.parse(_yCtrl.text),
        double.parse(_thetaCtrl.text),
      );
      _nameCtrl.clear();
      _xCtrl.clear();
      _yCtrl.clear();
      _thetaCtrl.text = '0';
      _destinations = await widget.service.getDestinationPoses();
      if (mounted) setState(() => _success = "Destination '$name' added.");
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// Open the real map to let the admin pick a pose by tapping + dragging.
  Future<void> _addFromMap() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a destination name first.');
      return;
    }
    setState(() { _error = null; _success = null; });
    final pose = await showMapPosePicker(
      context: context,
      service: widget.service,
      destinationName: name,
      existingDestinations: _destinations,
    );
    if (pose == null || !mounted) return;
    // Pre-fill the manual form fields with the picked values
    _xCtrl.text = pose.x.toStringAsFixed(3);
    _yCtrl.text = pose.y.toStringAsFixed(3);
    _thetaCtrl.text = pose.theta.toStringAsFixed(1);
    // Auto-save immediately
    await _addDestination();
  }

  /// Open the real map to reposition an existing destination.
  Future<void> _editOnMap(DestinationPose d) async {
    setState(() { _error = null; _success = null; });
    final updated = await showMapPosePicker(
      context: context,
      service: widget.service,
      destinationName: d.name,
      initialPose: d,
      existingDestinations: _destinations,
    );
    if (updated == null || !mounted) return;
    try {
      await widget.service.addDestination(
        updated.name,
        updated.x,
        updated.y,
        updated.theta,
      );
      _destinations = await widget.service.getDestinationPoses();
      if (mounted) setState(() => _success = "Updated '${d.name}' position.");
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }


  Future<void> _deleteDestination(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete destination?'),
        content: Text('Remove "$name" from the map?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: AppColors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.service.deleteDestination(name);
      _destinations = await widget.service.getDestinationPoses();
      setState(() => _success = "Destination '$name' deleted.");
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _xCtrl.dispose();
    _yCtrl.dispose();
    _thetaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_error != null) _banner(_error!, AppColors.red),
                if (_success != null) _banner(_success!, AppColors.green),
                _section('Connection', [
                  ListTile(
                    leading: const Icon(Icons.router, color: AppColors.navy),
                    title: const Text('Backend URL'),
                    subtitle: Text(widget.service.baseUrl),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Change IP/port on the login screen by signing out.',
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                _section('Appearance', [
                  SwitchListTile(
                    secondary: const Icon(Icons.dark_mode_outlined),
                    title: const Text('Dark mode'),
                    subtitle: const Text('Switch between light and dark theme'),
                    value: _darkMode,
                    onChanged: (v) async {
                      await PrefsService.setDarkMode(v);
                      themeNotifier.value =
                          v ? ThemeMode.dark : ThemeMode.light;
                      setState(() => _darkMode = v);
                    },
                  ),
                ]),
                const SizedBox(height: 16),
                _section('Session', [
                  ListTile(
                    leading: const Icon(Icons.timer_outlined, color: AppColors.navy),
                    title: const Text('Idle timeout'),
                    subtitle: Text('Auto sign-out after $_idleTimeout minutes'),
                  ),
                  Slider(
                    value: _idleTimeout.toDouble(),
                    min: 5,
                    max: 120,
                    divisions: 23,
                    label: '$_idleTimeout min',
                    activeColor: AppColors.navy,
                    onChanged: (v) async {
                      final m = v.round();
                      await PrefsService.setIdleTimeoutMinutes(m);
                      setState(() => _idleTimeout = m);
                    },
                  ),
                ]),
                const SizedBox(height: 16),
                _section('Notifications', [
                  SwitchListTile(
                    title: const Text('Mission alerts'),
                    value: _notifyMission,
                    activeThumbColor: AppColors.navy,
                    onChanged: (v) async {
                      await PrefsService.setNotifyMission(v);
                      setState(() => _notifyMission = v);
                    },
                  ),
                  SwitchListTile(
                    title: const Text('Launch / stop alerts'),
                    value: _notifyLaunch,
                    activeThumbColor: AppColors.navy,
                    onChanged: (v) async {
                      await PrefsService.setNotifyLaunch(v);
                      setState(() => _notifyLaunch = v);
                    },
                  ),
                ]),
                if (_isAdmin) ...[
                  const SizedBox(height: 16),
                  _section('Destinations (Admin)', [
                    ..._destinations.map((d) => ListTile(
                          title: Text(d.name),
                          subtitle: Text(
                            'x=${d.x.toStringAsFixed(2)}  '
                            'y=${d.y.toStringAsFixed(2)}  '
                            'θ=${d.theta.toStringAsFixed(1)}°',
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.textSecondary),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_location_alt, color: AppColors.navy),
                                tooltip: 'Reposition on map',
                                onPressed: () => _editOnMap(d),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: AppColors.red),
                                tooltip: 'Delete',
                                onPressed: () => _deleteDestination(d.name),
                              ),
                            ],
                          ),
                        )),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          TextField(
                            controller: _nameCtrl,
                            decoration: const InputDecoration(labelText: 'Name'),
                          ),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: TextField(
                                controller: _xCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(labelText: 'X'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _yCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(labelText: 'Y'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _thetaCtrl,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: const InputDecoration(labelText: 'θ (°)'),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 12),
                          // ── Add from Map (primary method) ────────────────
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _addFromMap,
                              icon: const Icon(Icons.map),
                              label: const Text('Pick on Map'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.navy,
                                foregroundColor: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          // ── Manual entry (fallback) ──────────────────────
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text(
                              'Manual coordinates',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.textSecondary),
                            ),
                            children: [
                              Row(children: [
                                Expanded(
                                  child: TextField(
                                    controller: _xCtrl,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(labelText: 'X (m)'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: _yCtrl,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(labelText: 'Y (m)'),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: _thetaCtrl,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: const InputDecoration(labelText: 'θ (°)'),
                                  ),
                                ),
                              ]),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  onPressed: _addDestination,
                                  icon: const Icon(Icons.add_location_alt),
                                  label: const Text('Add Manually'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ]),
                ],
                const SizedBox(height: 16),
                _section('Account', [
                  ListTile(
                    leading: const Icon(Icons.person, color: AppColors.navy),
                    title: Text('Role: ${widget.service.role ?? 'operator'}'),
                  ),
                ]),
              ],
            ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(title.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary,
                  letterSpacing: 1.2,
                )),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _banner(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      ),
    );
  }
}
