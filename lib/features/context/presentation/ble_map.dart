import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../context/application/context_providers.dart';
import '../../context/domain/models.dart';
import '../../devices/application/devices_provider.dart';

/// Shared BLE, Wi-Fi and CSI link diagram. Only saved placements carry
/// room coordinates. Unlocated radios live in a separate dock: signal
/// strength alone does not establish distance, floor or wall containment.
class BleMapView extends StatefulWidget {
  const BleMapView({
    super.key,
    required this.edges,
    required this.devices,
    required this.spaces,
    this.watchNames = const {},
  });

  final List<BleRelation> edges;
  final List<ThothDevice> devices;
  final List<SpaceInfo> spaces;

  /// bleId (MAC) → friendly name for wearable targets.
  final Map<String, String> watchNames;

  @override
  State<BleMapView> createState() => _BleMapViewState();
}

class _BleMapViewState extends State<BleMapView> {
  String? _selected;

  /// Drives InteractiveViewer programmatically (zoom buttons, reset).
  final TransformationController _viewCtl = TransformationController();

  /// Anonymous advertisers can flood the canvas — user can hide them.
  // Every recently observed transmitter is discoverable on first open.
  bool _showUnknowns = true;

  /// EMA of solved positions - multilaterated nodes glide between
  /// sighting bursts instead of jumping each rebuild.
  final Map<String, Offset> _smoothed = {};

  /// User-renamed node labels — persisted locally; keyed by node id
  /// (device uuid, ``ble:<MAC>``, entity id…).
  Map<String, String> _overrides = const {};

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      final raw = p.getString('ble_map_labels');
      if (raw != null && mounted) {
        setState(
          () => _overrides = Map<String, String>.from(jsonDecode(raw) as Map),
        );
      }
    });
  }

  @override
  void dispose() {
    _viewCtl.dispose();
    super.dispose();
  }

  Future<void> _rename(_Node n) async {
    final ctrl = TextEditingController(
      text: _overrides[n.id] ?? n.label,
    );
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
            'Label for ${n.id.length > 24 ? '${n.id.substring(0, 24)}…' : n.id}',),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. hallway beacon',
          ),
          onSubmitted: (v) => Navigator.pop(c, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, ''),
            child: const Text('Reset'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || !mounted) return;
    setState(() {
      _overrides = {..._overrides}..remove(n.id);
      if (name.isNotEmpty) _overrides[n.id] = name;
    });
    final p = await SharedPreferences.getInstance();
    await p.setString('ble_map_labels', jsonEncode(_overrides));
  }

  /// Hit-test node centers in canvas px — the painter and this share
  /// [_Scene.toCanvas], so taps stay exact under any zoom.
  void _onTap(Offset local, _Scene scene) {
    String? hit;
    var best = 30.0; // tap radius in px
    for (final n in scene.nodes.values) {
      if (!_showUnknowns && !n.known) continue;
      final d = (scene.toCanvas(n.pos) - local).distance;
      if (d < best) {
        best = d;
        hit = n.id;
      }
    }
    setState(() => _selected = hit == _selected ? null : hit);
  }

  @override
  Widget build(BuildContext context) {
    final scene = _Scene.build(
      edges: widget.edges,
      devices: widget.devices,
      spaces: widget.spaces,
      watchNames: widget.watchNames,
      labelOverrides: _overrides,
    );
    // Temporal smoothing: RSSI is bursty, so a solved position moves
    // toward its new estimate (35%) rather than snapping to it.
    for (final n in scene.nodes.values) {
      if (!n.estimated) continue;
      final prev = _smoothed[n.id];
      n.pos = prev == null ? n.pos : prev + (n.pos - prev) * 0.35;
      _smoothed[n.id] = n.pos;
    }
    final sel = _selected != null ? scene.nodes[_selected] : null;
    final selEdges = sel == null
        ? const <BleRelation>[]
        : (widget.edges
            .where((e) => e.observer == sel.id || e.target == sel.id)
            .toList()
          ..sort((a, b) => b.rssiDbm.compareTo(a.rssiDbm)));

    final worldSize = scene.canvasSize();
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  transformationController: _viewCtl,
                  // Unconstrained + generous boundary: the world is small
                  // (a floor plan) but zoom lets dense clusters resolve.
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(600),
                  minScale: 0.25,
                  maxScale: 6,
                  child: SizedBox.fromSize(
                    size: worldSize,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => _onTap(d.localPosition, scene),
                      child: CustomPaint(
                        size: worldSize,
                        painter: _BleMapPainter(
                          scene,
                          selectedId: _selected,
                          showUnknowns: _showUnknowns,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Legend — compact decoding of node/edge encodings.
              Positioned(
                left: 8,
                top: 8,
                child: _LegendCard(
                  counts: scene.kindCounts(_showUnknowns),
                  hidden: _showUnknowns
                      ? 0
                      : scene.nodes.values.where((n) => !n.known).length,
                ),
              ),
              // Map controls.
              Positioned(
                right: 8,
                top: 8,
                child: _MapControls(
                  viewCtl: _viewCtl,
                  showUnknowns: _showUnknowns,
                  onToggleUnknowns: () =>
                      setState(() => _showUnknowns = !_showUnknowns),
                ),
              ),
            ],
          ),
        ),
        // Selection card — the tapped node's links to everything else.
        if (sel != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            decoration: BoxDecoration(
              color: Colors.blueGrey.withValues(alpha: 0.08),
              border: Border(
                top: BorderSide(
                  color: Colors.blueGrey.withValues(alpha: 0.25),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _NodeDot(node: sel),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            sel.label,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            [
                              sel.kind,
                              if (!sel.known) 'unknown',
                              if (sel.placed)
                                'anchored'
                              else if (sel.estimated)
                                'est ±${sel.uncertaintyM.toStringAsFixed(1)} m'
                              else
                                'location unknown',
                              if (sel.floor.isNotEmpty) sel.floor,
                              sel.moving ? 'signal drifting' : 'signal stable',
                            ].join(' · '),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: () => _rename(sel),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.edit_outlined,
                          size: 16,
                          color: Colors.black45,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (selEdges.isEmpty)
                  const Text(
                    'no live links',
                    style: TextStyle(fontSize: 11, color: Colors.black54),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 132),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in selEdges.take(8))
                          _EdgeRow(edge: e, selId: sel.id, scene: scene),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Colored dot + kind glyph for the selection card header.
class _NodeDot extends StatelessWidget {
  const _NodeDot({required this.node});
  final _Node node;

  static const _icons = {
    'phone': Icons.smartphone,
    'watch': Icons.watch,
    'thoth': Icons.router,
    'ble': Icons.bluetooth,
    'tv': Icons.tv,
    'speaker': Icons.speaker,
  };

  Color get _color {
    if (!node.known) return Colors.grey;
    switch (node.kind) {
      case 'phone':
        return Colors.deepPurple;
      case 'watch':
        return Colors.teal;
      case 'ble':
        return Colors.blueGrey;
      case 'tv':
        return Colors.indigo;
      case 'speaker':
        return Colors.brown;
      default:
        return AppBlue.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: node.known ? _color : _color.withValues(alpha: 0.2),
        border: Border.all(color: _color, width: 1.4),
      ),
      child: Icon(
        _icons[node.kind] ?? Icons.bluetooth,
        size: 14,
        color: node.known ? Colors.white : _color,
      ),
    );
  }
}

/// One row in the selection card: a single live link with direction,
/// peer name, signal stats, and a recent-RSSI sparkline.
class _EdgeRow extends StatelessWidget {
  const _EdgeRow({
    required this.edge,
    required this.selId,
    required this.scene,
  });

  final BleRelation edge;
  final String selId;
  final _Scene scene;

  @override
  Widget build(BuildContext context) {
    final outgoing = edge.observer == selId;
    final peerId = outgoing ? edge.target : edge.observer;
    final peer = scene.nodes[peerId];
    final peerLabel = peer?.label ??
        (peerId.length > 18 ? '${peerId.substring(0, 18)}…' : peerId);
    final age = edge.ageSeconds;
    final freshStr = age < 5
        ? 'now'
        : age < 90
            ? '${age.round()}s ago'
            : '${(age / 60).round()}m ago';
    final spark = [...edge.rssiWindow, edge.rssiDbm];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            outgoing ? Icons.arrow_forward : Icons.arrow_back,
            size: 12,
            color: Colors.black45,
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 96,
            child: Text(
              peerLabel,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
          ),
          Text(
            '${edge.rssiDbm.round()} dBm',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            edge.modality,
            style: const TextStyle(fontSize: 10, color: Colors.black54),
          ),
          const SizedBox(width: 6),
          Text(
            '$freshStr · ×${edge.count}',
            style: const TextStyle(fontSize: 9, color: Colors.black45),
          ),
          const Spacer(),
          if (edge.moving)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(
                Icons.directions_walk,
                size: 12,
                color: Colors.orange,
              ),
            ),
          _RssiSpark(spark.map((v) => v.toDouble()).toList()),
        ],
      ),
    );
  }
}

// ── scene model ─────────────────────────────────────────────────────────────

class _Node {
  _Node({
    required this.id,
    required this.label,
    required this.kind,
    this.pos = Offset.zero,
    this.floor = '',
    this.placed = false,
  });

  final String id;
  String label; // user-overridable via the selection strip
  final String kind; // phone | watch | thoth | ble | tv | speaker | unknown
  Offset pos;
  String floor;
  bool moving = false;
  bool placed;

  /// Position solved from ≥2 RSSI anchors (multilateration) — drawn
  /// with an uncertainty ring, not as ground truth.
  bool estimated = false;

  /// Solver residual in meters — the dashed ring radius.
  double uncertaintyM = 0;
  String side = ''; // left | center | right within its space row
  /// False for unenrolled advertisers — drawn as hollow unknowns.
  bool known = true;
  String? advName;
}

class _SpaceBox {
  _SpaceBox({required this.name, required this.depth, required this.rect});
  final String name;
  final int depth; // parent-chain depth → floor above/below
  final Rect rect;
}

class _Scene {
  _Scene(this.nodes, this.edges, this.spaceBoxes);
  final Map<String, _Node> nodes;
  final List<BleRelation> edges;
  final List<_SpaceBox> spaceBoxes;

  /// Fixed px-per-meter render density. Everything — painter, labels,
  /// hit-test — lives in this space so InteractiveViewer is the only
  /// transform in play.
  static const pxPerM = 90.0;
  static const _padPx = 64.0;

  Rect? _world;

  /// World-space bounds of everything drawn (cached — nodes don't move
  /// between paints within a scene instance).
  Rect worldRect() => _world ??= _computeWorld();

  Offset toCanvas(Offset w) => Offset(
        (w.dx - worldRect().left) * pxPerM + _padPx,
        (w.dy - worldRect().top) * pxPerM + _padPx,
      );

  /// Full canvas size for the unconstrained InteractiveViewer child.
  Size canvasSize() {
    final w = worldRect();
    return Size(
      w.width * pxPerM + _padPx * 2,
      w.height * pxPerM + _padPx * 2,
    );
  }

  /// Node-count per kind for the legend chip (respects the unknowns
  /// filter so the legend matches what's drawn).
  Map<String, int> kindCounts(bool showUnknowns) {
    final m = <String, int>{};
    for (final n in nodes.values) {
      if (!showUnknowns && !n.known) continue;
      final k = n.known ? n.kind : 'unknown';
      m[k] = (m[k] ?? 0) + 1;
    }
    return m;
  }

  Rect _computeWorld() {
    var l = double.infinity, t = double.infinity;
    var r = -double.infinity, b = -double.infinity;
    void grow(Offset p) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }

    for (final n in nodes.values) {
      grow(n.pos);
      if (n.estimated) {
        grow(n.pos - Offset(n.uncertaintyM, n.uncertaintyM));
        grow(n.pos + Offset(n.uncertaintyM, n.uncertaintyM));
      }
    }
    for (final s in spaceBoxes) {
      grow(s.rect.topLeft);
      grow(s.rect.bottomRight);
    }
    if (!l.isFinite) return const Rect.fromLTWH(0, 0, 3, 2);
    return Rect.fromLTRB(l, t, r, b);
  }

  static String _kind(String? deviceType, String rawId) {
    if (rawId.startsWith('phone:')) return 'phone';
    final t = (deviceType ?? '').toLowerCase();
    if (t.contains('watch') ||
        t.contains('wearable') ||
        t.contains('pinetime')) {
      return 'watch';
    }
    if (t.contains('tv') || t.contains('television')) return 'tv';
    if (t.contains('phone')) return 'phone';
    if (t.contains('speaker') || t.contains('audio')) return 'speaker';
    if (t.contains('thoth') || t.contains('node')) return 'thoth';
    // A bare MAC / ble:<MAC> is a generic Bluetooth device - NOT a
    // watch. Only enrolled wearables (watchNames) earn that kind.
    if (rawId.startsWith('ble:') ||
        rawId.startsWith('device:ble:') ||
        RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(rawId)) {
      return 'ble';
    }
    if (rawId.startsWith('wifi:')) return 'wifi';
    if (t.isEmpty) return 'thoth';
    return t;
  }

  static _Scene build({
    required List<BleRelation> edges,
    required List<ThothDevice> devices,
    required List<SpaceInfo> spaces,
    required Map<String, String> watchNames,
    Map<String, String> labelOverrides = const {},
  }) {
    final nodes = <String, _Node>{};
    final byUuid = {for (final d in devices) d.uuid: d};

    // ── 1. Place every anchored device inside its space rect.
    // Space rects are laid out side-by-side, deepest-first is irrelevant
    // here — depth only drives the floor tag.
    final spaceBoxes = <_SpaceBox>[];
    final byId = {for (final s in spaces) s.id: s};
    int depthOf(SpaceInfo s) {
      var d = 0;
      var cur = s;
      final seen = <int>{};
      while (cur.parentId != null &&
          byId.containsKey(cur.parentId) &&
          seen.add(cur.id)) {
        d++;
        cur = byId[cur.parentId]!;
      }
      return d;
    }

    // Layout: root spaces first, then children under their parent. Each
    // box is normalized to a fixed height proportion in painter coords.
    final ordered = [...spaces]
      ..sort((a, b) => depthOf(a).compareTo(depthOf(b)));
    final plan = <int, Rect>{};
    const spaceW = 3.0, spaceH = 2.0; // normalized world units (m-ish)
    const gapX = 0.6, gapY = 0.5;
    var cursor = const Offset(0, 0);
    var rowMaxDepth = -1;
    for (final s in ordered) {
      final depth = depthOf(s);
      if (depth != rowMaxDepth) {
        if (rowMaxDepth >= 0) {
          cursor = Offset(0, cursor.dy + spaceH + gapY);
        }
        rowMaxDepth = depth;
      }
      plan[s.id] = Rect.fromLTWH(cursor.dx, cursor.dy, spaceW, spaceH);
      spaceBoxes.add(
        _SpaceBox(
          name: s.name,
          depth: depth,
          rect: plan[s.id]!,
        ),
      );
      cursor = Offset(cursor.dx + spaceW + gapX, cursor.dy);
    }

    void placeIn(
      int spaceId,
      String uuid,
      double x,
      double y,
      String name,
      String kind,
    ) {
      final r = plan[spaceId];
      if (r == null) return;
      final space = byId[spaceId];
      final w = (space?.widthM ?? 0) > 0 ? space!.widthM! : spaceW;
      final h = (space?.heightM ?? 0) > 0 ? space!.heightM! : spaceH;
      final nx = (x / w).clamp(0.05, 0.95);
      final ny = (y / h).clamp(0.05, 0.95);
      nodes[uuid] = _Node(
        id: uuid,
        label: name,
        kind: kind,
        pos: Offset(r.left + nx * r.width, r.top + ny * r.height),
        floor: _floorTag(space, byId),
        placed: true,
      );
    }

    for (final s in spaces) {
      for (final p in s.placements) {
        final uuid = '${p['device_id'] ?? ''}';
        if (uuid.isEmpty) continue;
        final x = (p['x'] as num?)?.toDouble() ?? 0;
        final y = (p['y'] as num?)?.toDouble() ?? 0;
        final d = byUuid[uuid];
        placeIn(
          s.id,
          uuid,
          x,
          y,
          '${p['device_name'] ?? d?.name ?? 'device'}',
          _kind(d?.deviceType, uuid),
        );
      }
    }

    // ── 2a. Every account device gets a node — the map is the whole
    // fleet, not only devices that happen to have placements/edges.
    for (final d in devices) {
      if (d.uuid.isEmpty || nodes.containsKey(d.uuid)) continue;
      nodes[d.uuid] = _Node(
        id: d.uuid,
        label: d.name,
        kind: _kind(d.deviceType, d.uuid),
      );
    }

    // ── 2. Nodes appearing only in BLE edges — orbit their strongest
    // anchor. Anchored devices without placement join the free pool.
    for (final e in edges) {
      for (final raw in [e.observer, e.target]) {
        final k = raw;
        if (nodes.containsKey(k)) continue;
        final d = byUuid[k];
        // ble:<MAC> keys normalize lookups back to the raw id.
        final rawId = raw.startsWith('ble:') ? raw.substring(4) : raw;
        // Enrolled wearable or an explicitly watch-typed device -
        // never "it's a MAC so it must be a watch".
        final isWatch = watchNames.containsKey(rawId) ||
            (d?.deviceType ?? '').toLowerCase().contains('watch');
        nodes[k] = _Node(
          id: k,
          label:
              d?.name ?? watchNames[rawId] ?? e.advName ?? raw.split(':').last,
          kind: isWatch ? 'watch' : _kind(d?.deviceType, k),
        );
      }
      // Discovery describes the target, never the observing account node.
      if (!e.known && !byUuid.containsKey(e.target)) {
        nodes[e.target]?.known = false;
      }
    }

    // Pass B: edgeless leftovers park in a tidy dock column right of
    // the mapped area — a holding pen, not a fake spatial claim.
    final placed = nodes.values.where((n) => n.placed).toList();
    final center = placed.isEmpty
        ? const Offset(1.5, 1.0)
        : placed.fold(Offset.zero, (s, n) => s + n.pos) /
            placed.length.toDouble();
    final dock = nodes.values.where((n) => !n.placed).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (dock.isNotEmpty) {
      var maxX = center.dx;
      for (final n in nodes.values) {
        if (n.pos.dx > maxX) maxX = n.pos.dx;
      }
      for (final s in spaceBoxes) {
        if (s.rect.right > maxX) maxX = s.rect.right;
      }
      for (var j = 0; j < dock.length; j++) {
        dock[j].pos = Offset(maxX + 1.4, j * 0.5);
      }
    }
    // Fallback for a solitary unplaced node.
    for (final n in nodes.values) {
      if (!n.placed && n.pos == Offset.zero) n.pos = center;
    }

    // User label overrides — applied last so they win over every
    // heuristic (advName, device name, id tail).
    for (final n in nodes.values) {
      final o = labelOverrides[n.id];
      if (o != null && o.isNotEmpty) n.label = o;
    }

    // Unknown-flag pass: anonymous subjects render hollow — but a
    // ble:<MAC> that matches a paired watch is enrolled, not unknown.
    for (final n in nodes.values) {
      if (n.id.startsWith('ble:')) {
        final raw = n.id.substring(4);
        n.known = watchNames.containsKey(raw);
      } else if (n.id.startsWith('device:ble:')) {
        n.known = false;
      }
    }

    // ── 3. Enrich: side ordering + moving flag.
    for (final s in spaces) {
      final inSpace = nodes.values
          .where(
            (n) =>
                n.placed &&
                s.placements.any((p) => '${p['device_id']}' == n.id),
          )
          .toList()
        ..sort((a, b) => a.pos.dx.compareTo(b.pos.dx));
      for (var k = 0; k < inSpace.length; k++) {
        inSpace[k].side = inSpace.length == 1
            ? 'center'
            : k == 0
                ? 'left'
                : k == inSpace.length - 1
                    ? 'right'
                    : 'middle';
      }
    }
    for (final e in edges) {
      for (final id in [e.observer, e.target]) {
        final n = nodes[id];
        if (n != null && e.moving) n.moving = true;
      }
    }

    return _Scene(nodes, edges, spaceBoxes);
  }

  static String _floorTag(SpaceInfo? s, Map<int, SpaceInfo> byId) =>
      s == null ? '' : '${s.name} · floor not set';
}

// ── painter ─────────────────────────────────────────────────────────────────

class _BleMapPainter extends CustomPainter {
  _BleMapPainter(
    this.scene, {
    this.selectedId,
    this.showUnknowns = true,
  });
  final _Scene scene;
  final String? selectedId;
  final bool showUnknowns;

  static const _kindIcons = {
    'phone': '📱',
    'watch': '⌚',
    'ble': '🔷',
    'tv': '📺',
    'speaker': '🔊',
    'thoth': '📡',
    'unknown': '•',
  };

  bool _drawable(_Node n) => showUnknowns || n.known;

  @override
  void paint(Canvas canvas, Size size) {
    final world = scene.worldRect();
    Offset map(Offset w) => scene.toCanvas(w);
    const scale = _Scene.pxPerM;

    // Meter grid — faint 1 m lines anchor the eye to real distances.
    final gridPaint = Paint()
      ..color = Colors.blueGrey.withValues(alpha: 0.10)
      ..strokeWidth = 0.6;
    for (var gx = world.left.floorToDouble();
        gx <= world.right + 1;
        gx += 1.0) {
      final x = map(Offset(gx, 0)).dx;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var gy = world.top.floorToDouble();
        gy <= world.bottom + 1;
        gy += 1.0) {
      final y = map(Offset(0, gy)).dy;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Space boxes.
    for (final b in scene.spaceBoxes) {
      final tl = map(b.rect.topLeft);
      final r = Rect.fromLTWH(
        tl.dx,
        tl.dy,
        b.rect.width * scale,
        b.rect.height * scale,
      );
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.blueGrey.withValues(alpha: 0.07)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        r,
        Paint()
          ..color = Colors.blueGrey.withValues(alpha: 0.4)
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        b.name,
        r.topLeft + const Offset(6, 4),
        Colors.blueGrey.shade700,
        12,
        bold: true,
      );
    }

    // Edges — selection highlights the tapped node's links.
    for (final e in scene.edges) {
      final a = scene.nodes[e.observer], b = scene.nodes[e.target];
      if (a == null || b == null || !_drawable(a) || !_drawable(b)) {
        continue;
      }
      final touched = selectedId != null &&
          (e.observer == selectedId || e.target == selectedId);
      final dimmed = selectedId != null && !touched;
      final pa = map(a.pos), pb = map(b.pos);
      final fresh = (1 - (e.ageSeconds / 90).clamp(0, 1)).toDouble();
      final strength = ((e.rssiDbm + 95) / 60).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = Color.lerp(Colors.red, Colors.blue, strength)!.withValues(
          alpha: dimmed
              ? 0.07
              : touched
                  ? 0.5 + 0.4 * fresh
                  : 0.18 + 0.5 * fresh,
        )
        ..strokeWidth = (touched ? 2.0 : 1) + 4 * strength
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(pa, pb, paint);
      // Observer → target direction tick at 60% along the edge.
      if (!dimmed && (pa - pb).distance > 60) {
        final dir = (pb - pa) / (pb - pa).distance;
        final at = pa + dir * (pb - pa).distance * 0.6;
        final n = Offset(-dir.dy, dir.dx) * 3.5;
        final arrow = Path()
          ..moveTo(at.dx, at.dy)
          ..lineTo((at - dir * 7 + n).dx, (at - dir * 7 + n).dy)
          ..moveTo(at.dx, at.dy)
          ..lineTo((at - dir * 7 - n).dx, (at - dir * 7 - n).dy);
        canvas.drawPath(arrow, paint..strokeWidth = 1.2);
      }
      final mid = Offset((pa.dx + pb.dx) / 2, (pa.dy + pb.dy) / 2);
      if (touched) {
        _textChip(
          canvas,
          '${e.rssiDbm.round()} dBm · '
          '${e.modality} · ${e.rssiDbm.round()} dBm',
          mid,
        );
      } else if (!dimmed) {
        _text(
          canvas,
          '${e.rssiDbm.round()} dBm',
          mid,
          Colors.black45,
          9,
        );
      }
    }

    // Nodes — selected gets a highlight ring.
    for (final n in scene.nodes.values) {
      if (!_drawable(n)) continue;
      final p = map(n.pos);
      final color = _nodeColor(n);
      // Multilaterated positions get a residual-sized uncertainty disc
      // + dashed ring — the estimate is a hint from RSSI, not a
      // floorplan coordinate.
      if (n.estimated) {
        final rpx = n.uncertaintyM * scale;
        canvas.drawCircle(
          p,
          rpx,
          Paint()
            ..color = color.withValues(alpha: 0.07)
            ..style = PaintingStyle.fill,
        );
        final rp = Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke;
        const segs = 24;
        for (var s = 0; s < segs; s += 2) {
          canvas.drawArc(
            Rect.fromCircle(center: p, radius: rpx),
            s * 2 * math.pi / segs,
            math.pi / segs,
            false,
            rp,
          );
        }
      }
      if (n.id == selectedId) {
        canvas.drawCircle(
          p,
          17,
          Paint()
            ..color = Colors.amber.withValues(alpha: 0.4)
            ..style = PaintingStyle.fill,
        );
      }
      // motion halo — RSSI variance flagged this link as unstable.
      if (n.moving) {
        canvas.drawCircle(
          p,
          16,
          Paint()
            ..color = Colors.orange.withValues(alpha: 0.25)
            ..style = PaintingStyle.fill,
        );
      }
      // Unknown advertisers render hollow.
      canvas.drawCircle(
        p,
        11,
        Paint()
          ..color = n.known ? color : color.withValues(alpha: 0.18)
          ..style = PaintingStyle.fill,
      );
      if (!n.known) {
        final dash = Paint()
          ..color = color
          ..strokeWidth = 1.2
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(p, 11, dash);
      }
      canvas.drawCircle(
        p,
        11,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        _kindIcons[n.kind] ?? '•',
        p - const Offset(6, 8),
        Colors.white,
        12,
      );
      _textHalo(canvas, n.label, p + const Offset(-14, 13), bold: true);
      final tag = [
        if (!n.known) 'unknown${n.advName != null ? ' · ${n.advName}' : ''}',
        if (n.estimated) '~±${n.uncertaintyM.toStringAsFixed(1)} m',
        if (n.floor.isNotEmpty) n.floor,
        if (n.side.isNotEmpty) n.side,
        if (n.moving) 'drifting',
      ].join(' · ');
      if (tag.isNotEmpty) {
        _textHalo(canvas, tag, p + const Offset(-14, 24), size: 8);
      }
    }

    _text(canvas, 'Link diagram · room offsets and floors not calibrated',
        Offset(16, size.height - 16),
        Colors.black54, 11,);
  }

  /// Edge-distance chip drawn over the line midpoint when selected.
  void _textChip(Canvas canvas, String text, Offset center) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.black87,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromCenter(
      center: center - const Offset(0, 10),
      width: tp.width + 10,
      height: tp.height + 6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(6)),
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(r, const Radius.circular(6)),
      Paint()
        ..color = Colors.blueGrey.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
    tp.paint(
      canvas,
      r.topLeft + const Offset(5, 3),
    );
  }

  /// Text with a soft white halo — stays readable over edges/grid.
  void _textHalo(
    Canvas canvas,
    String text,
    Offset at, {
    bool bold = false,
    double size = 10,
  }) {
    _text(
      canvas,
      text,
      at + const Offset(0.7, 0.7),
      Colors.white.withValues(alpha: 0.85),
      size,
      bold: bold,
    );
    _text(
      canvas,
      text,
      at,
      bold ? Colors.black87 : Colors.black54,
      size,
      bold: bold,
    );
  }

  Color _nodeColor(_Node n) {
    if (!n.known) return Colors.grey;
    switch (n.kind) {
      case 'phone':
        return Colors.deepPurple;
      case 'watch':
        return Colors.teal;
      case 'ble':
        return Colors.blueGrey;
      case 'tv':
        return Colors.indigo;
      case 'speaker':
        return Colors.brown;
      default:
        return AppBlue.value;
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset at,
    Color color,
    double size, {
    bool bold = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_BleMapPainter old) => true;
}

/// Small color constant to avoid importing the app theme here.
class AppBlue {
  static const value = Color(0xFF1E88E5);
}

// ── overlays ────────────────────────────────────────────────────────────────

/// Bottom-left legend: kind swatches with counts + link-strength key.
class _LegendCard extends StatelessWidget {
  const _LegendCard({required this.counts, this.hidden = 0});

  final Map<String, int> counts;
  final int hidden;

  static const _order = [
    'phone',
    'watch',
    'thoth',
    'ble',
    'tv',
    'speaker',
    'unknown',
  ];
  static const _icons = {
    'phone': Icons.smartphone,
    'watch': Icons.watch,
    'thoth': Icons.router,
    'ble': Icons.bluetooth,
    'tv': Icons.tv,
    'speaker': Icons.speaker,
    'unknown': Icons.help_outline,
  };
  static const _colors = {
    'phone': Colors.deepPurple,
    'watch': Colors.teal,
    'thoth': AppBlue.value,
    'ble': Colors.blueGrey,
    'tv': Colors.indigo,
    'speaker': Colors.brown,
    'unknown': Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    final keys = _order.where((k) => (counts[k] ?? 0) > 0).toList();
    if (keys.isEmpty && hidden == 0) return const SizedBox.shrink();
    return Card(
      color: Colors.white.withValues(alpha: 0.92),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final k in keys)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_icons[k], size: 13, color: _colors[k]),
                    const SizedBox(width: 6),
                    Text(
                      '$k ×${counts[k]}',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              ),
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.visibility_off,
                      size: 13,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '+$hidden ambient hidden',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 10, thickness: 0.6),
            // Link key: blue = strong (near), red = weak (far).
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 3,
                  color: Colors.blue.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                const Text('near', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 8),
                Container(
                  width: 10,
                  height: 3,
                  color: Colors.red.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                const Text('far', style: TextStyle(fontSize: 9)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-right controls: zoom in/out/reset + unknown-device filter toggle.
class _MapControls extends StatelessWidget {
  const _MapControls({
    required this.viewCtl,
    required this.showUnknowns,
    required this.onToggleUnknowns,
  }) : homeRect = null;

  final TransformationController viewCtl;
  final bool showUnknowns;
  final VoidCallback onToggleUnknowns;

  /// World rect the map is reset to (fit-to-content) on home tap.
  final Rect? homeRect;

  void _zoom(double factor) {
    final m = viewCtl.value.clone();
    final scale = m.getMaxScaleOnAxis();
    // Zoom around the viewport center.
    m.translateByDouble(-160.0, -160.0, 0.0, 1.0);
    m.scaleByDouble(factor, factor, 1.0, 1.0);
    m.translateByDouble(160.0, 160.0, 0.0, 1.0);
    if ((scale * factor).clamp(0.4, 6.0) == scale * factor) {
      viewCtl.value = m;
    }
  }

  void _reset() {
    if (homeRect == null) {
      viewCtl.value = Matrix4.identity();
      return;
    }
    viewCtl.value =
        Matrix4.identity(); // InteractiveViewer recentered on layout
  }

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, String tip, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Material(
            color: Colors.white.withValues(alpha: 0.92),
            elevation: 2,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: Tooltip(
                message: tip,
                child: SizedBox(
                  width: 34,
                  height: 34,
                  child: Icon(icon, size: 18, color: Colors.black87),
                ),
              ),
            ),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.add, 'Zoom in', () => _zoom(1.4)),
        btn(Icons.remove, 'Zoom out', () => _zoom(1 / 1.4)),
        btn(Icons.fit_screen, 'Reset view', _reset),
        btn(
          showUnknowns ? Icons.visibility : Icons.visibility_off,
          showUnknowns ? 'Hide unknown devices' : 'Show unknown devices',
          onToggleUnknowns,
        ),
      ],
    );
  }
}

/// Tiny RSSI history sparkline for the selection card edge list.
class _RssiSpark extends StatelessWidget {
  const _RssiSpark(this.samples)
      : height = 20,
        width = 72;

  final List<double> samples;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return SizedBox(width: width, height: height);
    }
    return CustomPaint(
      size: Size(width, height),
      painter: _SparkPainter(samples),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.samples);
  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) {
      if (samples.isNotEmpty) {
        canvas.drawCircle(
          Offset(size.width / 2, size.height / 2),
          1.6,
          Paint()..color = Colors.blueGrey,
        );
      }
      return;
    }
    // RSSI range fixed to a sane window so different edges are comparable.
    const lo = -95.0, hi = -35.0;
    double yOf(double v) =>
        size.height - ((v.clamp(lo, hi) - lo) / (hi - lo)) * size.height;
    final dx = size.width / (samples.length - 1);
    final path = Path();
    for (var i = 0; i < samples.length; i++) {
      final x = i * dx;
      final y = yOf(samples[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.blueGrey.shade400
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
    // Last-sample dot.
    canvas.drawCircle(
      Offset(size.width, yOf(samples.last)),
      2,
      Paint()..color = Colors.blueGrey.shade700,
    );
    // -60/-80 dBm guide lines.
    final guide = Paint()
      ..color = Colors.blueGrey.withValues(alpha: 0.18)
      ..strokeWidth = 0.6;
    canvas.drawLine(Offset(0, yOf(-60)), Offset(size.width, yOf(-60)), guide);
    canvas.drawLine(Offset(0, yOf(-80)), Offset(size.width, yOf(-80)), guide);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.samples != samples;
}
