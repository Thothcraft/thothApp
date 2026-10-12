import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../watch/application/watch_providers.dart';
import '../application/context_providers.dart';
import 'ble_map.dart';
import 'spatial_map.dart';
import 'trace_map_tab.dart';

/// Shared radio evidence graph; unknown positions remain unlocated.
class RelationsScreen extends ConsumerWidget {
  const RelationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final edgesAsync = ref.watch(bleRelationsProvider);
    final devicesAsync = ref.watch(deviceListProvider);
    final spacesAsync = ref.watch(spacesLiveProvider);
    final watchesAsync = ref.watch(watchListProvider);

    return edgesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child:
            Text('Radio evidence unavailable: $e', textAlign: TextAlign.center),
      ),),
      data: (edges) {
        final devices = devicesAsync.valueOrNull ?? const [];
        final spaces = spacesAsync.valueOrNull ?? const [];
        final watchNames = <String, String>{
          for (final w in watchesAsync.valueOrNull ?? const [])
            w.bleId: (w.name ?? 'watch'),
        };

        if (edges.isEmpty && devices.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No devices or BLE proximity evidence yet. Enable the '
                'BLE source in Settings → Sources and enroll a wearable.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return DefaultTabController(
            length: 3,
            child: Column(children: [
              const TabBar(
                  tabs: [
            Tab(text: 'House · 3D'),
            Tab(text: 'Radio links'),
            Tab(text: 'Trace'),
          ],),
              Expanded(
                  child: TabBarView(children: [
                SpatialMapView(
                    devices: devices, edges: edges, watchNames: watchNames,),
                Column(children: [
                  Expanded(
                      child: ClipRect(
                          child: BleMapView(
                              edges: edges,
                              devices: devices,
                              spaces: spaces,
                              watchNames: watchNames,),),),
                  _DescriptorList(edges: edges, watchNames: watchNames),
                ],),
                const TraceMapTab(),
              ],),),
            ],),);
      },
    );
  }
}

/// Compact rows of the map's semantic info — one per live edge plus a
/// 3D descriptor per endpoint (floor, side, moving/stationary, type).
class _DescriptorList extends StatelessWidget {
  const _DescriptorList({required this.edges, required this.watchNames});

  final List<BleRelation> edges;
  final Map<String, String> watchNames;

  String _name(String id) => watchNames[id] ?? id.split(':').last;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text('Live links · radio · signal strength · freshness',
              style: TextStyle(fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),),
        ),
        for (final e in edges)
          ListTile(
            dense: true,
            leading: Icon(e.moving ? Icons.directions_walk : Icons.bluetooth,
                size: 16, color: e.moving ? Colors.orange : null,),
            title: Text('${_name(e.observer)} → ${_name(e.target)}',
                style: const TextStyle(fontSize: 12),),
            subtitle: Text(
                '${e.rssiDbm.round()} dBm '
                '(±${e.rssiSpreadDb.toStringAsFixed(0)} dB) · '
                '${e.ageSeconds.round()}s · ×${e.count} · '
                '${e.modality} · ${e.moving ? 'signal varying' : 'signal steady'}',
                style: const TextStyle(fontSize: 11),),
          ),
        if (edges.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('No radio links yet — nodes above are placed devices.',
                style: TextStyle(fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),),
          ),
      ],),
    );
  }
}
