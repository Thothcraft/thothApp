import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../watch/data/trace_service.dart';

/// Movement trace — the phone's GPS breadcrumb rendered on OSM tiles,
/// coloured by watch-link RSSI. This is the Map tab's live spatial
/// feed that the relay also ships to Brain (pinetime-gps descriptor)
/// so the assistant sees the same path the user does.
class TraceMapTab extends StatefulWidget {
  const TraceMapTab({super.key});

  @override
  State<TraceMapTab> createState() => _TraceMapTabState();
}

class _TraceMapTabState extends State<TraceMapTab> {
  final _map = MapController();
  bool _followed = false;

  @override
  void initState() {
    super.initState();
    TraceService.instance.addListener(_refresh);
    _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    if (!_followed) {
      final p = TraceService.instance.lastFix;
      final t = TraceService.instance.trace;
      if (p != null || t.isNotEmpty) {
        final ll = t.isNotEmpty
            ? LatLng(t.last.lat, t.last.lon)
            : LatLng(p!.latitude, p.longitude);
        try {
          _map.move(ll, 17);
          _followed = true;
        } catch (_) {/* controller not ready yet — next point retries */}
      }
    }
  }

  @override
  void dispose() {
    TraceService.instance.removeListener(_refresh);
    super.dispose();
  }

  Color _rssiColor(int? rssi) {
    if (rssi == null) return Colors.blueGrey;
    if (rssi >= -55) return Colors.green;
    if (rssi >= -70) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final svc = TraceService.instance;
    final pts = svc.trace;
    if (pts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.route_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              svc.relayAttached
                  ? 'Waiting for the first GPS fix…'
                  : 'Connect a watch to record a movement trace.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],),
        ),
      );
    }
    final line = Polyline(
      points: [for (final p in pts) LatLng(p.lat, p.lon)],
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
      strokeWidth: 3,
    );
    final last = pts.last;
    return Stack(children: [
      FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: LatLng(last.lat, last.lon),
          initialZoom: 17,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'app.thothcraft',
          ),
          PolylineLayer(polylines: [line]),
          MarkerLayer(markers: [
            // Start
            Marker(
              point: LatLng(pts.first.lat, pts.first.lon),
              width: 14, height: 14,
              child: const Icon(Icons.circle, size: 12, color: Colors.grey),
            ),
            // Head — coloured by watch-link strength at that fix.
            Marker(
              point: LatLng(last.lat, last.lon),
              width: 40, height: 40,
              child: Icon(Icons.navigation,
                  color: _rssiColor(last.rssi), size: 26,),
            ),
          ],),
        ],
      ),
      Positioned(
        left: 12, right: 12, bottom: 12,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              const Icon(Icons.route, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${pts.length} fixes · '
                  '${(svc.distanceM / 1000).toStringAsFixed(2)} km · '
                  'watch ${svc.lastRssi ?? "—"} dBm',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Recenter',
                icon: const Icon(Icons.my_location, size: 18),
                onPressed: () =>
                    _map.move(LatLng(last.lat, last.lon), _map.camera.zoom),
              ),
              IconButton(
                tooltip: 'Clear trace',
                icon: const Icon(Icons.delete_outline, size: 18),
                onPressed: () {
                  svc.clearTrace();
                  _followed = false;
                },
              ),
            ],),
          ),
        ),
      ),
    ],);
  }
}
