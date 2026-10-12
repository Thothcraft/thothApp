import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/api/node_client.dart';
import '../../devices/application/devices_provider.dart';
import '../../devices/presentation/layout_editor_screen.dart';
import '../../watch/data/trace_service.dart';
import '../application/context_providers.dart';

/// Configured 3D geometry and live radio ranging share one coordinate
/// frame (building-anchored ENU). Anchored devices are ground truth;
/// sighted radios are trilaterated from ≥2 anchor RSSI readings and drawn
/// with an uncertainty ring — a single sighting yields a range circle on
/// its anchor, never a fake dot. Unlocated endpoints inherit nothing.
class SpatialMapView extends StatefulWidget {
  const SpatialMapView({
    super.key,
    required this.devices,
    required this.edges,
    this.watchNames = const {},
  });
  final List<ThothDevice> devices;
  final List<BleRelation> edges;

  /// ble MAC → friendly name for person-carried wearables.
  final Map<String, String> watchNames;
  @override
  State<SpatialMapView> createState() => _SpatialMapViewState();
}

class _SpatialMapViewState extends State<SpatialMapView> {
  Map<String, Map<String, dynamic>> _docs = {};
  List<String> _unavailable = [];
  bool _loading = false;
  bool _top = false;
  bool _showUnknowns = true;
  bool _showTrace = true;
  String? _building;

  /// EMA of solved positions — RSSI bursts jump, locations glide.
  final Map<String, List<double>> _smoothed = {};

  @override
  void initState() {
    super.initState();
    TraceService.instance.addListener(_onTrace);
    _load();
  }

  void _onTrace() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    TraceService.instance.removeListener(_onTrace);
    super.dispose();
  }

  @override
  void didUpdateWidget(SpatialMapView old) {
    super.didUpdateWidget(old);
    if (old.devices.map((d) => d.uuid).join() !=
        widget.devices.map((d) => d.uuid).join()) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final docs = <String, Map<String, dynamic>>{}, failed = <String>[];
    await Future.wait(
      widget.devices.map((device) async {
        try {
          final cached = await NodeClient.instance.room(device.uuid);
          final room = cached['room'];
          if (room is Map) {
            docs[device.uuid] = Map<String, dynamic>.from(room);
          } else {
            failed.add(device.name);
          }
        } catch (_) {
          failed.add(device.name);
        }
      }),
    );
    if (mounted) {
      setState(() {
        _docs = docs;
        _unavailable = failed;
        _loading = false;
      });
    }
  }

  Future<void> _configure(ThothDevice d) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LayoutEditorScreen(
          deviceId: d.uuid,
          fleet:
              widget.devices.map((e) => (uuid: e.uuid, name: e.name)).toList(),
        ),
      ),
    );
    if (mounted) await _load();
  }

  /// lat/lon → ENU metres around a building anchor (equirectangular —
  /// accurate to millimetres at building scale).
  static List<double> geoToEnu(
    double lat,
    double lon,
    double? alt,
    double lat0,
    double lon0,
    double alt0,
  ) {
    const r = 6378137.0;
    final latR = lat0 * math.pi / 180;
    return [
      (lon - lon0) * math.pi / 180 * r * math.cos(latR),
      (lat - lat0) * math.pi / 180 * r,
      (alt ?? alt0) - alt0,
    ];
  }

  /// Trace breadcrumb projected into the selected building's ENU
  /// frame — only when its doc carries a geo anchor.
  List<({List<double> enu, int? rssi})> _traceEnu(String? building) {
    if (building == null || !_showTrace) return const [];
    for (final doc in _docs.values) {
      final b = doc['building'] as Map?;
      if ('${b?['id'] ?? ''}' != building) continue;
      final a = b?['anchor'] as Map?;
      final lat0 = (a?['latitude'] as num?)?.toDouble();
      final lon0 = (a?['longitude'] as num?)?.toDouble();
      if (lat0 == null || lon0 == null) return const [];
      final alt0 = (a?['altitude_m'] as num?)?.toDouble() ?? 0.0;
      return [
        for (final p in TraceService.instance.trace)
          (
            enu: geoToEnu(p.lat, p.lon, null, lat0, lon0, alt0),
            rssi: p.rssi,
          ),
      ];
    }
    return const [];
  }

  String _labelFor(String id) {
    final mac = id.startsWith('ble:') ? id.substring(4) : id;
    if (widget.watchNames.containsKey(mac)) return widget.watchNames[mac]!;
    for (final d in widget.devices) {
      if (d.uuid == id) return d.name;
    }
    for (final e in widget.edges) {
      if (e.target == id && e.advName != null && e.advName!.isNotEmpty) {
        return e.advName!;
      }
    }
    return id.length > 14 ? '${id.substring(0, 14)}…' : id;
  }

  @override
  Widget build(BuildContext context) {
    final scene = SpatialScene.fromDocuments(
      _docs,
      widget.edges,
      widget.devices,
      widget.watchNames,
    );
    // Glide solved positions — 35% per rebuild.
    for (final p in scene.points) {
      if (!p.estimated) continue;
      final prev = _smoothed[p.id];
      final next = prev == null
          ? p.enu
          : [for (var i = 0; i < 3; i++) prev[i] + (p.enu[i] - prev[i]) * 0.35];
      p.enu = next;
      _smoothed[p.id] = next;
    }
    final buildings = scene.rooms.map((r) => r.building).toSet().toList()
      ..sort();
    final selected =
        buildings.contains(_building) ? _building : buildings.firstOrNull;
    final rooms = scene.rooms.where((r) => r.building == selected).toList();
    final visible = _showUnknowns ? scene.points : scene.knownPoints;
    final points = visible.where((p) => p.building == selected).toList();
    final located = <String>{
      for (final p in scene.points) p.id,
      for (final r in scene.rings) r.target,
    };
    final unlocated = <String>{
      for (final d in widget.devices) d.uuid,
      for (final e in widget.edges) ...[e.observer, e.target],
    }.difference(located).length;
    final estimates =
        scene.points.where((p) => p.estimated && p.building == selected);
    return Column(
      children: [
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (buildings.length > 1)
              DropdownButton<String>(
                value: selected,
                items: buildings
                    .map((b) => DropdownMenuItem(value: b, child: Text(b)))
                    .toList(),
                onChanged: (b) => setState(() => _building = b),
              ),
            TextButton.icon(
              onPressed: () => setState(() => _top = !_top),
              icon: Icon(_top ? Icons.view_in_ar : Icons.map_outlined),
              label: Text(_top ? '3D view' : 'Top view'),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _showUnknowns = !_showUnknowns),
              icon: Icon(
                _showUnknowns
                    ? Icons.visibility
                    : Icons.visibility_off_outlined,
              ),
              label: Text(_showUnknowns ? 'hide unknowns' : 'show unknowns'),
            ),
            IconButton(
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh room layouts',
            ),
            IconButton(
              onPressed: () => setState(() => _showTrace = !_showTrace),
              icon: Icon(
                _showTrace ? Icons.route : Icons.route_outlined,
              ),
              tooltip: 'Toggle GPS trace overlay',
            ),
            PopupMenuButton<ThothDevice>(
              tooltip: 'Edit layout visually',
              icon: const Icon(Icons.home_work_outlined),
              itemBuilder: (_) => widget.devices
                  .map(
                    (d) => PopupMenuItem(
                      value: d,
                      child: Text('Configure ${d.name}'),
                    ),
                  )
                  .toList(),
              onSelected: _configure,
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_unavailable.isNotEmpty)
          Text(
            'Layout unavailable: ${_unavailable.join(', ')}',
            style: const TextStyle(fontSize: 11),
          ),
        if (scene.conflicts.isNotEmpty)
          Text(
            'Conflicting placements: ${scene.conflicts.join(', ')}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Expanded(
          child: rooms.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.home_work_outlined, size: 40),
                        SizedBox(height: 12),
                        Text(
                          'Set up your house and room anchors',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Choose a device above to enter the house location, measured room layout, floor, direction and device position. Anchored devices become the reference points that located radios are solved against.',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : InteractiveViewer(
                  minScale: 0.4,
                  maxScale: 10,
                  boundaryMargin: const EdgeInsets.all(400),
                  child: LayoutBuilder(
                    builder: (_, constraints) => CustomPaint(
                      size: Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      ),
                      painter: _SpatialPainter(
                        rooms,
                        points,
                        scene.rings
                            .where((r) => r.building == selected)
                            .toList(),
                        widget.edges,
                        _top,
                        _labelFor,
                        trace: _traceEnu(selected),
                      ),
                    ),
                  ),
                ),
        ),
        Text(
          '${scene.points.where((p) => p.building == selected && !p.estimated).length} anchored · '
          '${estimates.length} located by radio · '
          '${scene.rings.where((r) => r.building == selected).length} ranged only · '
          '$unlocated unlocated',
          style: const TextStyle(fontSize: 12),
        ),
        for (final p in points.take(6))
          Text(
            '${_labelFor(p.id)} · floor ${p.floor ?? '?'} · '
            'h ${p.enu[2].toStringAsFixed(1)} m · ${p.membership}'
            '${p.estimated ? ' · est ±${p.uncertaintyM.toStringAsFixed(1)} m' : ''}',
            style: const TextStyle(fontSize: 11),
          ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'Anchored devices are measured positions. Radios seen by two or more anchors are trilaterated from BLE + Wi-Fi RSSI (dashed ring = solver uncertainty); a single sighting draws a range circle only.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}

bool _finite(dynamic v) => v is num && v.isFinite;
List<double>? _v3(dynamic v) => v is List && v.length == 3 && v.every(_finite)
    ? v.map((e) => (e as num).toDouble()).toList()
    : null;
List<double> roomToEnu(List<double> p, List<double> origin, double heading) {
  final a = heading * math.pi / 180;
  return [
    origin[0] + p[0] * math.cos(a) - p[2] * math.sin(a),
    origin[1] - p[0] * math.sin(a) - p[2] * math.cos(a),
    origin[2] + p[1],
  ];
}

class SpatialRoom {
  SpatialRoom(
    this.building,
    this.id,
    this.name,
    this.corners,
    this.floor,
    this.origin,
    this.headingDeg,
    this.hw,
    this.hd,
  );
  final String building, id, name;
  final List<List<double>> corners;
  final int? floor;

  /// ENU origin + heading so estimates can be tested for containment.
  final List<double> origin;
  final double headingDeg;

  /// Half-extents of the room box in its own frame.
  final double hw, hd;

  /// The room box test in ENU — invert the room transform (it is an
  /// involution, so the same mapping applies) then compare extents.
  bool containsEnu(double e, double n) {
    final a = headingDeg * math.pi / 180;
    final dx = e - origin[0], dn = n - origin[1];
    final rx = dx * math.cos(a) - dn * math.sin(a);
    final rz = -dx * math.sin(a) - dn * math.cos(a);
    return rx.abs() <= hw + 0.3 && rz.abs() <= hd + 0.3;
  }
}

/// One ranged-but-unsolved radio: single sighting → circle on its anchor.
class RangeRing {
  RangeRing(
    this.target,
    this.building,
    this.anchorEnu,
    this.radiusM,
    this.modality,
  );
  final String target, building, modality;
  final List<double> anchorEnu;
  final double radiusM;
}

/// Sensor field-of-view wedge attached to an anchored device.
class FovWedge {
  FovWedge(this.centerEnu, this.dirEnu, this.fovDeg, this.rangeM, this.type);
  final List<double> centerEnu, dirEnu;
  final double fovDeg, rangeM;
  final String type; // radar | camera | csi | …
}

class SpatialPoint {
  SpatialPoint(
    this.id,
    this.building,
    this.enu,
    this.floor,
    this.membership, {
    this.kind = 'thoth',
    this.estimated = false,
    this.uncertaintyM = 0,
    this.anchorCount = 0,
    this.known = true,
    this.moving = false,
    this.wedges = const [],
  });
  final String id, building, membership, kind;
  List<double> enu;
  final int? floor;
  final bool estimated, known, moving;
  final int anchorCount;
  final double uncertaintyM;
  final List<FovWedge> wedges;

  /// person-carried (watch/phone) vs fixed infrastructure (node w/ FOV).
  bool get personLinked => kind == 'watch' || kind == 'phone';
  bool get sensing => wedges.isNotEmpty;
}

class SpatialScene {
  final rooms = <SpatialRoom>[];
  final points = <SpatialPoint>[];
  final rings = <RangeRing>[];
  final conflicts = <String>{};

  List<SpatialPoint> get knownPoints => points.where((p) => p.known).toList();

  SpatialScene.fromDocuments(
    Map<String, Map<String, dynamic>> docs,
    List<BleRelation> edges,
    List<ThothDevice> devices,
    Map<String, String> watchNames,
  ) {
    final uniqueRooms = <String, SpatialRoom>{},
        uniquePoints = <String, SpatialPoint>{};
    final fleetKind = {for (final d in devices) d.uuid: _kindOf(d)};
    // Observer uuid → room doc lookup is implicit: each doc's devices[]
    // anchors may name any fleet uuid, including the observing node itself.
    for (final doc in docs.values) {
      final building = '${(doc['building'] as Map?)?['id'] ?? ''}';
      if (building.isEmpty) continue;
      for (final r in [
        doc,
        ...(doc['rooms'] as List? ?? []).whereType<Map>(),
      ]) {
        final id = '${r['room_id'] ?? ''}',
            s = r['spatial'] as Map? ?? {},
            dims = r['dims'] as Map? ?? {};
        final origin = _v3(s['origin_enu_m']);
        if (s['surveyed'] != true ||
            origin == null ||
            !_finite(s['heading_deg']) ||
            ![
              'w',
              'd',
              'h',
            ].every((k) => _finite(dims[k]) && (dims[k] as num) > 0)) {
          continue;
        }
        final heading = (s['heading_deg'] as num).toDouble(),
            w = (dims['w'] as num).toDouble(),
            d = (dims['d'] as num).toDouble(),
            h = (dims['h'] as num).toDouble();
        final corners = [
          for (final y in [0.0, h])
            for (final p in [
              [-w / 2, y, -d / 2],
              [w / 2, y, -d / 2],
              [w / 2, y, d / 2],
              [-w / 2, y, d / 2],
            ])
              roomToEnu(p, origin, heading),
        ];
        final room = SpatialRoom(
          building,
          id,
          '${r['name'] ?? id}',
          corners,
          s['floor'] is int ? s['floor'] as int : null,
          origin,
          heading,
          w / 2,
          d / 2,
        );
        uniqueRooms['$building/$id'] = room;
        for (final dev in (doc['devices'] as List? ?? []).whereType<Map>()) {
          final roomId =
              '${dev['room_id'] == '' || dev['room_id'] == null ? doc['room_id'] ?? '' : dev['room_id']}';
          final p = _v3(dev['pos']);
          if (roomId != id || p == null) continue;
          final did = '${dev['device_id'] ?? ''}';
          if (did.isEmpty) continue;
          final enu = roomToEnu(p, origin, heading),
              uncertainty = dev['position_uncertainty_m'];
          final margin = [
            w / 2 - p[0].abs(),
            d / 2 - p[2].abs(),
            p[1],
            h - p[1],
          ].reduce(math.min);
          final membership = !_finite(uncertainty) || uncertainty < 0
              ? 'inside/outside unknown'
              : margin > uncertainty
                  ? 'inside room'
                  : margin < -uncertainty
                      ? 'outside room'
                      : 'near room boundary';
          // Field-of-view wedges from this device's sensor placements.
          final devYaw = (dev['rot_y'] as num?)?.toDouble() ?? 0;
          final wedges = <FovWedge>[];
          for (final sen in (dev['sensors'] as List? ?? []).whereType<Map>()) {
            final fov = (sen['fov_deg'] as num?)?.toDouble(),
                range = (sen['range_m'] as num?)?.toDouble();
            final sp = _v3(sen['pos']) ?? p;
            final sc = roomToEnu(sp, origin, heading);
            if (fov == null || range == null || fov <= 0 || range <= 0) {
              continue;
            }
            final yaw = devYaw + ((sen['rot_y'] as num?)?.toDouble() ?? 0);
            // Room-frame forward at yaw: (sinθ, 0, -cosθ); map to ENU.
            final dirRoom = [
              math.sin(yaw * math.pi / 180),
              0.0,
              -math.cos(yaw * math.pi / 180),
            ];
            wedges.add(
              FovWedge(
                sc,
                roomToEnu(dirRoom, const [0, 0, 0], heading),
                fov,
                range,
                '${sen['type'] ?? 'sensor'}',
              ),
            );
          }
          final point = SpatialPoint(
            did,
            building,
            enu,
            s['floor'] is int ? s['floor'] as int : null,
            membership,
            kind: fleetKind[did] ?? 'thoth',
            wedges: wedges,
          );
          final old = uniquePoints[did];
          if (old != null &&
              (old.building != building ||
                  List.generate(3, (i) => (old.enu[i] - enu[i]).abs() > 0.001)
                      .any((v) => v))) {
            conflicts.add(did);
          }
          uniquePoints[did] = point;
        }
      }
    }
    rooms.addAll(uniqueRooms.values);
    points.addAll(uniquePoints.values.where((p) => !conflicts.contains(p.id)));

    _solveRadio(edges, devices, watchNames);
  }

  String _kindOf(ThothDevice d) {
    final t = (d.deviceType ?? '').toLowerCase();
    if (t.contains('watch') || t.contains('wearable')) return 'watch';
    if (t.contains('phone')) return 'phone';
    return 'thoth';
  }

  /// RSSI → metres (log-distance path-loss, indoor n≈2.5, −59 dBm @ 1 m).
  /// Wi-Fi beacons transmit hotter — a hair more range for equal RSSI.
  static double _rssiToM(String modality, double rssi) {
    final p0 = modality == 'Wi-Fi' ? -46.0 : -59.0;
    final d = math.pow(10.0, (p0 - rssi) / 25.0);
    return d.clamp(0.15, 80.0).toDouble();
  }

  /// Trilaterate every sighted target against the anchored fleet.
  /// Solve per-building; the building contributing the most sightings wins.
  void _solveRadio(
    List<BleRelation> edges,
    List<ThothDevice> devices,
    Map<String, String> watchNames,
  ) {
    final anchors = {
      for (final p in points.where((p) => !p.estimated)) p.id: p,
    };
    // Resolve watch targets: ble:<MAC> can also be a fleet uuid via the
    // watch registry — either way it ends up as one scene node.
    final movingTargets = {
      for (final e in edges)
        if (e.moving) e.target,
    };
    final sightings = <String, List<(SpatialPoint, double, String)>>{};
    for (final e in edges) {
      final a = anchors[e.observer];
      if (a == null || e.target.isEmpty) continue;
      // Anchor can't range itself; skip degenerate self-edges.
      if (a.id == e.target) continue;
      // Median of the sighting window beats the single freshest sample —
      // RSSI is noisy ±5 dB; the window already rides the relation.
      var rssi = e.rssiDbm;
      if (e.rssiWindow.length >= 3) {
        final w = [...e.rssiWindow]..sort();
        rssi = w[w.length ~/ 2];
      }
      final dist = _rssiToM(e.modality, rssi);
      sightings.putIfAbsent(e.target, () => []).add((a, dist, e.modality));
    }
    for (final entry in sightings.entries) {
      // Anchored devices stay ground truth — never re-solve them.
      if (anchors.containsKey(entry.key)) continue;
      // Split sightings by building — anchors in different ENU frames
      // can't be mixed into one solve.
      final byBuilding = <String, List<(SpatialPoint, double, String)>>{};
      for (final s in entry.value) {
        byBuilding.putIfAbsent(s.$1.building, () => []).add(s);
      }
      final best =
          byBuilding.values.reduce((a, b) => a.length >= b.length ? a : b);
      final building = best.first.$1.building;
      final target = entry.key;
      final isWatch = watchNames.entries
          .any((w) => 'ble:${w.key.toLowerCase()}' == target.toLowerCase());
      final fleet = devices.where((d) => d.uuid == target);
      final kind = fleet.isNotEmpty
          ? _kindOf(fleet.first)
          : isWatch
              ? 'watch'
              : target.startsWith('ble:')
                  ? 'ble'
                  : target.startsWith('wifi:')
                      ? 'wifi'
                      : 'ble';
      // Anonymous ble:<MAC> advertisers render hollow; enrolled wearables
      // and fleet devices are known.
      final known = fleet.isNotEmpty || isWatch || !target.startsWith('ble:');
      // Deduplicate anchors (several modalities/sensors on one node).
      final seen = <String>{};
      final sights = <(SpatialPoint, double, String)>[];
      for (final s in best) {
        if (seen.add(s.$1.id)) sights.add(s);
      }

      if (sights.length == 1) {
        final (a, dist, modality) = sights.first;
        rings.add(RangeRing(target, building, a.enu, dist, modality));
        continue;
      }

      // ≥2 anchors → weighted least-squares in the horizontal plane.
      final (a0, r0, _) = sights.first;
      var a11 = 0.0, a12 = 0.0, a22 = 0.0, b1 = 0.0, b2 = 0.0;
      var rows = 0;
      for (var i = 1; i < sights.length; i++) {
        final (ai, ri, _) = sights[i];
        final dx = 2 * (ai.enu[0] - a0.enu[0]),
            dy = 2 * (ai.enu[1] - a0.enu[1]);
        final rhs = r0 * r0 -
            ri * ri +
            ai.enu[0] * ai.enu[0] -
            a0.enu[0] * a0.enu[0] +
            ai.enu[1] * ai.enu[1] -
            a0.enu[1] * a0.enu[1];
        // Weight nearer anchors more — path-loss noise grows with range.
        final w = 1 / (1 + ri * ri * 0.1);
        a11 += w * dx * dx;
        a12 += w * dx * dy;
        a22 += w * dy * dy;
        b1 += w * dx * rhs;
        b2 += w * dy * rhs;
        rows++;
      }
      double px, pn;
      if (rows >= 2 && (a11 * a22 - a12 * a12).abs() > 1e-9) {
        final det = a11 * a22 - a12 * a12;
        px = (b1 * a22 - b2 * a12) / det;
        pn = (a11 * b2 - a12 * b1) / det;
      } else {
        // Degenerate geometry (two anchors / collinear): weighted
        // blend biased toward the nearer-ranging anchor.
        var wsum = 0.0, x = 0.0, n = 0.0;
        for (final (a, r, _) in sights) {
          final wgt = 1 / (r + 0.5);
          wsum += wgt;
          x += a.enu[0] * wgt;
          n += a.enu[1] * wgt;
        }
        px = x / wsum;
        pn = n / wsum;
      }
      // Residual RMSE → solver uncertainty ring radius.
      var sse = 0.0;
      for (final (a, r, _) in sights) {
        final dd =
            math.sqrt(math.pow(px - a.enu[0], 2) + math.pow(pn - a.enu[1], 2));
        sse += (dd - r) * (dd - r);
      }
      final rmse = math.sqrt(sse / sights.length);
      final unc = (rmse * 0.8 + 0.6).clamp(0.5, 25.0);
      // Height + floor: distance-weighted blend of anchor heights.
      var zw = 0.0, zsum = 0.0;
      SpatialPoint? nearest;
      var nd = double.infinity;
      for (final (a, r, _) in sights) {
        final wgt = 1 / (r + 0.5);
        zw += wgt;
        zsum += a.enu[2] * wgt;
        if (r < nd) {
          nd = r;
          nearest = a;
        }
      }
      final enu = [px, pn, zsum / zw];
      final floor = nearest?.floor;
      // Membership vs the building's surveyed rooms.
      var membership = 'outside all rooms';
      for (final room in rooms.where((r) => r.building == building)) {
        if (room.containsEnu(px, pn) &&
            (floor == null || room.floor == null || room.floor == floor)) {
          membership = 'inside ${room.name}';
          break;
        }
      }
      points.add(
        SpatialPoint(
          target,
          building,
          enu,
          floor,
          membership,
          kind: kind,
          estimated: true,
          uncertaintyM: unc,
          anchorCount: sights.length,
          known: known,
          moving: movingTargets.contains(target),
        ),
      );
    }
  }
}

class _SpatialPainter extends CustomPainter {
  _SpatialPainter(
    this.rooms,
    this.points,
    this.rings,
    this.edges,
    this.top,
    this.labelFor, {
    this.trace = const [],
  });
  final List<SpatialRoom> rooms;
  final List<SpatialPoint> points;
  final List<RangeRing> rings;
  final List<BleRelation> edges;
  final bool top;
  final String Function(String) labelFor;

  /// GPS breadcrumb in ENU (+ watch-link RSSI per fix for colouring).
  final List<({List<double> enu, int? rssi})> trace;

  late Offset Function(List<double>) _p;
  late double _scale;

  static const _kindColors = {
    'thoth': Color(0xFF1565C0),
    'watch': Color(0xFF00897B),
    'phone': Color(0xFF7B1FA2),
    'ble': Color(0xFF546E7A),
    'wifi': Color(0xFF3949AB),
  };
  static const _modalityColors = {
    'BLE': Color(0xFF00897B),
    'Wi-Fi': Color(0xFF3949AB),
    'CSI': Color(0xFF8E24AA),
  };
  static const _fovColors = {
    'radar': Color(0xFF2E7D32),
    'camera': Color(0xFF3949AB),
    'csi': Color(0xFF8E24AA),
  };
  static const _kindGlyph = {
    'thoth': '▣',
    'watch': '◉',
    'phone': '◆',
    'ble': '○',
    'wifi': '◇',
  };

  @override
  void paint(Canvas canvas, Size size) {
    Offset project(List<double> p) => top
        ? Offset(p[0], -p[1])
        : Offset((p[0] - p[1]) * 0.75, (p[0] + p[1]) * 0.42 - p[2] * 0.9);

    // World bounds over rooms, anchors, estimates, wedges and rings.
    final lo = [1e9, 1e9, 1e9], hi = [-1e9, -1e9, -1e9];
    void grow(List<double> p, [double pad = 0]) {
      for (var i = 0; i < 3; i++) {
        lo[i] = math.min(lo[i], p[i] - pad);
        hi[i] = math.max(hi[i], p[i] + pad);
      }
    }

    for (final r in rooms) {
      for (final c in r.corners) {
        grow(c);
      }
    }
    for (final p in points) {
      grow(p.enu, p.uncertaintyM);
      for (final w in p.wedges) {
        grow([
          w.centerEnu[0] + w.dirEnu[0] * w.rangeM,
          w.centerEnu[1] + w.dirEnu[1] * w.rangeM,
          w.centerEnu[2],
        ]);
      }
    }
    for (final r in rings) {
      grow(r.anchorEnu, r.radiusM);
    }
    if (lo[0] > hi[0]) {
      lo.setAll(0, [0, 0, 0]);
      hi.setAll(0, [3, 2, 2.5]);
    }
    final a = project(lo), b = project(hi);
    final bw = math.max(2.0, (b.dx - a.dx).abs()),
        bh = math.max(2.0, (b.dy - a.dy).abs());
    _scale = math.min(size.width / (bw + 8), size.height / (bh + 8));
    final center = Offset(
      size.width / 2 - (a.dx + b.dx) * _scale / 2,
      size.height / 2 - (a.dy + b.dy) * _scale / 2,
    );
    _p = (p) => center + project(p) * _scale;

    // GPS trace — breadcrumb through the building frame, coloured by
    // watch-link strength at each fix.
    if (trace.length > 1) {
      const rssiColors = <Color>[
        Colors.green,
        Colors.orange,
        Colors.red,
        Colors.blueGrey,
      ];
      final path = Path()
        ..moveTo(_p(trace.first.enu).dx, _p(trace.first.enu).dy);
      for (var i = 1; i < trace.length; i++) {
        path.lineTo(_p(trace[i].enu).dx, _p(trace[i].enu).dy);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.deepOrange.withValues(alpha: 0.75)
          ..strokeWidth = 2.4
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round,
      );
      for (final tp in trace) {
        final c = tp.rssi == null
            ? 3
            : tp.rssi! >= -55
                ? 0
                : tp.rssi! >= -70
                    ? 1
                    : 2;
        canvas.drawCircle(_p(tp.enu), 2.2, Paint()..color = rssiColors[c]);
      }
      final head = _p(trace.last.enu);
      canvas.drawCircle(
        head,
        6.5,
        Paint()..color = Colors.deepOrange.withValues(alpha: 0.9),
      );
      canvas.drawCircle(
        head,
        6.5,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        'trace',
        head + const Offset(9, -10),
        10,
        bold: true,
        color: Colors.deepOrange,
      );
    }

    final groundZ = lo[2];
    // Meter grid on the lowest floor plane.
    final grid = Paint()
      ..color = Colors.blueGrey.withValues(alpha: 0.10)
      ..strokeWidth = 0.6;
    for (var gx = lo[0].floorToDouble(); gx <= hi[0]; gx += 1.0) {
      canvas.drawLine(_p([gx, lo[1], groundZ]), _p([gx, hi[1], groundZ]), grid);
    }
    for (var gy = lo[1].floorToDouble(); gy <= hi[1]; gy += 1.0) {
      canvas.drawLine(_p([lo[0], gy, groundZ]), _p([hi[0], gy, groundZ]), grid);
    }

    // Rooms: floor fill, wireframe walls, name + floor tag.
    for (final r in rooms) {
      final floor = Path()..moveTo(_p(r.corners[0]).dx, _p(r.corners[0]).dy);
      for (var i = 1; i < 4; i++) {
        floor.lineTo(_p(r.corners[i]).dx, _p(r.corners[i]).dy);
      }
      floor.close();
      canvas.drawPath(
        floor,
        Paint()..color = Colors.blueGrey.withValues(alpha: 0.12),
      );
      final wall = Paint()
        ..color = Colors.blueGrey.shade700
        ..strokeWidth = 2;
      for (final ring in [r.corners.sublist(0, 4), r.corners.sublist(4, 8)]) {
        for (var i = 0; i < 4; i++) {
          canvas.drawLine(_p(ring[i]), _p(ring[(i + 1) % 4]), wall);
        }
      }
      for (var i = 0; i < 4; i++) {
        canvas.drawLine(_p(r.corners[i]), _p(r.corners[i + 4]), wall);
      }
      _text(
        canvas,
        '${r.name}${r.floor != null ? ' · F${r.floor}' : ''}',
        _p(r.corners[0]) + const Offset(4, -20),
        13,
        bold: true,
      );
    }

    // Sensor field-of-view wedges (behind links + nodes).
    for (final p in points) {
      for (final w in p.wedges) {
        final color = _fovColors[w.type] ?? _fovColors['radar']!;
        final half = w.fovDeg * math.pi / 360;
        final base = math.atan2(w.dirEnu[1], w.dirEnu[0]);
        final fan = Path()..moveTo(_p(w.centerEnu).dx, _p(w.centerEnu).dy);
        const steps = 16;
        for (var i = 0; i <= steps; i++) {
          final ang = base - half + 2 * half * i / steps;
          fan.lineTo(
            _p([
              w.centerEnu[0] + math.cos(ang) * w.rangeM,
              w.centerEnu[1] + math.sin(ang) * w.rangeM,
              w.centerEnu[2],
            ]).dx,
            _p([
              w.centerEnu[0] + math.cos(ang) * w.rangeM,
              w.centerEnu[1] + math.sin(ang) * w.rangeM,
              w.centerEnu[2],
            ]).dy,
          );
        }
        fan.close();
        canvas.drawPath(fan, Paint()..color = color.withValues(alpha: 0.10));
        canvas.drawPath(
          fan,
          Paint()
            ..color = color.withValues(alpha: 0.35)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      }
    }

    // Radio links — modality color, freshness alpha, strength width.
    final byId = {for (final p in points) p.id: p};
    for (final e in edges) {
      final a = byId[e.observer], b = byId[e.target];
      if (a == null || b == null || a.building != b.building) continue;
      final fresh = (1 - (e.ageSeconds / 90).clamp(0, 1)).toDouble();
      final strength = ((e.rssiDbm + 95) / 60).clamp(0.0, 1.0);
      final color = _modalityColors[e.modality] ?? Colors.teal;
      final pa = _p(a.enu), pb = _p(b.enu);
      canvas.drawLine(
        pa,
        pb,
        Paint()
          ..color = color.withValues(alpha: 0.15 + 0.5 * fresh)
          ..strokeWidth = 0.8 + 2.6 * strength
          ..strokeCap = StrokeCap.round,
      );
      final mid = Offset((pa.dx + pb.dx) / 2, (pa.dy + pb.dy) / 2);
      if ((pa - pb).distance > 70) {
        _text(
          canvas,
          '${e.rssiDbm.round()} dBm',
          mid,
          9,
          color: color.withValues(alpha: 0.75),
        );
      }
    }

    // Range rings — single-sighting radios circle their anchor.
    for (final r in rings) {
      _dashedCircle(
        canvas,
        _p([r.anchorEnu[0], r.anchorEnu[1], r.anchorEnu[2]]),
        r.radiusM,
        Colors.blueGrey.withValues(alpha: 0.55),
      );
      _text(
        canvas,
        '~${r.radiusM.toStringAsFixed(1)} m',
        _p([r.anchorEnu[0], r.anchorEnu[1] + r.radiusM, r.anchorEnu[2]]) +
            const Offset(6, 0),
        10,
        color: Colors.blueGrey,
      );
    }

    // Nodes — anchors as squares, estimates as circles + uncertainty.
    for (final p in points) {
      final c = _p(p.enu);
      final color =
          p.known ? (_kindColors[p.kind] ?? Colors.blueGrey) : Colors.grey;
      if (p.estimated) {
        _dashedCircle(canvas, c, p.uncertaintyM, color.withValues(alpha: 0.5));
        canvas.drawCircle(
          c,
          p.uncertaintyM * _scale,
          Paint()..color = color.withValues(alpha: 0.05),
        );
      }
      if (p.estimated) {
        canvas.drawCircle(c, 9, Paint()..color = color.withValues(alpha: 0.85));
        canvas.drawCircle(
          c,
          9,
          Paint()
            ..color = Colors.white
            ..strokeWidth = 1.6
            ..style = PaintingStyle.stroke,
        );
      } else {
        final rect = Rect.fromCenter(center: c, width: 18, height: 18);
        canvas.drawRect(rect, Paint()..color = color);
        canvas.drawRect(
          rect,
          Paint()
            ..color = Colors.white
            ..strokeWidth = 1.6
            ..style = PaintingStyle.stroke,
        );
      }
      _text(
        canvas,
        '${_kindGlyph[p.kind] ?? '•'} ${_label(p.id)}',
        c + const Offset(12, -14),
        12,
        bold: true,
        color: p.known ? Colors.black87 : Colors.grey,
      );
      final sub = p.estimated
          ? '±${p.uncertaintyM.toStringAsFixed(1)}m · ${p.anchorCount} anchors'
              '${p.moving ? ' · varying' : ''}'
          : [
              if (p.floor != null) 'F${p.floor}',
              '+${p.enu[2].toStringAsFixed(1)}m',
              if (p.sensing) 'FOV',
            ].join(' · ');
      _text(canvas, sub, c + const Offset(12, 0), 10, color: Colors.black54);
    }

    _legend(canvas, size);
  }

  String _label(String id) {
    final l = labelFor(id);
    return l.length > 18 ? '${l.substring(0, 18)}…' : l;
  }

  /// Dashed circle on the horizontal plane through [centerCanvas] —
  /// approximated as a canvas ellipse (sufficient at iso tilt).
  void _dashedCircle(Canvas canvas, Offset c, double radiusM, Color color) {
    final rpx = radiusM * _scale;
    if (rpx < 4) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke;
    const segs = 36;
    final rect = Rect.fromCircle(center: c, radius: rpx);
    for (var s = 0; s < segs; s += 2) {
      canvas.drawArc(
        rect,
        s * 2 * math.pi / segs,
        math.pi / segs,
        false,
        paint,
      );
    }
  }

  void _legend(Canvas canvas, Size size) {
    var y = size.height - 66;
    const x = 12.0;
    _text(
      canvas,
      '▣ anchored node   ◉ person device   ○ radio located',
      Offset(x, y),
      10,
      color: Colors.black54,
    );
    y += 14;
    _text(
      canvas,
      '— teal BLE · indigo Wi-Fi · purple CSI   -- dashed = estimate',
      Offset(x, y),
      10,
      color: Colors.black54,
    );
    // North arrow + 1 m scale bar (top-right).
    final nTop = Offset(size.width - 42, 26), nBot = nTop + const Offset(0, 22);
    canvas.drawLine(
      nBot,
      nTop,
      Paint()
        ..color = Colors.black54
        ..strokeWidth = 1.6,
    );
    canvas.drawCircle(nTop, 2.6, Paint()..color = Colors.black54);
    _text(canvas, 'N', nTop + const Offset(-3, -14), 11, bold: true);
    // A horizontal metre projects to ~0.86×scale px in the iso view.
    final meter = _scale * (top ? 1.0 : 0.86);
    canvas.drawLine(
      Offset(size.width - 18, size.height - 20),
      Offset(size.width - 18 - meter, size.height - 20),
      Paint()
        ..color = Colors.black87
        ..strokeWidth = 2,
    );
    _text(
      canvas,
      '1 m',
      Offset(size.width - 18 - meter / 2 - 8, size.height - 34),
      10,
    );
  }

  void _text(
    Canvas c,
    String s,
    Offset at,
    double size, {
    bool bold = false,
    Color color = Colors.black87,
  }) {
    (TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout())
        .paint(c, at);
  }

  @override
  bool shouldRepaint(_SpatialPainter old) => true;
}
