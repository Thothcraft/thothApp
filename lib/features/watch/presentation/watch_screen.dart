import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
              'Pair a PineTime watch or PineBuds Pro.\n'
              'The app keeps them connected in the background.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.black54),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onScan,
            icon: const Icon(Icons.bluetooth_searching),
            label: const Text('Scan for accessories'),
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
                if (relay?.lastError != null)
                  Expanded(
                    child: Text(relay!.lastError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 11,),),
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
                if (relay?.lastError != null)
                  Expanded(
                    child: Text(relay!.lastError!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 11,),),
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

/// Bottom sheet: unified BLE scan — watches and buds in one list.
/// Tap adopts instantly (non-blocking): the card appears and the
/// connection lands in the background — no modal spinner that can hang.
class AccessoryScanSheet extends ConsumerWidget {
  const AccessoryScanSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(accessoryScanProvider);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, scroll) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nearby accessories',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),),
          ),
          Expanded(
            child: results.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Scan failed: $e')),
              data: (list) {
                if (list.isEmpty) {
                  return const Center(
                      child: Text(
                          'Searching…\nKeep the accessory awake and in range.',
                          textAlign: TextAlign.center,),);
                }
                return ListView.builder(
                  controller: scroll,
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final hit = list[i];
                    final r = hit.result;
                    final name = r.advertisementData.advName.isNotEmpty
                        ? r.advertisementData.advName
                        : r.device.platformName;
                    return ListTile(
                      leading: Icon(hit.kind == AccessoryKind.earbuds
                          ? Icons.earbuds
                          : Icons.watch),
                      title: Text(name.isEmpty
                          ? (hit.kind == AccessoryKind.earbuds
                              ? 'PineBuds'
                              : 'PineTime')
                          : name),
                      subtitle: Text(
                          '${r.device.remoteId.str} • ${r.rssi} dBm',),
                      trailing: const Icon(Icons.add_link),
                      onTap: () => _adopt(context, ref, hit),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// One-tap adopt: close the sheet, persist the record, and let the
  /// manager connect + pair in the background. No blocking dialog — the
  /// card's "connecting…" state is the progress indicator, and the
  /// link's retry loop keeps working if the device is slow to answer.
  void _adopt(BuildContext context, WidgetRef ref, AccessoryHit hit) {
    final bleId = hit.result.device.remoteId.str;
    final name = hit.result.advertisementData.advName.isNotEmpty
        ? hit.result.advertisementData.advName
        : (hit.kind == AccessoryKind.earbuds ? 'PineBuds' : 'PineTime');
    Navigator.of(context).pop(); // sheet — the card shows the state now
    if (hit.kind == AccessoryKind.earbuds) {
      unawaited(ref
          .read(earbudsManagerProvider.notifier)
          .adopt(bleId, name: name));
    } else {
      unawaited(
          ref.read(watchManagerProvider.notifier).adopt(bleId, name: name));
    }
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connecting to $name…')),);
  }
}
