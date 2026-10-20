import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/timeline_repository.dart';
import '../domain/timeline_models.dart';

final timelineRepoProvider =
    Provider<TimelineRepository>((_) => TimelineRepository());

/// Poll cadence for the assembled feed — context events arrive on the
/// Brain SSE bus too, but a slow poll keeps minutes + live-chunks fresh
/// without depending on socket state.
const _pollCadence = Duration(seconds: 20);

/// The assembled timeline feed (events + predictions + node minutes +
/// models + deployments + live minute). Polls while the page is open.
final timelineFeedProvider = StreamProvider.autoDispose<TimelineFeed>((ref) async* {
  final repo = ref.watch(timelineRepoProvider);
  for (;;) {
    yield await repo.feed();
    await Future<void>.delayed(_pollCadence);
  }
});

/// Which context families the ribbon renders.
class TimelineFilter {
  const TimelineFilter({
    this.occupancy = true,
    this.zones = true,
    this.activity = true,
    this.presence = true,
    this.predictions = true,
    this.deviceId,
  });

  final bool occupancy;
  final bool zones;
  final bool activity;
  final bool presence;
  final bool predictions;
  final String? deviceId;

  TimelineFilter copyWith({
    bool? occupancy,
    bool? zones,
    bool? activity,
    bool? presence,
    bool? predictions,
    String? deviceId,
    bool clearDevice = false,
  }) =>
      TimelineFilter(
        occupancy: occupancy ?? this.occupancy,
        zones: zones ?? this.zones,
        activity: activity ?? this.activity,
        presence: presence ?? this.presence,
        predictions: predictions ?? this.predictions,
        deviceId: clearDevice ? null : (deviceId ?? this.deviceId),
      );

  bool accepts(MinuteBucket b) {
    if (deviceId != null && !b.devices.contains(deviceId)) return false;
    var any = false;
    if (occupancy && b.occupancy.isNotEmpty) any = true;
    if (zones && b.zones.isNotEmpty) any = true;
    if (activity && b.activities.isNotEmpty) any = true;
    if (presence &&
        b.events.any((e) => e.key.contains('presence'))) {
      any = true;
    }
    if (predictions &&
        (b.predictions.isNotEmpty || b.nodeEntries.isNotEmpty)) {
      any = true;
    }
    if (b.descriptors.isNotEmpty) any = true; // scenes always surface
    if (b.events.isNotEmpty &&
        !b.events.any((e) =>
            e.key == 'occupancy.v1' ||
            e.key == 'location.zone.v1' ||
            e.key.startsWith('activity.') ||
            e.key.contains('presence') ||
            e.key == 'prediction')) {
      any = true; // other context keys always render
    }
    return any;
  }
}

final timelineFilterProvider =
    StateProvider<TimelineFilter>((_) => const TimelineFilter());

/// Minutes passing the active filter, newest first.
final filteredMinutesProvider = Provider.autoDispose<List<MinuteBucket>>((ref) {
  final feed = ref.watch(timelineFeedProvider).valueOrNull;
  final filter = ref.watch(timelineFilterProvider);
  if (feed == null) return const [];
  return feed.minutes.where(filter.accepts).toList();
});
