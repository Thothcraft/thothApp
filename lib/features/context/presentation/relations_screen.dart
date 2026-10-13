import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../watch/application/watch_providers.dart';
import '../application/context_providers.dart';
import 'ble_map.dart';

/// Unified radio and device map. The map is deliberately evidence-first:
/// saved room placements provide coordinates; radio observations provide
/// links and do not, by themselves, establish a target's position.
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
      error: (error, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Radio evidence unavailable: $error',
            textAlign: TextAlign.center,
          ),
        ),
      ),
      data: (edges) {
        final devices = devicesAsync.valueOrNull ?? const [];
        final spaces = spacesAsync.valueOrNull ?? const [];
        final watchNames = <String, String>{
          for (final watch in watchesAsync.valueOrNull ?? const [])
            watch.bleId: watch.name ?? 'watch',
        };

        if (edges.isEmpty && devices.isEmpty && spaces.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No devices or radio observations yet. Enable an available '
                'radio source in Settings → Sources to begin.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        return BleMapView(
          edges: edges,
          devices: devices,
          spaces: spaces,
          watchNames: watchNames,
        );
      },
    );
  }
}
