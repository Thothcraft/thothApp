import 'dart:async';

import '../../../core/api/brain_client.dart';
import '../../../core/api/node_client.dart';
import '../../context/domain/models.dart';
import '../domain/timeline_models.dart';

/// Aggregates everything the timeline renders: context transitions,
/// raw prediction events, per-node minute manifests (via the Brain WS
/// relay), the model registry + deployments, and the in-flight minute
/// each device is capturing right now.
class TimelineRepository {
  TimelineRepository()
      : _brain = BrainClient.instance,
        _nodes = NodeClient.instance;

  final BrainClient _brain;
  final NodeClient _nodes;

  /// How far back the timeline reaches.
  static const defaultHours = 8;

  Future<TimelineFeed> feed({int hours = defaultHours}) async {
    final now = DateTime.now();
    final t0 =
        now.subtract(Duration(hours: hours)).millisecondsSinceEpoch / 1000.0;
    final errors = <String>[];

    Future<T> guard<T>(String what, Future<T> f, T fallback) async {
      try {
        return await f;
      } catch (e) {
        errors.add('$what: $e');
        return fallback;
      }
    }

    final results = await Future.wait([
      guard(
          'events',
          _brain.getV1('/context/events',
              params: {'since': t0, 'limit': 1000}),
          const <String, dynamic>{}),
      guard(
          'predictions',
          _brain.getV1('/events',
              params: {'kind': 'prediction', 'since_ts': t0, 'limit': 500}),
          const <String, dynamic>{}),
      guard(
          'descriptors',
          _brain.getV1('/context/evidence', params: {
            'key': 'context.descriptors.v1',
            'since': t0,
            'limit': 1000,
          }),
          const <String, dynamic>{}),
      guard('states', _brain.getV1('/context/state'),
          const <String, dynamic>{}),
      guard(
          'models', _brain.getV1('/models'), const <String, dynamic>{}),
      guard('deployments', _brain.getV1('/deployments'),
          const <String, dynamic>{}),
      guard('live', _brain.getJson('/device/live-chunks'),
          const <String, dynamic>{}),
      guard(
          'devices',
          _brain.getJson('/device/list', params: {'include_offline': true}),
          const <String, dynamic>{}),
    ]);

    final ctxEvents = ((results[0]['events'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ContextEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final predictions = ((results[1]['events'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) =>
            TimelinePrediction.fromEvent(Map<String, dynamic>.from(e)))
        .where((p) => p.timestamp > 0)
        .toList();
    final descriptors = ((results[2]['evidence'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ContextEvidence.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final states = ((results[3]['states'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => ContextState.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final models = ((results[4]['models'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => TimelineModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final deployments = ((results[5]['deployments'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) =>
            TimelineDeployment.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final deviceNames = <String, String>{};
    final nodeIds = <String>[];
    for (final d
        in ((results[7]['devices'] as List?) ?? const []).whereType<Map>()) {
      final uuid = '${d['device_uuid'] ?? d['device_id'] ?? ''}';
      if (uuid.isEmpty) continue;
      deviceNames[uuid] = '${d['device_name'] ?? d['name'] ?? uuid}';
      final type = '${d['device_type'] ?? ''}';
      final online = d['online'] == true || d['is_online'] == true;
      if (online && (type.isEmpty || type == 'thoth' || type == 'unknown')) {
        nodeIds.add(uuid);
      }
    }
    final live = _parseLive(results[6]);

    // Pull each online node's on-disk minute list through the Brain relay —
    // fills history the context feed missed (predictions that never changed
    // label, minutes held only on the node).
    final nodeMinutes = await Future.wait(nodeIds
        .map((id) => guard(
            'node $id',
            _nodes.get(id, '/api/v1/minutes')
                .timeout(const Duration(seconds: 6)),
            const <dynamic, dynamic>{}))
        .toList());
    final nodeEntries = <MinuteNodeEntry>[];
    for (var i = 0; i < nodeIds.length; i++) {
      final res = nodeMinutes[i];
      final list = res is Map
          ? (res['minutes'] as List? ?? const [])
          : (res is List ? res : const []);
      for (final m in list.whereType<Map>()) {
        final entry = _nodeEntry(nodeIds[i], Map<String, dynamic>.from(m));
        if (entry != null) nodeEntries.add(entry);
      }
    }

    final buckets = <int, MinuteBucket>{};
    MinuteBucket bucketFor(double tsSeconds) {
      final start = DateTime.fromMillisecondsSinceEpoch(
          (tsSeconds * 1000).floor() ~/ 60000 * 60000);
      return buckets.putIfAbsent(
          start.millisecondsSinceEpoch, () => MinuteBucket(start: start));
    }

    for (final e in ctxEvents) {
      final ts = e.timestamp;
      if (ts == null) continue;
      final b = bucketFor(ts);
      b.events.add(e);
      _applyStateEvent(b, e);
    }
    for (final p in predictions) {
      final b = bucketFor(p.timestamp);
      b.predictions.add(p);
      if (p.task == 'occupancy') {
        b.occupancy[p.deviceId] = _labelOccupied(p.label);
      }
    }
    for (final d in descriptors) {
      final ts = d.timestamp;
      if (ts == null) continue;
      bucketFor(ts).descriptors.add(d);
    }
    for (final e in nodeEntries) {
      final start = _minuteStart(e.minuteId);
      if (start == null) continue;
      final b = buckets.putIfAbsent(start.millisecondsSinceEpoch,
          () => MinuteBucket(start: start));
      b.nodeEntries.add(e);
      b.predictions.addAll(e.predictions);
      for (final p in e.predictions) {
        if (p.task == 'occupancy') {
          b.occupancy[p.deviceId] = _labelOccupied(p.label);
        }
      }
    }

    final minutes = buckets.values.where((b) => !b.isEmpty).toList()
      ..sort((a, b) => b.start.compareTo(a.start));

    return TimelineFeed(
      minutes: minutes,
      states: states,
      models: models,
      deployments: deployments,
      live: live,
      generatedAt: now,
      deviceNames: deviceNames,
      errors: errors,
    );
  }

  Map<String, LiveMinute> _parseLive(Map<String, dynamic> res) {
    final out = <String, LiveMinute>{};
    final devices = res['devices'];
    if (devices is! Map) return out;
    devices.forEach((uuid, raw) {
      if (raw is! Map) return;
      final m = Map<String, dynamic>.from(raw);
      final seconds = <LiveSecond>[];
      for (final s in (m['seconds'] as List? ?? const []).whereType<Map>()) {
        seconds.add(LiveSecond(
          index: (s['second_index'] as num?)?.toInt() ??
              (s['index'] as num?)?.toInt() ??
              seconds.length,
          status: '${s['status'] ?? ''}',
          occupied: s['occupied'] is bool ? s['occupied'] as bool : null,
        ));
      }
      final preds = <TimelinePrediction>[];
      for (final c in (m['chunks'] as List? ?? const []).whereType<Map>()) {
        final mp = c['model_predictions'];
        if (mp is List) {
          for (final p in mp.whereType<Map>()) {
            final j = Map<String, dynamic>.from(p);
            preds.add(TimelinePrediction(
              deviceId: '$uuid',
              runtimeModelId:
                  '${j['runtime_model_id'] ?? j['model_id'] ?? ''}',
              task: '${j['task'] ?? ''}',
              timestamp: (j['timestamp'] as num?)?.toDouble() ?? 0,
              label: '${j['label'] ?? j['class'] ?? ''}',
              confidence: (j['confidence'] as num?)?.toDouble(),
            ));
          }
        }
      }
      out['$uuid'] = LiveMinute(
        deviceId: '$uuid',
        minute: '${m['minute'] ?? ''}',
        seconds: seconds,
        labels: (m['labels'] as List? ?? const []).map((e) => '$e').toList(),
        predictions: preds,
      );
    });
    return out;
  }

  MinuteNodeEntry? _nodeEntry(String deviceId, Map<String, dynamic> m) {
    final minuteId = '${m['minute_id'] ?? m['id'] ?? ''}';
    if (minuteId.isEmpty) return null;
    final preds = <TimelinePrediction>[];
    for (final p
        in (m['predictions'] as List? ?? const []).whereType<Map>()) {
      final j = Map<String, dynamic>.from(p);
      preds.add(TimelinePrediction(
        deviceId: '${j['device_id'] ?? deviceId}',
        runtimeModelId:
            '${j['runtime_model_id'] ?? j['model_id'] ?? ''}',
        task: '${j['task'] ?? ''}',
        timestamp: (j['timestamp'] as num?)?.toDouble() ??
            (_minuteStart(minuteId)?.millisecondsSinceEpoch ?? 0) / 1000.0,
        label: '${j['label'] ?? j['class'] ?? ''}',
        confidence: (j['confidence'] as num?)?.toDouble(),
        peopleCount: (j['people_count'] as num?)?.toInt(),
      ));
    }
    final labels = (m['labels'] as List? ?? const []).map((e) => '$e').toList();
    return MinuteNodeEntry(
      deviceId: deviceId,
      minuteId: minuteId,
      predictionCount:
          (m['prediction_count'] as num?)?.toInt() ?? preds.length,
      labels: labels,
      predictions: preds,
    );
  }

  /// `YYYYMMDD_HHMM` → DateTime (local).
  static DateTime? _minuteStart(String id) {
    final m =
        RegExp(r'^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})$').firstMatch(id);
    if (m == null) return null;
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!),
        int.parse(m[4]!), int.parse(m[5]!));
  }

  void _applyStateEvent(MinuteBucket b, ContextEvent e) {
    switch (e.key) {
      case 'occupancy.v1':
        final dev = e.entityId ?? '';
        if (dev.isEmpty) return;
        final v = e.value;
        if (v is Map) {
          b.occupancy[dev] =
              v['occupied'] is bool ? v['occupied'] as bool : null;
        } else {
          b.occupancy[dev] = _labelOccupied('$v');
        }
      case 'location.zone.v1':
        final dev = e.entityId ?? '';
        final v = e.value;
        if (dev.isNotEmpty && v is Map && v['zone'] != null) {
          b.zones[dev] = '${v['zone']}';
        }
      case 'activity.motion.v1':
        final v = e.value;
        final motion = v is Map ? '${v['motion'] ?? ''}' : '$v';
        if (motion.isNotEmpty) b.activities.add(motion);
      case 'prediction':
        final dev = e.entityId ?? '';
        if (dev.isNotEmpty) {
          b.predictions.add(TimelinePrediction(
            deviceId: dev,
            runtimeModelId: '${e.provenance['estimator'] ?? ''}',
            task: '',
            timestamp: e.timestamp ?? 0,
            label: '${
                e.value is Map ? (e.value['label'] ?? e.value) : e.value}',
            confidence: e.confidence,
            previousLabel: e.previousValue is Map
                ? '${e.previousValue['label'] ?? e.previousValue}'
                : '${e.previousValue ?? ''}',
          ));
        }
    }
  }

  static bool? _labelOccupied(String label) {
    const positive = {
      'occupied', 'present', 'presence', 'person', 'human',
      'motion', 'activity', 'face', 'noisy', 'moving',
    };
    const negative = {
      'empty', 'absent', 'vacant', 'unoccupied', 'clear',
      'none', 'background', 'still', 'quiet', 'away', 'no_person',
      'no_face', 'stationary',
    };
    final l = label.toLowerCase();
    if (positive.contains(l)) return true;
    if (negative.contains(l)) return false;
    return null;
  }

  /// Queue a model deployment to a device (Brain pushes it down the
  /// node WS; the node's DeploymentManager installs + activates it).
  Future<TimelineDeployment> deploy(
      {required String modelId, required String deviceId}) async {
    final res = await _brain.postV1('/deployments',
        body: {'model_id': modelId, 'device_id': deviceId});
    final j = res['deployment'] is Map ? res['deployment'] as Map : res;
    return TimelineDeployment.fromJson(Map<String, dynamic>.from(j));
  }

  /// Toggle an installed runtime model on a node (local API via relay).
  Future<void> setModelActive(String deviceId, String runtimeModelId,
      {required bool active}) async {
    await _nodes.post(deviceId, '/api/models/activate',
        body: {'runtime_model_id': runtimeModelId, 'active': active});
  }

  /// Full minute manifest from a node (`/api/v1/minutes/<id>`).
  Future<Map<String, dynamic>> nodeMinute(
      String deviceId, String minuteId) async {
    final res = await _nodes.get(deviceId, '/api/v1/minutes/$minuteId')
        .timeout(const Duration(seconds: 8));
    return res is Map ? Map<String, dynamic>.from(res) : const {};
  }
}
