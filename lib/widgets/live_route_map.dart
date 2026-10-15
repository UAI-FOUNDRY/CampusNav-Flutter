import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/destination.dart';
import '../models/route.dart';
import '../theme/app_colors.dart';

const _streetUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

// Esri World Imagery (satellite). Note the order is {z}/{y}/{x}: row first.
const _satelliteUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// The real outdoor map. Shows satellite imagery (default) or the street map,
/// with either a route line, tappable destination pins, or both.
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

  /// Where to look when there is no route to fit (Universal AI University).
  static const campus = LatLng(18.9027, 73.3742);

  const LiveCampusMap({
    super.key,
    this.route = const [],
    this.color = AppColors.academic,
    this.pins = const [],
    this.onPinTap,
    this.height = 300,
  });

  @override
  State<LiveCampusMap> createState() => _LiveCampusMapState();
}

class _LiveCampusMapState extends State<LiveCampusMap> {
  bool _satellite = true;

  @override
  Widget build(BuildContext context) {
    final line = [for (final p in widget.route) LatLng(p.lat, p.lng)];
    final pinned = [for (final d in widget.pins) if (d.hasGeo) d];

    // What the camera should fit: the route if there is one, else every pin.
    final focus = line.isNotEmpty
        ? line
        : [for (final d in pinned) LatLng(d.lat!, d.lng!)];

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            FlutterMap(
              options: MapOptions(
                initialCenter: focus.isEmpty ? LiveCampusMap.campus : focus.first,
                initialZoom: 17,
                maxZoom: 21,
                initialCameraFit: focus.length > 1
                    ? CameraFit.bounds(
                        bounds: LatLngBounds.fromPoints(focus),
                        padding: const EdgeInsets.all(40),
                        maxZoom: 19,
                      )
                    : null,
                // No rotation: it makes a tiny campus map confusing.
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.drag |
                      InteractiveFlag.pinchZoom |
                      InteractiveFlag.doubleTapZoom,
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
                if (line.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: line,
                        strokeWidth: 6,
                        color: widget.color,
                        borderStrokeWidth: 3,
                        borderColor: Colors.white,
                      ),
                    ],
                  ),
                if (pinned.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      for (final d in pinned)
                        Marker(
                          point: LatLng(d.lat!, d.lng!),
                          width: 36,
                          height: 36,
                          alignment: Alignment.topCenter, // the pin's tip is the spot
                          child: GestureDetector(
                            onTap: widget.onPinTap == null
                                ? null
                                : () => widget.onPinTap!(d),
                            child: Icon(Icons.location_on, size: 32, color: widget.color),
                          ),
                        ),
                    ],
                  ),
                if (line.isNotEmpty)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: line.first,
                        width: 20,
                        height: 20,
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.ink,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                          ),
                        ),
                      ),
                      if (line.length > 1)
                        Marker(
                          point: line.last,
                          width: 36,
                          height: 36,
                          alignment: Alignment.topCenter,
                          child: Icon(Icons.location_on, size: 34, color: widget.color),
                        ),
                    ],
                  ),
                RichAttributionWidget(
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
          ],
        ),
      ),
    );
  }
}
