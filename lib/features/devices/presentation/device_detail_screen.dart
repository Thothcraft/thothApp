import 'package:flutter/material.dart';
import 'room_settings_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/node_client.dart';
import '../application/device_detail_provider.dart';
import '../application/devices_provider.dart';

/// Device detail — tabbed view over the node relay (status, captures,
/// automations, events). Every request flows Brain → node WS tunnel, so
/// the screen works for LAN-unreachable nodes too.
class DeviceDetailScreen extends ConsumerStatefulWidget {
  const DeviceDetailScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  ProviderSubscription<AsyncValue<List<Map<String, dynamic>>>>? _eventsSub;

  String get deviceId => widget.deviceId;

  @override
  void initState() {
    super.initState();
    _eventsSub = ref.listenManual(deviceEventFeedProvider(deviceId), (_, next) {
      for (final event in next.value ?? const <Map<String, dynamic>>[]) {
        final kind = event['kind']?.toString() ?? '';
        if (!mounted) return;
        if (kind == 'trigger_fired') {
          final data = event['data'] is Map ? event['data'] as Map : const {};
          _snack('Automation fired: ${data['automation'] ?? data['name'] ?? 'trigger'}');
        } else if (kind == 'room_changed') {
          _snack('Room layout updated');
        }
      }
    });
  }

  @override
  void dispose() {
    _eventsSub?.close();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(deviceStatusProvider(deviceId));
    final offline = status.maybeWhen(
      error: (e, _) =>
          e is NodeRelayException ? e.offline : status.hasError,
      orElse: () => false,
    );

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(status.valueOrNull?['name']?.toString() ?? 'Device'),
              Text(deviceId,
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),),
            ],
          ),
          actions: [
            IconButton(icon: const Icon(Icons.home_work_outlined), tooltip: 'House and room layout',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => RoomSettingsScreen(deviceId: deviceId),),),),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Icon(
                Icons.circle,
                size: 12,
                color: offline
                    ? Colors.grey
                    : (status.hasValue ? Colors.green : Colors.orange),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.videocam),
              tooltip: 'Live view',
              onPressed: () => context.push('/devices/$deviceId/live'),
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Overview'),
            Tab(text: 'Captures'),
            Tab(text: 'Automations'),
            Tab(text: 'Events'),
          ],),
        ),
        body: TabBarView(children: [
          _OverviewTab(deviceId: deviceId),
          _CapturesTab(deviceId: deviceId),
          _AutomationsTab(deviceId: deviceId),
          _EventsTab(deviceId: deviceId),
        ],),
      ),
    );
  }
}

class _OfflineNote extends StatelessWidget {
  const _OfflineNote(this.error);
  final Object error;

  @override
  Widget build(BuildContext context) {
    final e = error;
    final offline = e is NodeRelayException && e.offline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          offline
              ? 'Node is offline — no tunnel to Brain.'
              : 'Failed to load: $error',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _OverviewTab extends ConsumerWidget {
  const _OverviewTab({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(deviceStatusProvider(deviceId));
    final sensors = ref.watch(deviceSensorsProvider(deviceId));
    final meta = ref.watch(deviceMetadataProvider(deviceId));
    final room = ref.watch(deviceRoomProvider(deviceId));

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(deviceStatusProvider(deviceId));
        ref.invalidate(deviceSensorsProvider(deviceId));
        ref.invalidate(deviceMetadataProvider(deviceId));
        ref.invalidate(deviceRoomProvider(deviceId));
        ref.invalidate(devicesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          status.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => _OfflineNote(e),
            data: (s) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Status',
                        style: Theme.of(context).textTheme.titleMedium,),
                    const SizedBox(height: 8),
                    _kv('State', '${s['state'] ?? 'unknown'}'),
                    _kv('Uptime',
                        s['uptime_s'] != null
                            ? '${((s['uptime_s'] as num) / 60).round()} min'
                            : '—',),
                    _kv('Active models', '${s['models_active'] ?? '—'}'),
                    _kv('Paired to cloud',
                        (s['brain'] is Map && s['brain']['paired'] == true)
                            ? 'yes'
                            : 'no',),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _NetworkCard(deviceId: deviceId),
          const SizedBox(height: 12),
          _Esp32Card(deviceId: deviceId),
          const SizedBox(height: 12),
          _ActivityCard(deviceId: deviceId),
          const SizedBox(height: 12),
          sensors.when(
            loading: () => const LinearProgressIndicator(),
            error: (_, __) => const SizedBox.shrink(),
            data: (list) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sensors (${list.length})',
                        style: Theme.of(context).textTheme.titleMedium,),
                    const SizedBox(height: 8),
                    for (final s in list)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text('${s['id']}',
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 12,),),
                            ),
                            Text('${s['type'] ?? 'sensor'}',
                                style: Theme.of(context).textTheme.bodySmall,),
                            const SizedBox(width: 8),
                            Icon(Icons.circle,
                                size: 8,
                                color: s['online'] == false
                                    ? Colors.grey
                                    : Colors.green,),
                          ],
                        ),
                      ),
                    if (list.isEmpty)
                      Text('No sensors reported yet.',
                          style: Theme.of(context).textTheme.bodySmall,),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          meta.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (m) {
              final inferred = m['inferred'] is Map
                  ? Map<String, dynamic>.from(m['inferred'] as Map)
                  : const <String, dynamic>{};
              final battery = inferred['battery'] is Map
                  ? inferred['battery'] as Map
                  : null;
              final activity = inferred['activity'] is Map
                  ? inferred['activity'] as Map
                  : null;
              final roomDoc = room.valueOrNull?['room'];
              final roomName = roomDoc is Map
                  ? (roomDoc['name'] ?? roomDoc['room_id'])?.toString()
                  : null;
              if (battery == null && activity == null && roomName == null) {
                return const SizedBox.shrink();
              }
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Context',
                          style: Theme.of(context).textTheme.titleMedium,),
                      const SizedBox(height: 8),
                      if (roomName != null) _kv('Room', roomName),
                      if (battery?['percent'] != null)
                        _kv('Battery',
                            '${battery!['percent']}%${battery['charging'] == true ? ' ⚡' : ''}',),
                      if (activity?['kind'] != null)
                        _kv('Activity', '${activity!['kind']}'),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.black54)),
            Text(v, style: const TextStyle(fontWeight: FontWeight.w500)),
          ],
        ),
      );
}

/// Live "what is the node doing" card — sourced from the heartbeat's
/// ``hardware_info.activity`` snapshot carried by the device list, so it
/// works even when the node's local API is unreachable.
class _ActivityCard extends ConsumerWidget {
  const _ActivityCard({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider).valueOrNull ?? const [];
    Map<String, dynamic>? act;
    for (final d in devices) {
      if (d.uuid == deviceId) {
        act = d.activity;
        break;
      }
    }
    if (act == null) return const SizedBox.shrink();
    final streams = (act['streams'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final live = streams.where((s) => s['fresh'] == true).toList();
    final captures = act['captures'] as List? ?? const [];
    final models = act['models'] as List? ?? const [];
    final watches = act['watches'] as List? ?? const [];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Activity',
                style: Theme.of(context).textTheme.titleMedium,),
            const SizedBox(height: 8),
            _kv('Mode', '${act['mode'] ?? 'unknown'}'),
            _kv('Brain channel',
                act['brain_ws'] == true ? 'connected' : 'down',),
            if (models.isNotEmpty)
              _kv('Models', models.map((m) => '$m').join(', ')),
            if (captures.isNotEmpty)
              _kv('Capturing',
                  captures.map((c) => '${c['id']}').join(', '),),
            if (watches.isNotEmpty)
              _kv('Watches',
                  watches
                      .map((w) =>
                          '${(w['subject'] ?? '').toString().split(':').last.substring(0, 8)}${w['connected'] == true ? ' ✓' : ' ✗'}',)
                      .join(', '),),
            if (live.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Live streams',
                  style: Theme.of(context).textTheme.bodySmall,),
              for (final s in live)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      const Icon(Icons.sensors, size: 14,
                          color: Colors.green,),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('${s['id']}',
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 12,),),
                      ),
                      if ((s['subscribers'] as List? ?? const [])
                          .isNotEmpty)
                        Text(
                          (s['subscribers'] as List).join(', '),
                          style: const TextStyle(
                              fontSize: 10, color: Colors.black45,),
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
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
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w500),),
            ),
          ],
        ),
      );
}

/// Node Wi-Fi card — the Pi's own link, not the phone's. First-time
/// setup lives here: scan for networks, hand credentials, or drop the
/// link to re-engage the node's BLE/AP commissioning surface.
class _NetworkCard extends ConsumerWidget {
  const _NetworkCard({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final net = ref.watch(deviceNetProvider(deviceId));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: net.when(
          loading: () => const Center(
              child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),),),
          error: (_, __) => const SizedBox.shrink(),
          data: (m) {
            if (m.isEmpty || m['enabled'] == false) {
              return const SizedBox.shrink();
            }
            final wifi = m['wifi'] is Map
                ? Map<String, dynamic>.from(m['wifi'] as Map)
                : const <String, dynamic>{};
            final connected = wifi['connected'] == true;
            final state = '${m['state'] ?? 'unknown'}';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Network',
                    style: Theme.of(context).textTheme.titleMedium,),
                const SizedBox(height: 8),
                _kv('Wi-Fi',
                    connected
                        ? '${wifi['ssid'] ?? '?'}${wifi['ip'] != null ? ' (${wifi['ip']})' : ''}'
                        : state),
                if (m['last_error'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${m['last_error']}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.redAccent,),),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.wifi_tethering, size: 18),
                      label: Text(connected
                          ? 'Change network…'
                          : 'Join a network…'),
                      onPressed: () =>
                          _joinSheet(context, ref),
                    ),
                    if (connected)
                      TextButton.icon(
                        icon: const Icon(Icons.wifi_off, size: 18,
                            color: Colors.redAccent,),
                        label: const Text('Disconnect',
                            style: TextStyle(color: Colors.redAccent),),
                        onPressed: () => _disconnect(context, ref),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Disconnect Wi-Fi?'),
        content: const Text(
            'The node drops off the network — reach it again over its '
            'BLE commissioning surface or the thoth-setup AP it '
            'broadcasts after repeated failures.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await NodeClient.instance.netDisconnect(deviceId);
      ref.invalidate(deviceNetProvider(deviceId));
    } on NodeRelayException catch (e) {
      _snack(context, e.message);
    }
  }

  void _joinSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _WifiJoinSheet(deviceId: deviceId),
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
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontWeight: FontWeight.w500),),
            ),
          ],
        ),
      );

  void _snack(BuildContext context, String m) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }
}

/// Bottom sheet: node-side Wi-Fi scan → tap a network → enter the PSK →
/// the node joins it. Manual entry always available.
class _WifiJoinSheet extends ConsumerStatefulWidget {
  const _WifiJoinSheet({required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<_WifiJoinSheet> createState() => _WifiJoinSheetState();
}

class _WifiJoinSheetState extends ConsumerState<_WifiJoinSheet> {
  late Future<List<Map<String, dynamic>>> _scan;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _scan = NodeClient.instance.netScan(widget.deviceId);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        builder: (context, scroll) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Join network',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold,),),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => setState(() {
                      _scan =
                          NodeClient.instance.netScan(widget.deviceId);
                    }),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _scan,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                        child: CircularProgressIndicator());
                  }
                  final nets = snap.data ?? const [];
                  if (nets.isEmpty) {
                    return const Center(
                        child: Text(
                            'No networks found — the node may lack a '
                            'Wi-Fi backend, or scanning is disabled.\n'
                            'Tap a row after typing the SSID manually '
                            'isn\'t supported yet.',
                            textAlign: TextAlign.center,),);
                  }
                  return ListView.builder(
                    controller: scroll,
                    itemCount: nets.length,
                    itemBuilder: (context, i) {
                      final n = nets[i];
                      final open = '${n['security'] ?? ''}'.isEmpty;
                      return ListTile(
                        dense: true,
                        leading: Icon(open ? Icons.wifi : Icons.wifi_lock,
                            size: 20,),
                        title: Text('${n['ssid']}'),
                        subtitle: Text('${n['signal'] ?? '—'}%'),
                        onTap: _sending ? null : () => _join(n),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _join(Map<String, dynamic> net) async {
    final ssid = '${net['ssid']}';
    final open = '${net['security'] ?? ''}'.isEmpty;
    String? psk;
    if (!open) {
      psk = await showDialog<String>(
        context: context,
        builder: (dctx) {
          final ctl = TextEditingController();
          return AlertDialog(
            title: Text('Password for $ssid'),
            content: TextField(
              controller: ctl,
              obscureText: true,
              autofocus: true,
              decoration:
                  const InputDecoration(labelText: 'Wi-Fi password'),
              onSubmitted: (_) => Navigator.of(dctx).pop(ctl.text),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dctx).pop(ctl.text),
                child: const Text('Join'),
              ),
            ],
          );
        },
      );
      if (psk == null) return;
    }
    setState(() => _sending = true);
    try {
      await NodeClient.instance
          .netConnect(widget.deviceId, ssid, psk: psk ?? '');
      if (mounted) {
        Navigator.of(context).pop();
        ref.invalidate(deviceNetProvider(widget.deviceId));
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Joining network…')),);
      }
    } on NodeRelayException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

/// ESP32 (thoth_csi) boards on this node's USB — self-reported
/// identity + Wi-Fi state from the serial line, plus the credential
/// push leg of the provisioning chain (phone -> Brain -> node ->
/// serial `wifi=`). Empty-state when no board reports yet.
class _Esp32Card extends ConsumerWidget {
  const _Esp32Card({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final esp = ref.watch(deviceEsp32Provider(deviceId));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: esp.when(
          loading: () => const Center(
              child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(),),),
          error: (_, __) => const SizedBox.shrink(),
          data: (m) {
            final boards = (m['boards'] as List? ?? const [])
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            if (boards.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('ESP32 radios (${boards.length})',
                    style: Theme.of(context).textTheme.titleMedium,),
                const SizedBox(height: 8),
                for (final b in boards) ...[
                  _boardHeader(b),
                  _boardStats(b),
                  const SizedBox(height: 4),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('Rate & options\u2026'),
                      onPressed: () => _optsSheet(context, ref),
                    ),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.wifi_tethering, size: 18),
                      label: const Text('Set Wi-Fi\u2026'),
                      onPressed: () => _credSheet(context, ref),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _boardHeader(Map<String, dynamic> b) {
    final live = b['live'] is Map ? b['live'] as Map : null;
    final ip = live?['ip'] ?? b['ip'];
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(
            b['connected'] == true ? Icons.wifi : Icons.wifi_off,
            size: 18,
            color: b['connected'] == true
                ? Colors.green
                : Colors.redAccent,),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${b['name'] ?? b['mac'] ?? b['serial_port'] ?? 'esp32'}'
              '  \u00b7  ${b['role'] ?? 'recv'}',
              style: const TextStyle(fontWeight: FontWeight.w500),),),
          Text(
            b['connected'] == true
                ? '${b['ssid'] ?? ''} ($ip)'
                : (b['ssid'] != null
                    ? '${b['ssid']} — not connected'
                    : 'not connected'),
            style: TextStyle(
              fontSize: 12,
              color: b['connected'] == true
                  ? Colors.black87
                  : Colors.redAccent,),),
        ],
      ),
    );
  }

  /// Per-board counters — serial-side health fields plus the board's
  /// own dashboard values when the daemon merged them (`live`).
  Widget _boardStats(Map<String, dynamic> b) {
    final live = b['live'] is Map
        ? Map<String, dynamic>.from(b['live'] as Map)
        : null;
    final num? csi = live?['csi_frames'] is num
        ? live!['csi_frames'] as num
        : b['csi_enqueued'] is num ? b['csi_enqueued'] as num : null;
    final bits = <String>[
      if (live?['ping_hz'] != null) 'ping ${live!['ping_hz']} Hz',
      if (live?['ping_sent'] != null) 'sent ${live!['ping_sent']}',
      if (csi != null) 'csi $csi',
      if (live?['channel'] != null) 'ch ${live!['channel']}',
      if (live?['ap_rssi'] != null) 'rssi ${live!['ap_rssi']}',
      if (live?['sweep'] != null)
        'sweep ${live!['sweep'] == true ? 'on' : 'off'}',
      if (b['queue_depth'] != null) 'q ${b['queue_depth']}',
      if (b['output_dropped'] != null) 'dropped ${b['output_dropped']}',
      if (live?['free_heap'] != null)
        'heap ${((live!['free_heap'] as num) / 1024).round()}k',
      if (live?['uptime_s'] != null)
        'up ${((live!['uptime_s'] as num) / 60).round()}m',
    ];
    if (bits.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 26, top: 2),
      child: Text(
        bits.join('  ·  '),
        style: const TextStyle(fontSize: 11, color: Colors.black54),),
    );
  }

  void _credSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _Esp32CredSheet(deviceId: deviceId),
    );
  }

  void _optsSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _Esp32OptsSheet(deviceId: deviceId),
    );
  }
}

/// Bottom sheet: runtime options for the attached ESP32(s) — CSI
/// stimulus rate (`ping=<hz>`, 0–200) and channel sweep — relayed to
/// the boards' serial consoles. Live-applied, persisted in board NVS.
class _Esp32OptsSheet extends ConsumerStatefulWidget {
  const _Esp32OptsSheet({required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<_Esp32OptsSheet> createState() => _Esp32OptsSheetState();
}

class _Esp32OptsSheetState extends ConsumerState<_Esp32OptsSheet> {
  double _hz = 200;
  bool _sweep = false;
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ESP32 options',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),),
          const SizedBox(height: 4),
          const Text(
            'CSI stimulus rate — the board elicits downlink traffic '
            'from the router at this rate; each reply yields a CSI '
            'frame. Actual capture is UART-bound (~40–60 fps).',
            style: TextStyle(fontSize: 12, color: Colors.black54),),
          Row(
            children: [
              const Text('ping', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  value: _hz, min: 0, max: 200, divisions: 40,
                  label: '${_hz.round()} Hz',
                  onChanged: (v) => setState(() => _hz = v),),),
              SizedBox(
                width: 64,
                child: Text('${_hz.round()} Hz',
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontFamily: 'monospace'),),),
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Channel sweep',
                style: TextStyle(fontSize: 14),),
            subtitle: const Text('hop the sender across channels',
                style: TextStyle(fontSize: 11),),
            value: _sweep,
            onChanged: (v) => setState(() => _sweep = v),),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _sending ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sending ? null : _apply,
                child: Text(_sending ? 'Applying\u2026' : 'Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _apply() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await NodeClient.instance
          .esp32Cmd(widget.deviceId, 'ping=${_hz.round()}');
      await NodeClient.instance
          .esp32Cmd(widget.deviceId, 'sweep=${_sweep ? 1 : 0}');
      if (mounted) {
        Navigator.of(context).pop();
        Future.delayed(const Duration(seconds: 2),
            () => ref.invalidate(deviceEsp32Provider(widget.deviceId)));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('ESP32 options applied'),),);
      }
    } on NodeRelayException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

/// Bottom sheet: SSID + PSK -> POST /api/v1/esp32/net -> the node
/// writes `wifi=<ssid>,<psk>` to every attached ESP32 console; each
/// board persists, reboots and joins the AP (its serial SELF_DATA then
/// reports the new link state back up).
class _Esp32CredSheet extends ConsumerStatefulWidget {
  const _Esp32CredSheet({required this.deviceId});
  final String deviceId;

  @override
  ConsumerState<_Esp32CredSheet> createState() => _Esp32CredSheetState();
}

class _Esp32CredSheetState extends ConsumerState<_Esp32CredSheet> {
  final _ssid = TextEditingController();
  final _psk = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ssid.dispose();
    _psk.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('ESP32 Wi-Fi credentials',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),),
          const SizedBox(height: 4),
          const Text(
            'Written to the board\'s serial console — it persists, '
            'reboots, joins the AP and starts producing CSI off the '
            'router.',
            style: TextStyle(fontSize: 12, color: Colors.black54),),
          const SizedBox(height: 12),
          TextField(
            controller: _ssid,
            decoration: const InputDecoration(labelText: 'SSID'),
            textInputAction: TextInputAction.next,),
          TextField(
            controller: _psk,
            decoration: const InputDecoration(
                labelText: 'Password (empty for open)'),
            obscureText: true,
            onSubmitted: (_) => _send(),),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _sending ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _sending ? null : _send,
                child: Text(_sending ? 'Sending\u2026' : 'Send to board'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _send() async {
    final ssid = _ssid.text.trim();
    if (ssid.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await NodeClient.instance.esp32NetConnect(
          widget.deviceId, ssid, psk: _psk.text);
      if (mounted) {
        Navigator.of(context).pop();
        // The board reboots then reports ssid/ip on its next SELF_DATA —
        // refresh in a moment so the card picks it up.
        Future.delayed(const Duration(seconds: 6),
            () => ref.invalidate(deviceEsp32Provider(widget.deviceId)));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Credentials sent — board is rebooting'
                ' into the network\u2026'),),);
      }
    } on NodeRelayException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

class _CapturesTab extends ConsumerWidget {
  const _CapturesTab({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final captures = ref.watch(deviceCapturesProvider(deviceId));
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
                    await NodeClient.instance.startCapture(deviceId);
                    ref.invalidate(deviceCapturesProvider(deviceId));
                  } on NodeRelayException catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(e.message)),);
                    }
                  }
                },
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () =>
                    ref.invalidate(deviceCapturesProvider(deviceId)),
              ),
            ],
          ),
        ),
        Expanded(
          child: captures.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _OfflineNote(e),
            data: (list) {
              if (list.isEmpty) {
                return const Center(child: Text('No captures on this node.'));
              }
              return ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final cap = list[i];
                  final id = '${cap['id'] ?? cap['capture_id'] ?? ''}';
                  final active = cap['state'] == 'active' ||
                      (cap['started_at'] != null && cap['stopped_at'] == null);
                  final labels = (cap['labels'] as List? ?? const [])
                      .map((l) => l is Map ? '${l['label']}' : '$l')
                      .join(', ');
                  return ListTile(
                    leading: Icon(
                      active ? Icons.fiber_manual_record : Icons.folder,
                      color: active ? Colors.red : null,
                      size: 18,
                    ),
                    title: Text(id,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 13,),),
                    subtitle: Text([
                      if (labels.isNotEmpty) labels,
                      'sensors: ${(cap['sensors'] as List? ?? const []).length}',
                    ].join(' · '),),
                    trailing: active
                        ? IconButton(
                            icon: const Icon(Icons.stop_circle),
                            onPressed: () async {
                              try {
                                await NodeClient.instance
                                    .stopCapture(deviceId, id);
                                ref.invalidate(
                                    deviceCapturesProvider(deviceId),);
                              } on NodeRelayException catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(e.message)),);
                                }
                              }
                            },
                          )
                        : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AutomationsTab extends ConsumerWidget {
  const _AutomationsTab({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final automations = ref.watch(deviceAutomationsProvider(deviceId));
    return automations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _OfflineNote(e),
      data: (list) {
        if (list.isEmpty) {
          return const Center(
              child: Text('No automations on this node.\nCreate them in the portal dashboard.',
                  textAlign: TextAlign.center,),);
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final auto = list[i];
            final id = '${auto['id']}';
            final enabled = auto['enabled'] != false;
            return SwitchListTile(
              title: Text('${auto['name'] ?? id}'),
              subtitle: Text(
                '${auto['trigger'] ?? {}} → ${auto['action'] ?? {}}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
              value: enabled,
              onChanged: (v) async {
                try {
                  await NodeClient.instance
                      .toggleAutomation(deviceId, id, enabled: v);
                  ref.invalidate(deviceAutomationsProvider(deviceId));
                } on NodeRelayException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                }
              },
            );
          },
        );
      },
    );
  }
}

class _EventsTab extends ConsumerWidget {
  const _EventsTab({required this.deviceId});
  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // One-shot load of the recent feed; the live stream drives snackbars.
    final feed = ref.watch(deviceEventFeedProvider(deviceId));
    final seen = <String, Map<String, dynamic>>{};
    for (final batch in feed.value != null ? [feed.value!] : const []) {
      for (final e in batch) {
        seen['${e['id']}'] = e;
      }
    }
    final events = seen.values.toList()
      ..sort((a, b) =>
          (num.tryParse('${b['id']}') ?? 0)
              .compareTo(num.tryParse('${a['id']}') ?? 0),);

    if (events.isEmpty) {
      return Center(
        child: feed.isLoading
            ? const CircularProgressIndicator()
            : const Text('No events yet — triggers and room changes land here.'),
      );
    }
    return ListView.builder(
      itemCount: events.length,
      itemBuilder: (context, i) {
        final e = events[i];
        final ts = e['ts'] is num ? (e['ts'] as num).toDouble() : 0.0;
        final when = ts > 0
            ? DateTime.fromMillisecondsSinceEpoch((ts * 1000).round())
                .toLocal()
                .toString()
                .substring(11, 19)
            : '';
        return ListTile(
          dense: true,
          leading: Icon(
            e['kind'] == 'trigger_fired'
                ? Icons.bolt
                : e['kind'] == 'room_changed'
                    ? Icons.meeting_room
                    : Icons.info_outline,
            size: 18,
          ),
          title: Text('${e['kind']}', style: const TextStyle(fontSize: 13)),
          subtitle: Text(when,
              style: const TextStyle(fontSize: 11, color: Colors.black45),),
        );
      },
    );
  }
}
