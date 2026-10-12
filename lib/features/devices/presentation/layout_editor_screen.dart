import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../../core/api/node_client.dart';

/// Interactive plan-view editor for the same authoritative `room/v1`
/// document the numeric form edits. Drag devices into place inside a
/// room; tap a device/room/empty space for its property sheet; the
/// building geo-anchor (lat/lon/alt) ties the layout to real maps —
/// that's what projects the GPS trace onto the floor plan.
class LayoutEditorScreen extends StatefulWidget {
  const LayoutEditorScreen({
    super.key,
    required this.deviceId,
    required this.fleet,
  });

  /// Node whose room doc we edit.
  final String deviceId;

  /// All known fleet devices (uuid → name) for the place-device picker.
  final List<({String uuid, String name})> fleet;

  @override
  State<LayoutEditorScreen> createState() => _LayoutEditorScreenState();
}

class _LayoutEditorScreenState extends State<LayoutEditorScreen> {
  Map<String, dynamic>? _doc;
  String _roomId = '';
  String? _error;
  bool _saving = false;
  String? _dragId;
  Offset _dragPos = Offset.zero;

  /// World→canvas transform; recomputed on each build and shared with
  /// the painter + gesture handlers.
  final _Tx _tx = _Tx();

  // ── doc access ─────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _rooms {
    final d = _doc!;
    return [
      d,
      ...(d['rooms'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e)),
    ].where((r) => '${r['room_id'] ?? ''}'.isNotEmpty).toList();
  }

  Map<String, dynamic> get _room => _rooms.firstWhere(
        (r) => '${r['room_id']}' == _roomId,
        orElse: () => _rooms.first,
      );

  List<Map<String, dynamic>> get _devices =>
      (_doc!['devices'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// Devices whose `room_id` resolves to the selected room.
  List<Map<String, dynamic>> _roomDevices() {
    final doc = _doc!;
    return _devices
        .where((dev) {
          final rid = '${dev['room_id'] ?? doc['room_id'] ?? ''}';
          return rid == _roomId ||
              (dev['room_id'] == '' && _roomId == '${doc['room_id']}');
        })
        .where((dev) => dev['pos'] is List && (dev['pos'] as List).length >= 3)
        .toList();
  }

  Future<void> _load() async {
    try {
      final d =
          await NodeClient.instance.getMap(widget.deviceId, '/api/v1/room');
      if (!mounted) return;
      setState(() {
        _doc = jsonDecode(jsonEncode(d));
        _roomId = '${d['room_id'] ?? ''}';
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Cannot load layout: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── gestures ───────────────────────────────────────────────────────

  /// Nearest device marker to a canvas point (max 22 px pick radius).
  Map<String, dynamic>? _deviceAt(Offset px) {
    Map<String, dynamic>? best;
    var bestD = 22.0;
    for (final dev in _roomDevices()) {
      final p = dev['pos'] as List;
      final d =
          (_tx.p(Offset((p[0] as num).toDouble(), (p[2] as num).toDouble())) -
                  px)
              .distance;
      if (d < bestD) {
        bestD = d;
        best = dev;
      }
    }
    return best;
  }

  void _onPanStart(DragStartDetails d) {
    final hit = _deviceAt(d.localPosition);
    if (hit != null) {
      setState(() {
        _dragId = '${hit['device_id']}';
        _dragPos = d.localPosition;
      });
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final id = _dragId;
    if (id == null) return;
    setState(() {
      _dragPos = d.localPosition;
      final dev = (_doc!['devices'] as List)
          .firstWhere((x) => '${x['device_id']}' == id);
      final w = _tx.inv(d.localPosition);
      final dims = _room['dims'] as Map? ?? {};
      final hw = ((dims['w'] as num?)?.toDouble() ?? 5) / 2 - 0.05;
      final hd = ((dims['d'] as num?)?.toDouble() ?? 5) / 2 - 0.05;
      final p = dev['pos'] as List;
      p[0] = w.dx.clamp(-hw, hw);
      p[2] = w.dy.clamp(-hd, hd);
    });
  }

  void _onPanEnd(DragEndDetails _) {
    if (_dragId != null) setState(() => _dragId = null);
  }

  void _onTapUp(TapUpDetails d) {
    final hit = _deviceAt(d.localPosition);
    if (hit != null) {
      _deviceSheet(hit);
    }
  }

  // ── mutation helpers ───────────────────────────────────────────────

  void _mutateRoom(void Function(Map<String, dynamic> r) fn) {
    setState(() {
      final rooms = (_doc!['rooms'] as List? ?? []);
      if (_roomId == '${_doc!['room_id'] ?? ''}') {
        fn(_doc!);
      } else {
        fn(rooms.firstWhere((r) => '${r['room_id']}' == _roomId));
      }
    });
  }

  void _addRoom() {
    final ctl = TextEditingController();
    showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add room'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'room name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctl.text),
            child: const Text('Add'),
          ),
        ],
      ),
    ).then((name) {
      if (name is! String || name.trim().isEmpty || !mounted) return;
      setState(() {
        final rooms = (_doc!['rooms'] ??= []) as List;
        final id = 'room-${DateTime.now().millisecondsSinceEpoch % 100000}';
        rooms.add({
          'format': 'room/v1',
          'room_id': id,
          'name': name.trim(),
          'dims': {'w': 4.0, 'd': 4.0, 'h': 2.7},
          'spatial': {
            'surveyed': false,
            'floor': (_room['spatial'] as Map?)?['floor'],
            'heading_deg': (_room['spatial'] as Map?)?['heading_deg'],
            'origin_enu_m': [0, 0, 0],
          },
        });
        _roomId = id;
      });
    });
  }

  void _addDevice() {
    final known = _devices.map((d) => '${d['device_id']}').toSet();
    final free = widget.fleet
        .where((f) => !known.contains(f.uuid) && f.uuid != widget.deviceId)
        .toList();
    String pick = free.isNotEmpty ? free.first.uuid : widget.deviceId;
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
                  'Place device in room',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: pick,
                  decoration: const InputDecoration(labelText: 'Device'),
                  items: [
                    for (final f in [
                      ...free,
                      (uuid: widget.deviceId, name: 'this node'),
                    ])
                      DropdownMenuItem(
                        value: f.uuid,
                        child: Text(f.name.isEmpty ? f.uuid : f.name),
                      ),
                  ],
                  onChanged: (v) => setB(() => pick = v ?? pick),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(c);
                    setState(() {
                      final devices = (_doc!['devices'] ??= []) as List;
                      devices.removeWhere((d) => d['device_id'] == pick);
                      devices.add({
                        'device_id': pick,
                        'room_id': _roomId,
                        'pos': [0.0, 1.0, 0.0],
                        'sensors': <Map>[],
                      });
                    });
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

  // ── property sheets ────────────────────────────────────────────────

  Widget _textField(String label, String v, void Function(String) set) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          initialValue: v,
          decoration: InputDecoration(labelText: label),
          onChanged: set,
        ),
      );

  Widget _numField(String label, num? v, void Function(double?) set) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextFormField(
          initialValue: v?.toString() ?? '',
          decoration: InputDecoration(labelText: label),
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          onChanged: (t) => set(t.trim().isEmpty ? null : double.tryParse(t)),
        ),
      );

  void _deviceSheet(Map<String, dynamic> dev) {
    final id = '${dev['device_id']}';
    Map<String, dynamic> devRef() => (_doc!['devices'] as List)
        .firstWhere((x) => '${x['device_id']}' == id) as Map<String, dynamic>;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setB) => SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.of(c).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        id,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove placement',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        setState(
                          () => (_doc!['devices'] as List)
                              .removeWhere((x) => '${x['device_id']}' == id),
                        );
                        Navigator.pop(c);
                      },
                    ),
                  ],
                ),
                const Text(
                  'Drag on the plan to set X/Z. Height and rotation '
                  'below.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),
                _numField(
                  'height (m)',
                  (devRef()['pos'] as List)[1] as num?,
                  (v) => setB(() => devRef()['pos'][1] = v ?? 0),
                ),
                _numField(
                  'rotation ° (yaw)',
                  devRef()['rot_y'] as num?,
                  (v) => setB(() => devRef()['rot_y'] = v),
                ),
                Row(
                  children: [
                    const Text(
                      'Sensors (FOV)',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('add'),
                      onPressed: () => setB(
                        () => (devRef()['sensors'] ??= <Map>[]).add({
                          'type': 'radar',
                          'fov_deg': 90,
                          'range_m': 6,
                          'rot_y': 0,
                          'pos': null,
                        }),
                      ),
                    ),
                  ],
                ),
                for (final sen in (devRef()['sensors'] as List? ?? const [])
                    .whereType<Map>())
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${sen['type']} · '
                          '${sen['fov_deg']}° · ${sen['range_m']}m',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.tune, size: 18),
                        onPressed: () => _sensorSheet(devRef(), sen),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setB(
                          () => (devRef()['sensors'] as List).remove(sen),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _sensorSheet(Map<String, dynamic> dev, Map sen) {
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
                  'Sensor field of view',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                _textField(
                  'type (radar/camera/csi/…)',
                  '${sen['type'] ?? ''}',
                  (v) => setB(() => sen['type'] = v.trim()),
                ),
                _numField(
                  'FOV °',
                  sen['fov_deg'] as num?,
                  (v) => setB(() => sen['fov_deg'] = v ?? 90),
                ),
                _numField(
                  'range (m)',
                  sen['range_m'] as num?,
                  (v) => setB(() => sen['range_m'] = v ?? 6),
                ),
                _numField(
                  'yaw offset °',
                  sen['rot_y'] as num?,
                  (v) => setB(() => sen['rot_y'] = v ?? 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _roomSheet() {
    final r = _room;
    final s = r['spatial'] as Map? ?? {};
    final dims = r['dims'] as Map? ?? {};
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setB) => SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.of(c).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Room — ${r['name'] ?? _roomId}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (_roomId != '${_doc!['room_id'] ?? ''}')
                      IconButton(
                        tooltip: 'Delete room',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () {
                          setState(() {
                            (_doc!['rooms'] as List).removeWhere(
                              (x) => '${x['room_id']}' == _roomId,
                            );
                            _roomId = '${_doc!['room_id'] ?? ''}';
                          });
                          Navigator.pop(c);
                        },
                      ),
                  ],
                ),
                _textField(
                  'name',
                  '${r['name'] ?? ''}',
                  (v) => setB(() => _mutateRoom((rr) => rr['name'] = v.trim())),
                ),
                _numField(
                  'width w (m)',
                  dims['w'] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => (rr['dims'] as Map)['w'] = v ?? 4,
                    ),
                  ),
                ),
                _numField(
                  'depth d (m)',
                  dims['d'] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => (rr['dims'] as Map)['d'] = v ?? 4,
                    ),
                  ),
                ),
                _numField(
                  'height h (m)',
                  dims['h'] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => (rr['dims'] as Map)['h'] = v ?? 2.7,
                    ),
                  ),
                ),
                _numField(
                  'floor (0 = ground)',
                  s['floor'] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => (rr['spatial'] as Map)['floor'] = v?.toInt(),
                    ),
                  ),
                ),
                _numField(
                  'heading ° from north',
                  s['heading_deg'] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => (rr['spatial'] as Map)['heading_deg'] = v,
                    ),
                  ),
                ),
                _numField(
                  'origin east (m)',
                  (s['origin_enu_m'] as List?)?[0] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => ((rr['spatial'] as Map)['origin_enu_m'] ??= [
                        0,
                        0,
                        0,
                      ])[0] = v,
                    ),
                  ),
                ),
                _numField(
                  'origin north (m)',
                  (s['origin_enu_m'] as List?)?[1] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => ((rr['spatial'] as Map)['origin_enu_m'] ??= [
                        0,
                        0,
                        0,
                      ])[1] = v,
                    ),
                  ),
                ),
                _numField(
                  'origin up (m)',
                  (s['origin_enu_m'] as List?)?[2] as num?,
                  (v) => setB(
                    () => _mutateRoom(
                      (rr) => ((rr['spatial'] as Map)['origin_enu_m'] ??= [
                        0,
                        0,
                        0,
                      ])[2] = v,
                    ),
                  ),
                ),
                SwitchListTile(
                  title: const Text('Layout measured (surveyed)'),
                  subtitle: const Text(
                    'Surveyed rooms anchor the radio map',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: s['surveyed'] == true,
                  onChanged: (v) => setB(
                    () => _mutateRoom(
                      (rr) => (rr['spatial'] as Map)['surveyed'] = v,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _buildingSheet() {
    final b = (_doc!['building'] ??= {}) as Map;
    final a = (b['anchor'] ??= {}) as Map;
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setB) => SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              20,
              20,
              20 + MediaQuery.of(c).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Building / house',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 10),
                _textField(
                  'house id',
                  '${b['id'] ?? ''}',
                  (v) => setB(() => b['id'] = v.trim()),
                ),
                _textField(
                  'house name',
                  '${b['name'] ?? ''}',
                  (v) => setB(() => b['name'] = v.trim()),
                ),
                _numField(
                  'anchor latitude',
                  a['latitude'] as num?,
                  (v) => setB(() => a['latitude'] = v),
                ),
                _numField(
                  'anchor longitude',
                  a['longitude'] as num?,
                  (v) => setB(() => a['longitude'] = v),
                ),
                _numField(
                  'anchor altitude (m)',
                  a['altitude_m'] as num?,
                  (v) => setB(() => a['altitude_m'] = v),
                ),
                const Text(
                  'The geo-anchor projects the GPS trace onto this '
                  'floor plan — set it once on the house.',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── save ───────────────────────────────────────────────────────────

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final latest =
          await NodeClient.instance.getMap(widget.deviceId, '/api/v1/room');
      if (latest['updated_at'] != _doc!['updated_at']) {
        throw StateError('Layout changed elsewhere. Reload before saving.');
      }
      final saved = await NodeClient.instance
          .put(widget.deviceId, '/api/v1/room', body: _doc);
      if (!mounted) return;
      if (saved is! Map || saved['format'] != 'room/v1') {
        throw StateError('Layout was not accepted');
      }
      setState(() => _doc = Map<String, dynamic>.from(saved));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Layout saved')));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_doc == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Layout editor')),
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Text(_error!),
        ),
      );
    }
    final room = _room;
    final dims = room['dims'] as Map? ?? {};
    final w = (dims['w'] as num?)?.toDouble() ?? 4.0;
    final d = (dims['d'] as num?)?.toDouble() ?? 4.0;
    final devices = _roomDevices();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Layout editor'),
        actions: [
          IconButton(
            tooltip: 'Building / house anchor',
            icon: const Icon(Icons.apartment),
            onPressed: _buildingSheet,
          ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Room selector + actions row.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    value: _roomId,
                    isExpanded: true,
                    items: _rooms
                        .map(
                          (r) => DropdownMenuItem(
                            value: '${r['room_id']}',
                            child: Text('${r['name'] ?? r['room_id']}'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _roomId = v ?? _roomId),
                  ),
                ),
                IconButton(
                  tooltip: 'Room properties',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _roomSheet,
                ),
                IconButton(
                  tooltip: 'Add room',
                  icon: const Icon(Icons.add_home_work_outlined),
                  onPressed: _addRoom,
                ),
                IconButton(
                  tooltip: 'Place device',
                  icon: const Icon(Icons.add_location_alt_outlined),
                  onPressed: _addDevice,
                ),
              ],
            ),
          ),
          Expanded(
            child: _room['spatial']?['surveyed'] != true
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Mark this room "measured (surveyed)" in '
                        'the room sheet to edit it on the plan.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : LayoutBuilder(
                    builder: (_, cst) {
                      // Fit the room (+ 1 m margin) into the canvas.
                      const pad = 1.2;
                      final s = math.min(
                        cst.maxWidth / (w + pad * 2),
                        cst.maxHeight / (d + pad * 2),
                      );
                      _tx.s = s;
                      _tx.c = Offset(cst.maxWidth / 2, cst.maxHeight / 2);
                      return GestureDetector(
                        onPanStart: _onPanStart,
                        onPanUpdate: _onPanUpdate,
                        onPanEnd: _onPanEnd,
                        onTapUp: _onTapUp,
                        child: CustomPaint(
                          size: Size(cst.maxWidth, cst.maxHeight),
                          painter: _PlanPainter(
                            room,
                            devices,
                            _tx,
                            _dragId,
                            _dragPos,
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text(
              'Drag a device to move it · tap one for height, '
              'rotation and sensor fields of view · saves to the same '
              'layout the radio map reads.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared world→canvas transform (plan view: room x → right, z → down).
class _Tx {
  double s = 1; // metres → px
  Offset c = Offset.zero;
  Offset p(Offset w) => c + w * s;
  Offset inv(Offset px) => (px - c) / s;
}

class _PlanPainter extends CustomPainter {
  _PlanPainter(this.room, this.devices, this.tx, this.dragId, this.dragPos);
  final Map<String, dynamic> room;
  final List<Map<String, dynamic>> devices;
  final _Tx tx;
  final String? dragId;
  final Offset dragPos;

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
  void paint(Canvas canvas, Size size) {
    final dims = room['dims'] as Map? ?? {};
    final w = (dims['w'] as num?)?.toDouble() ?? 4.0;
    final d = (dims['d'] as num?)?.toDouble() ?? 4.0;
    final rect = Rect.fromLTRB(
      tx.p(Offset(-w / 2, -d / 2)).dx,
      tx.p(Offset(-w / 2, -d / 2)).dy,
      tx.p(Offset(w / 2, d / 2)).dx,
      tx.p(Offset(w / 2, d / 2)).dy,
    );

    // Metre grid.
    final grid = Paint()
      ..color = Colors.blueGrey.withValues(alpha: 0.12)
      ..strokeWidth = 0.6;
    for (var x = (-w / 2).ceilToDouble(); x <= w / 2; x += 1) {
      canvas.drawLine(tx.p(Offset(x, -d / 2)), tx.p(Offset(x, d / 2)), grid);
    }
    for (var z = (-d / 2).ceilToDouble(); z <= d / 2; z += 1) {
      canvas.drawLine(tx.p(Offset(-w / 2, z)), tx.p(Offset(w / 2, z)), grid);
    }

    // Room fill + border + origin cross + labels.
    canvas.drawRect(
      rect,
      Paint()..color = Colors.blueGrey.withValues(alpha: 0.10),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.blueGrey.shade700
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    final o = tx.p(Offset.zero);
    canvas.drawLine(
      o + const Offset(-8, 0),
      o + const Offset(8, 0),
      Paint()..color = Colors.black38,
    );
    canvas.drawLine(
      o + const Offset(0, -8),
      o + const Offset(0, 8),
      Paint()..color = Colors.black38,
    );
    _text(
      canvas,
      '${room['name'] ?? room['room_id']}  ${w.toStringAsFixed(1)}×${d.toStringAsFixed(1)} m',
      rect.topLeft + const Offset(6, -20),
      12,
      bold: true,
    );
    _text(
      canvas,
      '+x →',
      rect.bottomRight + const Offset(-34, -16),
      10,
      color: Colors.black45,
    );

    // Devices.
    for (final dev in devices) {
      final id = '${dev['device_id']}';
      final p = dev['pos'] as List;
      final c =
          tx.p(Offset((p[0] as num).toDouble(), (p[2] as num).toDouble()));
      final dragged = id == dragId;
      final pos = dragged ? dragPos : c;
      // Sensor FOV fans from the device yaw.
      final yaw = ((dev['rot_y'] as num?)?.toDouble() ?? 0) * math.pi / 180;
      for (final sen
          in (dev['sensors'] as List? ?? const []).whereType<Map>()) {
        final fov = ((sen['fov_deg'] as num?)?.toDouble() ?? 0);
        final range = (sen['range_m'] as num?)?.toDouble() ?? 0;
        if (fov <= 0 || range <= 0) continue;
        final syaw =
            yaw + ((sen['rot_y'] as num?)?.toDouble() ?? 0) * math.pi / 180;
        final half = fov * math.pi / 360;
        final fan = Path()..moveTo(pos.dx, pos.dy);
        for (var i = 0; i <= 12; i++) {
          final ang = -math.pi / 2 - half + syaw + 2 * half * i / 12;
          fan.lineTo(
            pos.dx + math.cos(ang) * range * tx.s,
            pos.dy + math.sin(ang) * range * tx.s,
          );
        }
        fan.close();
        canvas.drawPath(
          fan,
          Paint()..color = Colors.teal.withValues(alpha: 0.10),
        );
        canvas.drawPath(
          fan,
          Paint()
            ..color = Colors.teal.withValues(alpha: 0.4)
            ..strokeWidth = 1
            ..style = PaintingStyle.stroke,
        );
      }
      // Facing tick.
      canvas.drawLine(
        pos,
        pos + Offset(math.sin(yaw) * 14, -math.cos(yaw) * 14),
        Paint()
          ..color = Colors.black54
          ..strokeWidth = 1.4,
      );
      final r = dragged ? 11.0 : 9.0;
      canvas.drawCircle(
        pos,
        r,
        Paint()..color = dragged ? Colors.deepOrange : const Color(0xFF1565C0),
      );
      canvas.drawCircle(
        pos,
        r,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
      _text(
        canvas,
        id.length > 16 ? '${id.substring(0, 16)}…' : id,
        pos + const Offset(12, -8),
        11,
        bold: true,
      );
      final y = (p[1] as num?)?.toDouble() ?? 0;
      _text(
        canvas,
        '+${y.toStringAsFixed(1)}m',
        pos + const Offset(12, 6),
        9,
        color: Colors.black54,
      );
    }
  }

  @override
  bool shouldRepaint(_PlanPainter old) => true;
}
