import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../context/data/context_repository.dart';
import '../../context/domain/models.dart';
import '../../devices/application/devices_provider.dart';

/// One-shot repository accessor for imperative calls.
final contextRepoProvider =
    Provider<ContextRepository>((_) => ContextRepository());

/// Polling cadence — matches the Brain event feed contract (≤30 s).
const _pollCadence = Duration(seconds: 15);

/// Live context snapshot — entities + valid relationships + active
/// states. Polls on a cadence; the provider is kept alive while the
/// context tab is visible.
final contextSnapshotProvider =
    StreamProvider.autoDispose<ContextSnapshot>((ref) async* {
  final repo = ref.watch(contextRepoProvider);
  for (;;) {
    yield await repo.snapshot();
    await Future<void>.delayed(_pollCadence);
  }
});

/// Spaces with their live occupancy merged in.
final spacesLiveProvider =
    StreamProvider.autoDispose<List<SpaceInfo>>((ref) async* {
  final repo = ref.watch(contextRepoProvider);
  for (;;) {
    final spaces = await repo.spaces();
    Map<int, SpaceInfo> states = const {};
    try {
      states = await repo.spacesState();
    } catch (_) {/* state endpoint may lag creation */}
    yield spaces.map((s) {
      final live = states[s.id];
      return live == null
          ? s
          : SpaceInfo(
              id: s.id,
              name: s.name,
              parentId: s.parentId,
              widthM: s.widthM,
              heightM: s.heightM,
              zones: s.zones,
              placements: s.placements,
              occupied: live.occupied,
              peopleCount: live.peopleCount,
              occupancyConfidence: live.occupancyConfidence,
              zoneStates: live.zoneStates,
              lastActivity: live.lastActivity ?? s.lastActivity,
            );
    }).toList();
    await Future<void>.delayed(_pollCadence);
  }
});

/// Recent semantic events (transitions), newest first.
final contextEventsProvider =
    StreamProvider.autoDispose<List<ContextEvent>>((ref) async* {
  final repo = ref.watch(contextRepoProvider);
  for (;;) {
    yield await repo.events(limit: 100);
    await Future<void>.delayed(_pollCadence);
  }
});

/// All current states for one entity — the person page's context card.
final entityStatesProvider = FutureProvider.autoDispose
    .family<List<ContextState>, String>((ref, entityId) =>
        ref.watch(contextRepoProvider).states(entityId: entityId),);

/// Recent evidence touching an entity (via provenance) or a key.
final entityEvidenceProvider = FutureProvider.autoDispose
    .family<List<ContextEvidence>, String>((ref, entityId) async {
  final repo = ref.watch(contextRepoProvider);
  final all = await repo.evidence(limit: 300);
  return all
      .where((e) =>
          e.provenance['entity'] == entityId ||
          e.provenance['entity_id'] == entityId ||
          e.deviceId == entityId ||
          '${e.value}'.contains(entityId),)
      .toList();
});

/// Events for one entity — the person page's history.
final entityEventsProvider = FutureProvider.autoDispose
    .family<List<ContextEvent>, String>((ref, entityId) async {
  final all = await ref.watch(contextRepoProvider).events(limit: 300);
  return all.where((e) => e.entityId == entityId).toList();
});

/// Unified BLE proximity evidence → observer→target edges.
///
/// Three producers feed the same relation graph:
///   `ble.proximity.v1` — phone scan of enrolled wearables (flat value).
///   `ble.rssi.v1`      — node BLE observer (observation/v1 wrapper:
///                        `value.value.rssi_dbm`, `value.subject` is the
///                        target; `device_id` column is the node uuid).
///   `ble.discovery.v1` — phone scan of unenrolled advertisers (privacy:
///                        raw MAC stays on account; known=false).
final bleRelationsProvider =
    StreamProvider.autoDispose<List<BleRelation>>((ref) async* {
  final repo = ref.watch(contextRepoProvider);
  for (;;) {
    final since = (DateTime.now().millisecondsSinceEpoch - 60 * 1000) / 1000.0;
    final rows = <ContextEvidence>[];
    for (final key in [
      ContextKeys.bleProximityEvidence,
      ContextKeys.bleRssi,
      ContextKeys.bleDiscovery,
      'radio.ble.v1',
      'radio.wifi.v1',
      'radio.csi.v1',
    ]) {
      try {
        rows.addAll(await repo.evidence(key: key, since: since, limit: 400));
      } catch (_) {/* key may have no rows yet */}
    }

    rows.sort((a, b) => (a.timestamp ?? 0).compareTo(b.timestamp ?? 0));
    // Keep the freshest edge per (observer, target).
    final byKey = <String, BleRelation>{};
    for (final e in rows) {
      final parsed = _edgeFrom(e);
      if (parsed == null) continue;
      final (observer, target, rssi, known, advName) = parsed;
      final modality = e.key == 'radio.csi.v1'
          ? 'CSI'
          : e.key == 'radio.wifi.v1'
              ? 'Wi-Fi'
              : 'BLE';
      final component = e.sourceId ?? '';
      final key = '$observer/$component/$modality→$target';
      final existing = byKey[key];
      final ts = e.timestamp ?? 0;
      if (existing == null || ts > existing.timestamp) {
        byKey[key] = BleRelation(
          modality: modality,
          componentId: component,
          observer: observer,
          target: target,
          rssiDbm: rssi,
          timestamp: ts,
          count: (existing?.count ?? 0) + 1,
          confidence: e.confidence,
          known: known,
          advName: advName,
          rssiWindow: [
            ...?existing?.rssiWindow,
            rssi,
          ].reversed.take(12).toList().reversed.toList(),
        );
      } else {
        byKey[key] = existing.copyWith(count: existing.count + 1);
      }
    }
    yield byKey.values.toList();
    await Future<void>.delayed(_pollCadence);
  }
});

/// Normalizes one evidence row into (observer, target, rssi, known,
/// advName) regardless of which producer wrote it.
(String, String, double, bool, String?)? _edgeFrom(ContextEvidence e) {
  final outer = e.value is Map ? Map<String, dynamic>.from(e.value) : null;
  if (outer == null) return null;

  if (e.key.startsWith('radio.')) {
    final inner = outer['value'];
    final v = inner is Map ? Map<String, dynamic>.from(inner) : outer;
    final rssi = (v['rssi_dbm'] as num?)?.toDouble();
    final observer = e.deviceId ?? v['observer']?.toString() ?? '';
    final target = v['target']?.toString().toLowerCase() ?? '';
    if (observer.isEmpty || target.isEmpty || rssi == null || !rssi.isFinite) {
      return null;
    }
    return (observer, target, rssi, false, v['name']?.toString());
  }
  if (e.key == ContextKeys.bleRssi) {
    // Node observation envelope: value nests {value, subject, sequence}.
    final inner = outer['value'];
    final v = inner is Map ? Map<String, dynamic>.from(inner) : outer;
    final subject = '${outer['subject'] ?? v['subject'] ?? ''}';
    final rssi =
        (v['rssi_dbm'] as num?)?.toDouble() ?? (v['rssi'] as num?)?.toDouble();
    if (subject.isEmpty || rssi == null) return null;
    final observer = e.deviceId ?? e.sourceId ?? 'node';
    // MAC is the cross-observer join key: the same physical device is
    // one map node whether the node (device:ble:<hmac>) or the phone
    // (ble:<MAC>) saw it. Falls back to the subject when mac is absent
    // (older node builds).
    final mac = v['mac']?.toString().toLowerCase();
    final target = (mac != null && mac.isNotEmpty) ? 'ble:$mac' : subject;
    final known = !subject.startsWith('device:ble:');
    return (observer, target, rssi, known, v['name']?.toString());
  }

  // ble.proximity.v1 / ble.discovery.v1 — flat value.
  final observer = '${outer['observer'] ?? e.sourceId ?? 'unknown'}';
  var target = '${outer['target'] ?? ''}';
  final rssi = (outer['rssi_dbm'] as num?)?.toDouble() ??
      (outer['rssi'] as num?)?.toDouble();
  if (target.isEmpty || rssi == null) return null;
  // Enrolled edges carry bare MACs; discovery carries ble:<MAC>. Unify
  // under ble:<MAC> so node+phone sightings of one radio share a node.
  if (!target.startsWith('ble:') &&
      RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(target)) {
    target = 'ble:$target';
  }
  if (target.startsWith('ble:')) target = target.toLowerCase();
  final known = e.key != ContextKeys.bleDiscovery;
  final advName = outer['adv_name']?.toString();
  return (observer, target, rssi, known, advName);
}

class BleRelation {
  const BleRelation({
    required this.observer,
    required this.target,
    required this.rssiDbm,
    required this.timestamp,
    this.count = 1,
    this.confidence,
    this.rssiWindow = const [],
    this.known = true,
    this.advName,
    this.modality = 'BLE',
    this.componentId = '',
  });

  final String observer;
  final String target;
  final double rssiDbm;
  final double timestamp;
  final int count;
  final double? confidence;

  /// Recent RSSI samples for this edge (oldest→newest, ≤12).
  final List<double> rssiWindow;

  /// False for unenrolled advertisers (ble.discovery.v1 / anonymous
  /// node subjects) — the map renders them as unknowns.
  final bool known;
  final String? advName;
  final String modality;
  final String componentId;

  /// Age in seconds — freshness coloring on the graph edge.
  double get ageSeconds =>
      DateTime.now().millisecondsSinceEpoch / 1000 - timestamp;

  /// RSSI spread across the window — > 4 dB means the radio link is
  /// physically changing (someone/something moved). Honest label: it's
  /// signal variance, not a motion classifier.
  bool get moving {
    if (rssiWindow.length < 3) return false;
    final lo = rssiWindow.reduce(math.min);
    final hi = rssiWindow.reduce(math.max);
    return hi - lo > 4;
  }

  double get rssiSpreadDb => rssiWindow.length < 2
      ? 0
      : rssiWindow.reduce(math.max) - rssiWindow.reduce(math.min);

  BleRelation copyWith({int? count}) => BleRelation(
      observer: observer,
      target: target,
      rssiDbm: rssiDbm,
      timestamp: timestamp,
      count: count ?? this.count,
      confidence: confidence,
      rssiWindow: rssiWindow,
      known: known,
      advName: advName,
      modality: modality,
      componentId: componentId,);
}

/// One GPS fix from ``location.geo.v1`` evidence.
class GeoFix {
  const GeoFix(this.lat, this.lon, this.ts, {this.accM, this.speedMps});
  final double lat, lon, ts;
  final double? accM, speedMps;
}

/// Recent GPS breadcrumbs per GPS-capable source — ``location.geo.v1``
/// evidence grouped by device uuid (falling back to source id). The fleet
/// map draws one polyline + head pin per entry.
final geoTracesProvider =
    StreamProvider.autoDispose<Map<String, List<GeoFix>>>((ref) async* {
  final repo = ref.watch(contextRepoProvider);
  for (;;) {
    final since =
        (DateTime.now().millisecondsSinceEpoch - 12 * 3600 * 1000) / 1000.0;
    Map<String, List<GeoFix>> out = const {};
    try {
      final rows = await repo.evidence(
        key: ContextKeys.geoEvidence,
        since: since,
        limit: 2000,
      );
      final grouped = <String, List<GeoFix>>{};
      for (final e in rows) {
        final v = e.value is Map ? Map<String, dynamic>.from(e.value) : null;
        if (v == null) continue;
        final lat = (v['lat'] as num?)?.toDouble();
        final lon = (v['lon'] as num?)?.toDouble();
        if (lat == null || lon == null || !lat.isFinite || !lon.isFinite) {
          continue;
        }
        final id = e.deviceId ?? e.sourceId ?? 'unknown';
        grouped
            .putIfAbsent(id, () => [])
            .add(GeoFix(lat, lon, e.timestamp ?? 0,
                accM: (v['acc_m'] as num?)?.toDouble(),
                speedMps: (v['speed_mps'] as num?)?.toDouble()));
      }
      for (final l in grouped.values) {
        l.sort((a, b) => a.ts.compareTo(b.ts));
      }
      out = grouped;
    } catch (_) {/* evidence may be unavailable — keep last frame */}
    yield out;
    await Future<void>.delayed(_pollCadence);
  }
});

/// Owned devices (for claim/space pickers in setup).
final deviceListProvider = devicesProvider;
