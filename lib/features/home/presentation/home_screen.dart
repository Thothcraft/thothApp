import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../context/application/context_providers.dart';
import '../../context/domain/models.dart';
import '../../devices/application/devices_provider.dart';
import '../../earbuds/application/earbuds_providers.dart';
import '../../watch/application/watch_providers.dart';

/// Home — the daily driver screen. Apple-Home style: rooms first,
/// then accessories (watch + nodes), then a taste of recent activity.
/// No marketing copy — the portal owns that.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spaces = ref.watch(spacesLiveProvider).valueOrNull ?? const [];
    final devices = ref.watch(devicesProvider).valueOrNull ?? const [];
    final watches = ref.watch(watchListProvider).valueOrNull ?? const [];
    final buds = ref.watch(earbudsListProvider).valueOrNull ?? const [];
    final manager = ref.watch(watchManagerProvider);
    final budsManager = ref.watch(earbudsManagerProvider);
    final events = ref.watch(contextEventsProvider).valueOrNull ?? const [];
    final snap = ref.watch(contextSnapshotProvider).valueOrNull;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(spacesLiveProvider);
        ref.invalidate(devicesProvider);
        ref.invalidate(contextSnapshotProvider);
        ref.invalidate(contextEventsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _Greeting(now: DateTime.now()),
          const SizedBox(height: 16),

          // ── Spaces (portal-designed, shared here) ────────────────
          _SectionTitle(
              title: 'Spaces',
              action: TextButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New'),
                onPressed: () => _createSpace(context, ref),
              ),),
          if (spaces.isEmpty)
            const _EmptyHint(
                'No spaces yet — design spaces on the portal or tap + '
                'to create one; they appear here and on the BLE map.')
          else
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.5,
              children: [
                for (final s in spaces) _SpaceTile(space: s),
              ],
            ),
          const SizedBox(height: 20),

          // ── Who's where ───────────────────────────────────────────
          if (snap != null) ...[
            _PresenceStrip(snapshot: snap),
            const SizedBox(height: 20),
          ],

          // ── Accessories ──────────────────────────────────────────
          const _SectionTitle(title: 'Accessories'),
          for (final w in watches)
            _WatchTile(
                bleId: w.bleId,
                name: w.name ?? 'PineTime',
                connected: manager[w.bleId]?.connected ?? false,),
          for (final b in buds)
            _EarbudsTile(
                bleId: b.bleId,
                name: b.name ?? 'PineBuds',
                connected: budsManager[b.bleId]?.connected ?? false,),
          _NodesCard(devices: devices),
          const SizedBox(height: 20),

          // ── Recent activity ───────────────────────────────────────
          _SectionTitle(
              title: 'Recent activity',
              action: TextButton(
                onPressed: () => context.go('/events'),
                child: const Text('See all'),
              ),),
          if (events.isEmpty)
            const _EmptyHint(
                'Nothing yet — transitions between spaces will show up '
                'here as devices report movement.')
          else
            for (final e in events.take(5)) _EventRow(event: e),
        ],
      ),
    );
  }

  Future<void> _createSpace(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New space'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'e.g. Office, Kitchen, Lab',),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(c, ctrl.text.trim()),
              child: const Text('Create'),),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(contextRepoProvider).createSpace(name);
      ref.invalidate(spacesLiveProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Create failed: $e')));
      }
    }
  }
}

// ── sections ──────────────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  const _Greeting({required this.now});
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final h = now.hour;
    final hello = h < 12
        ? 'Good morning'
        : h < 18
            ? 'Good afternoon'
            : 'Good evening';
    final date = '${_wd[now.weekday]}, ${_mo[now.month]} ${now.day}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(hello, style: Theme.of(context).textTheme.headlineSmall),
      Text(date,
          style: TextStyle(
              color: Theme.of(context).colorScheme.outline,
              fontSize: 13,),),
    ],);
  }

  static const _wd = {
    1: 'Mon', 2: 'Tue', 3: 'Wed', 4: 'Thu', 5: 'Fri', 6: 'Sat', 7: 'Sun',
  };
  static const _mo = {
    1: 'Jan', 2: 'Feb', 3: 'Mar', 4: 'Apr', 5: 'May', 6: 'Jun',
    7: 'Jul', 8: 'Aug', 9: 'Sep', 10: 'Oct', 11: 'Nov', 12: 'Dec',
  };
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.action});
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(
          child: Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),),
        ),
        if (action != null) action!,
      ],),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text,
          style: TextStyle(
              fontSize: 12.5,
              color: Theme.of(context).colorScheme.outline,),),
    );
  }
}

/// Room-style tile — occupancy dot + headline stats, tap → detail.
class _SpaceTile extends StatelessWidget {
  const _SpaceTile({required this.space});
  final SpaceInfo space;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push('/context/spaces/${space.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(
                  space.occupied
                      ? Icons.sensor_door
                      : Icons.sensor_door_outlined,
                  size: 20,
                  color: space.occupied ? Colors.green : cs.outline,
                ),
                const Spacer(),
                if (space.occupied)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2,),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('Occupied',
                        style:
                            TextStyle(fontSize: 10, color: Colors.green),),
                  ),
              ],),
              const Spacer(),
              Text(space.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14,),),
              const SizedBox(height: 2),
              Text(
                '${space.peopleCount} ${space.peopleCount == 1 ? 'person' : 'people'}'
                ' · ${space.placements.length} devices',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "gad — in office" chips for entities carrying a location state.
class _PresenceStrip extends StatelessWidget {
  const _PresenceStrip({required this.snapshot});
  final ContextSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (final st in snapshot.states) {
      if (st.key != 'location.space.v1' || !st.active) continue;
      final place = _placeName(st.value);
      if (place.isEmpty) continue;
      ContextEntity? entity;
      for (final e in snapshot.entities) {
        if (e.id == st.entityId) {
          entity = e;
          break;
        }
      }
      final who = entity != null && (entity.name?.isNotEmpty ?? false)
          ? entity.name!
          : st.entityId.split(':').last;
      rows.add(Chip(
        avatar: Icon(
            entity?.kind == 'person' ? Icons.person : Icons.tag,
            size: 16,),
        label: Text('$who · $place', style: const TextStyle(fontSize: 12)),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),);
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const _SectionTitle(title: 'Presence'),
      Wrap(spacing: 8, runSpacing: 4, children: rows),
    ],);
  }

  static String _placeName(dynamic v) {
    if (v is String) return v;
    if (v is Map) {
      return '${v['space'] ?? v['name'] ?? v['space_id'] ?? ''}';
    }
    return '';
  }
}

/// One paired buds set — connection dot + tap through to accessories.
class _EarbudsTile extends ConsumerWidget {
  const _EarbudsTile(
      {required this.bleId, required this.name, required this.connected,});
  final String bleId;
  final String name;
  final bool connected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(earbudsConnectionProvider(bleId)).valueOrNull;
    final live = connected || conn == BluetoothConnectionState.connected;
    final tele = ref.watch(earbudsTelemetryProvider(bleId)).valueOrNull;
    final batt = tele?.status?.batteryPct;
    return Card(
      child: ListTile(
        leading: Icon(Icons.earbuds,
            color: live ? Colors.teal : Colors.grey, size: 30,),
        title: Text(name),
        subtitle: Text(
            live
                ? batt != null
                    ? 'connected · $batt%'
                    : 'connected'
                : 'not connected',
            style: TextStyle(
                fontSize: 12, color: live ? Colors.teal : Colors.grey,),),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/watch'),
      ),
    );
  }
}

/// One paired watch — connection dot + tap through to the watch hub.
class _WatchTile extends ConsumerWidget {
  const _WatchTile(
      {required this.bleId, required this.name, required this.connected,});
  final String bleId;
  final String name;
  final bool connected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(watchConnectionProvider(bleId)).valueOrNull;
    final live = connected || conn == BluetoothConnectionState.connected;
    final tele = ref.watch(watchTelemetryProvider(bleId)).valueOrNull;
    final batt = tele?.battery;
    return Card(
      child: ListTile(
        leading: Icon(Icons.watch,
            color: live ? Colors.teal : Colors.grey, size: 30,),
        title: Text(name),
        subtitle: Text(
            live
                ? 'Connected${batt != null ? ' · $batt%' : ''}'
                : 'Not connected',
            style: TextStyle(
                fontSize: 12, color: live ? Colors.teal : Colors.grey,),),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/watch'),
      ),
    );
  }
}

/// Fleet summary — online nodes with per-node activity, tap → devices.
class _NodesCard extends StatelessWidget {
  const _NodesCard({required this.devices});
  final List<ThothDevice> devices;

  @override
  Widget build(BuildContext context) {
    final nodes =
        devices.where((d) => (d.deviceType ?? '') != 'pinetime').toList();
    if (nodes.isEmpty) return const SizedBox.shrink();
    final online = nodes.where((d) => d.online).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(children: [
          InkWell(
            onTap: () => context.go('/devices'),
            child: Row(children: [
              const Icon(Icons.router, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text('$online of ${nodes.length} nodes online',
                    style: const TextStyle(fontWeight: FontWeight.w600),),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],),
          ),
          const SizedBox(height: 6),
          for (final d in nodes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: InkWell(
                onTap: () => context.push('/devices/${d.uuid}'),
                child: Row(children: [
                  Icon(Icons.circle,
                      size: 8,
                      color: d.online ? Colors.green : Colors.grey,),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(d.name,
                          style: const TextStyle(fontSize: 13),),),
                  Text(_activityTag(d),
                      style: const TextStyle(
                          fontSize: 11, color: Colors.grey,),),
                ],),
              ),
            ),
        ],),
      ),
    );
  }

  static String _activityTag(ThothDevice d) {
    final a = d.activity;
    if (a == null) return d.online ? 'idle' : 'offline';
    final mode = '${a['mode'] ?? 'idle'}';
    final streams = a['streams'] is List
        ? (a['streams'] as List).where((s) {
            return s is Map && (((s['age_s'] as num?) ?? 999) < 10);
          }).length
        : 0;
    return streams > 0 ? '$mode · $streams live' : mode;
  }
}

/// One transition row in the Recent activity preview.
class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final ContextEvent event;

  @override
  Widget build(BuildContext context) {
    final when = event.timestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(
            (event.timestamp! * 1000).round(),)
        : null;
    final icon = switch (event.type) {
      'entered' => Icons.login,
      'exited' => Icons.logout,
      _ => Icons.swap_horiz,
    };
    final color = switch (event.type) {
      'entered' => Colors.green,
      'exited' => Colors.grey,
      _ => Colors.blue,
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 18, color: color),
      title: Text(
          '${event.entityId?.split(':').last ?? 'entity'} '
          '${event.type} ${_val(event.value)}',
          style: const TextStyle(fontSize: 13),),
      subtitle: when != null
          ? Text(_ago(when), style: const TextStyle(fontSize: 11))
          : null,
    );
  }

  static String _val(dynamic v) {
    if (v is Map) return '${v['space'] ?? v['space_id'] ?? v}';
    return '$v';
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes}m ago';
    if (d.inDays < 1) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }
}
