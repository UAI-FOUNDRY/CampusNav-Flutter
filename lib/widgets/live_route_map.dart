import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/destination.dart';
import '../models/route.dart';
import '../theme/app_colors.dart';
import '../theme/destination_style.dart';
import 'person_marker.dart';

const _streetUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

// Esri World Imagery (satellite). Note the order is {z}/{y}/{x}: row first.
const _satelliteUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// The real outdoor map. Satellite imagery (default) or the street map, with
/// a route line, tappable destination pins, and "you are here".
///
/// Overview: pass [route]; the person icon sits at the start of the line.
/// Guidance: also pass [person] and [follow]. The person icon then glides
/// along the route to each new [person] position, the camera follows it, and
/// the part of the line already walked turns grey.
///
/// Both tile servers are free for light use with attribution, which is fine
/// for a university project. Before a public launch, check Esri's and
/// OpenStreetMap's terms, or switch to a keyed provider (Mapbox, MapTiler).
class LiveCampusMap extends StatefulWidget {
  final List<GeoPoint> route;
  final Color color;
  final List<Destination> pins;
  final ValueChanged<Destination>? onPinTap;
  final double height;

  /// Where the user is right now (guidance). Null shows the start of the route.
  final GeoPoint? person;

  /// Keep the camera centred on the person (guidance).
  final bool follow;

  /// While following: turn the map so the way you are walking points up,
  /// with you low on the screen and the route ahead above you (like Google
  /// Maps navigation). The direction comes from the route itself (where the
  /// path goes next), which is steadier than the phone's compass.
  final bool headingUp;

  /// Fill all the space it is given (square corners, round buttons at the
  /// bottom right) instead of being a rounded card of [height]. Used by the
  /// full-screen navigation view.
  final bool fill;

  /// In [fill] mode: space kept clear at the bottom (a card over the map);
  /// the round buttons and the attribution sit above it.
  final double bottomInset;

  /// Space kept clear at the top (chips over the map); the compass sits below.
  final double topInset;

  /// How long the person icon takes to glide to a new [person] position.
  final Duration glide;

  /// Where to look when there is no route to fit (Universal AI University).
  static const campus = LatLng(18.9027, 73.3742);

  const LiveCampusMap({
    super.key,
    this.route = const [],
    this.color = AppColors.academic,
    this.pins = const [],
    this.onPinTap,
    this.height = 300,
    this.person,
    this.follow = false,
    this.headingUp = false,
    this.fill = false,
    this.bottomInset = 0,
    this.topInset = 0,
    this.glide = const Duration(milliseconds: 1400),
  });

  @override
  State<LiveCampusMap> createState() => _LiveCampusMapState();
}

class _LiveCampusMapState extends State<LiveCampusMap>
    with SingleTickerProviderStateMixin {
  static const _dist = Distance(roundResult: false); // keep sub-metre precision
  static const _followZoom = 18.5;

  final _controller = MapController();
  late final AnimationController _anim;

  bool _satellite = true;
  double _rotation = 0; // degrees, for the compass

  // Following the person (guidance). A pan / pinch / twist by hand stops it
  // until "Centre on me"; the compass switches to north-up.
  bool _free = false;
  bool _northUp = false;
  double? _bearing; // degrees the camera is turned to (eased towards the route)
  bool _ready = false; // the map can only be moved after it has been built

  LatLng? _me; // where the person icon is drawn right now
  List<LatLng> _glide = const []; // the points it is walking along

  List<LatLng> get _line =>
      [for (final p in widget.route) LatLng(p.lat, p.lng)];

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..addListener(_tick);

    final person = widget.person;
    if (person != null) {
      _me = LatLng(person.lat, person.lng);
    } else if (_line.isNotEmpty) {
      _me = _line.first;
    }
  }

  @override
  void didUpdateWidget(LiveCampusMap old) {
    super.didUpdateWidget(old);
    final now = widget.person;
    final before = old.person;
    if (now == null) return;
    if (before != null && before.lat == now.lat && before.lng == now.lng) return;

    final from = _me;
    final to = LatLng(now.lat, now.lng);
    _glide = from == null ? [to] : _pathAlong(_line, from, to);
    _anim.duration = widget.glide;
    _anim.forward(from: 0);
  }

  @override
  void dispose() {
    _anim.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Runs on every frame of the glide.
  void _tick() {
    final p = _sample(_glide, Curves.easeInOut.transform(_anim.value));
    setState(() => _me = p);
    _followCamera(p);
  }

  bool get _turning => widget.follow && widget.headingUp && !_northUp;

  /// Keeps the camera on [p]: north-up and centred, or (heading-up) turned
  /// to the way ahead with [p] in the lower part of the screen.
  void _followCamera(LatLng p, {bool snap = false}) {
    if (!widget.follow || !_ready || _free) return;
    if (!_turning) {
      _controller.move(p, _controller.camera.zoom);
      return;
    }
    final target = _headingAt(p);
    if (target != null) {
      final now = _bearing;
      // Ease towards the new direction, the short way round, so corners turn
      // the map smoothly instead of snapping.
      _bearing = (now == null || snap) ? target : _wrap360(now + _wrap180(target - now) * 0.12);
      _controller.rotate(-_bearing!);
    }
    final h = _controller.camera.nonRotatedSize.height;
    _controller.move(p, _controller.camera.zoom, offset: Offset(0, h * 0.22));
  }

  static double _wrap180(double a) => ((a + 540) % 360) - 180;
  static double _wrap360(double a) => (a % 360 + 360) % 360;

  /// Compass direction (0 = north, clockwise) of the path from [p] towards a
  /// point about 15 m further along it. Looking a little ahead makes the map
  /// start turning just before a corner, not after it.
  double? _headingAt(LatLng p) {
    final line = _line;
    if (line.length < 2) return null;
    final at = _onLine(line, p);
    var from = at.point;
    var left = 15.0;
    var target = line.last;
    for (var i = at.seg + 1; i < line.length; i++) {
      final step = _dist.distance(from, line[i]);
      if (step >= left) {
        final f = step == 0 ? 0.0 : left / step;
        target = LatLng(
          from.latitude + (line[i].latitude - from.latitude) * f,
          from.longitude + (line[i].longitude - from.longitude) * f,
        );
        break;
      }
      left -= step;
      from = line[i];
    }
    if (_dist.distance(at.point, target) < 1) {
      // At the very end: keep the last direction of the path.
      return _dist.bearing(line[line.length - 2], line.last);
    }
    return _dist.bearing(at.point, target);
  }

  /// "Centre on me": follow again (and turn heading-up again, if used).
  void _recentre(LatLng me) {
    setState(() {
      _free = false;
      _northUp = false;
    });
    if (!_ready) return;
    if (widget.follow) {
      _controller.move(me, _followZoom);
      _followCamera(me, snap: true);
    } else {
      _controller.move(me, _followZoom);
    }
  }

  /// Where [p] lies on the line: the piece it is on (from line[seg] to
  /// line[seg + 1]) and the closest point. Measured along the pieces, not to
  /// the nearest corner: the nearest corner can be just ahead of you, which
  /// made the grey "walked" line overshoot and the red line cut the corner.
  ({int seg, LatLng point}) _onLine(List<LatLng> line, LatLng p) {
    if (line.length < 2) return (seg: 0, point: line.isEmpty ? p : line.first);
    final k = math.cos(p.latitude * math.pi / 180); // squash longitude to metres-ish
    final px = p.longitude * k;
    final py = p.latitude;
    var best = 0;
    var bestD = double.infinity;
    var bestPt = line.first;
    for (var i = 0; i + 1 < line.length; i++) {
      final ax = line[i].longitude * k, ay = line[i].latitude;
      final dx = line[i + 1].longitude * k - ax, dy = line[i + 1].latitude - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0).toDouble();
      final cx = ax + t * dx, cy = ay + t * dy;
      final d = (px - cx) * (px - cx) + (py - cy) * (py - cy);
      if (d < bestD) {
        bestD = d;
        best = i;
        bestPt = LatLng(cy, cx / k);
      }
    }
    return (seg: best, point: bestPt);
  }

  /// The route between two spots on it, so the person glides along the path
  /// (round its corners) instead of cutting across.
  List<LatLng> _pathAlong(List<LatLng> line, LatLng from, LatLng to) {
    if (line.length < 2) return [from, to];
    final i = _onLine(line, from).seg;
    final j = _onLine(line, to).seg;
    if (i == j) return [from, to];
    final corners = i < j
        ? line.sublist(i + 1, j + 1) // forwards: the corners in between
        : line.sublist(j + 1, i + 1).reversed.toList(); // backwards
    return [from, ...corners, to];
  }

  /// The point [t] (0..1) of the way along a path, measured in metres.
  LatLng _sample(List<LatLng> pts, double t) {
    if (pts.isEmpty) return _me ?? LiveCampusMap.campus;
    if (pts.length < 2) return pts.first;

    final lengths = <double>[];
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final m = _dist.distance(pts[i - 1], pts[i]);
      lengths.add(m);
      total += m;
    }
    if (total == 0) return pts.last;

    var left = total * t.clamp(0.0, 1.0);
    for (var i = 0; i < lengths.length; i++) {
      if (left <= lengths[i] || i == lengths.length - 1) {
        final f = lengths[i] == 0 ? 1.0 : (left / lengths[i]).clamp(0.0, 1.0);
        return LatLng(
          pts[i].latitude + (pts[i + 1].latitude - pts[i].latitude) * f,
          pts[i].longitude + (pts[i + 1].longitude - pts[i].longitude) * f,
        );
      }
      left -= lengths[i];
    }
    return pts.last;
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    final pinned = [for (final d in widget.pins) if (d.hasGeo) d];

    // Guidance: the walked part of the route turns grey.
    var walked = <LatLng>[];
    var ahead = line;
    final me = _me;
    if (widget.follow && me != null && line.length > 1) {
      // Split exactly where you are on the line.
      final k = _onLine(line, me).seg;
      walked = [...line.sublist(0, k + 1), me];
      ahead = [me, ...line.sublist(k + 1)];
    }

    // What the camera should fit: the route if there is one, else every pin.
    final focus = line.isNotEmpty
        ? line
        : [for (final d in pinned) LatLng(d.lat!, d.lng!)];
    final following = widget.follow && me != null;

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.fill ? 0 : 20),
      child: SizedBox(
        height: widget.fill ? double.infinity : widget.height,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _controller,
              options: MapOptions(
                initialCenter: (following ? me : null) ??
                    (focus.isEmpty ? LiveCampusMap.campus : focus.first),
                initialZoom: following ? _followZoom : 17,
                maxZoom: 21,
                initialCameraFit: !following && focus.length > 1
                    ? CameraFit.bounds(
                        bounds: LatLngBounds.fromPoints(focus),
                        padding: const EdgeInsets.all(40),
                        maxZoom: 19,
                      )
                    : null,
                onMapReady: () {
                  _ready = true;
                  final me = _me;
                  if (widget.follow && me != null) _followCamera(me, snap: true);
                },
                onPositionChanged: (camera, hasGesture) {
                  // Moved by hand while following: stop following until
                  // "Centre on me".
                  if (hasGesture && widget.follow && !_free) {
                    setState(() => _free = true);
                  }
                  if ((camera.rotation - _rotation).abs() > 0.5) {
                    setState(() => _rotation = camera.rotation);
                  }
                },
                // Gestures tuned to feel like Google Maps:
                // - a two-finger gesture first has to "decide" what it is: a
                //   twist of 15 degrees makes it a rotation, a clear pinch makes
                //   it a zoom (and then it will not turn the map by accident);
                // - once rotating, you can still zoom and move with the same
                //   two fingers;
                // - fling, two-finger move, double-tap zoom, double-tap-and-drag
                //   one-finger zoom and the mouse wheel all work.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                  enableMultiFingerGestureRace: true,
                  rotationThreshold: 15,
                  rotationWinGestures: MultiFingerGesture.all,
                  pinchZoomThreshold: 0.25,
                  pinchZoomWinGestures:
                      MultiFingerGesture.pinchZoom | MultiFingerGesture.pinchMove,
                  pinchMoveThreshold: 30,
                  pinchMoveWinGestures:
                      MultiFingerGesture.pinchZoom | MultiFingerGesture.pinchMove,
                ),
              ),
              children: [
                TileLayer(
                  key: ValueKey(_satellite),
                  urlTemplate: _satellite ? _satelliteUrl : _streetUrl,
                  // Past this zoom the server has no sharper tiles, so
                  // flutter_map enlarges the last real ones instead of
                  // showing "map data not available".
                  maxNativeZoom: 19,
                  userAgentPackageName: 'com.example.campus_navigation',
                ),
                if (walked.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: walked,
                        strokeWidth: 6,
                        color: Colors.grey.shade500,
                        borderStrokeWidth: 3,
                        borderColor: Colors.white,
                      ),
                    ],
                  ),
                if (ahead.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: ahead,
                        strokeWidth: 6,
                        color: widget.color,
                        borderStrokeWidth: 3,
                        borderColor: Colors.white,
                      ),
                    ],
                  ),
                if (pinned.isNotEmpty)
                  MarkerLayer(
                    rotate: true, // pins stay upright when the map turns
                    markers: [
                      for (final d in pinned)
                        Marker(
                          point: LatLng(d.lat!, d.lng!),
                          width: 44,
                          height: 44,
                          alignment: Alignment.topCenter, // the pin's tip is the spot
                          child: Semantics(
                            button: true,
                            label: '${d.name}, ${lineForType(d.type).name}',
                            excludeSemantics: true,
                            child: GestureDetector(
                            onTap: widget.onPinTap == null
                                ? null
                                : () => widget.onPinTap!(d),
                            // Each kind of place has its own line colour.
                            // Pin in the line colour with the category icon in
                            // its head, so it is not told apart by colour alone.
                            child: Stack(
                              alignment: Alignment.topCenter,
                              children: [
                                Icon(
                                  Icons.location_on,
                                  size: 40,
                                  color: colorForType(d.type),
                                  shadows: const [Shadow(color: Colors.white, blurRadius: 3)],
                                ),
                                Positioned(
                                  top: 7,
                                  child: Container(
                                    width: 18,
                                    height: 18,
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      iconForType(d.type),
                                      size: 12,
                                      color: lineInk(colorForType(d.type)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ),
                        ),
                    ],
                  ),
                if (line.length > 1 || me != null)
                  MarkerLayer(
                    rotate: true,
                    markers: [
                      // Where you are going.
                      if (line.length > 1)
                        Marker(
                          point: line.last,
                          width: 40,
                          height: 40,
                          alignment: Alignment.topCenter,
                          child: Icon(Icons.location_on, size: 38, color: widget.color),
                        ),
                      // Where you are (drawn last, so it is on top).
                      if (me != null)
                        Marker(
                          point: me,
                          width: 58,
                          height: 58,
                          child: PersonMarker(color: widget.color, size: 36),
                        ),
                    ],
                  ),
                RichAttributionWidget(
                  // Bottom left in full screen, because the buttons are on the right.
                  alignment: widget.fill
                      ? AttributionAlignment.bottomLeft
                      : AttributionAlignment.bottomRight,
                  showFlutterMapAttribution: false,
                  attributions: [
                    TextSourceAttribution(
                      _satellite
                          ? 'Source: Esri, Vantor, Earthstar Geographics, and the GIS User Community'
                          : '© OpenStreetMap contributors',
                    ),
                  ],
                ),
              ],
            ),
            // Shown while the map is turned; tap to turn it back north-up.
            Positioned(
              left: widget.fill ? null : 10,
              right: widget.fill ? 12 : null,
              top: widget.topInset + (widget.fill ? 12 : 10),
              child: AnimatedScale(
                scale: _rotation.abs() > 0.5 ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: Material(
                  color: Colors.white,
                  elevation: 3,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Turn back north-up',
                    onPressed: () {
                      // Heading-up: switch to north-up (Centre on me turns it back).
                      setState(() {
                        _rotation = 0;
                        _northUp = true;
                        _bearing = null;
                      });
                      if (_ready) _controller.rotate(0);
                      final me = _me;
                      if (me != null && widget.follow && !_free) _followCamera(me);
                    },
                    icon: Transform.rotate(
                      angle: _rotation * math.pi / 180,
                      child: const Icon(Icons.navigation, size: 22, color: AppColors.danger),
                    ),
                  ),
                ),
              ),
            ),
            if (widget.fill)
              Positioned(
                right: 12,
                bottom: 20 + widget.bottomInset,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _roundButton(
                      icon: _satellite ? Icons.map_outlined : Icons.satellite_alt,
                      tooltip: _satellite ? 'Street map' : 'Satellite',
                      onTap: () => setState(() => _satellite = !_satellite),
                    ),
                    if (me != null) ...[
                      const SizedBox(height: 10),
                      _roundButton(
                        icon: Icons.my_location,
                        tooltip: widget.follow && widget.headingUp
                            ? 'Follow me, direction up'
                            : 'Centre on me',
                        onTap: () => _recentre(me),
                      ),
                    ],
                  ],
                ),
              ),
            if (!widget.fill)
            Positioned(
              top: 10,
              right: 10,
              child: Material(
                color: Colors.white.withValues(alpha: 0.92),
                elevation: 2,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => setState(() => _satellite = !_satellite),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _satellite ? Icons.map_outlined : Icons.satellite_alt,
                          size: 18,
                          color: AppColors.ink,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _satellite ? 'Map' : 'Satellite',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (!widget.fill && widget.follow && me != null)
              Positioned(
                right: 10,
                bottom: 28,
                child: Material(
                  color: Colors.white.withValues(alpha: 0.92),
                  elevation: 2,
                  shape: const CircleBorder(),
                  child: IconButton(
                    tooltip: 'Centre on me',
                    icon: const Icon(Icons.my_location, size: 20, color: AppColors.ink),
                    onPressed: () => _recentre(me),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 22, color: AppColors.ink),
        onPressed: onTap,
      ),
    );
  }
}
