import 'package:flutter/material.dart';
import '../services/robot_service.dart';
import '../theme/app_theme.dart';

/// Displays event logs fetched from the Pi's /logs endpoint (FR-LOG-1/2/3).
class LogsScreen extends StatefulWidget {
  final RobotService service;
  const LogsScreen({super.key, required this.service});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String? _severity;
  late Future<Map<String, dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _future = widget.service.getLogs(severity: _severity, limit: 100);
    });
  }

  Color _severityColor(String s) {
    switch (s.toLowerCase()) {
      case 'error':
        return AppColors.red;
      case 'warning':
        return AppColors.orange;
      case 'info':
        return AppColors.navy;
      default:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Robot Logs'),
        actions: [
          PopupMenuButton<String?>(
            icon: const Icon(Icons.filter_list),
            tooltip: 'Filter by severity',
            onSelected: (v) {
              _severity = v;
              _load();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: null, child: Text('All')),
              const PopupMenuItem(value: 'info', child: Text('Info')),
              const PopupMenuItem(value: 'warning', child: Text('Warning')),
              const PopupMenuItem(value: 'error', child: Text('Error')),
            ],
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                snapshot.error.toString(),
                style: const TextStyle(color: AppColors.red),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final logs = (snapshot.data!['logs'] as List? ?? []);
          if (logs.isEmpty) {
            return const Center(
              child: Text(
                'No log entries found.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: logs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final entry = logs[i] as Map<String, dynamic>;
              final sev = entry['severity']?.toString() ?? 'info';
              final src = entry['source']?.toString() ?? '';
              final msg = entry['message']?.toString() ?? '';
              final ts = entry['timestamp']?.toString() ?? '';
              return ListTile(
                dense: true,
                leading: Icon(
                  sev == 'error'
                      ? Icons.error_outline
                      : sev == 'warning'
                          ? Icons.warning_amber_outlined
                          : Icons.info_outline,
                  color: _severityColor(sev),
                  size: 18,
                ),
                title: Text(msg, style: const TextStyle(fontSize: 13)),
                subtitle: Text(
                  '$src · $ts',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
