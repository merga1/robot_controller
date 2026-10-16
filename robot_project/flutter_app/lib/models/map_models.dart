/// Models for the real ROS occupancy-grid map and destination poses.
///
/// Coordinate system notes:
///   ROS map frame:
///     x increases to the right (east)
///     y increases upward (north)
///   Image pixel frame (standard image convention):
///     column (px) increases to the right
///     row    (py) increases downward
///
/// Transformation (standard ROS map_server convention):
///   px = (rosX - originX) / resolution
///   py = height - (rosY - originY) / resolution   ← Y axis is flipped
///
///   rosX = px * resolution + originX
///   rosY = (height - py) * resolution + originY
library;

import 'dart:math' as math;

/// Metadata returned by GET /navigation/map.
class MapMeta {
  /// URL relative to the Pi base URL, e.g. "/navigation/map/image"
  final String imageUrl;

  /// Metres per pixel (e.g. 0.05 means each pixel = 5 cm)
  final double resolution;

  /// ROS map frame origin — position of the lower-left image corner in map coords (metres)
  final double originX;
  final double originY;
  final double originYaw; // usually 0.0

  /// Image size in pixels
  final int width;
  final int height;

  /// Always "map"
  final String frameId;

  /// ROS map_server negate flag (0 = normal, 1 = invert occupancy)
  final int negate;

  const MapMeta({
    required this.imageUrl,
    required this.resolution,
    required this.originX,
    required this.originY,
    this.originYaw = 0.0,
    required this.width,
    required this.height,
    this.frameId = 'map',
    this.negate = 0,
  });

  factory MapMeta.fromJson(Map<String, dynamic> j) {
    final origin = j['origin'] as Map<String, dynamic>? ?? {};
    return MapMeta(
      imageUrl: j['image_url']?.toString() ?? '/navigation/map/image',
      resolution: (j['resolution'] as num?)?.toDouble() ?? 0.05,
      originX: (origin['x'] as num?)?.toDouble() ?? 0.0,
      originY: (origin['y'] as num?)?.toDouble() ?? 0.0,
      originYaw: (origin['yaw'] as num?)?.toDouble() ?? 0.0,
      width: (j['width'] as num?)?.toInt() ?? 0,
      height: (j['height'] as num?)?.toInt() ?? 0,
      frameId: j['frame_id']?.toString() ?? 'map',
      negate: (j['negate'] as num?)?.toInt() ?? 0,
    );
  }

  // ── Coordinate transformations ─────────────────────────────────────────────

  /// Convert ROS map frame coordinates (metres) to image pixel coordinates.
  ///
  /// Returns (pixelX, pixelY) where (0,0) is the top-left corner of the image.
  ///
  ///   px = (rosX - originX) / resolution
  ///   py = height - (rosY - originY) / resolution   ← Y flipped
  (double, double) rosToPixel(double rosX, double rosY) {
    final px = (rosX - originX) / resolution;
    final py = height - (rosY - originY) / resolution;
    return (px, py);
  }

  /// Convert image pixel coordinates to ROS map frame coordinates (metres).
  ///
  ///   rosX = px * resolution + originX
  ///   rosY = (height - py) * resolution + originY
  (double, double) pixelToRos(double px, double py) {
    final rosX = px * resolution + originX;
    final rosY = (height - py) * resolution + originY;
    return (rosX, rosY);
  }

  /// Map aspect ratio (width / height)
  double get aspectRatio => height > 0 ? width / height : 1.0;

  /// Map physical extent in metres
  double get physicalWidth => width * resolution;
  double get physicalHeight => height * resolution;

  @override
  String toString() =>
      'MapMeta(${width}x$height px, res=$resolution m/px, '
      'origin=(${originX.toStringAsFixed(2)}, ${originY.toStringAsFixed(2)}))';
}

/// A saved destination with full ROS map pose.
///
/// Returned by GET /destinations as part of the destinations array.
/// [theta] is stored in DEGREES (server storage convention, matching
/// destinations.json and navigate_client.py).
/// Use [thetaRadians] for trigonometry / display rotation.
class DestinationPose {
  final String name;

  /// ROS map frame position (metres)
  final double x;
  final double y;

  /// Orientation in DEGREES (server storage convention, matches destinations.json).
  final double theta;

  const DestinationPose({
    required this.name,
    required this.x,
    required this.y,
    required this.theta,
  });

  /// Orientation in radians (for trigonometry/CustomPaint rotation)
  double get thetaRadians => theta * math.pi / 180.0;

  factory DestinationPose.fromJson(Map<String, dynamic> j) => DestinationPose(
        name: j['name']?.toString() ?? '',
        x: (j['x'] as num?)?.toDouble() ?? 0.0,
        y: (j['y'] as num?)?.toDouble() ?? 0.0,
        theta: (j['theta'] as num?)?.toDouble() ?? 0.0,
      );

  /// To send to POST /destinations
  Map<String, dynamic> toJson() =>
      {'name': name, 'x': x, 'y': y, 'theta': theta};

  @override
  String toString() =>
      'Destination($name: x=${x.toStringAsFixed(2)}, '
      'y=${y.toStringAsFixed(2)}, θ=${theta.toStringAsFixed(1)}°)';
}
