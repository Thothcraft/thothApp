import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/brain_client.dart';
import '../../context/application/context_providers.dart';
import '../../settings/application/app_settings.dart';
import '../application/watch_providers.dart';
import '../data/firmware_feed.dart';
import '../data/legacy_dfu.dart';
import '../data/watch_store.dart';
import '../data/trace_service.dart';
import '../data/watch_relay.dart';
import '../domain/pinetime_gatt.dart';

/// PineTime detail — Gadgetbridge-style tabs over the BLE link + Brain relay:
/// live sensor tiles & IMU chart, watch controls, Brain captures, device info.
class PinetimeDetailScreen extends ConsumerStatefulWidget {
  const PinetimeDetailScreen({super.key, required this.bleId});

  final String bleId;

  @override
  ConsumerState<PinetimeDetailScreen> createState() =>
      _PinetimeDetailScreenState();
}

class _PinetimeDetailScreenState
    extends ConsumerState<PinetimeDetailScreen> {
  // Rolling window of accel samples for the chart (kept by wall time).
  final List<MotionSample> _motionWindow = [];
  static const _windowSeconds = 30;
  static const _windowCap = 2000; // hard bound — 60 s at ~30 Hz bursts
  Timer? _redraw;

  int _droppedSeq = 0;
  int? _lastSeq;
  DateTime _lastChartRepaint = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // ~10 fps repaint — BLE notify at ~10 Hz, smooth enough without
    // repainting on every packet.
    _redraw = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _redraw?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final relay = ref.watch(watchManagerProvider)[widget.bleId];
    final conn = ref.watch(watchConnectionProvider(widget.bleId));

    ref.listen(watchTelemetryProvider(widget.bleId), (_, next) {
      final t = next.value;
      final m = t?.motion;
      if (m == null) return;
      // Drop accounting on the stamped char's rolling seq (wraps at 256).
      final s = m.seq;
      if (s != null && _lastSeq != null) {
        final gap = (s - _lastSeq!) & 0xFF;
        if (gap > 1) _droppedSeq += gap - 1;
      }
      if (s != null) _lastSeq = s;

      _motionWindow.add(m);
      if (_motionWindow.length > _windowCap) {
        _motionWindow.removeRange(
            0, _motionWindow.length - _windowCap,);
      }
      // Repaint throttled to ~4 Hz — without setState the chart only
      // redrew on unrelated state changes, so a returning-from-sleep
      // phone looked like the IMU stream had stopped.
      final now = DateTime.now();
      if (mounted &&
          now.difference(_lastChartRepaint) >
              const Duration(milliseconds: 250)) {
        _lastChartRepaint = now;
        setState(() {});
      }
    });

    final connected =
        conn.value == BluetoothConnectionState.connected ||
            (relay?.connected ?? false);

    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(relay?.record.name ?? 'PineTime'),
              Text(
                connected ? 'connected' : 'disconnected',
                style: TextStyle(
                    fontSize: 11,
                    color: connected ? Colors.green : Colors.grey,),
              ),
            ],
          ),
          bottom: const TabBar(tabs: [
            Tab(text: 'Sensors'),
            Tab(text: 'Trace'),
            Tab(text: 'Controls'),
            Tab(text: 'Captures'),
            Tab(text: 'Info'),
          ],),
        ),
        body: TabBarView(children: [
          _SensorsTab(
              relay: relay,
              motion: _motionWindow,
              droppedSeq: _droppedSeq,),
          _TraceTab(relay: relay),
          _ControlsTab(bleId: widget.bleId),
          _WatchCapturesTab(bleId: widget.bleId),
          _InfoTab(relay: relay),
        ],),
      ),
    );
  }
}

// ── Sensors tab ─────────────────────────────────────────────────────────────

class _SensorsTab extends ConsumerWidget {
  const _SensorsTab(
      {required this.relay,
      required this.motion,
      required this.droppedSeq,});
  final WatchRelay? relay;
  final List<MotionSample> motion;
  final int droppedSeq;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            _tile('Heart rate',
                relay?.heartRate != null ? '${relay!.heartRate} bpm' : '—',
                Icons.favorite, Colors.red,),
            _tile('Steps',
                relay?.steps != null ? '${relay!.steps}' : '—',
                Icons.directions_walk, Colors.blue,),
            _tile('Battery',
                relay?.battery != null ? '${relay!.battery}%' : '—',
                Icons.battery_full, Colors.green,),
          ],
        ),
        const SizedBox(height: 12),
        const _ProximityCard(),
        const SizedBox(height: 12),
        const _BackgroundCard(),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Accelerometer (g)',
                        style: Theme.of(context).textTheme.titleMedium,),
                    const Spacer(),
                    // Stock firmware parks the accel while dozing — say
                    // so instead of implying a dead stream.
                    if (relay?.link?.motionStale == true)
                      _statChip(context, 'dozing'),
                    const SizedBox(width: 8),
                    _statChip(context, _rateLabel()),
                    const SizedBox(width: 8),
                    _statChip(context,
                        droppedSeq == 0 ? 'no drops' : '$droppedSeq dropped',),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 190,
                  child: CustomPaint(
                    painter: _ImuChartPainter(motion),
                    size: Size.infinite,
                  ),
                ),
                const SizedBox(height: 4),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Legend('X', Colors.red),
                    _Legend('Y', Colors.green),
                    _Legend('Z', Colors.blue),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (relay != null && relay!.recentEvents.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Watch events',
                      style: Theme.of(context).textTheme.titleMedium,),
                  for (final e in relay!.recentEvents.take(8))
                    Text('• $e',
                        style: Theme.of(context).textTheme.bodySmall,),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _rateLabel() {
    if (motion.length < 2) return '— Hz';
    final first = motion.first.at;
    final last = motion.last.at;
    final secs = last.difference(first).inMilliseconds / 1000.0;
    if (secs <= 0.05) return '— Hz';
    return '${(motion.length / secs).toStringAsFixed(1)} Hz';
  }

  Widget _statChip(BuildContext context, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),),
      );

  Widget _tile(String label, String value, IconData icon, Color color) =>
      Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              children: [
                Icon(icon, color: color),
                const SizedBox(height: 6),
                Text(value,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold,),),
                Text(label, style: const TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ),
      );
}

class _Legend extends StatelessWidget {
  const _Legend(this.label, this.color);
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Container(width: 10, height: 2, color: color),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],),
      );
}

/// 3-axis time-series chart — wall-clock x axis, ±2 g y axis.
///
/// Position on x is the sample's arrival timestamp, so the curve scrolls
/// left continuously regardless of burst pacing; the last
/// [_windowSeconds] are visible. Grid: 5 s vertical lines (HH:MM:SS
/// labels), 1 g horizontal lines (±g labels).
class _ImuChartPainter extends CustomPainter {
  _ImuChartPainter(this.samples);

  static const windowSeconds = _PinetimeDetailScreenState._windowSeconds;

  final List<MotionSample> samples;

  static const _colors = [Colors.red, Colors.green, Colors.blue];

  @override
  void paint(Canvas canvas, Size size) {
    // Layout: plot area leaves a bottom strip for timestamps and a left
    // strip for the g-axis labels.
    const leftPad = 26.0;
    const bottomPad = 16.0;
    final plot = Rect.fromLTWH(
        leftPad, 0, size.width - leftPad - 2, size.height - bottomPad,);

    final bg = Paint()
      ..color = Colors.black.withValues(alpha: 0.04)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
        RRect.fromRectAndRadius(plot, const Radius.circular(8)), bg,);

    // Window ends at now so the curve visibly flows even between packets.
    final tEnd = DateTime.now().toUtc();
    final tStart = tEnd.subtract(const Duration(seconds: windowSeconds));
    double xOf(DateTime t) =>
        plot.left +
        (t.difference(tStart).inMilliseconds /
                (windowSeconds * 1000.0))
            .clamp(0.0, 1.0) *
            plot.width;
    double yOf(double g) =>
        plot.top + plot.height / 2 - (g.clamp(-2.0, 2.0) / 2) * (plot.height / 2);

    // Horizontal g-grid + labels.
    final gridPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.08)
      ..strokeWidth = 0.5;
    final axisStyle = const TextStyle(fontSize: 9, color: Colors.black45);
    for (final g in const [-2, -1, 0, 1, 2]) {
      final y = yOf(g.toDouble());
      canvas.drawLine(
          Offset(plot.left, y), Offset(plot.right, y), gridPaint,);
      _text(canvas, '${g > 0 ? '+' : ''}$g', axisStyle,
          Offset(2, y - 5),);
    }

    // Vertical time-grid + HH:MM:SS labels every 5 s.
    final firstTick = DateTime.fromMillisecondsSinceEpoch(
        (tStart.millisecondsSinceEpoch ~/ 5000 + 1) * 5000,
        isUtc: true,);
    for (var t = firstTick;
        t.isBefore(tEnd);
        t = t.add(const Duration(seconds: 5))) {
      final x = xOf(t);
      canvas.drawLine(
          Offset(x, plot.top), Offset(x, plot.bottom), gridPaint,);
      final label = t.toLocal().toIso8601String().substring(11, 19);
      _text(canvas, label, axisStyle,
          Offset(x - 21, plot.bottom + 3),);
    }

    if (samples.isEmpty) {
      _text(canvas, 'waiting for motion data…', axisStyle,
          Offset(plot.center.dx - 60, plot.center.dy - 5),);
      return;
    }

    canvas.save();
    canvas.clipRect(plot);
    for (var axis = 0; axis < 3; axis++) {
      final paint = Paint()
        ..color = _colors[axis]
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      var started = false;
      for (final s in samples) {
        if (s.at.isBefore(tStart)) continue;
        final x = xOf(s.at);
        final v = axis == 0 ? s.x : (axis == 1 ? s.y : s.z);
        final y = yOf(v);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
    canvas.restore();
  }

  void _text(Canvas canvas, String text, TextStyle style, Offset at) {
    final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,)
      ..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _ImuChartPainter old) => true;
}

// ── Controls tab — direct GATT writes + Brain command-queue demo ────────────

class _ControlsTab extends ConsumerStatefulWidget {
  const _ControlsTab({required this.bleId});
  final String bleId;

  @override
  ConsumerState<_ControlsTab> createState() => _ControlsTabState();
}

class _ControlsTabState extends ConsumerState<_ControlsTab>
    with AutomaticKeepAliveClientMixin {
  late final TextEditingController _titleCtrl =
      TextEditingController(text: 'Thoth');
  late final TextEditingController _bodyCtrl = TextEditingController();

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final relay = ref.watch(watchManagerProvider)[widget.bleId];
    final link = relay?.link;

    Future<void> act(Future<bool>? Function() op, String what) async {
      final ok = link == null ? false : (await op()) ?? false;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(link == null
                ? 'Watch not connected'
                : ok
                    ? '$what sent'
                    : '$what failed',),),);
      }
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Notification',
                    style: Theme.of(context).textTheme.titleMedium,),
                TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(labelText: 'Title'),),
                TextField(
                    controller: _bodyCtrl,
                    decoration: const InputDecoration(labelText: 'Body'),),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.notifications),
                  label: const Text('Send to watch'),
                  onPressed: () => act(
                      () => link!.sendAlert(
                          title: _titleCtrl.text, body: _bodyCtrl.text,),
                      'Notification',),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.schedule),
                  label: const Text('Sync time'),
                  onPressed: () => act(() => link!.syncTime(), 'Time sync'),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.vibration),
                  label: const Text('Buzz'),
                  onPressed: () => act(() => link!.buzz(), 'Buzz'),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.music_note),
                  label: const Text('Music: play'),
                  onPressed: () =>
                      act(() => link!.setMusic(playing: true), 'Music'),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.pause),
                  label: const Text('Music: pause'),
                  onPressed: () =>
                      act(() => link!.setMusic(playing: false), 'Music'),
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.navigation),
                  label: const Text('Nav demo'),
                  onPressed: () => act(
                      () => link!.setNavigation(
                          flag: 'turn-right',
                          narrative: 'Turn right in',
                          distance: '50 m',
                          progress: 30,),
                      'Navigation',),
                ),
              ],
            ),
          ),
        ),
        // Demonstrate the Brain→watch command path end-to-end.
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Via Brain command queue',
                    style: Theme.of(context).textTheme.titleMedium,),
                const SizedBox(height: 4),
                const Text(
                    'Queues a DeviceCommand that this app drains on the next watch heartbeat (~30 s).',
                    style: TextStyle(fontSize: 12, color: Colors.black54),),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.cloud_upload),
                  label: const Text('Queue "buzz" command'),
                  onPressed: () async {
                    try {
                      await BrainClient.instance.queueDeviceCommand(
                          relay!.record.deviceUuid, 'watch_alert',);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Command queued — watch executes on next heartbeat',),),);
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Queue failed: $e')),);
                      }
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Proximity card — smoothed BLE RSSI → signal meter + distance band ─────

class _ProximityCard extends StatelessWidget {
  const _ProximityCard();

  @override
  Widget build(BuildContext context) {
    final svc = TraceService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final pct = svc.signalPct;
        final band = svc.proximityBand;
        final rssi = svc.lastRssi;
        final est = svc.proximityM;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.near_me, size: 18),
                  const SizedBox(width: 8),
                  Text('Phone proximity',
                      style: Theme.of(context).textTheme.titleMedium,),
                  const Spacer(),
                  Text(band ?? 'no signal',
                      style: TextStyle(
                          fontSize: 12,
                          color: pct == null
                              ? Colors.grey
                              : _rssiColor(rssi),
                          fontWeight: FontWeight.w600,),),
                ],),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: (pct ?? 0) / 100,
                    minHeight: 10,
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation(_rssiColor(rssi)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  rssi == null
                      ? 'Waiting for BLE RSSI…'
                      : '${svc.rssiSmooth?.toStringAsFixed(0) ?? rssi} dBm'
                          '${est != null ? '  •  ~${est.toStringAsFixed(1)} m (rough estimate)' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ── Background relay card — screen-off streaming switches ───────────────────

class _BackgroundCard extends ConsumerWidget {
  const _BackgroundCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    final notifier = ref.read(appSettingsProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.screen_lock_portrait, size: 18),
              const SizedBox(width: 8),
              Text('Keep streaming', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              ListenableBuilder(
                listenable: TraceService.instance,
                builder: (_, __) => Text(
                  TraceService.instance.foregroundServiceRunning
                      ? 'relay service on'
                      : 'relay service off',
                  style: TextStyle(
                      fontSize: 11,
                      color: TraceService.instance.foregroundServiceRunning
                          ? Colors.green
                          : Colors.grey,),
                ),
              ),
            ],),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Background relay'),
              subtitle: const Text(
                  'Phone stays connected while the screen is off. On stock InfiniTime the accel parks when the watch dozes — samples resume on wake; the thoth firmware streams unconditionally.',
                  style: TextStyle(fontSize: 11),),
              value: settings?.backgroundRelay ?? true,
              onChanged: (v) => notifier.setBackgroundRelay(v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('GPS trace'),
              subtitle: const Text(
                  'Log phone location + watch RSSI for the Trace map.',
                  style: TextStyle(fontSize: 11),),
              value: settings?.gpsTrace ?? true,
              onChanged: (v) => notifier.setGpsTrace(v),
            ),
            TextButton.icon(
              icon: const Icon(Icons.battery_saver, size: 18),
              label: const Text('Disable battery optimization'),
              onPressed: () => TraceService.instance
                  .requestBatteryOptimizationExemption(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Trace tab — phone GPS path colored by BLE RSSI (portal 'Live' analog) ─

/// RSSI → dot color: ≥−55 green, ≥−70 amber, weaker red.
Color _rssiColor(int? rssi) => rssi == null
    ? Colors.blueGrey
    : rssi >= -55
        ? Colors.green
        : rssi >= -70
            ? Colors.orange
            : Colors.red;

class _TraceTab extends ConsumerStatefulWidget {
  const _TraceTab({required this.relay});
  final WatchRelay? relay;

  @override
  ConsumerState<_TraceTab> createState() => _TraceTabState();
}

class _TraceTabState extends ConsumerState<_TraceTab>
    with AutomaticKeepAliveClientMixin {
  final MapController _map = MapController();
  late final List<TracePoint> _points = List.of(TraceService.instance.trace);
  StreamSubscription<TracePoint>? _sub;
  Timer? _fleetTimer;

  /// Latest known position of every device on the account —
  /// device_uuid → fix. Powers the shared fleet map.
  final Map<String, _FleetFix> _fleet = {};
  bool _follow = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _sub = TraceService.instance.points.listen((p) {
      if (!mounted) return;
      setState(() => _points.add(p));
    });
    _refreshFleet();
    _fleetTimer = Timer.periodic(
        const Duration(seconds: 15), (_) => _refreshFleet(),);
    // Raw fixes arrive every ~2 s even when the jitter filter keeps them
    // out of the path — follow tracks the live position, not just the
    // recorded points.
    TraceService.instance.addListener(_onSvc);
  }

  void _onSvc() {
    if (!mounted) return;
    final fix = TraceService.instance.lastFix;
    setState(() {}); // repaint live marker + stats
    if (_follow && fix != null) {
      _map.move(LatLng(fix.latitude, fix.longitude), _map.camera.zoom);
    }
  }

  /// Pull every account device's live-chunks and keep each one's newest
  /// GPS sample — the whole fleet coexists on this map.
  Future<void> _refreshFleet() async {
    if (!mounted || !BrainClient.instance.hasToken) return;
    try {
      final devices = await BrainClient.instance.listDevices();
      final results = await Future.wait([
        for (final d in devices)
          BrainClient.instance
              .getLiveChunks('${d['device_uuid'] ?? ''}')
              .then((r) => MapEntry(d, r))
              .catchError((_) => MapEntry(d, const <String, dynamic>{})),
      ]);
      if (!mounted) return;
      var changed = false;
      for (final e in results) {
        final d = e.key;
        final uuid = '${d['device_uuid'] ?? ''}';
        if (uuid.isEmpty) continue;
        final fix = _latestGps(e.value['chunks']);
        if (fix == null) continue;
        // Ignore positions older than an hour — they're noise, not presence.
        if (DateTime.now().toUtc().difference(fix.at).inMinutes > 60) {
          changed |= _fleet.remove(uuid) != null;
          continue;
        }
        _fleet[uuid] = fix.copyWith(
          name: '${d['device_name'] ?? 'device'}',
          type: '${d['device_type'] ?? ''}',
          online: d['online'] == true,
        );
        changed = true;
      }
      if (changed && mounted) setState(() {});
    } catch (e) {
      debugPrint('[fleet] refresh failed: $e');
    }
  }

  _FleetFix? _latestGps(Object? chunks) {
    if (chunks is! List) return null;
    _FleetFix? best;
    for (final c in chunks) {
      final samples = (c as Map?)?['samples'];
      if (samples is! List) continue;
      for (final s in samples) {
        final m = s as Map?;
        if (m?['sensor_type'] != 'gps') continue;
        final p = m?['payload'];
        if (p is! Map) continue;
        final lat = (p['lat'] as num?)?.toDouble();
        final lon = (p['lon'] as num?)?.toDouble();
        if (lat == null || lon == null) continue;
        final at = DateTime.tryParse('${m?['timestamp'] ?? ''}')?.toUtc() ??
            DateTime.now().toUtc();
        if (best == null || at.isAfter(best.at)) {
          best = _FleetFix(
              lat: lat,
              lon: lon,
              at: at,
              rssi: (p['rssi'] as num?)?.toInt(),
              name: '',
              type: '',
              online: false,);
        }
      }
    }
    return best;
  }

  @override
  void dispose() {
    _sub?.cancel();
    _fleetTimer?.cancel();
    TraceService.instance.removeListener(_onSvc);
    _map.dispose();
    super.dispose();
  }

  void _zoomToFit() {
    if (_points.length < 2) return;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(
          [for (final p in _points) LatLng(p.lat, p.lon)],),
      padding: const EdgeInsets.all(48),
    ),);
    setState(() => _follow = false);
  }

  /// Resolve a BLE-relation endpoint to a map position: the phone is
  /// the live GPS fix, a watch bleId resolves through its device_uuid
  /// to the fleet fix, and device uuids resolve via the fleet map.
  (LatLng, LatLng)? _edgeEndpoints(BleRelation e, TraceService svc,
      Map<String, String> bleToUuid,) {
    LatLng? posOf(String id) {
      if (id.startsWith('phone:')) {
        final f = svc.lastFix;
        return f == null ? null : LatLng(f.latitude, f.longitude);
      }
      final uuid = bleToUuid[id] ?? id;
      final fx = _fleet[uuid];
      return fx == null ? null : LatLng(fx.lat, fx.lon);
    }

    final a = posOf(e.observer);
    final b = posOf(e.target);
    if (a == null || b == null || a == b) return null;
    return (a, b);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final svc = TraceService.instance;
    final latest = _points.isEmpty ? null : _points.last;
    final fix = svc.lastFix;
    final rssi = svc.lastRssi;
    final dist = svc.distanceM;
    final fixAge = fix == null
        ? null
        : DateTime.now().difference(fix.timestamp).inSeconds;
    // BLE overlay data: all live relations, and the watch bleId→uuid map
    // so a wearable target can anchor to its fleet position.
    final bleEdges =
        ref.watch(bleRelationsProvider).valueOrNull ?? const <BleRelation>[];
    final bleToUuid = <String, String>{
      for (final w in ref.watch(watchListProvider).valueOrNull ?? const [])
        w.bleId: w.deviceUuid,
    };

    return Column(
      children: [
        // Stats strip.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              _traceStat(Icons.route,
                  dist >= 1000 ? '${(dist / 1000).toStringAsFixed(2)} km' : '${dist.toStringAsFixed(0)} m',),
              _traceStat(Icons.place, '${_points.length} pts'),
              _traceStat(Icons.gps_fixed,
                  fix == null ? 'no fix' : '±${fix.accuracy.toStringAsFixed(0)} m',),
              _traceStat(Icons.bluetooth,
                  rssi != null ? '$rssi dBm' : '—',),
            ],
          ),
        ),
        if (fixAge != null && fixAge > 10)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Row(children: [
              const Icon(Icons.warning_amber, size: 13, color: Colors.orange),
              const SizedBox(width: 4),
              Text('GPS stale — last fix ${fixAge}s ago',
                  style: const TextStyle(fontSize: 11, color: Colors.orange),),
            ],),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: latest == null && fix == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      svc.relayAttached
                          ? 'Waiting for a GPS fix…\nStep outside if the sky view is poor.'
                          : 'Connect the watch to start the trace.\nGPS fix + BLE RSSI are logged every fix.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: LatLng(
                      latest?.lat ?? fix!.latitude,
                      latest?.lon ?? fix!.longitude,
                    ),
                    initialZoom: 17,
                    onPositionChanged: (camera, hasGesture) {
                      if (hasGesture) _follow = false;
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.thothcraft.app',
                    ),
                    // Live GPS accuracy halo — real fix accuracy in meters.
                    if (fix != null)
                      CircleLayer(circles: [
                        CircleMarker(
                          point: LatLng(fix.latitude, fix.longitude),
                          radius: fix.accuracy.clamp(4.0, 500.0),
                          useRadiusInMeter: true,
                          color: Colors.blue.withValues(alpha: 0.12),
                          borderColor: Colors.blue.withValues(alpha: 0.35),
                          borderStrokeWidth: 1,
                        ),
                      ],),
                    PolylineLayer(polylines: [
                      Polyline(
                        points: [
                          for (final p in _points) LatLng(p.lat, p.lon),
                        ],
                        strokeWidth: 4,
                        borderStrokeWidth: 1.5,
                        borderColor: Colors.black26,
                        color: Colors.blue.withValues(alpha: 0.8),
                      ),
                    ],),
                    CircleLayer(circles: [
                      for (final p in _points)
                        CircleMarker(
                          point: LatLng(p.lat, p.lon),
                          radius: 4,
                          color: _rssiColor(p.rssi),
                          borderStrokeWidth: 0.5,
                          borderColor: Colors.white,
                        ),
                    ],),
                    // Start marker + live position dot.
                    CircleLayer(circles: [
                      if (_points.isNotEmpty)
                        CircleMarker(
                          point:
                              LatLng(_points.first.lat, _points.first.lon),
                          radius: 6,
                          color: Colors.white,
                          borderColor: Colors.green,
                          borderStrokeWidth: 3,
                        ),
                      if (fix != null)
                        CircleMarker(
                          point: LatLng(fix.latitude, fix.longitude),
                          radius: 7,
                          color: Colors.white,
                          borderColor: Colors.blue,
                          borderStrokeWidth: 3.5,
                        ),
                    ],),
                    // BLE relation overlay — every live proximity edge
                    // drawn on the absolute map. Width = RSSI strength,
                    // alpha = freshness. Signal, not distance.
                    PolylineLayer(polylines: [
                      for (final e in bleEdges)
                        if (_edgeEndpoints(e, svc, bleToUuid)
                            case (final a, final b))
                          Polyline(
                            points: [a, b],
                            strokeWidth:
                                1.5 + 3 * ((e.rssiDbm + 95) / 60).clamp(0, 1),
                            color: _rssiColor(e.rssiDbm.round()).withValues(
                                alpha: 0.25 +
                                    0.6 *
                                        (1 -
                                            (e.ageSeconds / 90)
                                                .clamp(0, 1)),),
                          ),
                    ],),
                    // Fleet — every account device with a recent GPS fix.
                    MarkerLayer(markers: [
                      for (final e in _fleet.entries)
                        Marker(
                          point: LatLng(e.value.lat, e.value.lon),
                          width: 90,
                          height: 50,
                          child: _FleetMarker(
                              fix: e.value, self: _isSelf(e.key),),
                        ),
                    ],),
                    // Endpoint labels — first and latest trace dots.
                    MarkerLayer(markers: [
                      if (_points.isNotEmpty)
                        Marker(
                          point: LatLng(
                              _points.first.lat, _points.first.lon,),
                          width: 90,
                          height: 18,
                          child: Transform.translate(
                            offset: const Offset(0, -14),
                            child: _TraceTag(
                                'start ${_hhmm(_points.first.at)}',),
                          ),
                        ),
                      if (_points.length > 1)
                        Marker(
                          point: LatLng(latest!.lat, latest.lon),
                          width: 110,
                          height: 18,
                          child: Transform.translate(
                            offset: const Offset(0, -14),
                            child: _TraceTag(
                                'now · ${_hhmm(latest.at)}'
                                '${latest.rssi != null ? ' · ${latest.rssi} dBm' : ''}'),
                          ),
                        ),
                    ],),
                  ],
                ),
        ),
        // Legend + actions.
        Material(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Expanded(
                  child: Wrap(
                    spacing: 10,
                    children: [
                      _DotLegend(Colors.green, 'close'),
                      _DotLegend(Colors.orange, 'near'),
                      _DotLegend(Colors.red, 'far'),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.my_location,
                      size: 20,
                      color: _follow ? Colors.blue : null,),
                  tooltip: 'Follow me',
                  onPressed: () {
                    setState(() => _follow = true);
                    if (fix != null) {
                      _map.move(LatLng(fix.latitude, fix.longitude), 17);
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.zoom_out_map, size: 20),
                  tooltip: 'Fit trace',
                  onPressed: _zoomToFit,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: 'Clear trace',
                  onPressed: () => setState(() {
                    svc.clearTrace();
                    _points.clear();
                  }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The watch this screen belongs to — its fleet marker is highlighted.
  bool _isSelf(String uuid) => uuid == widget.relay?.record.deviceUuid;

  Widget _traceStat(IconData icon, String text) => Expanded(
        child: Column(
          children: [
            Icon(icon, size: 14, color: Colors.grey),
            const SizedBox(height: 2),
            Text(text,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',),),
          ],
        ),
      );
}

/// One fleet device's last known position on the shared map.
class _FleetFix {
  const _FleetFix({
    required this.lat,
    required this.lon,
    required this.at,
    required this.name,
    required this.type,
    required this.online,
    this.rssi,
  });

  final double lat;
  final double lon;
  final DateTime at;
  final String name;
  final String type;
  final bool online;
  final int? rssi;

  _FleetFix copyWith({String? name, String? type, bool? online}) =>
      _FleetFix(
          lat: lat,
          lon: lon,
          at: at,
          rssi: rssi,
          name: name ?? this.name,
          type: type ?? this.type,
          online: online ?? this.online,);
}

class _FleetMarker extends StatelessWidget {
  const _FleetMarker({required this.fix, required this.self});
  final _FleetFix fix;
  final bool self;

  @override
  Widget build(BuildContext context) {
    final age = DateTime.now().toUtc().difference(fix.at);
    final fresh = age.inSeconds < 30;
    final color = !fix.online
        ? Colors.grey
        : self
            ? Colors.deepPurple
            : Colors.teal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(self ? Icons.watch : Icons.sensors,
            size: 20, color: fresh ? color : color.withValues(alpha: 0.5),),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            age.inMinutes >= 1 ? '${fix.name} · ${age.inMinutes}m' : fix.name,
            style: TextStyle(
                fontSize: 9,
                fontWeight: self ? FontWeight.w700 : FontWeight.w500,
                color: color,),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _DotLegend extends StatelessWidget {
  const _DotLegend(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );
}

/// Tiny pill label over a trace endpoint dot.
class _TraceTag extends StatelessWidget {
  const _TraceTag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.black12),
          ),
          child: Text(text,
              style:
                  const TextStyle(fontSize: 9, color: Colors.black87),
              overflow: TextOverflow.ellipsis,),
        ),
      );
}

String _hhmm(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:'
      '${l.minute.toString().padLeft(2, '0')}';
}

// ── Captures tab — v1 capture control for the watch device ──────────────────

class _WatchCapturesTab extends ConsumerStatefulWidget {
  const _WatchCapturesTab({required this.bleId});
  final String bleId;

  @override
  ConsumerState<_WatchCapturesTab> createState() =>
      _WatchCapturesTabState();
}

class _WatchCapturesTabState extends ConsumerState<_WatchCapturesTab>
    with AutomaticKeepAliveClientMixin {
  Future<List<Map<String, dynamic>>>? _future;

  @override
  bool get wantKeepAlive => true;

  String get _uuid =>
      ref.read(watchManagerProvider)[widget.bleId]?.record.deviceUuid ?? '';

  void _reload() {
    setState(() {
      _future = BrainClient.instance.getDeviceCaptures(_uuid);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final relay = ref.watch(watchManagerProvider)[widget.bleId];
    if (relay == null) {
      return const Center(child: Text('Connect the watch first.'));
    }
    final uuid = _uuid;
    // First fetch only once the relay is up — the uuid is empty until then.
    _future ??= BrainClient.instance.getDeviceCaptures(uuid);
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final captures = snap.data ?? const [];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.fiber_manual_record, size: 16),
                    label: const Text('Start capture'),
                    onPressed: () async {
                      try {
                        await BrainClient.instance.startCapture(uuid,
                            sensors: const [
                              kWatchSensorMotion,
                              kWatchSensorHr,
                              kWatchSensorSteps,
                              kWatchSensorBattery,
                            ],);
                        _reload();
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('$e')),);
                        }
                      }
                    },
                  ),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _reload,),
                ],
              ),
            ),
            Expanded(
              child: snap.connectionState == ConnectionState.waiting
                  ? const Center(child: CircularProgressIndicator())
                  : snap.hasError
                      ? Center(
                          child: Text('Failed to load\n${snap.error}',
                              textAlign: TextAlign.center,),)
                      : captures.isEmpty
                          ? const Center(
                              child:
                                  Text('No captures yet for this watch.'),)
                          : ListView.builder(
                              itemCount: captures.length,
                              itemBuilder: (context, i) {
                                final c = captures[i];
                                return ListTile(
                                  leading: const Icon(Icons.folder_zip,
                                      size: 18,),
                                  title: Text('${c['id'] ?? ''}',
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 13,),),
                                  subtitle:
                                      Text('${c['state'] ?? ''}'),
                                  trailing: c['state'] == 'active'
                                      ? IconButton(
                                          icon:
                                              const Icon(Icons.stop_circle),
                                          onPressed: () async {
                                            await BrainClient.instance
                                                .stopCapture(
                                                    '${c['id']}',);
                                            _reload();
                                          },
                                        )
                                      : null,
                                );
                              },
                            ),
            ),
          ],
        );
      },
    );
  }
}

// ── Info tab ────────────────────────────────────────────────────────────────

class _InfoTab extends StatelessWidget {
  const _InfoTab({required this.relay});
  final WatchRelay? relay;

  @override
  Widget build(BuildContext context) {
    final r = relay?.record;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Device', style: Theme.of(context).textTheme.titleMedium),
                _kv('Name', r?.name ?? 'PineTime'),
                _kv('BLE address', r?.bleId ?? '—'),
                _kv('Brain UUID', r?.deviceUuid ?? '—'),
                _kv('Firmware', relay?.firmware ?? '—'),
                _kv('Device token',
                    (r?.deviceToken?.isNotEmpty ?? false)
                        ? 'device-scoped JWT stored'
                        : 'missing — re-pair',),
                _kv('Relay error', relay?.lastError ?? 'none'),
              ],
            ),
          ),
        ),
        if (r != null) _FirmwareUpdateCard(record: r),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.black54)),
            Flexible(
              child: Text(v,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w500,
                      fontFamily: 'monospace',
                      fontSize: 12,),),
            ),
          ],
        ),
      );
}

// ── OTA firmware update (Nordic Secure DFU / mcuboot) ────────────────────────

/// Pick a ``*-dfu.zip`` (e.g. pinetime-mcuboot-app-dfu-1.16.99.zip from the
/// thoth-fork build) and stream it to the watch bootloader. The watch
/// reboots into DFU mode; the app's BLE link must be dropped first.
class _FirmwareUpdateCard extends ConsumerStatefulWidget {
  const _FirmwareUpdateCard({required this.record});
  final WatchRecord record;

  @override
  ConsumerState<_FirmwareUpdateCard> createState() =>
      _FirmwareUpdateCardState();
}

class _FirmwareUpdateCardState extends ConsumerState<_FirmwareUpdateCard> {
  int? _percent;
  String _status = '';
  bool _running = false;
  WatchFirmwareRelease? _latest;
  bool _checked = false;
  final _feed = WatchFirmwareFeed();

  /// Thoth-fork image bundled with the app — stamped motion + neighbor
  /// scan GATT. Always flashable offline; the release feed remains the
  /// way to pick up anything newer than the bundled build.
  static const _bundledAsset =
      'assets/firmware/pinetime-mcuboot-app-dfu-1.16.99.zip';
  static const _bundledVersion = '1.16.99';

  @override
  void initState() {
    super.initState();
    _checkLatest();
  }

  Future<void> _checkLatest() async {
    final rel = await _feed.latest();
    if (mounted) setState(() { _latest = rel; _checked = true; });
  }

  /// Manual path: pick a local ``*-dfu.zip``.
  Future<void> _start() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      dialogTitle: 'Select DFU package (*-dfu.zip)',
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    setState(() {
      _running = true;
      _percent = 0;
      _status = 'Reading package…';
    });
    try {
      final (bin, dat) = LegacyDfu.unpackZip(path);
      await _flash(bin, dat);
    } catch (e) {
      _fail(e);
    }
  }

  /// Automatic path: download the latest published DFU zip (verified
  /// against the release manifest sha256) and flash it.
  Future<void> _startLatest() async {
    final rel = _latest;
    if (rel == null) return;
    setState(() {
      _running = true;
      _percent = 0;
      _status = 'Downloading ${rel.tag}…';
    });
    try {
      final path = await _feed.download(rel, onProgress: (pct) {
        if (mounted) {
          setState(() => _status = 'Downloading ${rel.tag}… $pct%');
        }
      },);
      final (bin, dat) = LegacyDfu.unpackZip(path);
      await _flash(bin, dat);
    } catch (e) {
      _fail(e);
    }
  }

  /// Bundled path: unpack the asset in memory and flash — works
  /// offline and never depends on the release feed.
  Future<void> _startBundled() async {
    setState(() {
      _running = true;
      _percent = 0;
      _status = 'Unpacking bundled $_bundledVersion…';
    });
    try {
      final bytes =
          (await rootBundle.load(_bundledAsset)).buffer.asUint8List();
      final (bin, dat) = LegacyDfu.unpackBytes(bytes);
      await _flash(bin, dat);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (mounted) {
      setState(() {
        _status = 'DFU failed: $e';
        _running = false;
      });
    }
  }

  Future<void> _flash(Uint8List bin, Uint8List dat) async {
    try {
      // The InfiniTime app-side DfuService receives the image over the
      // live link (writes it to external flash, then reboots into
      // mcuboot) — no disconnect, no separate DFU advertiser needed.
      final manager = ref.read(watchManagerProvider.notifier);
      var relay = manager.relayFor(widget.record.bleId);
      if (relay?.connected != true) {
        setState(() => _status = 'Connecting…');
        relay = await manager.connect(widget.record);
      }
      final link = relay!.link!;
      final device = link.device;
      if (mounted) {
        setState(() => _status = 'Uploading ${bin.length >> 10} kB…');
      }
      final dfu = LegacyDfu(device)
        ..onProgress = (pct, stage) {
          if (mounted) {
            setState(() {
              _percent = pct;
              _status = stage;
            });
          }
        };
      // The link's 10 Hz motion poll shares this GATT connection —
      // suspend it so packet writes don't hit 'gatt busy'.
      link.suspendTelemetry();
      try {
        // One automatic retry of the whole transfer — the BLE stack
        // occasionally drops the response to the packet-receipt control
        // write mid-upload; run() re-sends abort+start so a retry is
        // safe even after a partial transfer.
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            await dfu.run(bin, dat);
            break;
          } catch (e) {
            if (attempt == 1 || !mounted) rethrow;
            if (mounted) {
              setState(() => _status = 'Retrying — $e');
            }
            await Future<void>.delayed(const Duration(seconds: 2));
            if (!device.isConnected) {
              // Watch dropped mid-upload — let the link reconnect before
              // retrying (DFU times out quickly on a dead link anyway).
              await manager.connect(widget.record);
            }
          }
        }
      } finally {
        link.resumeTelemetry();
      }
      if (mounted) {
        setState(() {
          _status = 'Done — watch rebooted into new firmware';
          _percent = 100;
          _running = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = 'DFU failed: $e';
          _running = false;
        });
      }
    }
    // WatchLink's auto-reconnect loop picks the link back up once the
    // watch reboots — nothing to restore on the app side.
  }

  @override
  Widget build(BuildContext context) {
    final installed = ref.read(watchManagerProvider.notifier)
        .relayFor(widget.record.bleId)?.firmware;
    final latestFw = _latest?.fwVersion ?? '';
    final outdated = latestFw.isNotEmpty &&
        firmwareIsNewer(installed ?? '', latestFw);
    final bundledNewer =
        firmwareIsNewer(installed ?? '', _bundledVersion);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Firmware update (OTA)',
                style: Theme.of(context).textTheme.titleMedium,),
            const SizedBox(height: 4),
            Text(
                installed == null
                    ? 'Watch reboots into its mcuboot DFU loader during the '
                        'transfer.'
                    : 'Installed: $installed'
                        '${latestFw.isEmpty ? '' : ' · Latest: $latestFw'}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),),
            if (outdated) ...[
              const SizedBox(height: 6),
              Row(children: [
                Icon(Icons.new_releases, size: 16,
                    color: Theme.of(context).colorScheme.primary,),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Update available: $latestFw',
                      style: TextStyle(fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,),),
                ),
              ],),
            ],
            const SizedBox(height: 8),
            if (_percent != null)
              LinearProgressIndicator(value: (_percent ?? 0) / 100),
            if (_status.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_status, style: const TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.system_update),
                label: Text(_running
                    ? 'Updating…'
                    : 'Flash thoth $_bundledVersion'
                        '${bundledNewer ? ' (bundled)' : ' (bundled — already installed)'}',),
                onPressed: _running ? null : _startBundled,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.cloud_download),
                label: Text(_latest == null
                    ? (_checked ? 'No release found' : 'Checking…')
                    : 'Feed ${_latest!.fwVersion.isEmpty ? _latest!.tag : _latest!.fwVersion}'),
                onPressed: _running || _latest == null ? null : _startLatest,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open),
                label: const Text('Local zip'),
                onPressed: _running ? null : _start,
              ),
            ],),
          ],
        ),
      ),
    );
  }
}

/// Convenience for a Device row tap → watch detail.
String? bleIdForDeviceUuid(WidgetRef ref, String deviceUuid) {
  final watches = ref.read(watchListProvider).value ?? const [];
  for (final w in watches) {
    if (w.deviceUuid == deviceUuid) return w.bleId;
  }
  return null;
}
