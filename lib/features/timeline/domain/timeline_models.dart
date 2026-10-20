import '../../context/domain/models.dart';

/// One whispy `Prediction` as it crosses the wire — emitted by any model
/// (rule / torchscript / fusion / builtin discriminator) on a node, the
/// phone, or a laptop, and fan-fanned to Brain as a `prediction` event.
class TimelinePrediction {
  const TimelinePrediction({
    required this.deviceId,
    required this.runtimeModelId,
    required this.task,
    required this.timestamp,
    required this.label,
    this.confidence,
    this.scores = const {},
    this.peopleCount,
    this.metadata = const {},
    this.previousLabel,
  });

  final String deviceId;
  final String runtimeModelId;
  final String task;
  final double timestamp;
  final String label;
  final double? confidence;
  final Map<String, double> scores;
  final int? peopleCount;
  final Map<String, dynamic> metadata;
  final String? previousLabel;

  bool get isBuiltin => runtimeModelId.startsWith('builtin:');

  /// Short model name for chips — `builtin:occupancy-radar` → `occupancy-radar`.
  String get shortModel => runtimeModelId.startsWith('builtin:')
      ? runtimeModelId.substring(8)
      : runtimeModelId;

  factory TimelinePrediction.fromEvent(Map<String, dynamic> e) {
    final data = e['data'] is Map
        ? Map<String, dynamic>.from(e['data'] as Map)
        : const <String, dynamic>{};
    final scores = <String, double>{};
    if (data['scores'] is Map) {
      (data['scores'] as Map).forEach((k, v) {
        final n = v is num ? v.toDouble() : double.tryParse('$v');
        if (n != null) scores['$k'] = n;
      });
    }
    double ts = 0;
    final rawTs = data['timestamp'] ?? e['ts'];
    if (rawTs is num) ts = rawTs.toDouble();
    return TimelinePrediction(
      deviceId: '${e['device_id'] ?? data['device_id'] ?? ''}',
      runtimeModelId:
          '${data['runtime_model_id'] ?? data['model_id'] ?? ''}',
      task: '${data['task'] ?? ''}',
      timestamp: ts,
      label: '${data['label'] ?? ''}',
      confidence: (data['confidence'] as num?)?.toDouble(),
      scores: scores,
      peopleCount: (data['people_count'] as num?)?.toInt(),
      metadata: data['metadata'] is Map
          ? Map<String, dynamic>.from(data['metadata'] as Map)
          : const {},
      previousLabel: data['previous_label']?.toString(),
    );
  }
}

/// A model in the Brain registry (`GET /v1/models`).
class TimelineModel {
  const TimelineModel({
    required this.id,
    required this.name,
    this.processor = 'torchscript',
    this.sensor,
    this.task,
    this.visibility = 'private',
    this.manifest,
  });

  final String id;
  final String name;
  final String processor;
  final String? sensor;
  final String? task;
  final String visibility;
  final Map<String, dynamic>? manifest;

  factory TimelineModel.fromJson(Map<String, dynamic> j) => TimelineModel(
        id: '${j['id'] ?? ''}',
        name: '${j['name'] ?? j['id'] ?? ''}',
        processor: '${j['processor'] ?? 'torchscript'}',
        sensor: j['sensor']?.toString(),
        task: j['task']?.toString(),
        visibility: '${j['visibility'] ?? 'private'}',
        manifest:
            j['manifest'] is Map ? Map<String, dynamic>.from(j['manifest']) : null,
      );
}

/// A model→device deployment (`GET /v1/deployments`).
class TimelineDeployment {
  const TimelineDeployment({
    required this.deploymentId,
    required this.deviceId,
    required this.modelId,
    required this.state,
    this.runtimeModelId = '',
    this.failure,
  });

  final String deploymentId;
  final String deviceId;
  final String modelId;
  final String state; // queued|received|validated|installed|acknowledged|active|failed|declined
  final String runtimeModelId;
  final Map<String, dynamic>? failure;

  bool get active => state == 'active';
  bool get failed => state == 'failed';
  bool get pending =>
      state == 'queued' ||
      state == 'received' ||
      state == 'validated' ||
      state == 'installed' ||
      state == 'acknowledged';

  factory TimelineDeployment.fromJson(Map<String, dynamic> j) =>
      TimelineDeployment(
        deploymentId: '${j['deployment_id'] ?? ''}',
        deviceId: '${j['device_id'] ?? ''}',
        modelId: '${j['model_id'] ?? ''}',
        state: '${j['state'] ?? 'queued'}',
        runtimeModelId: '${j['runtime_model_id'] ?? ''}',
        failure:
            j['failure'] is Map ? Map<String, dynamic>.from(j['failure']) : null,
      );
}

/// Per-second cell of the current in-flight minute (live-chunks).
class LiveSecond {
  const LiveSecond({required this.index, this.status = '', this.occupied});

  final int index;
  final String status; // waiting|collecting|stored|error
  final bool? occupied;
}

/// The current minute being captured on a device.
class LiveMinute {
  const LiveMinute({
    required this.deviceId,
    required this.minute,
    this.seconds = const [],
    this.labels = const [],
    this.predictions = const [],
  });

  final String deviceId;
  final String minute; // YYYYMMDD_HHMM
  final List<LiveSecond> seconds;
  final List<String> labels;
  final List<TimelinePrediction> predictions;
}

/// Everything we know about one minute of the user's day.
class MinuteBucket {
  MinuteBucket({required this.start});

  final DateTime start;
  final List<ContextEvent> events = [];
  final List<TimelinePrediction> predictions = [];
  final List<ContextEvidence> descriptors = [];
  final List<MinuteNodeEntry> nodeEntries = [];

  /// Latest `occupied` verdict per device id within the minute.
  final Map<String, bool?> occupancy = {};

  /// Latest zone per device id (`location.zone.v1` value.zone).
  final Map<String, String> zones = {};

  /// Motion verdicts (`moving`/`stationary`) seen this minute.
  final Set<String> activities = {};

  bool get isEmpty =>
      events.isEmpty &&
      predictions.isEmpty &&
      descriptors.isEmpty &&
      nodeEntries.isEmpty;

  /// Latest scene text emitted by a node's context descriptor this minute.
  String? get scene {
    for (final d in descriptors) {
      final v = d.value;
      if (v is Map && v['scene'] != null && '${v['scene']}'.isNotEmpty) {
        return '${v['scene']}';
      }
    }
    return null;
  }

  /// Distinct runtimes that produced predictions this minute.
  Set<String> get runtimes =>
      predictions.map((p) => p.runtimeModelId).where((s) => s.isNotEmpty).toSet();

  /// Distinct device ids contributing anything this minute.
  Set<String> get devices => {
        ...occupancy.keys,
        ...zones.keys,
        ...predictions.map((p) => p.deviceId),
        ...descriptors.map((d) => d.deviceId ?? ''),
        ...nodeEntries.map((e) => e.deviceId),
      }..remove('');

  /// Dominant occupancy across devices: occupied if any device saw occupied.
  bool? get occupied {
    if (occupancy.isEmpty) return null;
    if (occupancy.values.any((v) => v == true)) return true;
    if (occupancy.values.every((v) => v == false)) return false;
    return null;
  }

  double get meanConfidence {
    final cs = predictions
        .map((p) => p.confidence)
        .whereType<double>()
        .toList(growable: false);
    if (cs.isEmpty) return 0;
    return cs.reduce((a, b) => a + b) / cs.length;
  }
}

/// A node-side minute summary pulled through the Brain relay
/// (`/api/v1/minutes`) — fills gaps where predictions never reached Brain.
class MinuteNodeEntry {
  const MinuteNodeEntry({
    required this.deviceId,
    required this.minuteId,
    this.predictionCount = 0,
    this.labels = const [],
    this.predictions = const [],
  });

  final String deviceId;
  final String minuteId;
  final int predictionCount;
  final List<String> labels;
  final List<TimelinePrediction> predictions;
}

/// The assembled feed for the timeline page.
class TimelineFeed {
  const TimelineFeed({
    required this.minutes,
    required this.states,
    required this.models,
    required this.deployments,
    required this.live,
    required this.generatedAt,
    this.deviceNames = const {},
    this.errors = const [],
  });

  /// Minutes with content, newest first.
  final List<MinuteBucket> minutes;
  final List<ContextState> states;
  final List<TimelineModel> models;
  final List<TimelineDeployment> deployments;

  /// device_uuid → in-flight minute (only the freshest minute is kept by Brain).
  final Map<String, LiveMinute> live;
  final DateTime generatedAt;

  /// device_uuid → display name (from /api/device/list).
  final Map<String, String> deviceNames;
  final List<String> errors;

  String deviceName(String id) => deviceNames[id] ?? shortId(id);

  static String shortId(String id) =>
      id.length > 8 ? '${id.substring(0, 8)}…' : id;

  /// Latest live scene text across nodes.
  String? get currentScene {
    for (final m in minutes) {
      final s = m.scene;
      if (s != null) return s;
    }
    return null;
  }

  /// Active deployments grouped by device.
  Map<String, List<TimelineDeployment>> get deploymentsByDevice {
    final out = <String, List<TimelineDeployment>>{};
    for (final d in deployments) {
      out.putIfAbsent(d.deviceId, () => []).add(d);
    }
    return out;
  }
}
