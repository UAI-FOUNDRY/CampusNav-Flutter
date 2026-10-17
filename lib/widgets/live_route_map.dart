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

  /// Fill all the space it is given (square corners, round buttons at the
  /// bottom right) instead of being a rounded card of [height]. Used by the
  /// full-screen navigation view.
  final bool fill;

  /// In [fill] mode: space kept clear at the bottom (a card over the map);
  /// the round buttons and the attribution sit above it.
  final double bottomInset;

  /// Space kept clear at the top (chips over the map); the compass sits below.
  final double topInset;

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
    this.fill = false,
    this.bottomInset = 0,
    this.topInset = 0,
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
    if (widget.follow && _ready) {
      _controller.move(p, _controller.camera.zoom);
    }
  }

  int _nearest(List<LatLng> pts, LatLng to) {
    var best = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final d = _dist.distance(pts[i], to);
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    return best;
  }

  /// The route points between two spots, so the person walks along the path
  /// and does not cut corners.
  List<LatLng> _pathAlong(List<LatLng> line, LatLng from, LatLng to) {
    if (line.length < 2) return [from, to];
    final i = _nearest(line, from);
    final j = _nearest(line, to);
    if (i == j) return [from, to];
    final middle = i < j ? line.sublist(i, j + 1) : line.sublist(j, i + 1).reversed.toList();
    return [from, ...middle, to];
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
      final i = _nearest(line, me);
      walked = [...line.sublist(0, i + 1), me];
      ahead = [me, ...line.sublist(i + 1)];
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
                onMapReady: () => _ready = true,
                onPositionChanged: (camera, hasGesture) {
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
                            child: Icon(
                              Icons.location_on,
                              size: 32,
                              color: colorForType(d.type),
                              shadows: const [Shadow(color: Colors.white, blurRadius: 3)],
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
                      if (_ready) _controller.rotate(0);
                      setState(() => _rotation = 0);
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
                        tooltip: 'Centre on me',
                        onTap: () {
                          if (_ready) _controller.move(me, _followZoom);
                        },
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
                    onPressed: () {
                      if (_ready) _controller.move(me, _followZoom);
                    },
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
