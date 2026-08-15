import 'dart:async';
import 'package:flutter/material.dart';
import '../services/robot_service.dart';
import '../theme/app_theme.dart';

class MissionsScreen extends StatefulWidget {
  final RobotService service;
  final List<String> destinations;
  const MissionsScreen({super.key, required this.service, required this.destinations});

  @override
  State<MissionsScreen> createState() => _MissionsScreenState();
}

class _MissionsScreenState extends State<MissionsScreen> {
  final List<String> _selected = [];
  bool _loading = false;
  Map<String, dynamic>? _lastMission;
  String? _error;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _toggle(String dest) {
    setState(() {
      if (_selected.contains(dest)) {
        _selected.remove(dest);
      } else {
        _selected.add(dest);
      }
    });
  }

  Future<void> _start() async {
    if (_selected.isEmpty) return;
    setState(() { _loading = true; _error = null; });
    try {
      final m = await widget.service.createMission(List.from(_selected));
      setState(() { _lastMission = m; _selected.clear(); });
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    if (_lastMission == null) return;
    try {
      final m = await widget.service.getMission(_lastMission!['id'] as int);
      if (mounted) setState(() => _lastMission = m);
    } catch (e) {
      if (!silent && mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Color _stepColor(String status) {
    switch (status) {
      case 'completed':
        return AppColors.green;
      case 'in_progress':
        return AppColors.navy;
      case 'failed':
        return AppColors.red;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delivery Missions'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => _refresh()),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Build Mission',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    const SizedBox(height: 4),
                    const Text('Tap destinations in delivery order:',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 16),
                    if (widget.destinations.isEmpty)
                      const Text('No destinations available.',
                          style: TextStyle(color: AppColors.textSecondary))
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: widget.destinations.map((d) {
                          final sel = _selected.contains(d);
                          return FilterChip(
                            label: Text(d),
                            selected: sel,
                            selectedColor: AppColors.navy.withValues(alpha: 0.15),
                            checkmarkColor: AppColors.navy,
                            onSelected: (_) => _toggle(d),
                          );
                        }).toList(),
                      ),
                    if (_selected.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        children: _selected.asMap().entries.map((e) => Chip(
                              label: Text('${e.key + 1}. ${e.value}',
                                  style: const TextStyle(fontSize: 12)),
                              backgroundColor: AppColors.navy.withValues(alpha: 0.08),
                            )).toList(),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(_error!,
                            style: const TextStyle(color: AppColors.red, fontSize: 13)),
                      ),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: (_selected.isEmpty || _loading) ? null : _start,
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.play_arrow),
                        label: Text(_selected.isEmpty
                            ? 'Select destinations'
                            : 'Start Mission (${_selected.length} stops)'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            if (_lastMission != null) ...[
              Row(
                children: [
                  const Text('Active Mission',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const Spacer(),
                  if (_lastMission!['status'] == 'in_progress')
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('Mission #${_lastMission!["id"]}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          const Spacer(),
                          _StatusBadge(status: _lastMission!['status'] as String),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Progress: ${_lastMission!["progress"]}',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 13)),
                      const SizedBox(height: 16),
                      ...(_lastMission!['steps'] as List).map((s) {
                        final step = s as Map<String, dynamic>;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                step['status'] == 'completed'
                                    ? Icons.check_circle
                                    : step['status'] == 'in_progress'
                                        ? Icons.navigation
                                        : step['status'] == 'failed'
                                            ? Icons.cancel
                                            : Icons.radio_button_unchecked,
                                color: _stepColor(step['status'] as String),
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              Text('${(step['order'] as int) + 1}. ${step['destination']}',
                                  style: TextStyle(
                                    fontWeight: step['status'] == 'in_progress'
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  )),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = status == 'completed'
        ? AppColors.green
        : status == 'in_progress'
            ? AppColors.navy
            : status == 'failed'
                ? AppColors.red
                : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(status.replaceAll('_', ' ').toUpperCase(),
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}
