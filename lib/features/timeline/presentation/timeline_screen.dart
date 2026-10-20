import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../context/domain/models.dart';
import '../application/timeline_providers.dart';
import '../domain/timeline_models.dart';

/// Minute-level model timeline — the fleet's running whispy models,
/// context states, and node minutes rendered as one continuous river
/// of the user's day.
class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen>
    with TickerProviderStateMixin {
  late final AnimationController _sweep;
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    _sweep = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 3800));
    _drift = AnimationController(
        vsync: this, duration: const Duration(seconds: 16));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (MediaQuery.of(context).disableAnimations) return;
      _sweep.repeat();
      _drift.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _sweep.dispose();
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feedAsync = ref.watch(timelineFeedProvider);
    final feed = feedAsync.valueOrNull;
    final filter = ref.watch(timelineFilterProvider);
    final minutes = ref.watch(filteredMinutesProvider);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _HeroPanel(feed: feed, sweep: _sweep, drift: _drift),
        ),
        SliverToBoxAdapter(
          child: _FilterBar(filter: filter),
        ),
        if (feed != null)
          SliverToBoxAdapter(child: _ModelConstellation(feed: feed)),
        if (feedAsync.isLoading && feed == null)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (feedAsync.hasError && feed == null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _FeedError(error: '${feedAsync.error}'),
          )
        else if (minutes.isEmpty)
          const SliverToBoxAdapter(child: _EmptyTimeline())
        else
          _MinuteSliver(minutes: minutes, feed: feed!, sweep: _sweep),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hero — live "now" panel: animated radar sweep + current context.
// ---------------------------------------------------------------------------

class _HeroPanel extends StatelessWidget {
  const _HeroPanel({required this.feed, required this.sweep, required this.drift});

  final TimelineFeed? feed;
  final AnimationController sweep;
  final AnimationController drift;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scene = feed?.currentScene;
    final states = feed?.states ?? const <ContextState>[];
    final occupancy = states.where((s) => s.key == 'occupancy.v1').toList();
    final zones = states.where((s) => s.key == 'location.zone.v1').toList();
    final activity =
        states.where((s) => s.key.startsWith('activity.')).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primaryContainer.withValues(alpha: 0.9),
                scheme.surfaceContainerHighest,
              ],
            ),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: drift,
                  builder: (_, __) => CustomPaint(
                    painter: _AuroraPainter(t: drift.value, scheme: scheme),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 96,
                          height: 96,
                          child: AnimatedBuilder(
                            animation: sweep,
                            builder: (_, __) => CustomPaint(
                              painter: _SweepPainter(
                                t: sweep.value,
                                scheme: scheme,
                                occupied: _anyOccupied(occupancy),
                                blips: _blips(feed),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('NOW',
                                  style: TextStyle(
                                      fontSize: 11,
                                      letterSpacing: 3,
                                      fontWeight: FontWeight.w800,
                                      color: scheme.primary)),
                              const SizedBox(height: 4),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 500),
                                child: Text(
                                  scene ?? 'Listening to the fleet…',
                                  key: ValueKey(scene),
                                  style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                feed == null
                                    ? 'connecting'
                                    : '${feed!.minutes.length} minutes · ${feed!.deployments.where((d) => d.active).length} active models',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final s in occupancy.take(3))
                          _StateChip(
                            icon: _occupancyIcon(s),
                            label:
                                '${feed?.deviceName(s.entityId) ?? TimelineFeed.shortId(s.entityId)} · ${_occupancyText(s)}',
                            color: _occupancyColor(s),
                          ),
                        for (final s in zones.take(2))
                          _StateChip(
                            icon: Icons.place_outlined,
                            label:
                                '${feed?.deviceName(s.entityId) ?? ''} → ${_zoneText(s)}',
                            color: scheme.tertiary,
                          ),
                        for (final s in activity.take(2))
                          _StateChip(
                            icon: Icons.directions_walk,
                            label: _activityText(s),
                            color: scheme.secondary,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool? _anyOccupied(List<ContextState> occ) {
    if (occ.isEmpty) return null;
    for (final s in occ) {
      final v = s.value;
      if (v is Map && v['occupied'] == true) return true;
    }
    if (occ.every((s) => s.value is Map && s.value['occupied'] == false)) {
      return false;
    }
    return null;
  }

  static List<_SweepBlip> _blips(TimelineFeed? feed) {
    if (feed == null) return const [];
    final out = <_SweepBlip>[];
    var i = 0;
    for (final e in feed.deploymentsByDevice.entries) {
      final active = e.value.any((d) => d.active);
      final angle = (e.key.hashCode % 360) * math.pi / 180;
      final radius = 0.35 + 0.55 * ((i * 37) % 60) / 60;
      out.add(_SweepBlip(
          angle: angle, radius: radius.clamp(0.25, 0.92), active: active));
      i++;
    }
    return out;
  }

  static IconData _occupancyIcon(ContextState s) {
    final v = s.value;
    if (v is Map && v['occupied'] == true) return Icons.person;
    if (v is Map && v['occupied'] == false) return Icons.person_off_outlined;
    return Icons.help_outline;
  }

  static String _occupancyText(ContextState s) {
    final v = s.value;
    if (v is Map) {
      if (v['occupied'] == true) {
        final n = (v['distinct_subjects'] as num?)?.toInt();
        return n != null && n > 0 ? 'occupied · $n' : 'occupied';
      }
      if (v['occupied'] == false) return 'empty';
    }
    return 'unknown';
  }

  static Color _occupancyColor(ContextState s) {
    final v = s.value;
    if (v is Map && v['occupied'] == true) return AppColors.success;
    if (v is Map && v['occupied'] == false) return Colors.blueGrey;
    return AppColors.warning;
  }

  static String _zoneText(ContextState s) {
    final v = s.value;
    if (v is Map) return '${v['zone'] ?? v['best_zone'] ?? '—'}';
    return '$v';
  }

  static String _activityText(ContextState s) {
    final v = s.value;
    if (v is Map) return '${v['motion'] ?? v['state'] ?? v['label'] ?? v}';
    return '$v';
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip(
      {required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filter bar
// ---------------------------------------------------------------------------

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.filter});

  final TimelineFilter filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(timelineFeedProvider).valueOrNull;
    final devices = feed?.deviceNames ?? const <String, String>{};
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _filterChip(context, ref, 'Occupancy', Icons.person, filter.occupancy,
              (v) => filter.copyWith(occupancy: v)),
          _filterChip(context, ref, 'Zones', Icons.place_outlined, filter.zones,
              (v) => filter.copyWith(zones: v)),
          _filterChip(context, ref, 'Activity', Icons.directions_run,
              filter.activity, (v) => filter.copyWith(activity: v)),
          _filterChip(context, ref, 'Presence', Icons.bluetooth, filter.presence,
              (v) => filter.copyWith(presence: v)),
          _filterChip(context, ref, 'Models', Icons.psychology_outlined,
              filter.predictions, (v) => filter.copyWith(predictions: v)),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            onSelected: (v) => ref
                .read(timelineFilterProvider.notifier)
                .state = filter.copyWith(
                deviceId: v == '__all__' ? null : v, clearDevice: v == '__all__'),
            itemBuilder: (_) => [
              const PopupMenuItem(value: '__all__', child: Text('All devices')),
              for (final e in devices.entries)
                PopupMenuItem(value: e.key, child: Text(e.value)),
            ],
            child: Chip(
              avatar: const Icon(Icons.devices, size: 16),
              label: Text(filter.deviceId == null
                  ? 'All devices'
                  : (devices[filter.deviceId] ??
                      TimelineFeed.shortId(filter.deviceId!))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(BuildContext context, WidgetRef ref, String label,
      IconData icon, bool on, TimelineFilter Function(bool) update) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: on,
        onSelected: (v) =>
            ref.read(timelineFilterProvider.notifier).state = update(v),
        avatar: Icon(icon,
            size: 16, color: on ? scheme.onPrimary : scheme.onSurfaceVariant),
        label: Text(label),
        showCheckmark: false,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Model constellation — deployments per device + deploy action.
// ---------------------------------------------------------------------------

class _ModelConstellation extends ConsumerWidget {
  const _ModelConstellation({required this.feed});

  final TimelineFeed feed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.hub_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 6),
              const Text('Deployed models',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: feed.models.isEmpty
                    ? null
                    : () => _deploySheet(context, ref, feed),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Deploy'),
              ),
            ],
          ),
          SizedBox(
            height: 44,
            child: feed.deployments.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No deployments yet — deploy a whispy model to a node or this phone.',
                      style: TextStyle(
                          fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: feed.deployments.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final d = feed.deployments[i];
                      final model = feed.models
                          .where((m) => m.id == d.modelId)
                          .firstOrNull;
                      return _DeploymentChip(
                        deployment: d,
                        model: model,
                        deviceName: feed.deviceName(d.deviceId),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _deploySheet(BuildContext context, WidgetRef ref, TimelineFeed feed) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DeploySheet(feed: feed),
    );
  }
}

class _DeploymentChip extends StatelessWidget {
  const _DeploymentChip(
      {required this.deployment, this.model, required this.deviceName});

  final TimelineDeployment deployment;
  final TimelineModel? model;
  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = deployment.active
        ? AppColors.success
        : deployment.failed
            ? AppColors.error
            : deployment.pending
                ? AppColors.warning
                : Colors.blueGrey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(color: color, animate: deployment.active),
          const SizedBox(width: 7),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(model?.name ?? deployment.modelId,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700)),
              Text('$deviceName · ${deployment.state}',
                  style: TextStyle(
                      fontSize: 10, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.animate});

  final Color color;
  final bool animate;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.animate && !MediaQuery.of(context).disableAnimations) {
        _c.repeat();
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final r = widget.animate ? 3.5 + 2 * _c.value : 3.5;
        return Container(
          width: r * 2,
          height: r * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color
                .withValues(alpha: widget.animate ? 1 - _c.value * 0.6 : 1),
          ),
        );
      },
    );
  }
}

class _DeploySheet extends ConsumerStatefulWidget {
  const _DeploySheet({required this.feed});

  final TimelineFeed feed;

  @override
  ConsumerState<_DeploySheet> createState() => _DeploySheetState();
}

class _DeploySheetState extends ConsumerState<_DeploySheet> {
  String? _modelId;
  String? _deviceId;
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final devices = feed.deviceNames;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Deploy a model',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Brain queues the deployment; the target (node, laptop, or phone) downloads, validates, and activates it locally.',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            initialValue: _modelId,
            decoration: const InputDecoration(
                labelText: 'Model', border: OutlineInputBorder()),
            items: [
              for (final m in feed.models)
                DropdownMenuItem(
                  value: m.id,
                  child: Text(
                      '${m.name}${m.task != null ? ' · ${m.task}' : ''}',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _modelId = v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _deviceId,
            decoration: const InputDecoration(
                labelText: 'Target device', border: OutlineInputBorder()),
            items: [
              for (final e in devices.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _deviceId = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AppColors.error)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy || _modelId == null || _deviceId == null
                  ? null
                  : _deploy,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.rocket_launch_outlined),
              label: Text(_busy ? 'Deploying…' : 'Deploy'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deploy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(timelineRepoProvider)
          .deploy(modelId: _modelId!, deviceId: _deviceId!);
      ref.invalidate(timelineFeedProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }
}

// ---------------------------------------------------------------------------
// The minute river
// ---------------------------------------------------------------------------

class _MinuteSliver extends StatelessWidget {
  const _MinuteSliver(
      {required this.minutes, required this.feed, required this.sweep});

  final List<MinuteBucket> minutes;
  final TimelineFeed feed;
  final AnimationController sweep;

  @override
  Widget build(BuildContext context) {
    // Flatten into [header, row, row, header, ...] for hour separators.
    final items = <_Item>[];
    String? lastHour;
    for (final m in minutes) {
      final hour = DateFormat('EEE · HH:00').format(m.start);
      if (hour != lastHour) {
        items.add(_Item(header: hour));
        lastHour = hour;
      }
      items.add(_Item(bucket: m));
    }
    return SliverList.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final it = items[i];
        if (it.header != null) {
          return _HourHeader(label: it.header!);
        }
        final b = it.bucket!;
        return _MinuteRow(
          key: ValueKey(b.start.millisecondsSinceEpoch),
          bucket: b,
          feed: feed,
          sweep: sweep,
          index: i,
        );
      },
    );
  }
}

class _Item {
  _Item({this.header, this.bucket});
  final String? header;
  final MinuteBucket? bucket;
}

class _HourHeader extends StatelessWidget {
  const _HourHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 18, 16, 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.primary.withValues(alpha: 0.6)),
          ),
          const SizedBox(width: 10),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.4,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(width: 10),
          Expanded(
              child:
                  Divider(color: scheme.outlineVariant.withValues(alpha: 0.4))),
        ],
      ),
    );
  }
}

class _MinuteRow extends ConsumerWidget {
  const _MinuteRow({
    super.key,
    required this.bucket,
    required this.feed,
    required this.sweep,
    required this.index,
  });

  final MinuteBucket bucket;
  final TimelineFeed feed;
  final AnimationController sweep;
  final int index;

  bool get isNow {
    final now = DateTime.now();
    return bucket.start.year == now.year &&
        bucket.start.month == now.month &&
        bucket.start.day == now.day &&
        bucket.start.hour == now.hour &&
        bucket.start.minute == now.minute;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final filter = ref.watch(timelineFilterProvider);
    final delay = Duration(milliseconds: (index * 24).clamp(0, 600));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delay.inMilliseconds),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: InkWell(
        onTap: () => _openMinute(context, ref),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Spine: dial on the vertical line.
                Column(
                  children: [
                    Expanded(
                      child: Container(
                        width: 2,
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: _MinuteDial(
                      bucket: bucket, sweep: sweep, isNow: isNow, feed: feed),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _MinuteCard(
                        bucket: bucket, feed: feed, filter: filter),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openMinute(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MinuteSheet(bucket: bucket, feed: feed),
    );
  }
}

/// The circular minute dial — 60 ticks, ring colour = occupancy verdict,
/// ticks lit by live per-second capture status when available.
class _MinuteDial extends StatelessWidget {
  const _MinuteDial({
    required this.bucket,
    required this.sweep,
    required this.isNow,
    required this.feed,
  });

  final MinuteBucket bucket;
  final AnimationController sweep;
  final bool isNow;
  final TimelineFeed feed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    LiveMinute? live;
    if (isNow) {
      for (final l in feed.live.values) {
        if (l.seconds.isNotEmpty) {
          live = l;
          break;
        }
      }
    }
    return AnimatedBuilder(
      animation: sweep,
      builder: (_, __) => CustomPaint(
        size: const Size(46, 46),
        painter: _MinuteDialPainter(
          scheme: scheme,
          occupied: bucket.occupied,
          density: _density(),
          ticks: live?.seconds ?? const [],
          pulse: isNow ? sweep.value : null,
        ),
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(_icon(), size: 16, color: _color(scheme)),
        ),
      ),
    );
  }

  double _density() {
    final n = bucket.events.length +
        bucket.predictions.length +
        bucket.nodeEntries.fold<int>(0, (a, e) => a + e.predictionCount);
    return (n / 20).clamp(0.08, 1.0);
  }

  IconData _icon() {
    if (bucket.occupied == true) return Icons.person;
    if (bucket.occupied == false) return Icons.home_outlined;
    if (bucket.activities.contains('moving')) return Icons.directions_run;
    return Icons.blur_on;
  }

  Color _color(ColorScheme scheme) {
    if (bucket.occupied == true) return AppColors.success;
    if (bucket.occupied == false) return Colors.blueGrey;
    return scheme.primary;
  }
}

class _MinuteCard extends StatelessWidget {
  const _MinuteCard(
      {required this.bucket, required this.feed, required this.filter});

  final MinuteBucket bucket;
  final TimelineFeed feed;
  final TimelineFilter filter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scene = bucket.scene;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(DateFormat('HH:mm').format(bucket.start),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      fontFeatures: [])),
              const Spacer(),
              if (bucket.meanConfidence > 0)
                Text('${(bucket.meanConfidence * 100).round()}%',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant)),
            ],
          ),
          if (scene != null) ...[
            const SizedBox(height: 4),
            Text(scene,
                style: TextStyle(
                    fontSize: 12.5, color: scheme.onSurface, height: 1.3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (filter.occupancy)
                for (final e in bucket.occupancy.entries)
                  _tag(
                    scheme,
                    '${feed.deviceName(e.key)} ${e.value == true ? 'occupied' : e.value == false ? 'empty' : '?'}',
                    e.value == true
                        ? AppColors.success
                        : e.value == false
                            ? Colors.blueGrey
                            : AppColors.warning,
                  ),
              if (filter.zones)
                for (final e in bucket.zones.entries)
                  _tag(scheme, '${feed.deviceName(e.key)} → ${e.value}',
                      scheme.tertiary),
              if (filter.activity)
                for (final a in bucket.activities)
                  _tag(scheme, a, scheme.secondary),
              if (filter.predictions)
                for (final r in bucket.runtimes.take(4))
                  _tag(scheme, r, scheme.primary,
                      icon: Icons.psychology_outlined),
              for (final n in bucket.nodeEntries)
                _tag(scheme, '${feed.deviceName(n.deviceId)} · min',
                    Colors.blueGrey,
                    icon: Icons.dns_outlined),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tag(ColorScheme scheme, String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 4),
          ],
          Text(text,
              style: TextStyle(
                  fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Minute detail sheet
// ---------------------------------------------------------------------------

class _MinuteSheet extends StatelessWidget {
  const _MinuteSheet({required this.bucket, required this.feed});

  final MinuteBucket bucket;
  final TimelineFeed feed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preds = [...bucket.predictions]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (_, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text(DateFormat('EEEE · HH:mm').format(bucket.start),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '${bucket.events.length} transitions · ${bucket.predictions.length} predictions · ${bucket.descriptors.length} scene descriptors',
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (preds.isNotEmpty) ...[
            _sectionTitle(context, 'Model predictions'),
            for (final p in preds) _predictionTile(context, p),
            const SizedBox(height: 12),
          ],
          if (bucket.descriptors.isNotEmpty) ...[
            _sectionTitle(context, 'Context builder'),
            for (final d in bucket.descriptors) _descriptorTile(context, d),
            const SizedBox(height: 12),
          ],
          if (bucket.events.isNotEmpty) ...[
            _sectionTitle(context, 'Transitions'),
            for (final e in bucket.events) _eventTile(context, e),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary)),
      );

  Widget _predictionTile(BuildContext context, TimelinePrediction p) {
    final scheme = Theme.of(context).colorScheme;
    final conf = p.confidence ?? 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_taskIcon(p.task), size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${p.shortModel.isEmpty ? 'model' : p.shortModel}${p.task.isEmpty ? '' : ' · ${p.task}'}',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(DateFormat('HH:mm:ss').format(
                  DateTime.fromMillisecondsSinceEpoch(
                      (p.timestamp * 1000).round())),
                  style: TextStyle(
                      fontSize: 10.5, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${p.previousLabel != null && p.previousLabel!.isNotEmpty ? '${p.previousLabel} → ' : ''}${p.label}',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              if (p.peopleCount != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('×${p.peopleCount}',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
          if (conf > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: conf.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor:
                    scheme.outlineVariant.withValues(alpha: 0.3),
                color: conf > 0.7
                    ? AppColors.success
                    : conf > 0.4
                        ? AppColors.warning
                        : AppColors.error,
              ),
            ),
          ],
          if (p.scores.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in p.scores.entries.take(6))
                  Text('${e.key} ${(e.value * 100).round()}%',
                      style: TextStyle(
                          fontSize: 10, color: scheme.onSurfaceVariant)),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _descriptorTile(BuildContext context, ContextEvidence d) {
    final scheme = Theme.of(context).colorScheme;
    final v = d.value;
    final fields = <Widget>[];
    if (v is Map) {
      if (v['scene'] != null) {
        fields.add(Text('${v['scene']}',
            style: const TextStyle(fontSize: 13)));
      }
      if (v['location'] is Map) {
        final loc = v['location'] as Map;
        final place =
            [loc['site'], loc['room'], loc['city']].whereType<String>().join(' · ');
        if (place.isNotEmpty) {
          fields.add(Text(place,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant)));
        }
      }
      if (v['predictions'] is Map) {
        final chips = (v['predictions'] as Map).entries.take(4).map((e) {
          final pv = e.value;
          final label = pv is Map ? pv['label'] : pv;
          return '$label';
        }).join('  ');
        if (chips.isNotEmpty) {
          fields.add(Text(chips,
              style: TextStyle(
                  fontSize: 11, color: scheme.onSurfaceVariant)));
        }
      }
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(feed.deviceName(d.deviceId ?? d.sourceId ?? ''),
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          if (fields.isEmpty)
            Text('${d.value}',
                style: const TextStyle(fontSize: 12),
                maxLines: 4,
                overflow: TextOverflow.ellipsis)
          else
            ...fields,
        ],
      ),
    );
  }

  Widget _eventTile(BuildContext context, ContextEvent e) {
    final scheme = Theme.of(context).colorScheme;
    final color = e.type == 'exited'
        ? Colors.blueGrey
        : e.type == 'entered'
            ? AppColors.success
            : scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
              e.type == 'entered'
                  ? Icons.login
                  : e.type == 'exited'
                      ? Icons.logout
                      : Icons.swap_horiz,
              size: 15,
              color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${e.key} · ${e.type}',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                Text(
                  '${e.previousValue ?? '—'} → ${e.value ?? '—'}',
                  style: TextStyle(
                      fontSize: 11.5, color: scheme.onSurfaceVariant),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (e.timestamp != null)
            Text(
              DateFormat('HH:mm:ss').format(
                  DateTime.fromMillisecondsSinceEpoch(
                      (e.timestamp! * 1000).round())),
              style: TextStyle(
                  fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  static IconData _taskIcon(String task) {
    switch (task) {
      case 'occupancy':
        return Icons.meeting_room_outlined;
      case 'person_presence':
      case 'face_detection':
      case 'face_recognition':
        return Icons.face_outlined;
      case 'speech_to_text':
        return Icons.mic_none;
      case 'presence':
        return Icons.bluetooth;
      case 'activity':
        return Icons.directions_run;
      case 'noise':
        return Icons.graphic_eq;
      case 'fusion':
        return Icons.merge_type;
      default:
        return Icons.psychology_outlined;
    }
  }
}

// ---------------------------------------------------------------------------
// Empty / error
// ---------------------------------------------------------------------------

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(Icons.timeline, size: 56, color: scheme.outlineVariant),
          const SizedBox(height: 12),
          const Text('Nothing on the timeline yet',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Once models are deployed and devices report, predictions and context transitions land here minute by minute.',
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _FeedError extends StatelessWidget {
  const _FeedError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          Icon(Icons.cloud_off, size: 48, color: scheme.error),
          const SizedBox(height: 12),
          const Text('Timeline unavailable',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(error,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Painters
// ---------------------------------------------------------------------------

class _SweepBlip {
  const _SweepBlip(
      {required this.angle, required this.radius, required this.active});
  final double angle;
  final double radius;
  final bool active;
}

/// Animated radar sweep — concentric rings, rotating gradient beam,
/// device blips that flash as the beam passes.
class _SweepPainter extends CustomPainter {
  const _SweepPainter({
    required this.t,
    required this.scheme,
    required this.blips,
    this.occupied,
  });

  final double t;
  final ColorScheme scheme;
  final List<_SweepBlip> blips;
  final bool? occupied;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final beamColor = occupied == true
        ? AppColors.success
        : occupied == false
            ? Colors.blueGrey
            : scheme.primary;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = scheme.onSurfaceVariant.withValues(alpha: 0.25);
    for (final f in [1.0, 0.72, 0.44]) {
      canvas.drawCircle(c, r * f, ring);
    }
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), ring);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), ring);

    // Trailing beam: a sweep arc with a fading gradient.
    final beam = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi / 2.4,
        colors: [
          beamColor.withValues(alpha: 0),
          beamColor.withValues(alpha: 0.45),
        ],
        transform: GradientRotation(t * 2 * math.pi - math.pi / 2.4),
      ).createShader(Rect.fromCircle(center: c, radius: r));
    canvas.drawCircle(c, r, beam);

    final line = Paint()
      ..strokeWidth = 1.6
      ..color = beamColor.withValues(alpha: 0.9);
    final a = t * 2 * math.pi;
    canvas.drawLine(
        c, Offset(c.dx + r * math.cos(a), c.dy + r * math.sin(a)), line);

    for (final b in blips) {
      final p = Offset(
          c.dx + r * b.radius * math.cos(b.angle),
          c.dy + r * b.radius * math.sin(b.angle));
      // Blip brightens right after the beam passes it.
      final dt = (a - b.angle) % (2 * math.pi);
      final glow = (1 - dt / (2 * math.pi)).clamp(0.0, 1.0);
      canvas.drawCircle(
          p,
          2.2 + 1.4 * glow,
          Paint()
            ..color = (b.active ? beamColor : Colors.blueGrey)
                .withValues(alpha: 0.45 + 0.55 * glow));
    }
  }

  @override
  bool shouldRepaint(_SweepPainter old) => true;
}

/// Slow aurora backdrop — two drifting radial blooms.
class _AuroraPainter extends CustomPainter {
  const _AuroraPainter({required this.t, required this.scheme});

  final double t;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    void bloom(double cx, double cy, double r, Color color, double alpha) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));
      canvas.drawRect(Offset.zero & size, paint);
    }

    final w = size.width, h = size.height;
    bloom(w * (0.15 + 0.1 * math.sin(t * 2 * math.pi)),
        h * (0.2 + 0.15 * math.cos(t * 2 * math.pi)), w * 0.6,
        scheme.primary, 0.10);
    bloom(w * (0.85 - 0.08 * math.cos(t * 2 * math.pi)),
        h * (0.85 - 0.1 * math.sin(t * 2 * math.pi + 1)), w * 0.7,
        scheme.tertiary, 0.08);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => true;
}

/// The minute dial: 60 second-ticks around a ring. Ring colour encodes
/// the occupancy verdict; live minutes light ticks per capture status
/// and the current minute pulses with the sweep.
class _MinuteDialPainter extends CustomPainter {
  const _MinuteDialPainter({
    required this.scheme,
    required this.occupied,
    required this.density,
    required this.ticks,
    this.pulse,
  });

  final ColorScheme scheme;
  final bool? occupied;
  final double density;
  final List<LiveSecond> ticks;
  final double? pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    final ringColor = occupied == true
        ? AppColors.success
        : occupied == false
            ? Colors.blueGrey
            : scheme.outlineVariant;

    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = ringColor.withValues(alpha: 0.7));

    // Density arc — how "full" the minute is with model/context data.
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = (occupied == true ? AppColors.success : scheme.primary)
          .withValues(alpha: 0.85);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2,
        2 * math.pi * density.clamp(0.05, 1.0), false, arc);

    // Per-second ticks.
    final byIndex = {for (final s in ticks) s.index: s};
    for (var i = 0; i < 60; i++) {
      final a = -math.pi / 2 + i * (2 * math.pi / 60);
      final inner = r - 4.5;
      final p1 = Offset(c.dx + inner * math.cos(a), c.dy + inner * math.sin(a));
      final p2 = Offset(
          c.dx + (r - 1.5) * math.cos(a), c.dy + (r - 1.5) * math.sin(a));
      final s = byIndex[i];
      final col = s == null
          ? scheme.outlineVariant.withValues(alpha: 0.25)
          : s.status == 'error'
              ? AppColors.error
              : s.occupied == true
                  ? AppColors.success
                  : s.occupied == false
                      ? Colors.blueGrey
                      : scheme.primary;
      canvas.drawLine(
          p1,
          p2,
          Paint()
            ..strokeWidth = 1.4
            ..color = col.withValues(alpha: s == null ? 0.25 : 0.9));
    }

    if (pulse != null) {
      canvas.drawCircle(
          c,
          r + 1.5 + 2.5 * pulse!,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = scheme.primary.withValues(alpha: (1 - pulse!) * 0.6));
    }
  }

  @override
  bool shouldRepaint(_MinuteDialPainter old) => true;
}
