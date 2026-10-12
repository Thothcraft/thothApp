import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../application/context_providers.dart';
import '../domain/models.dart';

/// Context home (Part 5) — the operational view answering:
/// what spaces exist · which entities are where · what is happening ·
/// what evidence supports it · what recently changed.
///
/// Observations and context stay visually distinct: spaces show derived
/// state; the evidence row links to raw supporting observations.
class ContextHomeScreen extends ConsumerWidget {
  const ContextHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(contextSnapshotProvider);
    final spaces = ref.watch(spacesLiveProvider);
    final events = ref.watch(contextEventsProvider);
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(contextSnapshotProvider);
        ref.invalidate(spacesLiveProvider);
        ref.invalidate(contextEventsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Spaces ────────────────────────────────────────────────────
          _SectionTitle('Spaces', action: TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New'),
            onPressed: () => _createSpaceDialog(context, ref),
          ),),
          spaces.when(
            loading: () => const _Skeleton(),
            error: (e, _) => _ErrCard('spaces unavailable: $e'),
            data: (list) => list.isEmpty
                ? const _EmptyCard(
                    'No spaces yet — assign a node to a space during setup.',)
                : Column(
                    children: [
                      for (final s in list)
                        AnimatedSwitcher(
                          duration: reduceMotion
                              ? Duration.zero
                              : const Duration(milliseconds: 400),
                          child: _SpaceCard(key: ValueKey(
                              '${s.id}-${s.occupied}',), space: s,),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 20),

          // ── Entities ──────────────────────────────────────────────────
          _SectionTitle('Entities', action: TextButton.icon(
            icon: const Icon(Icons.hub_outlined, size: 16),
            label: const Text('Radio map'),
            onPressed: () => context.push('/context/relations'),
          ),),
          snapshot.when(
            loading: () => const _Skeleton(),
            error: (e, _) => _ErrCard('context unavailable: $e'),
            data: (snap) => snap.entities.isEmpty
                ? const _EmptyCard(
                    'No entities — devices and people appear here as '
                    'evidence links them to the space.')
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final e in snap.entities)
                        _EntityChip(entity: e, states: snap.states),
                    ],
                  ),
          ),
          const SizedBox(height: 20),

          // ── What's happening now ──────────────────────────────────────
          _SectionTitle('Now', action: TextButton.icon(
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text('Infer'),
            onPressed: () => context.push('/context/infer'),
          ),),
          snapshot.when(
            loading: () => const _Skeleton(),
            error: (_, __) => const SizedBox.shrink(),
            data: (snap) {
              final live = snap.states.where((s) => s.active).toList();
              if (live.isEmpty) {
                return const _EmptyCard(
                    'No active context — predictions become context once '
                    'an estimator attributes evidence.');
              }
              return Column(children: [
                for (final st in live) _StateRow(state: st),
              ],);
            },
          ),
          const SizedBox(height: 20),

          // ── Recently changed ──────────────────────────────────────────
          const _SectionTitle('Recent transitions'),
          events.when(
            loading: () => const _Skeleton(),
            error: (_, __) => const SizedBox.shrink(),
            data: (list) => list.isEmpty
                ? const _EmptyCard('No transitions yet.')
                : Column(children: [
                    for (final ev in list.take(12)) _EventRow(event: ev),
                  ],),
          ),
        ],
      ),
    );
  }

  Future<void> _createSpaceDialog(BuildContext context, WidgetRef ref) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New space'),
        content: TextField(
            controller: ctl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'e.g. office'),),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await ref
          .read(contextRepoProvider)
          .createSpace(ctl.text.trim());
      ref.invalidate(spacesLiveProvider);
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.action});
  final String text;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          Text(text, style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (action != null) action!,
        ],
      );
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({super.key, required this.space});
  final SpaceInfo space;

  @override
  Widget build(BuildContext context) {
    final occupied = space.occupied;
    final color = occupied ? AppColors.primaryBlue : Colors.grey;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => context.push('/context/spaces/${space.id}'),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(Icons.meeting_room_outlined, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(space.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),),
                Text(
                  occupied
                      ? 'occupied · ${space.peopleCount} '
                          '· ${(space.occupancyConfidence * 100).round()}%'
                      : 'no occupancy reported',
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ],),
            ),
            if (space.zoneStates.isNotEmpty)
              Wrap(spacing: 4, children: [
                for (final z in space.zoneStates.entries)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(z.key, style: const TextStyle(fontSize: 10)),
                    avatar: Icon(Icons.circle,
                        size: 8,
                        color: z.value['occupied'] == true
                            ? Colors.green
                            : Colors.grey,),
                  ),
              ],),
          ],),
        ),
      ),
    );
  }
}

class _EntityChip extends StatelessWidget {
  const _EntityChip({required this.entity, required this.states});
  final ContextEntity entity;
  final List<ContextState> states;

  @override
  Widget build(BuildContext context) {
    final mine = states.where((s) => s.entityId == entity.id && s.active);
    final location = mine
        .where((s) => s.key == ContextKeys.locationSpace)
        .map((s) => '${s.value}')
        .firstOrNull;
    final activity = mine
        .where((s) => s.key.startsWith('activity.'))
        .map((s) => '${s.value}')
        .firstOrNull;
    return InkWell(
      onTap: () => context.push('/context/entities/${entity.id}'),
      borderRadius: BorderRadius.circular(20),
      child: Chip(
        avatar: Icon(
          switch (entity.kind) {
            'person' => Icons.person_outline,
            'wearable' => Icons.watch_outlined,
            'device' => Icons.memory_outlined,
            'space' => Icons.meeting_room_outlined,
            _ => Icons.category_outlined,
          },
          size: 18,
        ),
        label: Text(
          [entity.name ?? entity.id.split(':').last,
               if (location != null) '@$location',
               if (activity != null) activity,]
              .join(' '),
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}

class _StateRow extends StatelessWidget {
  const _StateRow({required this.state});
  final ContextState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.insights_outlined, size: 20),
        title: Text('${state.key}  ·  ${state.value}',
            style: const TextStyle(fontSize: 13),),
        subtitle: Text(
          '${state.entityId.isEmpty ? 'space' : state.entityId}'
          ' · est ${state.estimator.isEmpty ? '—' : state.estimator}'
          ' · ${(state.confidence * 100).round()}%'
          ' · ${state.ageSeconds.round()}s ago',
          style: const TextStyle(fontSize: 11),
        ),
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});
  final ContextEvent event;

  @override
  Widget build(BuildContext context) {
    final when = event.timestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(
                (event.timestamp! * 1000).round(),)
            .toLocal()
            .toString()
            .substring(11, 19)
        : '';
    final icon = switch (event.type) {
      'entered' => Icons.login,
      'exited' => Icons.logout,
      _ => Icons.swap_horiz,
    };
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18,
          color: event.type == 'exited' ? Colors.grey : AppColors.primaryBlue,),
      title: Text(
        '${event.entityId ?? ''} ${event.type} ${event.value ?? event.key}',
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text('${event.key} · $when',
          style: TextStyle(fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant),),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) =>
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),),
        ),
      );
}

class _ErrCard extends StatelessWidget {
  const _ErrCard(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text(text, style: const TextStyle(fontSize: 12)),
        ),
      );
}
