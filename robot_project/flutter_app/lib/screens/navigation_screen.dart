import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../models/map_models.dart';
import '../models/robot_state.dart';
import '../services/robot_service.dart';
import '../theme/app_theme.dart';

/// Full-screen navigation screen showing the real ROS occupancy-grid map.
///
/// Features:
///   - Loads and displays the actual map from GET /navigation/map/image (once, cached)
///   - Positions robot marker using AMCL pose via the existing /robot/status poll
///   - Positions destination markers from GET /destinations (full poses)
///   - Tap a destination to select it, then press GO to trigger NavigateToPose
///   - Cancel navigation while in progress
///   - Correct ROS ↔ pixel coordinate transformation (Y-axis inverted)
///
/// The map is served from the Pi's saved map file (my_map.pgm / my_map.png).
/// Only the configured map is exposed — no arbitrary filesystem access.
class NavigationScreen extends StatefulWidget {
  final RobotService service;

  const NavigationScreen({super.key, required this.service});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  // ── State ──────────────────────────────────────────────────────────────────
  MapMeta? _mapMeta;
  Uint8List? _mapImageBytes;
  List<DestinationPose> _destinations = [];
  DestinationPose? _selectedDest;
  RobotState _robotState = RobotState.initial();

  bool _loadingMap = true;
  bool _loadingNav = false;
  String? _mapError;
  String? _navError;

  StreamSubscription<RobotState>? _stateSub;

  @override
  void initState() {
    super.initState();
    // Subscribe to the existing 1-second robot state stream — no extra polling.
    // Only rebuild when pose or status actually changed to avoid re-painting
    // the full map (LayoutBuilder + CustomPaint) every second when stationary.
    _stateSub = widget.service.stateStream.listen((s) {
      if (!mounted) return;
      final prev = _robotState;
      final poseChanged =
          (prev.pose.x - s.pose.x).abs() > 0.01 ||
          (prev.pose.y - s.pose.y).abs() > 0.01 ||
          (prev.pose.theta - s.pose.theta).abs() > 0.1;
      final statusChanged =
          prev.status != s.status ||
          prev.isNavigating != s.isNavigating ||
          prev.destination != s.destination ||
          prev.canOperate != s.canOperate;
      if (poseChanged || statusChanged) {
        setState(() {
          _robotState = s;
          // Clear the selected destination when navigation finishes so the
          // GO button resets and the user cannot accidentally re-trigger it.
          if (prev.isNavigating && !s.isNavigating) {
            _selectedDest = null;
          }
        });
      }
    });
    _loadMap();
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  // ── Data loading ──────────────────────────────────────────────────────────

  Future<void> _loadMap() async {
    setState(() { _loadingMap = true; _mapError = null; });
    try {
      // Fetch metadata and image in parallel
      final metaFuture = widget.service.getMapMeta();
      final destFuture = widget.service.getDestinationPoses();

      final meta = await metaFuture;
      _mapMeta = meta;

      // Fetch map image bytes (with auth header — the endpoint requires JWT)
      final imageBytes = await _fetchMapImage(meta);
      _mapImageBytes = imageBytes;

      _destinations = await destFuture;
    } catch (e) {
      _mapError = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _loadingMap = false);
    }
  }

  Future<Uint8List> _fetchMapImage(MapMeta meta) async {
    final token = widget.service.authToken;
    final url = '${widget.service.baseUrl}${meta.imageUrl}';
    final response = await http.get(
      Uri.parse(url),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
      },
    ).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Map image HTTP ${response.statusCode}');
    }
    return ensureDisplayableMapImage(response.bodyBytes);
  }

  Future<void> _refreshDestinations() async {
    try {
      final d = await widget.service.getDestinationPoses();
      if (mounted) setState(() => _destinations = d);
    } catch (_) {}
  }

  Future<void> _repositionDestination(DestinationPose d) async {
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
      await _refreshDestinations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Position for "${updated.name}" updated!'),
            backgroundColor: AppColors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }

  Future<void> _addNewDestination() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add New Destination'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Table / Place Name',
            hintText: 'e.g. Table 3',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Next: Place on Map'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    final pose = await showMapPosePicker(
      context: context,
      service: widget.service,
      destinationName: name,
      existingDestinations: _destinations,
    );
    if (pose == null || !mounted) return;
    try {
      await widget.service.addDestination(pose.name, pose.x, pose.y, pose.theta);
      await _refreshDestinations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added "${pose.name}" on map!'),
            backgroundColor: AppColors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add: $e'),
            backgroundColor: AppColors.red,
          ),
        );
      }
    }
  }

  void _showTableRepositionSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.edit_location_alt, color: AppColors.navy),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Place / Reposition Tables',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Tap "Move" on any table to place it at its exact location on the map:',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            ),
            const Divider(),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ..._destinations.map(
                    (d) => ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: AppColors.navy,
                        radius: 16,
                        child: Icon(Icons.table_restaurant, color: Colors.white, size: 18),
                      ),
                      title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(
                        'x=${d.x.toStringAsFixed(2)}m  y=${d.y.toStringAsFixed(2)}m  θ=${d.theta.toStringAsFixed(1)}°',
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                      trailing: ElevatedButton.icon(
                        icon: const Icon(Icons.place, size: 16),
                        label: const Text('Move'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.navy,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _repositionDestination(d);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add_location_alt),
                label: const Text('Add New Table / Place'),
                onPressed: () {
                  Navigator.pop(ctx);
                  _addNewDestination();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onDestinationLongPressed(DestinationPose d) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.place, color: AppColors.navy),
              title: Text(d.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                'Pose: x=${d.x.toStringAsFixed(2)}m, y=${d.y.toStringAsFixed(2)}m, θ=${d.theta.toStringAsFixed(1)}°',
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.edit_location_alt, color: AppColors.navy),
              title: const Text('Reposition Table on Map'),
              subtitle: const Text('Move this table to its physical location'),
              onTap: () {
                Navigator.pop(ctx);
                _repositionDestination(d);
              },
            ),
            if (_robotState.canOperate && !_robotState.isNavigating)
              ListTile(
                leading: const Icon(Icons.navigation, color: AppColors.green),
                title: Text('Navigate to ${d.name}'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _selectedDest = d);
                  _sendGoal();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Navigation actions ────────────────────────────────────────────────────

  Future<void> _sendGoal() async {
    if (_selectedDest == null) return;
    setState(() { _loadingNav = true; _navError = null; });

    // Show a brief snackbar with the destination coordinates so the user can
    // verify the stored position matches where they placed the table on the map.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Navigating to ${_selectedDest!.name}  '
            '(x=${_selectedDest!.x.toStringAsFixed(2)}m, '
            'y=${_selectedDest!.y.toStringAsFixed(2)}m, '
            'θ=${_selectedDest!.theta.toStringAsFixed(1)}°)',
          ),
          duration: const Duration(seconds: 4),
          backgroundColor: AppColors.navy,
        ),
      );
    }

    try {
      await widget.service.sendGoal(_selectedDest!.name);
    } catch (e) {
      setState(() => _navError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loadingNav = false);
    }
  }

  Future<void> _cancelNavigation() async {
    try {
      await widget.service.cancelNavigation();
    } catch (e) {
      setState(() => _navError = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Navigation Map'),
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_location_alt),
            tooltip: 'Place / Reposition tables',
            onPressed: _showTableRepositionSheet,
          ),
          // Tap = quick refresh destinations only (fast);
          // long-press = full map + destinations reload (slow but thorough).
          GestureDetector(
            onLongPress: _loadMap,
            child: IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh destinations (long-press to reload full map)',
              onPressed: _refreshDestinations,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Status bar ───────────────────────────────────────────────────
          _StatusBar(
            robotState: _robotState,
            selectedDest: _selectedDest,
            navError: _navError,
            loadingNav: _loadingNav,
            onGo: (_robotState.canOperate &&
                    _selectedDest != null &&
                    !_robotState.isNavigating &&
                    !_loadingNav)
                ? _sendGoal
                : null,
            onCancel: _robotState.isNavigating ? _cancelNavigation : null,
            onClearError: () => setState(() => _navError = null),
          ),
          // ── Map area ─────────────────────────────────────────────────────
          Expanded(
            child: _loadingMap
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Loading navigation map...'),
                      ],
                    ),
                  )
                : _mapError != null
                    ? _MapErrorWidget(
                        error: _mapError!,
                        onRetry: _loadMap,
                      )
                    : _MapView(
                        mapMeta: _mapMeta!,
                        mapImageBytes: _mapImageBytes!,
                        destinations: _destinations,
                        selectedDest: _selectedDest,
                        robotState: _robotState,
                        onDestinationTapped: (d) =>
                            setState(() => _selectedDest =
                                _selectedDest?.name == d.name ? null : d),
                        onDestinationLongPressed: _onDestinationLongPressed,
                      ),
          ),
          // ── Destination list ─────────────────────────────────────────────
          if (!_loadingMap && _mapError == null && _destinations.isNotEmpty)
            _DestinationBar(
              destinations: _destinations,
              selected: _selectedDest,
              canOperate: _robotState.canOperate,
              onSelect: (d) =>
                  setState(() => _selectedDest =
                      _selectedDest?.name == d.name ? null : d),
            ),
        ],
      ),
    );
  }
}

// ── Status bar ─────────────────────────────────────────────────────────────────

class _StatusBar extends StatelessWidget {
  final RobotState robotState;
  final DestinationPose? selectedDest;
  final String? navError;
  final bool loadingNav;
  final VoidCallback? onGo;
  final VoidCallback? onCancel;
  final VoidCallback onClearError;

  const _StatusBar({
    required this.robotState,
    required this.selectedDest,
    required this.navError,
    required this.loadingNav,
    required this.onGo,
    required this.onCancel,
    required this.onClearError,
  });

  String get _statusText {
    if (!robotState.rosRunning) return 'Robot not running — press START';
    if (robotState.isNavigating) {
      return robotState.destination != null
          ? 'Navigating → ${robotState.destination}'
          : robotState.message;
    }
    if (selectedDest != null) return 'Selected: ${selectedDest!.name}';
    return 'Tap a destination on the map or list below';
  }

  Color get _statusColor {
    if (!robotState.rosRunning) return AppColors.textSecondary;
    if (robotState.isNavigating) return AppColors.navy;
    if (selectedDest != null) return AppColors.green;
    return AppColors.textSecondary;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.navy.withValues(alpha: 0.05),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (navError != null) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.red.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: AppColors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(navError!,
                        style: const TextStyle(color: AppColors.red, fontSize: 12)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 14, color: AppColors.red),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: onClearError,
                  ),
                ],
              ),
            ),
          ],
          Row(
            children: [
              // Robot pose
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _statusText,
                      style: TextStyle(
                        color: _statusColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Robot: x=${robotState.pose.x.toStringAsFixed(2)} '
                      'y=${robotState.pose.y.toStringAsFixed(2)} '
                      'θ=${robotState.pose.theta.toStringAsFixed(1)}°',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              // Buttons
              if (robotState.isNavigating && onCancel != null) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.cancel, size: 16, color: AppColors.orange),
                  label: const Text('Cancel',
                      style: TextStyle(color: AppColors.orange, fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppColors.orange),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
              if (!robotState.isNavigating) ...[
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: onGo,
                  icon: loadingNav
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.navigation, size: 16),
                  label: Text(selectedDest != null
                      ? 'GO to ${selectedDest!.name}'
                      : 'GO'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: onGo != null ? AppColors.navy : AppColors.textSecondary,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ── Map view ──────────────────────────────────────────────────────────────────

class _MapView extends StatelessWidget {
  final MapMeta mapMeta;
  final Uint8List mapImageBytes;
  final List<DestinationPose> destinations;
  final DestinationPose? selectedDest;
  final RobotState robotState;
  final void Function(DestinationPose) onDestinationTapped;
  final void Function(DestinationPose)? onDestinationLongPressed;

  const _MapView({
    required this.mapMeta,
    required this.mapImageBytes,
    required this.destinations,
    required this.selectedDest,
    required this.robotState,
    required this.onDestinationTapped,
    this.onDestinationLongPressed,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Compute the actual rendered map rectangle within the available space,
      // preserving the map aspect ratio (letterboxing).
      final widgetW = constraints.maxWidth;
      final widgetH = constraints.maxHeight;
      final mapAspect = mapMeta.aspectRatio;
      final widgetAspect = widgetW / widgetH;

      double renderW, renderH, offsetX, offsetY;
      if (mapAspect > widgetAspect) {
        // Map is wider — fit to width, letterbox top/bottom
        renderW = widgetW;
        renderH = widgetW / mapAspect;
        offsetX = 0;
        offsetY = (widgetH - renderH) / 2;
      } else {
        // Map is taller — fit to height, pillarbox left/right
        renderH = widgetH;
        renderW = widgetH * mapAspect;
        offsetX = (widgetW - renderW) / 2;
        offsetY = 0;
      }

      // Scale factor: rendered pixels per image pixel
      final scale = renderW / mapMeta.width;

      return Stack(
        children: [
          // ── Map image ──────────────────────────────────────────────────
          Positioned(
            left: offsetX,
            top: offsetY,
            width: renderW,
            height: renderH,
            child: Image.memory(
              mapImageBytes,
              fit: BoxFit.fill,
            ),
          ),
          // ── Destination markers + robot marker ────────────────────────
          Positioned(
            left: offsetX,
            top: offsetY,
            width: renderW,
            height: renderH,
            child: CustomPaint(
              painter: _MapOverlayPainter(
                mapMeta: mapMeta,
                destinations: destinations,
                selectedDest: selectedDest,
                robotPose: robotState.pose,
                scale: scale,
              ),
              child: GestureDetector(
                onTapUp: (details) {
                  final tapPx = details.localPosition.dx / scale;
                  final tapPy = details.localPosition.dy / scale;

                  DestinationPose? closest;
                  double minDist = double.infinity;
                  const tolerancePx = 40.0; // pixels in image space

                  for (final d in destinations) {
                    final (destPx, destPy) =
                        mapMeta.rosToPixel(d.x, d.y);
                    final dx = tapPx - destPx;
                    final dy = tapPy - destPy;
                    final dist = math.sqrt(dx * dx + dy * dy);
                    if (dist < tolerancePx && dist < minDist) {
                      minDist = dist;
                      closest = d;
                    }
                  }
                  if (closest != null) {
                    onDestinationTapped(closest);
                  }
                },
                onLongPressStart: (details) {
                  final tapPx = details.localPosition.dx / scale;
                  final tapPy = details.localPosition.dy / scale;

                  DestinationPose? closest;
                  double minDist = double.infinity;
                  const tolerancePx = 40.0;

                  for (final d in destinations) {
                    final (destPx, destPy) =
                        mapMeta.rosToPixel(d.x, d.y);
                    final dx = tapPx - destPx;
                    final dy = tapPy - destPy;
                    final dist = math.sqrt(dx * dx + dy * dy);
                    if (dist < tolerancePx && dist < minDist) {
                      minDist = dist;
                      closest = d;
                    }
                  }
                  if (closest != null) {
                    onDestinationLongPressed?.call(closest);
                  }
                },
              ),
            ),
          ),
          // ── Map info overlay (bottom-left) ────────────────────────────
          Positioned(
            left: offsetX + 8,
            bottom: (widgetH - offsetY - renderH) + 8,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                '${mapMeta.width}×${mapMeta.height}px  '
                '${mapMeta.resolution * 100}cm/px  '
                '${mapMeta.physicalWidth.toStringAsFixed(1)}×'
                '${mapMeta.physicalHeight.toStringAsFixed(1)}m',
                style: const TextStyle(
                    color: Colors.white70, fontSize: 10),
              ),
            ),
          ),
        ],
      );
    });
  }
}

// ── Map overlay painter ────────────────────────────────────────────────────────

class _MapOverlayPainter extends CustomPainter {
  final MapMeta mapMeta;
  final List<DestinationPose> destinations;
  final DestinationPose? selectedDest;
  final RobotPose robotPose;
  final double scale; // rendered pixels per image pixel

  _MapOverlayPainter({
    required this.mapMeta,
    required this.destinations,
    required this.selectedDest,
    required this.robotPose,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // ── Destination markers ──────────────────────────────────────────────
    for (final dest in destinations) {
      final (px, py) = mapMeta.rosToPixel(dest.x, dest.y);
      final sx = px * scale;
      final sy = py * scale;
      final isSelected = selectedDest?.name == dest.name;

      _drawDestinationMarker(
        canvas: canvas,
        sx: sx,
        sy: sy,
        yawRad: dest.thetaRadians,
        isSelected: isSelected,
        label: dest.name,
      );
    }

    // ── Robot marker ─────────────────────────────────────────────────────
    // theta from /amcl_pose is already in DEGREES (converted in ros_hub.py)
    final robotYawRad = robotPose.theta * math.pi / 180.0;
    final (robotPx, robotPy) = mapMeta.rosToPixel(robotPose.x, robotPose.y);
    final robotSx = robotPx * scale;
    final robotSy = robotPy * scale;
    _drawRobotMarker(canvas, robotSx, robotSy, robotYawRad);
  }

  void _drawDestinationMarker({
    required Canvas canvas,
    required double sx,
    required double sy,
    required double yawRad,
    required bool isSelected,
    required String label,
  }) {
    final color = isSelected ? AppColors.green : AppColors.navy;
    final bgColor = isSelected
        ? AppColors.green.withValues(alpha: 0.85)
        : AppColors.navy.withValues(alpha: 0.75);

    // Circle background
    canvas.drawCircle(
      Offset(sx, sy),
      isSelected ? 14 : 10,
      Paint()..color = bgColor,
    );
    canvas.drawCircle(
      Offset(sx, sy),
      isSelected ? 14 : 10,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Orientation arrow
    _drawArrow(canvas, sx, sy, yawRad,
        length: isSelected ? 22 : 16,
        color: Colors.white,
        strokeWidth: isSelected ? 2.5 : 2.0);

    // Label
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          shadows: const [
            Shadow(color: Colors.white, blurRadius: 3),
            Shadow(color: Colors.white, blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(sx - textPainter.width / 2, sy + (isSelected ? 18 : 14)),
    );
  }

  void _drawRobotMarker(Canvas canvas, double sx, double sy, double yawRad) {
    // Orange robot body circle
    canvas.drawCircle(
      Offset(sx, sy),
      12,
      Paint()..color = AppColors.orange,
    );
    canvas.drawCircle(
      Offset(sx, sy),
      12,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Heading arrow (longer than destination arrows)
    _drawArrow(canvas, sx, sy, yawRad,
        length: 20, color: Colors.white, strokeWidth: 3);

    // "R" label
    final textPainter = TextPainter(
      text: const TextSpan(
        text: 'R',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset(sx - textPainter.width / 2, sy - textPainter.height / 2),
    );
  }

  /// Draw a direction arrow from (sx, sy) at angle [yawRad] (ROS convention:
  /// 0 = +X = right, 90° = +Y = up on map = down on screen because Y is
  /// flipped). We convert: screenAngle = -yawRad (Y axis flip).
  void _drawArrow(
    Canvas canvas,
    double sx,
    double sy,
    double yawRad, {
    required double length,
    required Color color,
    required double strokeWidth,
  }) {
    // In screen coords, ROS yaw 0 → pointing right (+x screen).
    // ROS yaw 90° → +y ROS → -y screen (up on screen).
    // Therefore screenAngle = -yawRad
    final angle = -yawRad;
    final tipX = sx + math.cos(angle) * length;
    final tipY = sy + math.sin(angle) * length;

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(sx, sy), Offset(tipX, tipY), paint);

    // Arrowhead
    final headLen = length * 0.35;
    const headAngle = 0.45; // radians
    canvas.drawLine(
      Offset(tipX, tipY),
      Offset(
        tipX - math.cos(angle - headAngle) * headLen,
        tipY - math.sin(angle - headAngle) * headLen,
      ),
      paint,
    );
    canvas.drawLine(
      Offset(tipX, tipY),
      Offset(
        tipX - math.cos(angle + headAngle) * headLen,
        tipY - math.sin(angle + headAngle) * headLen,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_MapOverlayPainter old) {
    if (old.robotPose.x != robotPose.x ||
        old.robotPose.y != robotPose.y ||
        old.robotPose.theta != robotPose.theta ||
        old.selectedDest?.name != selectedDest?.name ||
        old.scale != scale) {
      return true;
    }
    // Compare full destination content, not just length — repositioning
    // a destination changes coordinates but not count.
    if (old.destinations.length != destinations.length) return true;
    for (var i = 0; i < destinations.length; i++) {
      final a = old.destinations[i];
      final b = destinations[i];
      if (a.name != b.name || a.x != b.x || a.y != b.y || a.theta != b.theta) {
        return true;
      }
    }
    return false;
  }
}

// ── Destination list bar ───────────────────────────────────────────────────────

class _DestinationBar extends StatelessWidget {
  final List<DestinationPose> destinations;
  final DestinationPose? selected;
  final bool canOperate;
  final void Function(DestinationPose) onSelect;

  const _DestinationBar({
    required this.destinations,
    required this.selected,
    required this.canOperate,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      color: Colors.white,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: destinations.length,
        itemBuilder: (context, i) {
          final d = destinations[i];
          final isSelected = selected?.name == d.name;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(d.name,
                  style: TextStyle(
                    color: isSelected ? Colors.white : AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  )),
              selected: isSelected,
              selectedColor: AppColors.navy,
              checkmarkColor: Colors.white,
              onSelected: canOperate ? (_) => onSelect(d) : null,
            ),
          );
        },
      ),
    );
  }
}

// ── Error widget ───────────────────────────────────────────────────────────────

class _MapErrorWidget extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _MapErrorWidget({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'Could not load navigation map',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Make sure REAL1_WS or ROBOT_MAP_YAML is set in real1_link.env '
              'on the Raspberry Pi and the backend has been restarted.',
              style:
                  TextStyle(color: AppColors.textSecondary, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.navy,
                  foregroundColor: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Map-based pose picker — used by SettingsScreen to let admin click+drag a
// destination pose on the real map.
// ─────────────────────────────────────────────────────────────────────────────

/// Shows a full-screen map on which the user can select an (x, y, yaw) pose
/// by tapping/dragging on the real map.
///
/// Returns a [DestinationPose] with the selected pose and [name], or null
/// if cancelled. Theta is returned in DEGREES to match server convention.
Future<DestinationPose?> showMapPosePicker({
  required BuildContext context,
  required RobotService service,
  required String destinationName,
  DestinationPose? initialPose,
  List<DestinationPose>? existingDestinations,
}) {
  return Navigator.push<DestinationPose>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _MapPosePickerScreen(
        service: service,
        destinationName: destinationName,
        initialPose: initialPose,
        existingDestinations: existingDestinations ?? [],
      ),
    ),
  );
}

class _MapPosePickerScreen extends StatefulWidget {
  final RobotService service;
  final String destinationName;
  final DestinationPose? initialPose;
  final List<DestinationPose> existingDestinations;

  const _MapPosePickerScreen({
    required this.service,
    required this.destinationName,
    this.initialPose,
    this.existingDestinations = const [],
  });

  @override
  State<_MapPosePickerScreen> createState() => _MapPosePickerScreenState();
}

class _MapPosePickerScreenState extends State<_MapPosePickerScreen> {
  MapMeta? _mapMeta;
  Uint8List? _mapImageBytes;
  bool _loading = true;
  String? _error;

  // Pose being constructed
  Offset? _anchorPixel; // image-pixel coords of the selected point
  double _yawRad = 0.0; // orientation in radians (ROS convention: +X=0, +Y=pi/2)
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPose != null) {
      _yawRad = widget.initialPose!.thetaRadians;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final meta = await widget.service.getMapMeta();
      _mapMeta = meta;
      if (widget.initialPose != null) {
        final (px, py) = meta.rosToPixel(widget.initialPose!.x, widget.initialPose!.y);
        _anchorPixel = Offset(px, py);
      }
      final token = widget.service.authToken;
      final url = '${widget.service.baseUrl}${meta.imageUrl}';
      final response = await http.get(
        Uri.parse(url),
        headers: {if (token != null) 'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 30));
      _mapImageBytes = ensureDisplayableMapImage(response.bodyBytes);
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setAnchor(double localX, double localY, double scale) {
    setState(() {
      _anchorPixel = Offset(localX / scale, localY / scale);
    });
  }

  void _onPanStart(DragStartDetails details, double scale) {
    setState(() {
      _dragging = true;
      _anchorPixel = Offset(
        details.localPosition.dx / scale,
        details.localPosition.dy / scale,
      );
    });
  }

  void _onPanUpdate(DragUpdateDetails details, double scale) {
    if (_anchorPixel == null) return;
    final curPx = details.localPosition.dx / scale;
    final curPy = details.localPosition.dy / scale;
    final dx = curPx - _anchorPixel!.dx;
    final dy = curPy - _anchorPixel!.dy;
    if (dx.abs() > 3 || dy.abs() > 3) {
      setState(() => _yawRad = -math.atan2(dy, dx));
    }
  }

  void _onPanEnd(DragEndDetails _) {
    setState(() => _dragging = false);
  }

  void _confirm() {
    if (_anchorPixel == null || _mapMeta == null) return;
    final (rosX, rosY) = _mapMeta!.pixelToRos(_anchorPixel!.dx, _anchorPixel!.dy);
    final thetaDeg = _yawRad * 180.0 / math.pi;

    // Validate: warn if the computed ROS coordinates fall outside the
    // physical map extent (sanity check for origin/resolution mismatch).
    final maxX = _mapMeta!.physicalWidth + _mapMeta!.originX;
    final maxY = _mapMeta!.physicalHeight + _mapMeta!.originY;
    final outOfBounds =
        rosX < _mapMeta!.originX || rosX > maxX ||
        rosY < _mapMeta!.originY || rosY > maxY;
    if (outOfBounds) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '⚠ Coordinates (x=${rosX.toStringAsFixed(2)}, y=${rosY.toStringAsFixed(2)}) '
            'are outside the map extent. '
            'Map: x=[${_mapMeta!.originX.toStringAsFixed(1)}, ${maxX.toStringAsFixed(1)}] '
            'y=[${_mapMeta!.originY.toStringAsFixed(1)}, ${maxY.toStringAsFixed(1)}]. '
            'Saving anyway — verify map origin is correct.',
          ),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 6),
        ),
      );
    }

    Navigator.pop(
      context,
      DestinationPose(
        name: widget.destinationName,
        x: rosX,
        y: rosY,
        theta: thetaDeg,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Place: ${widget.destinationName}'),
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        actions: [
          if (_anchorPixel != null)
            TextButton.icon(
              onPressed: _confirm,
              icon: const Icon(Icons.check, color: Colors.white),
              label: const Text(
                'SAVE',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Loading floor map...'),
                ],
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: const TextStyle(color: AppColors.red)),
                      const SizedBox(height: 12),
                      ElevatedButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Position display & quick actions banner
                    Container(
                      color: AppColors.navy.withValues(alpha: 0.08),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.touch_app, size: 18, color: AppColors.navy),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _anchorPixel == null
                                      ? 'Tap or drag on the map to place "${widget.destinationName}"'
                                      : () {
                                          // Compute pixelToRos once — avoids calling it twice for x and y.
                                          final (rx, ry) = _mapMeta!.pixelToRos(
                                            _anchorPixel!.dx,
                                            _anchorPixel!.dy,
                                          );
                                          return 'x=${rx.toStringAsFixed(2)}m  '
                                              'y=${ry.toStringAsFixed(2)}m  '
                                              'θ=${(_yawRad * 180 / math.pi).toStringAsFixed(1)}°';
                                        }(),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              if (_anchorPixel != null)
                                TextButton(
                                  onPressed: () => setState(() => _anchorPixel = null),
                                  child: const Text('Clear'),
                                ),
                            ],
                          ),
                          if (_anchorPixel != null) ...[
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                const Text(
                                  'Heading:',
                                  style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                ),
                                const SizedBox(width: 8),
                                _angleChip('0° E', 0.0),
                                const SizedBox(width: 4),
                                _angleChip('90° N', 90.0),
                                const SizedBox(width: 4),
                                _angleChip('180° W', 180.0),
                                const SizedBox(width: 4),
                                _angleChip('270° S', 270.0),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(builder: (ctx, constraints) {
                        final meta = _mapMeta!;
                        final widgetW = constraints.maxWidth;
                        final widgetH = constraints.maxHeight;
                        final mapAspect = meta.aspectRatio;
                        final widgetAspect = widgetW / widgetH;

                        double renderW, renderH, offsetX, offsetY;
                        if (mapAspect > widgetAspect) {
                          renderW = widgetW;
                          renderH = widgetW / mapAspect;
                          offsetX = 0;
                          offsetY = (widgetH - renderH) / 2;
                        } else {
                          renderH = widgetH;
                          renderW = widgetH * mapAspect;
                          offsetX = (widgetW - renderW) / 2;
                          offsetY = 0;
                        }
                        final scale = renderW / meta.width;

                        return Stack(
                          children: [
                            Positioned(
                              left: offsetX,
                              top: offsetY,
                              width: renderW,
                              height: renderH,
                              child: GestureDetector(
                                onTapUp: (d) => _setAnchor(
                                  d.localPosition.dx,
                                  d.localPosition.dy,
                                  scale,
                                ),
                                onPanStart: (d) => _onPanStart(d, scale),
                                onPanUpdate: (d) => _onPanUpdate(d, scale),
                                onPanEnd: _onPanEnd,
                                child: CustomPaint(
                                  painter: _PosePickerPainter(
                                    mapMeta: meta,
                                    anchorPixel: _anchorPixel,
                                    yawRad: _yawRad,
                                    scale: scale,
                                    dragging: _dragging,
                                    destinationName: widget.destinationName,
                                    otherDestinations: widget.existingDestinations,
                                  ),
                                  child: Image.memory(
                                    _mapImageBytes!,
                                    fit: BoxFit.fill,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),
                    ),
                  ],
                ),
    );
  }

  Widget _angleChip(String label, double deg) {
    // Use positive-safe modulo: Dart's % returns negative for negative operands.
    final curDeg = ((_yawRad * 180 / math.pi) % 360 + 360) % 360;
    final isSelected = ((curDeg - deg).abs() < 5) || ((curDeg - deg).abs() > 355);
    return InkWell(
      onTap: () => setState(() => _yawRad = deg * math.pi / 180.0),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.navy : Colors.white,
          border: Border.all(color: AppColors.navy.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isSelected ? Colors.white : AppColors.navy,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _PosePickerPainter extends CustomPainter {
  final MapMeta mapMeta;
  final Offset? anchorPixel; // in image pixel space
  final double yawRad;
  final double scale;
  final bool dragging;
  final String destinationName;
  final List<DestinationPose> otherDestinations;

  _PosePickerPainter({
    required this.mapMeta,
    required this.anchorPixel,
    required this.yawRad,
    required this.scale,
    required this.dragging,
    this.destinationName = '',
    this.otherDestinations = const [],
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw other destinations faintly so user has spatial reference
    for (final d in otherDestinations) {
      if (d.name == destinationName) continue;
      final (px, py) = mapMeta.rosToPixel(d.x, d.y);
      final sx = px * scale;
      final sy = py * scale;
      canvas.drawCircle(
        Offset(sx, sy),
        8,
        Paint()..color = AppColors.navy.withValues(alpha: 0.4),
      );
      canvas.drawCircle(
        Offset(sx, sy),
        8,
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: d.name,
          style: TextStyle(
            color: AppColors.navy.withValues(alpha: 0.7),
            fontSize: 10,
            fontWeight: FontWeight.w500,
            shadows: const [
              Shadow(color: Colors.white, blurRadius: 2),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(sx - tp.width / 2, sy + 10));
    }

    if (anchorPixel == null) return;
    final sx = anchorPixel!.dx * scale;
    final sy = anchorPixel!.dy * scale;

    // Selected circle marker
    canvas.drawCircle(
      Offset(sx, sy),
      14,
      Paint()..color = AppColors.green.withValues(alpha: 0.85),
    );
    canvas.drawCircle(
      Offset(sx, sy),
      14,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // Orientation arrow (screen angle = -rosYaw)
    final screenAngle = -yawRad;
    final len = dragging ? 40.0 : 28.0;
    final tipX = sx + math.cos(screenAngle) * len;
    final tipY = sy + math.sin(screenAngle) * len;

    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(sx, sy), Offset(tipX, tipY), paint);

    const headLen = 12.0;
    const headAngle = 0.5;
    canvas.drawLine(
      Offset(tipX, tipY),
      Offset(
        tipX - math.cos(screenAngle - headAngle) * headLen,
        tipY - math.sin(screenAngle - headAngle) * headLen,
      ),
      paint,
    );
    canvas.drawLine(
      Offset(tipX, tipY),
      Offset(
        tipX - math.cos(screenAngle + headAngle) * headLen,
        tipY - math.sin(screenAngle + headAngle) * headLen,
      ),
      paint,
    );

    // Destination name label
    if (destinationName.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: destinationName,
          style: const TextStyle(
            color: AppColors.green,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            shadows: [
              Shadow(color: Colors.white, blurRadius: 4),
              Shadow(color: Colors.white, blurRadius: 4),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(sx - tp.width / 2, sy + 18));
    }
  }

  @override
  bool shouldRepaint(_PosePickerPainter old) =>
      old.anchorPixel != anchorPixel ||
      old.yawRad != yawRad ||
      old.dragging != dragging;
}

// ─────────────────────────────────────────────────────────────────────────────
// Map Image Format Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Ensures map image bytes are in a format supported by Flutter's [Image.memory]
/// (PNG, JPEG, BMP). If raw PGM (P5 Netpbm) bytes are received, converts them
/// to an uncompressed 8-bit BMP in memory.
Uint8List ensureDisplayableMapImage(Uint8List bytes) {
  if (bytes.length < 4) return bytes;
  // PNG magic: 0x89 'P' 'N' 'G'
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    return bytes;
  }
  // BMP magic: 'B' 'M'
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return bytes;
  }
  // JPEG magic: 0xFF 0xD8
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    return bytes;
  }
  // PGM magic: 'P' '5' (binary grayscale Netpbm)
  if (bytes[0] == 0x50 && bytes[1] == 0x35) {
    try {
      return _convertP5ToBmp(bytes);
    } catch (_) {
      return bytes;
    }
  }
  return bytes;
}

/// Converts raw P5 binary PGM bytes into an uncompressed 8-bit BMP byte array.
Uint8List _convertP5ToBmp(Uint8List pgm) {
  int pos = 0;
  final tokens = <String>[];
  while (tokens.length < 4 && pos < pgm.length) {
    // Skip whitespace
    while (pos < pgm.length &&
        (pgm[pos] == 32 || pgm[pos] == 9 || pgm[pos] == 10 || pgm[pos] == 13)) {
      pos++;
    }
    if (pos >= pgm.length) break;
    // Skip comment line
    if (pgm[pos] == 35) {
      while (pos < pgm.length && pgm[pos] != 10 && pgm[pos] != 13) {
        pos++;
      }
      continue;
    }
    final start = pos;
    while (pos < pgm.length &&
        pgm[pos] != 32 &&
        pgm[pos] != 9 &&
        pgm[pos] != 10 &&
        pgm[pos] != 13 &&
        pgm[pos] != 35) {
      pos++;
    }
    if (start < pos) {
      tokens.add(String.fromCharCodes(pgm.sublist(start, pos)));
    }
  }
  // Skip exactly one whitespace character following maxval
  if (pos < pgm.length &&
      (pgm[pos] == 32 || pgm[pos] == 9 || pgm[pos] == 10 || pgm[pos] == 13)) {
    pos++;
  }
  if (tokens.length < 4 || tokens[0] != 'P5') {
    return pgm;
  }
  final width = int.tryParse(tokens[1]) ?? 0;
  final height = int.tryParse(tokens[2]) ?? 0;
  if (width <= 0 || height <= 0) return pgm;

  final rowPad = (4 - (width % 4)) % 4;
  final rowStride = width + rowPad;
  final pixelSize = rowStride * height;
  const offset = 14 + 40 + 1024;
  final fileSize = offset + pixelSize;

  final bmp = Uint8List(fileSize);
  final bd = ByteData.sublistView(bmp);

  // 14-byte File Header
  bmp[0] = 0x42; // 'B'
  bmp[1] = 0x4D; // 'M'
  bd.setUint32(2, fileSize, Endian.little);
  bd.setUint32(6, 0, Endian.little);
  bd.setUint32(10, offset, Endian.little);

  // 40-byte DIB Header (BITMAPINFOHEADER)
  bd.setUint32(14, 40, Endian.little);
  bd.setInt32(18, width, Endian.little);
  bd.setInt32(22, -height, Endian.little); // negative height for top-down bitmap
  bd.setUint16(26, 1, Endian.little);
  bd.setUint16(28, 8, Endian.little); // 8 bpp
  bd.setUint32(30, 0, Endian.little); // BI_RGB
  bd.setUint32(34, pixelSize, Endian.little);
  bd.setInt32(38, 2835, Endian.little);
  bd.setInt32(42, 2835, Endian.little);
  bd.setUint32(46, 256, Endian.little);
  bd.setUint32(50, 256, Endian.little);

  // 1024-byte Grayscale Palette (B, G, R, 0)
  int palOffset = 54;
  for (int i = 0; i < 256; i++) {
    bmp[palOffset++] = i;
    bmp[palOffset++] = i;
    bmp[palOffset++] = i;
    bmp[palOffset++] = 0;
  }

  // Copy rows
  int dataPos = pos;
  int outPos = offset;
  for (int r = 0; r < height; r++) {
    for (int c = 0; c < width; c++) {
      if (dataPos < pgm.length) {
        bmp[outPos++] = pgm[dataPos++];
      } else {
        bmp[outPos++] = 205;
      }
    }
    for (int p = 0; p < rowPad; p++) {
      bmp[outPos++] = 0;
    }
  }

  return bmp;
}
