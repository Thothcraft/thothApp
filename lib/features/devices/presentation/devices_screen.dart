import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/brain_client.dart';
import '../../../core/api/node_client.dart';
import '../../earbuds/application/earbuds_providers.dart';
import '../../observe/data/phone_relay.dart';
import '../application/devices_provider.dart';
import '../../watch/application/watch_providers.dart';
import '../../watch/presentation/pinetime_detail_screen.dart';
import '../../watch/presentation/watch_screen.dart';

/// Devices tab — real paired devices from Brain.
///
/// Long-press enters selection mode: pick any set of online devices and
/// bulk-start streaming (node captures / phone relay) or queue their
/// locally-stored capture minutes for upload to cloud storage.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  final Set<String> _selected = {};
  bool _busy = false;

  bool get _selecting => _selected.isNotEmpty;

  bool _isNode(ThothDevice d) =>
      d.deviceType == null ||
      d.deviceType == 'thoth' ||
      d.deviceType == 'unknown';

  bool _isPhone(ThothDevice d) =>
      d.deviceType == 'phone' || d.name.startsWith('phone:');

  void _toggle(ThothDevice d) {
    setState(() {
      if (!_selected.remove(d.uuid)) _selected.add(d.uuid);
    });
  }

  void _selectAllOnline(List<ThothDevice> list) {
    setState(() {
      _selected
        ..clear()
        ..addAll(list.where((d) => d.online).map((d) => d.uuid));
    });
  }

  void _exitSelection() => setState(_selected.clear);

  Future<void> _runForSelected(
    Future<String> Function(ThothDevice d) action,
  ) async {
    if (_busy) return;
    final devices = ref.read(devicesProvider).valueOrNull ?? const [];
    final targets =
        devices.where((d) => _selected.contains(d.uuid)).toList();
    setState(() => _busy = true);
    final results = <String>[];
    for (final d in targets) {
      try {
        results.add('${d.name}: ${await action(d)}');
      } catch (e) {
        results.add('${d.name}: failed — $e');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(results.join('\n')),
      duration: const Duration(seconds: 6),
    ),);
  }

  /// Start streaming: node → begin a capture (streams + stores locally);
  /// phone → start the in-app relay; watch/buds → kick the BLE link so
  /// their relays resume streaming immediately instead of waiting for
  /// the accessory's own retry loop.
  Future<void> _streamSelected() => _runForSelected((d) async {
        if (!d.online) return 'offline — skipped';
        if (_isPhone(d)) {
          await PhoneRelay.instance.start();
          return 'phone relay streaming';
        }
        if (_isNode(d)) {
          await NodeClient.instance.startCapture(d.uuid);
          return 'capture started';
        }
        if (d.deviceType == 'pinetime') return _kickWatch(d);
        if (d.deviceType == 'pinebuds') return _kickBuds(d);
        return 'streams automatically via its relay';
      });

  /// Wake the watch relay for [d] without blocking the bulk action —
  /// `connect()` can wait up to 60 s for the BLE link.
  String _kickWatch(ThothDevice d) {
    final watches = ref.read(watchListProvider).valueOrNull ?? const [];
    for (final w in watches) {
      if (w.deviceUuid != d.uuid) continue;
      final relay = ref.read(watchManagerProvider)[w.bleId];
      if (relay != null && relay.connected) {
        return 'watch relay already streaming';
      }
      unawaited(Future(() async {
        try {
          await ref.read(watchManagerProvider.notifier).connect(w);
        } catch (_) {/* link retry loop still owns the reconnect */}
      },),);
      return 'watch link connecting — streams when it lands';
    }
    return 'streams when its relay connects';
  }

  String _kickBuds(ThothDevice d) {
    final records = ref.read(earbudsListProvider).valueOrNull ?? const [];
    for (final r in records) {
      if (r.deviceUuid != d.uuid) continue;
      final relay = ref.read(earbudsManagerProvider)[r.bleId];
      if (relay != null && relay.connected) {
        return 'buds relay already streaming';
      }
      unawaited(Future(() async {
        try {
          await ref.read(earbudsManagerProvider.notifier).connect(r);
        } catch (_) {/* link retry loop still owns the reconnect */}
      },),);
      return 'buds link connecting — streams when it lands';
    }
    return 'streams when its relay connects';
  }

  /// Store to cloud: flag every locally-held capture minute for upload.
  /// Devices upload on their next heartbeat; phone/BLE data already
  /// lands on cloud as live-chunks, so those are skipped.
  Future<void> _storeSelected() => _runForSelected((d) async {
        if (!d.online) return 'offline — skipped';
        final res = await BrainClient.instance
            .getJson('/device/${d.uuid}/files');
        final files = (res['files'] as List? ?? const []);
        final pending = <String>{};
        for (final f in files) {
          if (f is Map && f['on_cloud'] != true) {
            final minute = '${f['filename'] ?? ''}';
            if (minute.isNotEmpty) pending.add(minute);
          }
        }
        if (pending.isEmpty) {
          return _isNode(d)
              ? 'no local minutes to upload'
              : 'data already lands on cloud';
        }
        var queued = 0;
        for (final minute in pending) {
          try {
            await BrainClient.instance.postJson(
              '/device/${d.uuid}/captures/$minute/request-upload',
              body: const {},
            );
            queued++;
          } catch (_) {/* per-minute failures are counted below */}
        }
        return 'queued $queued/${pending.length} minutes for upload';
      });

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(devicesProvider);

    return Scaffold(
      bottomNavigationBar: !_selecting
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Text('${_selected.length} selected'),
                    const Spacer(),
                    TextButton(
                      onPressed: _busy ? null : _exitSelection,
                      child: const Text('Cancel'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : _streamSelected,
                      icon: const Icon(Icons.sensors, size: 18),
                      label: const Text('Stream'),
                    ),
                    const SizedBox(width: 4),
                    FilledButton.icon(
                      onPressed: _busy ? null : _storeSelected,
                      icon: const Icon(Icons.cloud_upload, size: 18),
                      label: const Text('Store'),
                    ),
                  ],
                ),
              ),
            ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(devicesProvider.future),
        child: devices.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              const SizedBox(height: 120),
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 16),
              Center(child: Text('Could not load devices\n$e',
                  textAlign: TextAlign.center,),),
            ],
          ),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  const Icon(Icons.devices_other, size: 48),
                  const SizedBox(height: 16),
                  const Center(child: Text('No devices paired yet')),
                  const SizedBox(height: 16),
                  Center(
                    child: FilledButton.icon(
                      onPressed: () => context.push('/pair'),
                      icon: const Icon(Icons.add_link),
                      label: const Text('Pair a device'),
                    ),
                  ),
                ],
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: list.length + 2,
              itemBuilder: (context, i) {
                if (i == list.length) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/pair'),
                      icon: const Icon(Icons.add_link),
                      label: const Text('Pair a device'),
                    ),
                  );
                }
                if (i == list.length + 1) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: OutlinedButton.icon(
                      onPressed: () => showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => const AccessoryScanSheet(),
                      ),
                      icon: const Icon(Icons.watch),
                      label: const Text('Add accessory (watch / buds)'),
                    ),
                  );
                }
                final d = list[i];
                final isWatch = d.deviceType == 'pinetime';
                final act = d.activity;
                final mode = act?['mode']?.toString();
                final freshStreams = (act?['streams'] as List? ?? const [])
                    .where((s) => s is Map && s['fresh'] == true)
                    .length;
                final sub = StringBuffer(
                    '${d.deviceType ?? 'thoth'} • ${d.online ? 'online' : 'offline'}',);
                if (d.online && mode != null) sub.write(' • $mode');
                if (d.online && freshStreams > 0) {
                  sub.write(' · $freshStreams live');
                }
                final selected = _selected.contains(d.uuid);
                return Card(
                  child: ListTile(
                    leading: _selecting
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => _toggle(d),
                          )
                        : Icon(
                            isWatch ? Icons.watch : Icons.sensors,
                            color: d.online ? Colors.green : Colors.grey,
                          ),
                    title: Text(d.name),
                    subtitle: Text(isWatch
                        ? sub.toString()
                        : '${sub.toString()}\n${d.hostname}:5000',),
                    isThreeLine: !isWatch,
                    trailing: _selecting
                        ? null
                        : d.batteryLevel != null
                            ? Text('${d.batteryLevel}%')
                            : null,
                    onLongPress: () {
                      if (!d.online) return;
                      _toggle(d);
                    },
                    onTap: () {
                      if (_selecting) {
                        _toggle(d);
                        return;
                      }
                      if (isWatch) {
                        final bleId = bleIdForDeviceUuid(ref, d.uuid);
                        if (bleId != null) {
                          context.push('/watch/${Uri.encodeComponent(bleId)}');
                          return;
                        }
                      }
                      context.push('/devices/${d.uuid}');
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: _selecting
          ? null
          : devices.valueOrNull?.any((d) => d.online) == true
              ? FloatingActionButton.extended(
                  onPressed: () =>
                      _selectAllOnline(devices.valueOrNull ?? const []),
                  icon: const Icon(Icons.playlist_add_check),
                  label: const Text('Select online'),
                )
              : null,
    );
  }
}
