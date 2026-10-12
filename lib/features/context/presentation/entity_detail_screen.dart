import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/context_providers.dart';

/// Entity detail — one person/device's current context, supporting
/// evidence and recent history (Part 5).
class EntityDetailScreen extends ConsumerWidget {
  const EntityDetailScreen({super.key, required this.entityId});

  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(contextSnapshotProvider);
    final states = ref.watch(entityStatesProvider(entityId));
    final evidence = ref.watch(entityEvidenceProvider(entityId));
    final events = ref.watch(entityEventsProvider(entityId));

    final entity = snapshot.valueOrNull?.entities
        .where((e) => e.id == entityId)
        .firstOrNull;
    final title = entity?.name ?? entityId.split(':').last;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── current context ────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current context',
                      style: Theme.of(context).textTheme.titleMedium,),
                  const SizedBox(height: 8),
                  states.when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => Text('$e'),
                    data: (list) {
                      final live = list.where((s) => s.active).toList();
                      if (live.isEmpty) {
                        return Text('No active context.',
                            style: TextStyle(color: Theme.of(context)
                                .colorScheme.onSurfaceVariant),);
                      }
                      return Column(children: [
                        for (final s in live)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${s.key}: ${s.value}'),
                            subtitle: Text(
                                '${(s.confidence * 100).round()}% · '
                                '${s.estimator} · '
                                '${s.ageSeconds.round()}s'),
                          ),
                      ],);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── relationships ──────────────────────────────────────────────
          snapshot.maybeWhen(
            data: (snap) {
              final rels = snap.relationships.where((r) =>
                  r.subject == entityId || r.object == entityId,).toList();
              if (rels.isEmpty) return const SizedBox.shrink();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Relationships',
                            style: Theme.of(context).textTheme.titleMedium,),
                        for (final r in rels)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.hub_outlined, size: 18),
                            title: Text(
                                '${r.subject} —${r.predicate}→ ${r.object}',
                                style: const TextStyle(fontSize: 13),),
                            subtitle: Text(
                                '${(r.confidence * 100).round()}% · '
                                '${r.active ? 'active' : 'ended'}',
                                style: const TextStyle(fontSize: 11),),
                          ),
                      ],),
                ),
              );
            },
            orElse: () => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),

          // ── supporting evidence ────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Evidence',
                        style: Theme.of(context).textTheme.titleMedium,),
                    const SizedBox(height: 4),
                    Text(
                        'Observations and predictions supporting the '
                        'context above — evidence is not asserted truth.',
                        style: TextStyle(fontSize: 11, color: Theme.of(context)
                            .colorScheme.onSurfaceVariant),),
                    const SizedBox(height: 8),
                    evidence.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text('$e'),
                      data: (list) => list.isEmpty
                          ? Text('No evidence yet.',
                              style: TextStyle(color: Theme.of(context)
                                  .colorScheme.onSurfaceVariant),)
                          : Column(children: [
                              for (final ev in list.take(10))
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(ev.key,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12,),),
                                  subtitle: Text(
                                      '${ev.value} · '
                                      '${ev.sourceId ?? ''} · '
                                      '${ev.confidence != null ? '${(ev.confidence! * 100).round()}%' : ''}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11),),
                                ),
                            ],),
                    ),
                  ],),
            ),
          ),
          const SizedBox(height: 12),

          // ── history ────────────────────────────────────────────────────
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('History',
                        style: Theme.of(context).textTheme.titleMedium,),
                    events.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) => Text('$e'),
                      data: (list) => list.isEmpty
                          ? Text('No transitions recorded.',
                              style: TextStyle(color: Theme.of(context)
                                  .colorScheme.onSurfaceVariant),)
                          : Column(children: [
                              for (final ev in list.take(20))
                                ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    ev.type == 'entered'
                                        ? Icons.login
                                        : ev.type == 'exited'
                                            ? Icons.logout
                                            : Icons.swap_horiz,
                                    size: 16,
                                  ),
                                  title: Text(
                                      '${ev.type} ${ev.value ?? ev.key}',
                                      style: const TextStyle(fontSize: 13),),
                                  subtitle: Text(ev.key,
                                      style:
                                          const TextStyle(fontSize: 11),),
                                ),
                            ],),
                    ),
                  ],),
            ),
          ),
        ],
      ),
    );
  }
}
