import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../application/devices_provider.dart';
import '../../watch/presentation/pinetime_detail_screen.dart';
import '../../watch/presentation/watch_screen.dart';

/// Devices tab — real paired devices from Brain.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);

    return Scaffold(
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
                return Card(
                  child: ListTile(
                    leading: Icon(
                      isWatch ? Icons.watch : Icons.sensors,
                      color: d.online ? Colors.green : Colors.grey,
                    ),
                    title: Text(d.name),
                    subtitle: Text(isWatch
                        ? sub.toString()
                        : '${sub.toString()}\n${d.hostname}:5000',),
                    isThreeLine: !isWatch,
                    trailing: d.batteryLevel != null
                        ? Text('${d.batteryLevel}%')
                        : null,
                    onTap: () {
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
    );
  }
}
