import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/brain_client.dart';
import '../../earbuds/application/earbuds_providers.dart';
import '../../earbuds/data/earbuds_relay.dart';
import '../../earbuds/data/earbuds_store.dart';
import '../application/watch_providers.dart';
import '../data/trace_service.dart';
import '../data/watch_relay.dart';
import '../data/watch_store.dart';

/// Accessories tab — paired watches AND earbuds as cards, "+" scans for
/// any supported wearable. Each card shows live BLE + relay state.
class WatchScreen extends ConsumerWidget {
  const WatchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watches = ref.watch(watchListProvider);
    final buds = ref.watch(earbudsListProvider);
    final relays = ref.watch(watchManagerProvider);
    final budsRelays = ref.watch(earbudsManagerProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(watchListProvider.notifier).refresh();
          await ref.read(earbudsListProvider.notifier).refresh();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (watches.hasError || buds.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 120),
                child: Center(
                  child: Text(
                      'Could not load accessories\n'
                      '${watches.error ?? ''}${buds.error ?? ''}',
                      textAlign: TextAlign.center,),
                ),
              )
            else if ((watches.valueOrNull ?? const []).isEmpty &&
                (buds.valueOrNull ?? const []).isEmpty)
              _EmptyAccessories(onScan: () => _openScan(context))
            else ...[
              for (final w in watches.valueOrNull ?? const <WatchRecord>[])
                _WatchCard(record: w, relay: relays[w.bleId]),
              for (final b in buds.valueOrNull ?? const <EarbudsRecord>[])
                _EarbudsCard(record: b, relay: budsRelays[b.bleId]),
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add accessory',
        onPressed: () => _openScan(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _openScan(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const AccessoryScanSheet(),
    );
  }
}

class _EmptyAccessories extends StatelessWidget {
  const _EmptyAccessories({required this.onScan});
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.watch, size: 56),
          const SizedBox(height: 16),
          const Center(
            child: Text('No accessories paired yet',
                style: TextStyle(fontSize: 16),),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Pair a PineTime or PineBuds Pro in Android Bluetooth\n'
              'settings, then add it here — the app shows its stats,\n'
              'sensors and commands, and streams its data.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Add accessory'),
          ),
        ],
      );
}

class _WatchCard extends ConsumerWidget {
  const _WatchCard({required this.record, this.relay});
  final WatchRecord record;
  final WatchRelay? relay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = relay?.connected ?? false;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: connected
                  ? Colors.green.withValues(alpha: 0.15)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(Icons.watch,
                  color: connected
                      ? Colors.green
                      : Theme.of(context).colorScheme.outline,),
            ),
            title: Text(record.name ?? 'PineTime'),
            subtitle: Text(
              '${record.deviceUuid.length > 8 ? record.deviceUuid.substring(0, 8) : record.deviceUuid}…'
              '${relay?.firmware != null ? ' • fw ${relay!.firmware}' : ''}',
            ),
            trailing: connected
                ? ListenableBuilder(
                    listenable: TraceService.instance,
                    builder: (_, __) => Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _chip(Icons.bluetooth,
                            '${TraceService.instance.lastRssi ?? '—'} dBm',),
                        const SizedBox(height: 4),
                        _chip(Icons.battery_full,
                            relay?.battery != null ? '${relay!.battery}%' : '—',),
                      ],
                    ),
                  )
                : Text(relay == null ? 'not connected' : 'connecting…',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey),),
            onTap: () =>
                context.push('/watch/${Uri.encodeComponent(record.bleId)}'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                if (!connected)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Connect'),
                    onPressed: () async {
                      try {
                        await ref
                            .read(watchManagerProvider.notifier)
                            .connect(record);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Connect failed: $e')),);
                        }
                      }
                    },
                  )
                else
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('Disconnect'),
                    onPressed: () => ref
                        .read(watchManagerProvider.notifier)
                        .disconnect(record.bleId),
                  ),
                const SizedBox(width: 12),
                if (!connected && (relay?.link?.lastError ?? relay?.lastError) != null)
                  Expanded(
                    child: Text(
                        relay!.link?.lastError ?? relay!.lastError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 11,),),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Rename',
                  onPressed: () => _renameAccessory(context, ref,
                      bleId: record.bleId,
                      deviceUuid: record.deviceUuid,
                      current: record.name,
                      kind: AccessoryKind.watch,),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Unpair',
                  onPressed: () async {
                    await ref
                        .read(watchManagerProvider.notifier)
                        .disconnect(record.bleId);
                    await ref
                        .read(watchListProvider.notifier)
                        .remove(record.bleId);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EarbudsCard extends ConsumerWidget {
  const _EarbudsCard({required this.record, this.relay});
  final EarbudsRecord record;
  final EarbudsRelay? relay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = relay?.connected ?? false;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: connected
                  ? Colors.green.withValues(alpha: 0.15)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(Icons.earbuds,
                  color: connected
                      ? Colors.green
                      : Theme.of(context).colorScheme.outline,),
            ),
            title: Text(record.name ?? 'PineBuds'),
            subtitle: Text(
              '${record.deviceUuid.length > 8 ? record.deviceUuid.substring(0, 8) : record.deviceUuid}…'
              '${relay?.firmware != null ? ' • fw ${relay!.firmware}' : ''}'
              '${relay?.session != null && relay!.session != 'idle' ? ' • ${relay!.session}' : ''}',
            ),
            trailing: connected
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _chip(Icons.earbuds,
                          relay?.battery != null ? '${relay!.battery}%' : '—',),
                      const SizedBox(height: 4),
                      _chip(Icons.earbuds_battery,
                          relay?.peerBattery != null
                              ? 'peer ${relay!.peerBattery}%'
                              : 'peer —',),
                    ],
                  )
                : Text(relay == null ? 'not connected' : 'connecting…',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.grey),),
            onTap: () =>
                context.push('/earbuds/${Uri.encodeComponent(record.bleId)}'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                if (!connected)
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Connect'),
                    onPressed: () async {
                      try {
                        await ref
                            .read(earbudsManagerProvider.notifier)
                            .connect(record);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Connect failed: $e')),);
                        }
                      }
                    },
                  )
                else
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.link_off, size: 18),
                    label: const Text('Disconnect'),
                    onPressed: () => ref
                        .read(earbudsManagerProvider.notifier)
                        .disconnect(record.bleId),
                  ),
                const SizedBox(width: 12),
                if (!connected && (relay?.link?.lastError ?? relay?.lastError) != null)
                  Expanded(
                    child: Text(
                        relay!.link?.lastError ?? relay!.lastError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 11,),),
                  ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Rename',
                  onPressed: () => _renameAccessory(context, ref,
                      bleId: record.bleId,
                      deviceUuid: record.deviceUuid,
                      current: record.name,
                      kind: AccessoryKind.earbuds,),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Unpair',
                  onPressed: () async {
                    await ref
                        .read(earbudsManagerProvider.notifier)
                        .disconnect(record.bleId);
                    await ref
                        .read(earbudsListProvider.notifier)
                        .remove(record.bleId);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Widget _chip(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.grey),
        const SizedBox(width: 3),
        Text(text,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),),
      ],
    );

/// Bottom sheet: add an accessory. Two sources:
///   • devices the phone's own Bluetooth already owns — paired in
///     Android settings or connected at the system level (PineBuds on
///     A2DP land here even with no LE link up). One tap adopts them.
///   • nearby BLE advertisers (a watch that was never paired with the
///     phone still shows up here via its InfiniTime advertisement).
/// Adopt is non-blocking in both cases: the card appears and the GATT
/// link lands in the background — the OS keeps owning the bond.
class AccessoryScanSheet extends ConsumerWidget {
  const AccessoryScanSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sys = ref.watch(systemAccessoriesProvider);
    final results = ref.watch(accessoryScanProvider);
    final adopted = {
      ...?ref.watch(watchListProvider).valueOrNull?.map((w) => w.bleId),
      ...?ref.watch(earbudsListProvider).valueOrNull?.map((b) => b.bleId),
    };
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, scroll) => ListView(
        controller: scroll,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('Add accessory',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),),
          ),
          _sectionLabel('Connected to this phone'),
          sys.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Bluetooth unavailable: $e'),
            ),
            data: (devices) {
              if (devices.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Text(
                    'Nothing paired yet — pair your PineBuds or PineTime '
                    'in Android Bluetooth settings and it appears here.',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                );
              }
              return Column(children: [
                for (final d in devices)
                  _systemTile(context, ref, d, adopted.contains(d.bleId)),
              ]);
            },
          ),
          const Divider(height: 24),
          _sectionLabel('Nearby (advertising)'),
          results.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Scan failed: $e'),
            ),
            data: (list) {
              final unseen =
                  list.where((h) => !adopted.contains(h.result.device.remoteId.str)).toList();
              if (unseen.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Text(
                    'Searching… keep the accessory awake and in range.',
                    style: TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                );
              }
              return Column(children: [
                for (final hit in unseen) _scanTile(context, ref, hit),
              ]);
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 0.6,
                color: Colors.black45,
                fontWeight: FontWeight.w600,),),
      );

  Widget _systemTile(BuildContext context, WidgetRef ref,
      SystemAccessory d, bool adopted) {
    return ListTile(
      leading: Icon(d.kind == AccessoryKind.earbuds
          ? Icons.earbuds
          : d.kind == AccessoryKind.watch
              ? Icons.watch
              : Icons.bluetooth),
      title: Text(d.displayName),
      subtitle: Text([
        d.bleId,
        if (d.systemConnected) 'connected' else 'paired',
      ].join(' • ')),
      trailing: adopted
          ? const Icon(Icons.check, color: Colors.green)
          : d.kind != null
              ? const Icon(Icons.add_link)
              : null,
      onTap: adopted
          ? null
          : d.kind != null
              ? () => _adoptSystem(context, ref, d, d.kind!)
              : () => _pickKind(context, ref, d),
    );
  }

  Widget _scanTile(BuildContext context, WidgetRef ref, AccessoryHit hit) {
    final r = hit.result;
    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName;
    return ListTile(
      leading: Icon(
          hit.kind == AccessoryKind.earbuds ? Icons.earbuds : Icons.watch),
      title: Text(name.isEmpty
          ? (hit.kind == AccessoryKind.earbuds ? 'PineBuds' : 'PineTime')
          : name),
      subtitle: Text('${r.device.remoteId.str} • ${r.rssi} dBm'),
      trailing: const Icon(Icons.add_link),
      onTap: () => _adoptScan(context, ref, hit),
    );
  }

  /// Bonded device with no wearable name match — let the user declare
  /// what it is before adopting.
  void _pickKind(
      BuildContext context, WidgetRef ref, SystemAccessory d) {
    showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Add ${d.displayName}'),
        children: [
          SimpleDialogOption(
            child: const ListTile(
                dense: true,
                leading: Icon(Icons.watch),
                title: Text('PineTime watch')),
            onPressed: () {
              Navigator.of(ctx).pop();
              _adoptSystem(context, ref, d, AccessoryKind.watch);
            },
          ),
          SimpleDialogOption(
            child: const ListTile(
                dense: true,
                leading: Icon(Icons.earbuds),
                title: Text('PineBuds earbuds')),
            onPressed: () {
              Navigator.of(ctx).pop();
              _adoptSystem(context, ref, d, AccessoryKind.earbuds);
            },
          ),
        ],
      ),
    );
  }

  void _adoptSystem(BuildContext context, WidgetRef ref, SystemAccessory d,
      AccessoryKind kind) {
    _adopt(context, ref, d.bleId, _uniqueDefault(d.bleId, d.displayName, kind),
        kind);
  }

  void _adoptScan(BuildContext context, WidgetRef ref, AccessoryHit hit) {
    final adv = hit.result.advertisementData.advName;
    final bleId = hit.result.device.remoteId.str;
    _adopt(context, ref, bleId, _uniqueDefault(bleId, adv, hit.kind), hit.kind);
  }

  /// Identifying default name: two InfiniTime watches can't share one
  /// label, so generic firmware names gain a MAC-derived suffix. A
  /// custom Bluetooth name is kept as-is (already identifying).
  static String _uniqueDefault(
      String bleId, String? name, AccessoryKind kind) {
    final base = (name ?? '').trim();
    final tail = bleId.replaceAll(RegExp('[^0-9A-Fa-f]'), '');
    final suffix = tail.length > 4
        ? tail.substring(tail.length - 4).toUpperCase()
        : tail.toUpperCase();
    final fallback = kind == AccessoryKind.earbuds ? 'PineBuds' : 'PineTime';
    if (base.isEmpty) return '$fallback-$suffix';
    final n = base.toLowerCase();
    const generic = ['infinitime', 'pinetime', 'pinebuds', 'bes_ble', 'buds'];
    if (generic.any(n.contains)) return '$base-$suffix';
    return base;
  }

  /// Name-then-adopt: the chosen name becomes the record name AND the
  /// Brain device_name at pairing, so two watches land as independent,
  /// distinguishable Brain devices. Connect + pair run in background —
  /// the card's "connecting…" state is the progress indicator.
  Future<void> _adopt(BuildContext context, WidgetRef ref, String bleId,
      String defaultName, AccessoryKind kind) async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController(text: defaultName);
        return AlertDialog(
          title: Text(
              'Add ${kind == AccessoryKind.earbuds ? 'earbuds' : 'watch'}'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
                labelText: 'Device name',
                helperText: 'Shown on the device list and Brain'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('Add')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || !context.mounted) return;
    // Messenger lookup must happen before pop — the sheet's context is
    // unsafe for inherited lookups once it deactivates.
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    if (kind == AccessoryKind.earbuds) {
      unawaited(
          ref.read(earbudsManagerProvider.notifier).adopt(bleId, name: name));
    } else {
      unawaited(
          ref.read(watchManagerProvider.notifier).adopt(bleId, name: name));
    }
    messenger.showSnackBar(
        SnackBar(content: Text('Connecting to $name…')),);
  }
}

/// Rename an adopted accessory on Brain (``PUT /device/{uuid}/identity``)
/// and in the local record — the display name stays in sync because
/// heartbeats send the record name.
Future<void> _renameAccessory(BuildContext context, WidgetRef ref,
    {required String bleId,
    required String deviceUuid,
    required String? current,
    required AccessoryKind kind,}) async {
  final ctrl = TextEditingController(
      text: (current == null || current.isEmpty)
          ? (kind == AccessoryKind.earbuds ? 'PineBuds' : 'PineTime')
          : current,);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename device'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Device name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save')),
      ],
    ),
  );
  if (name == null || name.isEmpty || !context.mounted) return;
  try {
    await BrainClient.instance.putJson('/device/$deviceUuid/identity',
        body: {'device_name': name},);
  } catch (e) {
    // Brain rename failed (offline) — the local name still updates and
    // the next heartbeat carries it up.
    debugPrint('[accessory] rename: $e');
  }
  if (kind == AccessoryKind.earbuds) {
    final records = ref.read(earbudsListProvider).valueOrNull ?? const [];
    final rec =
        records.where((r) => r.bleId == bleId).firstOrNull;
    if (rec == null) return;
    final updated = rec.copyWith(name: name);
    await EarbudsStore.instance.upsert(updated);
    ref.read(earbudsManagerProvider)[bleId]?.record = updated;
    await ref.read(earbudsListProvider.notifier).refresh();
  } else {
    final records = ref.read(watchListProvider).valueOrNull ?? const [];
    final rec = records.where((w) => w.bleId == bleId).firstOrNull;
    if (rec == null) return;
    final updated = rec.copyWith(name: name);
    await WatchStore.instance.upsert(updated);
    ref.read(watchManagerProvider)[bleId]?.record = updated;
    await ref.read(watchListProvider.notifier).refresh();
  }
}


