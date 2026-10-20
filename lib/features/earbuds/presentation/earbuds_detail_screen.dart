import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/earbuds_providers.dart';
import '../data/recording_service.dart';
import '../domain/earbuds_gatt.dart';

/// PineBuds detail — status tiles, per-bud gesture remap (opb_config
/// FFC1/FFC2), the 8-band hardware parametric EQ (opb_eq FFD0-FFD6),
/// session/event controls, and a live gesture log.
class EarbudsDetailScreen extends ConsumerStatefulWidget {
  const EarbudsDetailScreen({super.key, required this.bleId});

  final String bleId;

  @override
  ConsumerState<EarbudsDetailScreen> createState() =>
      _EarbudsDetailScreenState();
}

class _EarbudsDetailScreenState extends ConsumerState<EarbudsDetailScreen> {
  final List<_LogRow> _events = [];
  BudsInfo? _info;
  BudsStatus? _status;
  int? _eqStatus;
  static const _eventCap = 80;

  // Gesture maps — null until read from the bud.
  List<int>? _leftMap;
  List<int>? _rightMap;
  bool _gesturesLoading = false;

  // EQ — null until read.
  EqConfig? _eq;
  int? _eqPreset;
  bool? _eqEnabled;
  bool _eqLoading = false;

  Future<void> _loadGestures() async {
    final link = ref.read(earbudsManagerProvider)[widget.bleId]?.link;
    if (link == null) return;
    setState(() => _gesturesLoading = true);
    try {
      _leftMap = await link.readGestureMap(left: true);
      _rightMap = await link.readGestureMap(left: false);
    } finally {
      if (mounted) setState(() => _gesturesLoading = false);
    }
  }

  Future<void> _loadEq() async {
    final link = ref.read(earbudsManagerProvider)[widget.bleId]?.link;
    if (link == null) return;
    setState(() => _eqLoading = true);
    try {
      _eq = await link.readEqConfig();
      final p = await link.readRaw(EarbudsGatt.charEqPreset);
      if (p != null && p.length >= 4) {
        _eqPreset = ByteData.sublistView(
                Uint8List.fromList(p))
            .getUint32(0, Endian.little);
      }
      final e = await link.readRaw(EarbudsGatt.charEqEnable);
      if (e != null && e.isNotEmpty) _eqEnabled = e.first != 0;
    } finally {
      if (mounted) setState(() => _eqLoading = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final relay = ref.watch(earbudsManagerProvider)[widget.bleId];
    final conn = ref.watch(earbudsConnectionProvider(widget.bleId));

    ref.listen(earbudsTelemetryProvider(widget.bleId), (_, next) {
      final t = next.value;
      if (t == null) return;
      var dirty = false;
      if (t.info != null) {
        _info = t.info;
        dirty = true;
      }
      if (t.status != null) {
        _status = t.status;
        dirty = true;
      }
      if (t.eqStatus != null) {
        _eqStatus = t.eqStatus;
        dirty = true;
      }
      if (t.event != null) {
        _events.insert(0, _LogRow(DateTime.now(), t.event!));
        if (_events.length > _eventCap) _events.removeLast();
        dirty = true;
      }
      if (dirty && mounted) setState(() {});
    });

    final connected =
        conn.value == BluetoothConnectionState.connected ||
            (relay?.connected ?? false);
    final link = relay?.link;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(relay?.record.name ?? 'PineBuds'),
              Text(
                connected ? 'connected' : 'disconnected',
                style: TextStyle(
                    fontSize: 11,
                    color: connected ? Colors.green : Colors.grey),
              ),
            ],
          ),
          bottom: const TabBar(tabs: [
            Tab(text: 'Status'),
            Tab(text: 'Gestures'),
            Tab(text: 'EQ'),
            Tab(text: 'Events'),
          ]),
        ),
        body: TabBarView(children: [
          _statusTab(relay, link, connected),
          _gesturesTab(link, connected),
          _eqTab(link, connected),
          _eventsTab(relay, link, connected),
        ]),
      ),
    );
  }

  // ── Status ─────────────────────────────────────────────────────────────

  Widget _statusTab(relay, link, bool connected) {
    final st = _status;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (!connected && link?.lastError != null)
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('link: ${link!.lastError}',
                  style: const TextStyle(fontSize: 12)),
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tile('battery',
                st?.batteryPct != null ? '${st!.batteryPct}%' : '—'),
            _tile('peer',
                st?.peerBatteryPct != null ? '${st!.peerBatteryPct}%' : '—'),
            _tile('firmware', _info?.firmware ?? relay?.firmware ?? '—'),
            _tile('side', _info?.side ?? '—'),
            _tile('session', st?.session ?? relay?.session ?? 'idle'),
            _tile('rssi', relay?.rssi != null ? '${relay!.rssi} dBm' : '—'),
            _tile('tws', st != null ? (st.twsLinked ? 'linked' : 'off') : '—'),
            _tile('a2dp',
                st != null ? (st.a2dpStreaming ? 'on' : 'off') : '—'),
            _tile('call', st != null ? (st.scoCall ? 'sco' : 'off') : '—'),
            _tile('anc', st != null ? (st.ancOn ? 'on' : 'off') : '—'),
            _tile('charging',
                st != null ? (st.charging ? 'yes' : 'no') : '—'),
            _tile('role',
                st != null ? (st.roleMaster ? 'master' : 'slave') : '—'),
            _tile('proto',
                _info != null ? 'v${_info!.proto}' : '—'),
            _tile('tick', st != null ? '${st.tickMs} ms' : '—'),
            _tile('seq', st != null ? '${st.seq}' : '—'),
            _tile('eq', _eqStatus == null
                ? '—'
                : _eqStatus == 0
                    ? 'ok'
                    : 'err $_eqStatus'),
          ],
        ),
        if (_info != null) ...[
          const SizedBox(height: 16),
          Text('Capabilities',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _cap('gestures', _info!.gestureEvents),
              _cap('battery', _info!.battery),
              _cap('session fb', _info!.sessionFeedback),
              _cap('anc', _info!.anc),
              _cap('tws peer', _info!.twsPeerStatus),
              _cap('mic/hfp', _info!.micHfp),
            ],
          ),
        ],
      ],
    );
  }

  Widget _cap(String label, bool on) => Chip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        avatar: Icon(on ? Icons.check : Icons.close,
            size: 14, color: on ? Colors.green : Colors.grey),
        visualDensity: VisualDensity.compact,
      );

  Widget _tile(String label, String value) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 10, color: Colors.grey)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 14)),
            ],
          ),
        ),
      );

  // ── Gestures ───────────────────────────────────────────────────────────

  Widget _gesturesTab(link, bool connected) {
    if (!connected) {
      return const Center(child: Text('connect the buds to edit gestures'));
    }
    if (_gesturesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_leftMap == null && _rightMap == null) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.download),
          label: const Text('Read gesture maps'),
          onPressed: _loadGestures,
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _gestureEditor('Left bud', _leftMap, link, true),
        const SizedBox(height: 12),
        _gestureEditor('Right bud', _rightMap, link, false),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.restart_alt),
          label: const Text('Restore factory maps'),
          onPressed: () async {
            final okL = await link.writeGestureMap(
                EarbudsCodec.defaultGestureLeft, left: true);
            final okR = await link.writeGestureMap(
                EarbudsCodec.defaultGestureRight, left: false);
            _snack(okL && okR ? 'factory maps written' : 'write failed');
            await _loadGestures();
          },
        ),
      ],
    );
  }

  Widget _gestureEditor(
      String title, List<int>? map, link, bool left) {
    if (map == null) {
      return Card(
        child: ListTile(
          title: Text(title),
          subtitle: const Text('not readable on this bud'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (var i = 0; i < EarbudsCodec.gestureSlots.length; i++)
              Row(
                children: [
                  SizedBox(
                      width: 100,
                      child: Text(EarbudsCodec.gestureSlots[i],
                          style: const TextStyle(fontSize: 12))),
                  Expanded(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: EarbudsCodec.actionNames.containsKey(map[i])
                          ? map[i]
                          : 0,
                      items: [
                        for (final e in EarbudsCodec.actionNames.entries)
                          DropdownMenuItem(
                              value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() => map[i] = v);
                      },
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: () async {
                  final ok =
                      await link.writeGestureMap(map, left: left);
                  _snack(ok ? '$title saved' : 'write failed');
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── EQ ─────────────────────────────────────────────────────────────────

  Widget _eqTab(link, bool connected) {
    if (!connected) {
      return const Center(child: Text('connect the buds to edit EQ'));
    }
    if (_eqLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_eq == null) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.download),
          label: const Text('Read EQ'),
          onPressed: _loadEq,
        ),
      );
    }
    final eq = _eq!;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                dense: true,
                title: const Text('EQ enabled'),
                value: _eqEnabled ?? true,
                onChanged: (v) async {
                  setState(() => _eqEnabled = v);
                  await link.setEqEnabled(v);
                },
              ),
            ),
            DropdownButton<int?>(
              hint: const Text('preset'),
              value: _eqPreset,
              items: [
                for (final p in EarbudsCodec.eqPresets)
                  DropdownMenuItem(value: p.$1, child: Text(p.$2)),
              ],
              onChanged: (v) async {
                if (v == null) return;
                setState(() => _eqPreset = v);
                await link.setEqPreset(v);
                _snack('preset sent — tap Apply to make it live');
              },
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
                child: _numField('pre gain dB', eq.preGainDb,
                    (v) => _eq = EqConfig(
                        preGainDb: v,
                        postGainDb: eq.postGainDb,
                        bands: eq.bands))),
            const SizedBox(width: 8),
            Expanded(
                child: _numField('post gain dB', eq.postGainDb,
                    (v) => _eq = EqConfig(
                        preGainDb: eq.preGainDb,
                        postGainDb: v,
                        bands: eq.bands))),
          ],
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < eq.bands.length; i++) _bandEditor(i, eq.bands[i]),
        if (eq.bands.length < 8)
          TextButton.icon(
            icon: const Icon(Icons.add, size: 18),
            label: const Text('add band'),
            onPressed: () => setState(() {
              _eq = EqConfig(
                  preGainDb: eq.preGainDb,
                  postGainDb: eq.postGainDb,
                  bands: [
                    ...eq.bands,
                    const EqBand(
                        filterType: 1, gainDb: 0, freqHz: 1000, q: 1),
                  ]);
            }),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () async {
                await link.writeEqConfig(eq);
                final ok = await link.applyEq(2);
                _snack(ok ? 'EQ applied (temporary)' : 'apply failed');
              },
              child: const Text('Preview'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () async {
                await link.writeEqConfig(eq);
                final ok = await link.applyEq(1);
                _snack(ok ? 'EQ applied + saved' : 'apply failed');
              },
              child: const Text('Apply + save'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () async {
                final ok = await link.applyEq(3);
                _snack(ok ? 'EQ reset to flat' : 'reset failed');
                await _loadEq();
              },
              child: const Text('Flat'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bandEditor(int i, EqBand band) {
    final eq = _eq!;
    void update(EqBand b) => setState(() {
          final bands = [...eq.bands]..[i] = b;
          _eq = EqConfig(
              preGainDb: eq.preGainDb,
              postGainDb: eq.postGainDb,
              bands: bands);
        });
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            Row(
              children: [
                Text('band ${i + 1}',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: band.filterType
                        .clamp(0, EarbudsCodec.eqFilterNames.length - 1),
                    items: [
                      for (var t = 0;
                          t < EarbudsCodec.eqFilterNames.length;
                          t++)
                        DropdownMenuItem(
                            value: t,
                            child: Text(EarbudsCodec.eqFilterNames[t])),
                    ],
                    onChanged: (v) =>
                        update(band.copyWith(filterType: v)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() {
                    final bands = [...eq.bands]..removeAt(i);
                    _eq = EqConfig(
                        preGainDb: eq.preGainDb,
                        postGainDb: eq.postGainDb,
                        bands: bands);
                  }),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                    child: _numField('gain dB', band.gainDb,
                        (v) => update(band.copyWith(gainDb: v)))),
                const SizedBox(width: 8),
                Expanded(
                    child: _numField('freq Hz', band.freqHz,
                        (v) => update(band.copyWith(freqHz: v)))),
                const SizedBox(width: 8),
                Expanded(
                    child: _numField('Q', band.q,
                        (v) => update(band.copyWith(q: v)))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numField(String label, double value,
          void Function(double) onChanged) =>
      TextFormField(
        key: ValueKey('$label-$value'),
        initialValue: value.toStringAsFixed(1),
        decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder()),
        style: const TextStyle(fontSize: 12),
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
        ],
        onChanged: (s) {
          final v = double.tryParse(s);
          if (v != null) onChanged(v);
        },
      );

  // ── Events ─────────────────────────────────────────────────────────────

  Widget _eventsTab(relay, link, bool connected) {
    final st = _status;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Session', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in const [
              'idle', 'listening', 'processing', 'speaking'
            ])
              FilterChip(
                label: Text(s),
                selected: st?.session == s,
                onSelected:
                    connected ? (_) => link?.setSessionState(s) : null,
              ),
            ActionChip(
              avatar: const Icon(Icons.campaign_outlined, size: 18),
              label: const Text('all gestures'),
              onPressed:
                  connected ? () => link?.setEventMask(true) : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _recordingCard(relay),
        const SizedBox(height: 16),
        Text('Gesture log', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        if (_events.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
                child: Text('tap a bud to see gestures here',
                    style: TextStyle(color: Colors.grey))),
          )
        else
          for (final row in _events)
            ListTile(
              dense: true,
              leading: Icon(
                  row.event.thothAction
                      ? Icons.auto_awesome
                      : Icons.touch_app_outlined,
                  size: 18,
                  color: row.event.thothAction
                      ? Colors.purple
                      : Colors.grey),
              title: Text(
                  '${row.event.gesture ?? '?'} → ${row.event.action ?? '?'}',
                  style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                  '${row.event.side ?? '?'} • seq ${row.event.seq} • '
                  '${row.time.hour.toString().padLeft(2, '0')}:'
                  '${row.time.minute.toString().padLeft(2, '0')}:'
                  '${row.time.second.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 11)),
            ),
      ],
    );
  }
  /// Long-press → phone recording: thoth_voice (0x10) toggles, 0x11 ends.
  /// Mic switch pause/resumes mid-session; sync uploads on stop.
  Widget _recordingCard(relay) {
    final svc = RecordingService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final e = svc.elapsed;
        final elapsed =
            '${e.inMinutes.toString().padLeft(2, '0')}:'
            '${(e.inSeconds % 60).toString().padLeft(2, '0')}';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.fiber_manual_record,
                        size: 14,
                        color: svc.recording && !svc.paused
                            ? Colors.red
                            : Colors.grey),
                    const SizedBox(width: 6),
                    Text(
                        svc.recording
                            ? (svc.paused ? 'paused $elapsed' : 'recording $elapsed')
                            : 'phone recording',
                        style: Theme.of(context).textTheme.titleSmall),
                    const Spacer(),
                    FilledButton.tonal(
                      onPressed: () => svc.toggle(
                          deviceUuid: relay?.record.deviceUuid),
                      child: Text(svc.recording ? 'Stop' : 'Start'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilterChip(
                      avatar: const Icon(Icons.mic, size: 16),
                      label: const Text('mic'),
                      selected: svc.micEnabled,
                      onSelected: svc.setMicEnabled,
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      avatar: const Icon(Icons.cloud_upload_outlined,
                          size: 16),
                      label: const Text('sync to Brain'),
                      selected: svc.syncEnabled,
                      onSelected: svc.setSyncEnabled,
                    ),
                  ],
                ),
                if (svc.lastFile != null || svc.lastError != null ||
                    svc.uploadState != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                        [
                          if (svc.lastFile != null)
                            svc.lastFile!.split('/').last,
                          if (svc.uploadState != null)
                            'upload: ${svc.uploadState}',
                          if (svc.lastError != null) svc.lastError!,
                        ].join(' • '),
                        style: const TextStyle(
                            fontSize: 10, color: Colors.grey)),
                  ),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                      'map long_press → thoth voice in the Gestures tab '
                      'to toggle this from the bud',
                      style: TextStyle(fontSize: 10, color: Colors.grey)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LogRow {
  const _LogRow(this.time, this.event);
  final DateTime time;
  final BudsEvent event;
}
