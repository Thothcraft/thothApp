import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/node_client.dart';
import '../../devices/application/devices_provider.dart';
import '../../devices/presentation/layout_editor_screen.dart';
import '../../watch/application/watch_providers.dart';
import '../../watch/data/trace_service.dart';
import '../application/context_providers.dart';
import 'spatial_map.dart';

/// Fleet map — one continuous zoom from the world down into the room.
///
/// High level (zoomed out): OSM tiles with a pin per GPS-capable owned
/// device — phones/watches that emit ``location.geo.v1`` evidence plus
/// anchored nodes whose surveyed room doc pins them to a building —
/// and each device's movement trace as a polyline.
///
/// Zooming past the indoor threshold over a geo-anchored building
/// cross-fades a plan layer drawn in the same geographic frame: surveyed
/// rooms, named zones, and the stationary devices (thoth nodes, laptops)
/// the user drags into place and rotates to aim their field of view.
/// Every other radio sighted by the stationary fleet is solved by
/// BLE/Wi-Fi RSSI trilateration and rendered around them — a single
/// sighting draws a range ring, never a fake dot.
class FleetMapScreen extends ConsumerWidget {
  const FleetMapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edgesAsync = ref.watch(bleRelationsProvider);
    final devicesAsync = ref.watch(deviceListProvider);
    final watchesAsync = ref.watch(watchListProvider);
    final geoAsync = ref.watch(geoTracesProvider);

    return edgesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Radio evidence unavailable: $error',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      data: (edges) => FleetMapView(
        edges: edges,
        devices: devicesAsync.valueOrNull ?? const [],
        watchNames: {
          for (final watch in watchesAsync.valueOrNull ?? const [])
            watch.bleId: watch.name ?? 'watch',
        },
        geoTraces: geoAsync.valueOrNull ?? const {},
      ),
    );
  }
}

class FleetMapView extends StatefulWidget {
  const FleetMapView({
    super.key,
    required this.edges,
    required this.devices,
    this.watchNames = const {},
    this.geoTraces = const {},
  });

  final List<BleRelation> edges;
  final List<ThothDevice> devices;

  /// ble MAC → friendly name for person-carried wearables.
  final Map<String, String> watchNames;

  /// device uuid / source id → recent GPS fixes (oldest → newest).
  final Map<String, List<GeoFix>> geoTraces;

  @override
  State<FleetMapView> createState() => _FleetMapViewState();
}

/// Zoom band where the plan fades in over the tiles.
const double _kZoomInStart = 17.3;
const double _kZoomInFull = 18.6;
const double _kIndoorZoom = 19.2;

/// An anchor counts for indoor mode while the camera stays this close.
const double _kIndoorRangeM = 220;

class _Anchor {
  const _Anchor(this.building, this.name, this.lat, this.lon, this.alt);
  final String building;
  final String name;
  final double lat, lon, alt;
}

/// One surveyed room inside a room/v1 doc — carries the doc uuid so
/// edits route back to the node that owns the layout.
class _RoomRef {
  _RoomRef({
    required this.docUuid,
    required this.doc,
    required this.room,
    required this.building,
    required this.anchor,
    required this.origin,
    required this.headingDeg,
    required this.hw,
    required this.hd,
    required this.h,
  });
  final String docUuid;
  final Map<String, dynamic> doc;
  final Map<String, dynamic> room;
  final String building;
  final _Anchor anchor;
  final List<double> origin;
  final double headingDeg;
  final double hw, hd, h;
  String get roomId => '${room['room_id'] ?? doc['room_id'] ?? ''}';
  String get name => '${room['name'] ?? roomId}';
  int? get floor => (room['spatial'] as Map?)?['floor'] is int
      ? (room['spatial'] as Map)['floor'] as int
      : null;

  /// Room x/z → ENU metres (y is up within the room).
  List<double> toEnu(double x, double y, double z) =>
      roomToEnu([x, y, z], origin, headingDeg);

  /// ENU → room x/y/z — the horizontal mapping is an involution, so the
  /// same rotation applied to the delta vector yields (x, z) in slots
  /// 0/1; height is a plain offset.
  List<double> fromEnu(double e, double n, double u) {
    final r = roomToEnu(
        [e - origin[0], 0, n - origin[1]], const [0, 0, 0], headingDeg);
    return [r[0], u - origin[2], r[1]];
  }

  /// Axis-aligned zones in room coords: {id, name, rect:[x,z,w,d]}.
  List<Map<String, dynamic>> get zones =>
      (room['zones'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
}

class _FleetMapViewState extends State<FleetMapView>
    with TickerProviderStateMixin {
  final _map = MapController();
  Map<String, Map<String, dynamic>> _docs = {};
  List<String> _unavailable = [];
  bool _loading = false;
  bool _positioned = false;
  bool _showUnknowns = true;
  bool _showTrace = true;

  double _indoorT = 0;
  _Anchor? _indoorAnchor;
  String? _selectedDevice;
  bool _zoneMode = false;

  /// Active single-pointer gesture state.
  int _pointers = 0;
  String? _dragDeviceId;
  String? _dragPersonId;
  _RoomRef? _dragRoom;
  bool _rotating = false;
  Offset _zoneDraftStart = Offset.zero;
  Offset? _zoneDraftPos;
  _RoomRef? _zoneRoom;

  final Set<String> _saving = {};
  AnimationController? _fly;

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
    _fly?.dispose();
    TraceService.instance.removeListener(_onTrace);
    _map.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(FleetMapView old) {
    super.didUpdateWidget(old);
    if (old.devices.map((d) => d.uuid).join() !=
        widget.devices.map((d) => d.uuid).join()) {
      _load();
    }
    if (!_positioned) _positionCamera();
  }

  // ── data ───────────────────────────────────────────────────────────

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
      _positionCamera();
    }
  }

  /// Building geo-anchors from every room doc that carries one.
  List<_Anchor> get _anchors {
    final out = <String, _Anchor>{};
    for (final doc in _docs.values) {
      final b = doc['building'] as Map?;
      final id = '${b?['id'] ?? ''}';
      if (id.isEmpty) continue;
      final a = b?['anchor'] as Map?;
      final lat = (a?['latitude'] as num?)?.toDouble();
      final lon = (a?['longitude'] as num?)?.toDouble();
      if (lat == null || lon == null) continue;
      out.putIfAbsent(
        id,
        () => _Anchor(
          id,
          '${b?['name'] ?? id}',
          lat,
          lon,
          (a?['altitude_m'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    return out.values.toList()..sort((a, b) => a.building.compareTo(b.building));
  }

  /// Surveyed rooms, each carrying the node uuid that owns its doc.
  List<_RoomRef> get _rooms {
    final byId = {for (final a in _anchors) a.building: a};
    final out = <_RoomRef>[];
    for (final e in _docs.entries) {
      final doc = e.value;
      final building = '${(doc['building'] as Map?)?['id'] ?? ''}';
      final anchor = byId[building];
      if (anchor == null) continue;
      for (final r in [
        doc,
        ...(doc['rooms'] as List? ?? []).whereType<Map>(),
      ]) {
        final s = r['spatial'] as Map? ?? {};
        final dims = r['dims'] as Map? ?? {};
        final origin = _v3(s['origin_enu_m']);
        if (s['surveyed'] != true ||
            origin == null ||
            !_finite(s['heading_deg']) ||
            !['w', 'd', 'h']
                .every((k) => _finite(dims[k]) && (dims[k] as num) > 0)) {
          continue;
        }
        out.add(
          _RoomRef(
            docUuid: e.key,
            doc: doc,
            room: Map<String, dynamic>.from(r),
            building: building,
            anchor: anchor,
            origin: origin,
            headingDeg: (s['heading_deg'] as num).toDouble(),
            hw: (dims['w'] as num).toDouble() / 2,
            hd: (dims['d'] as num).toDouble() / 2,
            h: (dims['h'] as num).toDouble(),
          ),
        );
      }
    }
    return out;
  }

  /// Device placement rows of [doc] whose room resolves to a surveyed
  /// room of [building] — the draggable anchors.
  List<({Map<String, dynamic> row, _RoomRef room, String docUuid})>
      _anchorRows(String building) {
    final rooms = _rooms.where((r) => r.building == building).toList();
    final out = <({Map<String, dynamic> row, _RoomRef room, String docUuid})>[];
    for (final e in _docs.entries) {
      for (final dev
          in (e.value['devices'] as List? ?? const []).whereType<Map>()) {
        final rid =
            '${dev['room_id'] == '' || dev['room_id'] == null ? e.value['room_id'] ?? '' : dev['room_id']}';
        final room = rooms.where((r) => r.roomId == rid).firstOrNull;
        final p = dev['pos'];
        if (room == null ||
            p is! List ||
            p.length < 3 ||
            !p.every(_finite)) {
          continue;
        }
        out.add((
          row: Map<String, dynamic>.from(dev),
          room: room,
          docUuid: e.key,
        ));
      }
    }
    return out;
  }

  /// Person rows of [doc] inside surveyed rooms of [building].
  List<({Map<String, dynamic> row, _RoomRef room, String docUuid})>
      _personRows(String building) {
    final rooms = _rooms.where((r) => r.building == building).toList();
    final out = <({Map<String, dynamic> row, _RoomRef room, String docUuid})>[];
    for (final e in _docs.entries) {
      for (final person
          in (e.value['persons'] as List? ?? const []).whereType<Map>()) {
        final rid =
            '${person['room_id'] == '' || person['room_id'] == null ? e.value['room_id'] ?? '' : person['room_id']}';
        final room = rooms.where((r) => r.roomId == rid).firstOrNull;
        final p = person['pos'];
        if (room == null ||
            p is! List ||
            p.length < 3 ||
            !p.every(_finite)) {
          continue;
        }
        out.add((
          row: Map<String, dynamic>.from(person),
          room: room,
          docUuid: e.key,
        ));
      }
    }
    return out;
  }

  /// Live device rows inside the real doc (mutated during drags).
  Map<String, dynamic>? _docRow(String docUuid, String deviceId) {
    for (final d
        in (_docs[docUuid]?['devices'] as List? ?? const []).whereType<Map>()) {
      if ('${d['device_id']}' == deviceId) {
        return Map<String, dynamic>.from(d);
      }
    }
    return null;
  }

  void _mutateRow(String docUuid, String deviceId,
      void Function(Map<String, dynamic>) fn) {
    final rows = _docs[docUuid]?['devices'] as List?;
    if (rows == null) return;
    for (final d in rows.whereType<Map>()) {
      if ('${d['device_id']}' == deviceId) {
        fn(d as Map<String, dynamic>);
        return;
      }
    }
  }

  void _mutatePerson(String docUuid, String personId,
      void Function(Map<String, dynamic>) fn) {
    final rows = _docs[docUuid]?['persons'] as List?;
    if (rows == null) return;
    for (final d in rows.whereType<Map>()) {
      if ('${d['person_id']}' == personId) {
        fn(d as Map<String, dynamic>);
        return;
      }
    }
  }

  // ── geo helpers ────────────────────────────────────────────────────

  static List<double> geoToEnu(
          double lat, double lon, double? alt, _Anchor a) =>
      _geoToEnu(lat, lon, alt, a.lat, a.lon, a.alt);

  LatLng _enuToGeo(List<double> enu, _Anchor a) {
    const r = 6378137.0;
    return LatLng(
      a.lat + enu[1] / r * 180 / math.pi,
      a.lon + enu[0] / (r * math.cos(a.lat * math.pi / 180)) * 180 / math.pi,
    );
  }

  Offset _geoToScreen(double lat, double lon) {
    final p = _map.camera.latLngToScreenPoint(LatLng(lat, lon));
    return Offset(p.x, p.y);
  }

  Offset _enuToScreen(List<double> enu, _Anchor a) {
    final g = _enuToGeo(enu, a);
    return _geoToScreen(g.latitude, g.longitude);
  }

  /// Screen px → room x/z for [room]; null when the point is outside.
  Offset? _screenToRoom(Offset px, _RoomRef room) {
    final geo = _map.camera
        .pointToLatLng(math.Point<double>(px.dx, px.dy));
    final enu = geoToEnu(geo.latitude, geo.longitude, null, room.anchor);
    final local = room.fromEnu(enu[0], enu[1], enu[2]);
    final x = local[0], z = local[2];
    if (x.abs() > room.hw + 0.4 || z.abs() > room.hd + 0.4) return null;
    return Offset(x.clamp(-room.hw + 0.05, room.hw - 0.05),
        z.clamp(-room.hd + 0.05, room.hd - 0.05));
  }

  /// Metres per screen px at the anchor — sizes range rings.
  double _pxPerMeter(_Anchor a) {
    final p0 = _geoToScreen(a.lat, a.lon);
    final e1 = _enuToGeo([1, 0, 0], a);
    final p1 = _geoToScreen(e1.latitude, e1.longitude);
    return math.max(0.1, (p1 - p0).distance);
  }

  // ── camera / zoom transition ───────────────────────────────────────

  void _positionCamera() {
    if (_positioned) return;
    final anchors = _anchors;
    final trace = TraceService.instance.trace;
    LatLng? target;
    double zoom = 3;
    if (trace.isNotEmpty) {
      target = LatLng(trace.last.lat, trace.last.lon);
      zoom = 16.5;
    } else if (anchors.isNotEmpty) {
      target = LatLng(anchors.first.lat, anchors.first.lon);
      zoom = 17;
    } else {
      final heads = widget.geoTraces.values.where((l) => l.isNotEmpty);
      if (heads.isNotEmpty) {
        target = LatLng(heads.first.last.lat, heads.first.last.lon);
        zoom = 15.5;
      }
    }
    if (target == null) return;
    _positioned = true;
    try {
      _map.move(target, zoom);
    } catch (_) {/* map not laid out yet */}
  }

  void _flyTo(LatLng center, double zoom) {
    _fly?.dispose();
    final from = _map.camera;
    final c0 = from.center, z0 = from.zoom;
    _fly = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..addListener(() {
        final t = Curves.easeInOutCubic.transform(_fly!.value);
        _map.move(
          LatLng(
            c0.latitude + (center.latitude - c0.latitude) * t,
            c0.longitude + (center.longitude - c0.longitude) * t,
          ),
          z0 + (zoom - z0) * t,
        );
      });
    _fly!.forward();
  }

  static double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * r * math.asin(math.sqrt(a));
  }

  void _onCamera(MapCamera cam, bool hasGesture) {
    final buildingsWithRooms = _rooms.map((r) => r.building).toSet();
    _Anchor? nearest;
    var best = _kIndoorRangeM;
    for (final a in _anchors) {
      if (!buildingsWithRooms.contains(a.building)) continue;
      final d = _haversineM(
          cam.center.latitude, cam.center.longitude, a.lat, a.lon);
      if (d < best) {
        best = d;
        nearest = a;
      }
    }
    final t = nearest == null
        ? 0.0
        : ((cam.zoom - _kZoomInStart) / (_kZoomInFull - _kZoomInStart))
            .clamp(0.0, 1.0);
    if (t != _indoorT ||
        (t > 0 && nearest!.building != _indoorAnchor?.building)) {
      setState(() {
        _indoorT = t;
        if (t > 0) _indoorAnchor = nearest;
        if (t == 0) {
          _zoneMode = false;
          _selectedDevice = null;
        }
      });
    }
  }

  bool get _indoor => _indoorT > 0.55 && _indoorAnchor != null;

  // ── gestures (indoor overlay) ──────────────────────────────────────

  void _onPointerDown(PointerDownEvent e, _Anchor anchor) {
    _pointers++;
    if (_pointers > 1) return;
    final px = e.localPosition;
    final hits = _hitList(anchor);
    if (_zoneMode) {
      _zoneRoom = _rooms
          .where((r) => r.building == anchor.building)
          .where((r) => _screenToRoom(px, r) != null)
          .firstOrNull;
      _zoneDraftStart = px;
      _zoneDraftPos = px;
      return;
    }
    // Rotate handle of the selected device first — it floats off-center.
    final sel = _selectedDevice;
    if (sel != null) {
      for (final h in hits) {
        if (h.deviceId == sel &&
            (h.handle - px).distance < 22) {
          _rotating = true;
          _dragDeviceId = sel;
          _dragRoom = h.room;
          return;
        }
      }
    }
    for (final h in hits) {
      if ((h.screen - px).distance < 26) {
        _dragDeviceId = h.deviceId;
        _dragRoom = h.room;
        _selectedDevice = h.deviceId;
        setState(() {});
        return;
      }
    }
    for (final p in _personHits(anchor)) {
      if ((p.screen - px).distance < 24) {
        _dragPersonId = p.personId;
        _dragRoom = p.room;
        return;
      }
    }
    final zone = _zoneAt(px, anchor);
    if (zone != null) {
      _zoneOptions(zone.room, zone.zone);
      return;
    }
    if (_selectedDevice != null) setState(() => _selectedDevice = null);
  }

  void _onPointerMove(PointerMoveEvent e, _Anchor anchor) {
    if (_pointers > 1) return;
    final px = e.localPosition;
    if (_zoneMode && _zoneDraftPos != null) {
      setState(() => _zoneDraftPos = px);
      return;
    }
    final devId = _dragDeviceId;
    final room = _dragRoom;
    if (devId != null && room != null) {
      final local = _roomPosFromScreen(px, room);
      if (local == null) return;
      setState(() {
        if (_rotating) {
          // Forward in the room plane is (sinθ, −cosθ) over x/z.
          final dev = _docRow(room.docUuid, devId);
          final p = dev?['pos'];
          if (p is List && p.length >= 3) {
            final dx = local.dx - (p[0] as num).toDouble();
            final dz = local.dy - (p[2] as num).toDouble();
            if (dx * dx + dz * dz > 0.01) {
              var yaw = math.atan2(dx, -dz) * 180 / math.pi;
              if (yaw < 0) yaw += 360;
              _mutateRow(room.docUuid, devId, (r) => r['rot_y'] = yaw);
            }
          }
        } else {
          _mutateRow(room.docUuid, devId, (r) {
            final p = r['pos'] as List;
            p[0] = local.dx;
            p[2] = local.dy;
          });
        }
      });
      return;
    }
    final personId = _dragPersonId;
    if (personId != null && room != null) {
      final local = _roomPosFromScreen(px, room);
      if (local == null) return;
      setState(() {
        _mutatePerson(room.docUuid, personId, (r) {
          final p = r['pos'] as List;
          p[0] = local.dx;
          p[2] = local.dy;
        });
      });
    }
  }

  /// Screen px → unclamped room x/z (rotation needs the free vector).
  Offset? _roomPosFromScreen(Offset px, _RoomRef room) {
    final geo =
        _map.camera.pointToLatLng(math.Point<double>(px.dx, px.dy));
    final enu = geoToEnu(geo.latitude, geo.longitude, null, room.anchor);
    final local = room.fromEnu(enu[0], enu[1], enu[2]);
    return Offset(local[0], local[2]);
  }

  void _onPointerUp(PointerEvent e, _Anchor anchor) {
    _pointers = math.max(0, _pointers - 1);
    if (_zoneMode && _zoneDraftPos != null && _zoneRoom != null) {
      final a = _screenToRoom(_zoneDraftStart, _zoneRoom!);
      final b = _screenToRoom(_zoneDraftPos!, _zoneRoom!);
      final room = _zoneRoom!;
      _zoneDraftPos = null;
      if (a != null && b != null && (b - a).distance > 0.15) {
        _addZoneDialog(room, a, b);
        return;
      }
      setState(() {});
      return;
    }
    final room = _dragRoom;
    if (room != null) unawaited(_save(room.docUuid));
    setState(() {
      _dragDeviceId = null;
      _dragPersonId = null;
      _dragRoom = null;
      _rotating = false;
    });
  }

  // Hit-test records computed with the same projection as the painter.
  List<_AnchorHit> _hitList(_Anchor anchor) {
    final out = <_AnchorHit>[];
    for (final a in _anchorRows(anchor.building)) {
      final p = a.row['pos'] as List;
      final enu = a.room.toEnu(
          (p[0] as num).toDouble(), 0, (p[2] as num).toDouble());
      final c = _enuToScreen(enu, anchor);
      final yaw =
          ((a.row['rot_y'] as num?)?.toDouble() ?? 0) * math.pi / 180;
      final tip = a.room.toEnu(
          (p[0] as num).toDouble() + math.sin(yaw) * 0.8,
          0,
          (p[2] as num).toDouble() - math.cos(yaw) * 0.8);
      final tipPx = _enuToScreen(tip, anchor);
      final dir = tipPx - c;
      final handle = dir.distance < 1
          ? c + const Offset(0, -34)
          : c + dir / dir.distance * 34;
      out.add(_AnchorHit('${a.row['device_id']}', c, handle, a.row, a.room));
    }
    return out;
  }

  List<_PersonHit> _personHits(_Anchor anchor) => [
        for (final p in _personRows(anchor.building))
          _PersonHit(
            '${p.row['person_id']}',
            _enuToScreen(
              p.room.toEnu((p.row['pos'][0] as num).toDouble(), 0,
                  (p.row['pos'][2] as num).toDouble()),
              anchor,
            ),
            p.row,
            p.room,
          ),
      ];

  ({_RoomRef room, Map<String, dynamic> zone})? _zoneAt(
      Offset px, _Anchor anchor) {
    for (final r in _rooms.where((r) => r.building == anchor.building)) {
      final local = _roomPosFromScreen(px, r);
      if (local == null ||
          local.dx.abs() > r.hw + 0.3 ||
          local.dy.abs() > r.hd + 0.3) {
        continue;
      }
      for (final z in r.zones) {
        final rect = z['rect'];
        if (rect is List && rect.length == 4 && rect.every(_finite)) {
          final cx = (rect[0] as num).toDouble(),
              cz = (rect[1] as num).toDouble(),
              w = (rect[2] as num).toDouble(),
              d = (rect[3] as num).toDouble();
          if ((local.dx - cx).abs() <= w / 2 &&
              (local.dy - cz).abs() <= d / 2) {
            return (room: r, zone: z);
          }
        }
      }
    }
    return null;
  }

  // ── mutation + save ────────────────────────────────────────────────

  Future<void> _save(String docUuid) async {
    final doc = _docs[docUuid];
    if (doc == null || !_saving.add(docUuid)) return;
    try {
      final latest =
          await NodeClient.instance.getMap(docUuid, '/api/v1/room');
      if (latest.isNotEmpty &&
          latest['updated_at'] != doc['updated_at']) {
        throw StateError('Layout changed elsewhere — reloaded.');
      }
      final saved =
          await NodeClient.instance.put(docUuid, '/api/v1/room', body: doc);
      if (saved is Map && saved['format'] == 'room/v1') {
        _docs[docUuid] = Map<String, dynamic>.from(saved);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      await _load();
    } finally {
      _saving.remove(docUuid);
      if (mounted) setState(() {});
    }
  }

  Future<void> _addZoneDialog(_RoomRef room, Offset a, Offset b) async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New zone'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. desk'),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctl.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) {
      setState(() {});
      return;
    }
    final cx = (a.dx + b.dx) / 2, cz = (a.dy + b.dy) / 2;
    final w = (b.dx - a.dx).abs(), d = (b.dy - a.dy).abs();
    setState(() {
      // room.room is a display copy — write into the owning doc row.
      final roomRow = _roomRowInDoc(room);
      final zones = (roomRow!['zones'] ??= <Map>[]) as List;
      zones.add({
        'id': 'zone-${DateTime.now().millisecondsSinceEpoch % 100000}',
        'name': name,
        'rect': [cx, cz, w, d],
      });
      _zoneMode = false;
    });
    unawaited(_save(room.docUuid));
  }

  void _zoneOptions(_RoomRef room, Map<String, dynamic> zone) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${zone['name'] ?? zone['id']}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete zone'),
                onPressed: () {
                  Navigator.pop(c);
                  setState(() {
                    final roomRow = _roomRowInDoc(room);
                    (roomRow?['zones'] as List?)
                        ?.removeWhere((z) => '${z['id']}' == '${zone['id']}');
                  });
                  unawaited(_save(room.docUuid));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The real room map inside the owning doc (zone deletes mutate it).
  Map<String, dynamic>? _roomRowInDoc(_RoomRef r) {
    if (r.roomId == '${r.doc['room_id'] ?? ''}') return r.doc;
    for (final m
        in (r.doc['rooms'] as List? ?? const []).whereType<Map>()) {
      if ('${m['room_id']}' == r.roomId) {
        return m as Map<String, dynamic>;
      }
    }
    return null;
  }

  void _addDevice(_Anchor anchor) {
    final rooms = _rooms.where((r) => r.building == anchor.building).toList();
    if (rooms.isEmpty) return;
    _RoomRef room = rooms.first;
    final known = <String>{
      for (final e in _docs.entries)
        for (final d
            in (e.value['devices'] as List? ?? const []).whereType<Map>())
          '${d['device_id']}',
    };
    final free = widget.devices.where((f) => !known.contains(f.uuid)).toList();
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Every fleet device is placed already')),
      );
      return;
    }
    String pick = free.first.uuid;
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setB) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Place a stationary device',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: pick,
                  decoration: const InputDecoration(labelText: 'Device'),
                  items: [
                    for (final f in free)
                      DropdownMenuItem(
                        value: f.uuid,
                        child: Text(f.name.isEmpty ? f.uuid : f.name),
                      ),
                  ],
                  onChanged: (v) => setB(() => pick = v ?? pick),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: room.roomId,
                  decoration: const InputDecoration(labelText: 'Room'),
                  items: [
                    for (final r in rooms)
                      DropdownMenuItem(value: r.roomId, child: Text(r.name)),
                  ],
                  onChanged: (v) => setB(
                    () => room =
                        rooms.firstWhere((r) => r.roomId == v),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(c);
                    setState(() {
                      final devices =
                          (_docs[room.docUuid]!['devices'] ??= []) as List;
                      devices.removeWhere((d) => d['device_id'] == pick);
                      devices.add({
                        'device_id': pick,
                        'room_id': room.roomId,
                        'pos': [0.0, 1.0, 0.0],
                        'sensors': <Map>[],
                      });
                      _selectedDevice = pick;
                    });
                    unawaited(_save(room.docUuid));
                  },
                  child: const Text('Place at room centre'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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

  // ── build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scene = SpatialScene.fromDocuments(
      _docs,
      widget.edges,
      widget.devices,
      widget.watchNames,
    );
    final anchors = _anchors;
    final anchor = _indoorAnchor;
    final trace = TraceService.instance.trace;
    final traceLine = trace.length > 1
        ? Polyline(
            points: [for (final p in trace) LatLng(p.lat, p.lon)],
            color: Colors.deepOrange.withValues(alpha: 0.85),
            strokeWidth: 3,
          )
        : null;

    final indoorFlags = InteractiveFlag.pinchZoom |
        InteractiveFlag.pinchMove |
        InteractiveFlag.scrollWheelZoom |
        InteractiveFlag.doubleTapZoom |
        InteractiveFlag.flingAnimation;
    final worldFlags = InteractiveFlag.all & ~InteractiveFlag.rotate;

    return Column(
      children: [
        _toolbar(context, anchor),
        if (_loading) const LinearProgressIndicator(),
        if (_unavailable.isNotEmpty)
          Text(
            'Layout unavailable: ${_unavailable.join(', ')}',
            style: const TextStyle(fontSize: 11),
          ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: anchors.isNotEmpty
                        ? LatLng(anchors.first.lat, anchors.first.lon)
                        : const LatLng(20, 0),
                    initialZoom: anchors.isNotEmpty ? 17 : 3,
                    minZoom: 2.5,
                    maxZoom: 21,
                    interactionOptions: InteractionOptions(
                      flags: _indoor ? indoorFlags : worldFlags,
                    ),
                    onMapReady: _positionCamera,
                    onPositionChanged: _onCamera,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'app.thothcraft',
                    ),
                    if (_showTrace && traceLine != null)
                      PolylineLayer(polylines: [traceLine]),
                    _geoTracesLayer(),
                    if (_indoorT < 0.95)
                      MarkerLayer(
                        markers: _worldMarkers(anchors, scene),
                      ),
                    if (anchor != null && _indoorT > 0)
                      IgnorePointer(
                        child: Opacity(
                          opacity: _indoorT,
                          child: CustomPaint(
                            painter: _IndoorPainter(
                              anchor: anchor,
                              rooms: _rooms
                                  .where((r) => r.building == anchor.building)
                                  .toList(),
                              anchors: _anchorRows(anchor.building),
                              persons: _personRows(anchor.building),
                              scene: scene,
                              toScreen: _enuToScreen,
                              pxPerMeter: _pxPerMeter(anchor),
                              labelFor: _labelFor,
                              selectedId: _selectedDevice,
                              showUnknowns: _showUnknowns,
                              zoneDraft: _zoneDraftPos != null
                                  ? (_zoneDraftStart, _zoneDraftPos!)
                                  : null,
                              scrimColor: Theme.of(context)
                                  .colorScheme
                                  .surface
                                  .withValues(alpha: 0.62 * _indoorT),
                              labelColor:
                                  Theme.of(context).colorScheme.onSurface,
                              mutedColor: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_indoor)
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _onPointerDown(e, anchor!),
                    onPointerMove: (e) => _onPointerMove(e, anchor!),
                    onPointerUp: (e) => _onPointerUp(e, anchor!),
                    onPointerCancel: (e) => _onPointerUp(e, anchor!),
                  ),
                ),
              Positioned(
                left: 10,
                bottom: 10,
                child: _statusChip(scene),
              ),
              if (trace.isNotEmpty && _indoorT < 0.55)
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        '${trace.length} fixes · '
                        '${(TraceService.instance.distanceM / 1000).toStringAsFixed(2)} km',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Text(
            'Zoom into a house pin to edit the floor plan — drag devices to '
            'move them, drag the handle to aim their field of view. '
            'Everything else is placed by BLE/Wi-Fi ranging.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context, _Anchor? anchor) {
    return Wrap(
      spacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (_indoor && anchor != null)
          TextButton.icon(
            onPressed: () =>
                _flyTo(LatLng(anchor.lat, anchor.lon), _kZoomInStart - 0.8),
            icon: const Icon(Icons.public, size: 18),
            label: Text('${anchor.name} — world'),
          ),
        if (_indoor) ...[
          TextButton.icon(
            onPressed: () => setState(() => _zoneMode = !_zoneMode),
            icon: Icon(
              _zoneMode ? Icons.crop_free : Icons.crop_square,
              size: 18,
            ),
            label: Text(_zoneMode ? 'drawing zone…' : 'Add zone'),
          ),
          IconButton(
            tooltip: 'Place device',
            onPressed: () => _addDevice(anchor!),
            icon: const Icon(Icons.add_location_alt_outlined, size: 20),
          ),
        ],
        IconButton(
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh, size: 20),
          tooltip: 'Refresh room layouts',
        ),
        IconButton(
          onPressed: () => setState(() => _showTrace = !_showTrace),
          icon: Icon(
            _showTrace ? Icons.route : Icons.route_outlined,
            size: 20,
          ),
          tooltip: 'Toggle GPS traces',
        ),
        IconButton(
          onPressed: () => setState(() => _showUnknowns = !_showUnknowns),
          icon: Icon(
            _showUnknowns
                ? Icons.visibility
                : Icons.visibility_off_outlined,
            size: 20,
          ),
          tooltip: _showUnknowns ? 'Hide unknowns' : 'Show unknowns',
        ),
        PopupMenuButton<ThothDevice>(
          tooltip: 'Edit layout numerically',
          icon: const Icon(Icons.home_work_outlined, size: 20),
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
        IconButton(
          tooltip: 'Radio link graph',
          icon: const Icon(Icons.hub_outlined, size: 20),
          onPressed: () => context.push('/context/relations'),
        ),
      ],
    );
  }

  Widget _statusChip(SpatialScene scene) {
    final b = _indoorAnchor?.building;
    final scoped = b == null
        ? scene.points
        : scene.points.where((p) => p.building == b).toList();
    final anchored = scoped.where((p) => !p.estimated).length;
    final estimated = scoped.where((p) => p.estimated).length;
    final rings = scene.rings.where((r) => r.building == b).length;
    final unlocated = <String>{
      for (final d in widget.devices) d.uuid,
      for (final e in widget.edges) ...[e.observer, e.target],
    }
        .difference({
          for (final p in scene.points) p.id,
          for (final r in scene.rings) r.target,
        })
        .length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          '$anchored anchored · $estimated located by radio · '
          '$rings ranged · $unlocated unlocated',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }

  /// Evidence trails for GPS-capable sources (device uuid → fixes).
  Widget _geoTracesLayer() {
    if (!_showTrace) return const SizedBox.shrink();
    const colors = [
      Colors.deepPurple,
      Colors.teal,
      Colors.indigo,
      Colors.brown,
      Colors.pink,
    ];
    var i = 0;
    return PolylineLayer(
      polylines: [
        for (final e in widget.geoTraces.entries)
          if (e.value.length > 1)
            Polyline(
              points: [
                for (final f in e.value.take(300)) LatLng(f.lat, f.lon)
              ],
              color: colors[i++ % colors.length].withValues(alpha: 0.7),
              strokeWidth: 2.4,
            ),
      ],
    );
  }

  List<Marker> _worldMarkers(List<_Anchor> anchors, SpatialScene scene) {
    final markers = <Marker>[];
    // Building pins — the dive-in targets.
    for (final a in anchors) {
      markers.add(
        Marker(
          point: LatLng(a.lat, a.lon),
          width: 110,
          height: 54,
          child: GestureDetector(
            onTap: () => _flyTo(LatLng(a.lat, a.lon), _kIndoorZoom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.home_work, size: 30,
                    color: Colors.blue.shade800),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    a.name,
                    style: const TextStyle(fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Anchored fleet devices — their geo position comes from the survey.
    for (final p in scene.points.where((p) => !p.estimated)) {
      final a = anchors.where((x) => x.building == p.building).firstOrNull;
      if (a == null) continue;
      final g = _enuToGeo(p.enu, a);
      markers.add(
        Marker(
          point: g,
          width: 60,
          height: 36,
          child: GestureDetector(
            onTap: () => _flyTo(LatLng(a.lat, a.lon), _kIndoorZoom),
            child: Tooltip(
              message: _labelFor(p.id),
              child: Icon(Icons.router, size: 18,
                  color: Colors.blue.shade700),
            ),
          ),
        ),
      );
    }
    // GPS-capable devices — latest evidence fix as a pin.
    for (final e in widget.geoTraces.entries) {
      if (e.value.isEmpty) continue;
      final f = e.value.last;
      markers.add(
        Marker(
          point: LatLng(f.lat, f.lon),
          width: 60,
          height: 44,
          child: GestureDetector(
            onTap: () => _flyTo(LatLng(f.lat, f.lon), _map.camera.zoom + 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.smartphone, size: 18,
                    color: Colors.deepPurple),
                Text(
                  _labelFor(e.key),
                  style: const TextStyle(fontSize: 9,
                      color: Colors.deepPurple),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      );
    }
    // Local phone trace head.
    final t = TraceService.instance.trace;
    if (t.isNotEmpty) {
      final last = t.last;
      markers.add(
        Marker(
          point: LatLng(last.lat, last.lon),
          width: 30,
          height: 30,
          child: const Icon(Icons.navigation,
              size: 22, color: Colors.deepOrange),
        ),
      );
    }
    return markers;
  }
}

class _AnchorHit {
  const _AnchorHit(this.deviceId, this.screen, this.handle, this.row, this.room);
  final String deviceId;
  final Offset screen, handle;
  final Map<String, dynamic> row;
  final _RoomRef room;
}

class _PersonHit {
  const _PersonHit(this.personId, this.screen, this.row, this.room);
  final String personId;
  final Offset screen;
  final Map<String, dynamic> row;
  final _RoomRef room;
}

/// lat/lon → ENU metres around a building anchor (equirectangular —
/// accurate to millimetres at building scale).
List<double> _geoToEnu(
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

bool _finite(dynamic v) => v is num && v.isFinite;
List<double>? _v3(dynamic v) => v is List && v.length == 3 && v.every(_finite)
    ? v.map((e) => (e as num).toDouble()).toList()
    : null;

/// The indoor plan layer, painted in the map's geographic frame so the
/// transition is a literal zoom: rooms become visible exactly where the
/// survey says they stand.
class _IndoorPainter extends CustomPainter {
  _IndoorPainter({
    required this.anchor,
    required this.rooms,
    required this.anchors,
    required this.persons,
    required this.scene,
    required this.toScreen,
    required this.pxPerMeter,
    required this.labelFor,
    required this.selectedId,
    required this.showUnknowns,
    required this.scrimColor,
    required this.labelColor,
    required this.mutedColor,
    this.zoneDraft,
  });

  final _Anchor anchor;
  final List<_RoomRef> rooms;
  final List<({Map<String, dynamic> row, _RoomRef room, String docUuid})>
      anchors;
  final List<({Map<String, dynamic> row, _RoomRef room, String docUuid})>
      persons;
  final SpatialScene scene;
  final Offset Function(List<double> enu, _Anchor a) toScreen;
  final double pxPerMeter;
  final String Function(String) labelFor;
  final String? selectedId;
  final bool showUnknowns;
  final Color scrimColor, labelColor, mutedColor;
  final (Offset, Offset)? zoneDraft;

  static const _fovColors = {
    'radar': Color(0xFF2E7D32),
    'camera': Color(0xFF3949AB),
    'csi': Color(0xFF8E24AA),
  };
  static const _zoneColor = Color(0xFF6A1B9A);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = scrimColor);

    // Metre grid + room shells.
    for (final r in rooms) {
      final grid = Paint()
        ..color = mutedColor.withValues(alpha: 0.14)
        ..strokeWidth = 0.6;
      for (var x = -r.hw; x <= r.hw; x += 1) {
        canvas.drawLine(
          toScreen(r.toEnu(x, 0, -r.hd), anchor),
          toScreen(r.toEnu(x, 0, r.hd), anchor),
          grid,
        );
      }
      for (var z = -r.hd; z <= r.hd; z += 1) {
        canvas.drawLine(
          toScreen(r.toEnu(-r.hw, 0, z), anchor),
          toScreen(r.toEnu(r.hw, 0, z), anchor),
          grid,
        );
      }
      final c = [
        r.toEnu(-r.hw, 0, -r.hd),
        r.toEnu(r.hw, 0, -r.hd),
        r.toEnu(r.hw, 0, r.hd),
        r.toEnu(-r.hw, 0, r.hd),
      ].map((e) => toScreen(e, anchor)).toList();
      final floor = ui.Path()..moveTo(c[0].dx, c[0].dy);
      for (var i = 1; i < 4; i++) {
        floor.lineTo(c[i].dx, c[i].dy);
      }
      floor.close();
      canvas.drawPath(
        floor,
        Paint()..color = Colors.blueGrey.withValues(alpha: 0.10),
      );
      canvas.drawPath(
        floor,
        Paint()
          ..color = Colors.blueGrey.shade700
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        '${r.name}  ${(r.hw * 2).toStringAsFixed(1)}×${(r.hd * 2).toStringAsFixed(1)} m'
        '${r.floor != null ? ' · F${r.floor}' : ''}',
        c[0] + const Offset(4, -18),
        11,
        bold: true,
      );

      // Zones — named sub-regions inside the room.
      for (final z in r.zones) {
        final rect = z['rect'];
        if (rect is! List || rect.length != 4 || !rect.every(_finite)) {
          continue;
        }
        final cx = (rect[0] as num).toDouble(),
            cz = (rect[1] as num).toDouble(),
            w = (rect[2] as num).toDouble(),
            d = (rect[3] as num).toDouble();
        final zc = [
          r.toEnu(cx - w / 2, 0, cz - d / 2),
          r.toEnu(cx + w / 2, 0, cz - d / 2),
          r.toEnu(cx + w / 2, 0, cz + d / 2),
          r.toEnu(cx - w / 2, 0, cz + d / 2),
        ].map((e) => toScreen(e, anchor)).toList();
        final zp = ui.Path()..moveTo(zc[0].dx, zc[0].dy);
        for (var i = 1; i < 4; i++) {
          zp.lineTo(zc[i].dx, zc[i].dy);
        }
        zp.close();
        canvas.drawPath(
          zp,
          Paint()..color = _zoneColor.withValues(alpha: 0.12),
        );
        canvas.drawPath(
          zp,
          Paint()
            ..color = _zoneColor.withValues(alpha: 0.6)
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke,
        );
        _text(
          canvas,
          '${z['name'] ?? z['id']}',
          zc[0] + const Offset(3, 2),
          10,
          bold: true,
          color: _zoneColor,
        );
      }
    }

    // Zone draft rubber-band.
    final draft = zoneDraft;
    if (draft != null) {
      final rect = Rect.fromPoints(draft.$1, draft.$2);
      canvas.drawRect(
        rect,
        Paint()..color = _zoneColor.withValues(alpha: 0.15),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = _zoneColor
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke,
      );
    }

    // Single-sighting radios — a range ring on the anchor, nothing more.
    for (final ring in scene.rings.where((r) => r.building == anchor.building)) {
      _dashedCircle(
        canvas,
        toScreen(ring.anchorEnu, anchor),
        ring.radiusM * pxPerMeter,
        mutedColor.withValues(alpha: 0.6),
      );
    }

    // Radios located by ≥2 anchors — they "align around" the stationary
    // fleet via the BLE/Wi-Fi solve, drawn with an honest uncertainty ring.
    for (final p in scene.points.where(
      (p) => p.building == anchor.building && p.estimated,
    )) {
      if (!showUnknowns && !p.known) continue;
      final c = toScreen(p.enu, anchor);
      final color =
          p.known ? const Color(0xFF546E7A) : Colors.grey.shade500;
      final rpx = p.uncertaintyM * pxPerMeter;
      if (rpx > 3) {
        canvas.drawCircle(
          c,
          rpx,
          Paint()..color = color.withValues(alpha: 0.07),
        );
        _dashedCircle(canvas, c, rpx, color.withValues(alpha: 0.55));
      }
      canvas.drawCircle(c, 8, Paint()..color = color.withValues(alpha: 0.9));
      canvas.drawCircle(
        c,
        8,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        labelFor(p.id),
        c + const Offset(10, -10),
        10,
        color: p.known ? labelColor : mutedColor,
      );
      _text(
        canvas,
        '±${p.uncertaintyM.toStringAsFixed(1)}m${p.moving ? ' · varying' : ''}',
        c + const Offset(10, 3),
        9,
        color: mutedColor,
      );
    }

    // People pinned on the plan.
    for (final p in persons) {
      final pos = p.row['pos'] as List;
      final c = toScreen(
        p.room.toEnu(
            (pos[0] as num).toDouble(), 0, (pos[2] as num).toDouble()),
        anchor,
      );
      canvas.drawCircle(c, 11, Paint()..color = const Color(0xFFC96F3F));
      canvas.drawCircle(
        c,
        11,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        '${p.row['name'] ?? p.row['person_id']}',
        c + const Offset(14, -7),
        11,
        bold: true,
        color: labelColor,
      );
    }

    // Stationary devices — draggable anchors with FOV wedges and a
    // rotate handle on the selected one.
    for (final a in anchors) {
      final row = a.row;
      final id = '${row['device_id']}';
      final p = row['pos'] as List;
      final px = (p[0] as num).toDouble(), pz = (p[2] as num).toDouble();
      final c = toScreen(a.room.toEnu(px, 0, pz), anchor);
      final yaw = ((row['rot_y'] as num?)?.toDouble() ?? 0) * math.pi / 180;
      final selected = id == selectedId;

      // Sensor fans.
      for (final sen
          in (row['sensors'] as List? ?? const []).whereType<Map>()) {
        final fov = (sen['fov_deg'] as num?)?.toDouble() ?? 0;
        final range = (sen['range_m'] as num?)?.toDouble() ?? 0;
        if (fov <= 0 || range <= 0) continue;
        final syaw = yaw +
            ((sen['rot_y'] as num?)?.toDouble() ?? 0) * math.pi / 180;
        final half = fov * math.pi / 360;
        final color = _fovColors['${sen['type']}'] ?? _fovColors['radar']!;
        final fan = ui.Path()..moveTo(c.dx, c.dy);
        // Fan edge rays: room-plane forward at yaw+rel is (sin, −cos).
        for (var i = 0; i <= 14; i++) {
          final rel = -half + 2 * half * i / 14;
          final ex = px + math.sin(syaw + rel) * range;
          final ez = pz - math.cos(syaw + rel) * range;
          final edge = toScreen(a.room.toEnu(ex, 0, ez), anchor);
          fan.lineTo(edge.dx, edge.dy);
        }
        fan.close();
        canvas.drawPath(fan, Paint()..color = color.withValues(alpha: 0.10));
        canvas.drawPath(
          fan,
          Paint()
            ..color = color.withValues(alpha: 0.38)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      }

      // Facing tick.
      final nose = toScreen(
        a.room.toEnu(px + math.sin(yaw) * 0.8, 0, pz - math.cos(yaw) * 0.8),
        anchor,
      );
      final dir = nose - c;
      if (dir.distance > 1) {
        final u = dir / dir.distance;
        canvas.drawLine(
          c,
          c + u * 14,
          Paint()
            ..color = Colors.black54
            ..strokeWidth = 1.6,
        );
        if (selected) {
          // Rotate handle on the facing ray.
          final handle = c + u * 34;
          canvas.drawLine(
            c + u * 16,
            handle,
            Paint()
              ..color = Colors.deepOrange.withValues(alpha: 0.7)
              ..strokeWidth = 1.2,
          );
          canvas.drawCircle(handle, 7, Paint()..color = Colors.deepOrange);
          canvas.drawCircle(
            handle,
            7,
            Paint()
              ..color = Colors.white
              ..strokeWidth = 1.4
              ..style = PaintingStyle.stroke,
          );
        }
      }

      final rect = Rect.fromCenter(
        center: c,
        width: selected ? 20 : 16,
        height: selected ? 20 : 16,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = selected ? Colors.deepOrange : const Color(0xFF1565C0),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        labelFor(id),
        c + const Offset(11, -12),
        11,
        bold: true,
        color: labelColor,
      );
      _text(
        canvas,
        '${((row['rot_y'] as num?)?.toDouble() ?? 0).round()}°',
        c + const Offset(11, 1),
        9,
        color: mutedColor,
      );
    }
  }

  void _dashedCircle(Canvas canvas, Offset c, double rpx, Color color) {
    if (rpx < 4) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.1
      ..style = PaintingStyle.stroke;
    const segs = 36;
    final rect = Rect.fromCircle(center: c, radius: rpx);
    for (var s = 0; s < segs; s += 2) {
      canvas.drawArc(rect, s * 2 * math.pi / segs, math.pi / segs, false, paint);
    }
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
  bool shouldRepaint(_IndoorPainter old) => true;
}
