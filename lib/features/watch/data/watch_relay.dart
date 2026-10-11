import 'dart:async';
import 'dart:convert';
import 'dart:math' show pow;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/brain_client.dart';
import '../domain/pinetime_gatt.dart';
import 'watch_link.dart';
import 'watch_store.dart';

/// Brain-side sensor ids the watch relays under — surfaced on
/// ``/v1/devices/{id}/streams/{sensor_id}``.
const kWatchSensorMotion = 'pinetime-motion';
const kWatchSensorHr = 'pinetime-hr';
const kWatchSensorSteps = 'pinetime-steps';
const kWatchSensorBattery = 'pinetime-battery';
const kWatchSensorProx = 'pinetime-prox'; // BLE RSSI → phone proximity
const kWatchSensorGps = 'pinetime-gps';   // phone GPS trace

/// Gateway: PineTime (BLE) ⇄ Brain (HTTPS).
///
/// For each paired [WatchRecord] it owns a [WatchLink], buffers decoded
/// telemetry into 10-second live-chunks (``SensorSampleV1`` arrays —
/// whitelisted upstream), heartbeats the watch's device JWT, and drains
/// ``pending_commands`` into typed GATT writes before acking.
class WatchRelay {
  WatchRelay(this.record);

  final WatchRecord record;
  WatchLink? _link;

  final _telemetryOut = StreamController<WatchTelemetry>.broadcast();
  final List<WatchTelemetry> _buffer = [];
  final List<String> _seenEvents = [];

  Timer? _flushTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<WatchTelemetry>? _telemetrySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  // ── context-state producers (rules + assistant read these) ─────────
  // watch.link.v1    {connected, rssi}        — link up/down
  // proximity.v1     {distance_m, rssi}       — watch↔phone BLE range
  // watch.worn.v1    {worn, acc_std, n}       — IMU-variance heuristic
  bool? _worn;
  double? _lastProxPushM;
  double _lastProxPushAt = 0;

  String get _watchEntity => 'device:${record.deviceUuid}';

  /// Upsert one context state for this watch — user-scoped, so it
  /// lands on the same /v1/context surface rules and the assistant
  /// read. Fire-and-forget: offline → skip silently.
  void _pushState(String key, Map<String, dynamic> value,
      {String? transition,}) {
    final client = BrainClient.instance;
    if (!client.hasToken) return;
    unawaited(client.postV1('/context/state', body: {
      'key': key,
      'entity_id': _watchEntity,
      'value': value,
      'estimator': 'thoth-app-watch-relay',
      if (transition != null) 'transition': transition,
    }).then<void>((_) {}).catchError(
        (Object e) => debugPrint('[watch-relay] state $key: $e'),),);
  }

  int _seq = 0;
  int? _battery;
  int? _steps;
  int? _heartRate;
  int? _rssi;
  String? _firmware;
  String? _lastError;
  bool _running = false;

  WatchLink? get link => _link;
  int? get battery => _battery;
  int? get steps => _steps;
  int? get heartRate => _heartRate;
  int? get rssi => _rssi;
  /// Free-space path-loss estimate in meters (Tx −59 dBm @1 m, n = 2).
  double? get proximityM =>
      _rssi == null ? null : pow(10, (-59 - _rssi!) / 20).toDouble();
  String? get firmware => _firmware;
  String? get lastError => _lastError;

  // Diagnostics — prove the pipeline stayed alive with the screen off.
  int _chunksSent = 0;
  int _chunksFailed = 0;
  int get bufferedSamples => _buffer.length;
  int get chunksSent => _chunksSent;
  int get chunksFailed => _chunksFailed;

  Stream<WatchTelemetry> get telemetry => _telemetryOut.stream;
  bool get connected => _link?.device.isConnected ?? false;

  /// DNS-namespace uuid5 of the BLE id — identical to Brain's
  /// ``_normalized_device_uuid`` for non-UUID ids.
  static String deviceUuidFor(String bleId) =>
      const Uuid().v5(Namespace.dns.value, bleId);

  /// One-shot pairing: start a session, claim the code as the signed-in
  /// user, exchange the pairing secret for the watch's device JWT.
  /// Returns the completed [WatchRecord].
  static Future<WatchRecord> pair(String bleId, {String? name}) async {
    final client = BrainClient.instance;
    final deviceUuid = deviceUuidFor(bleId);
    final start = await client.devicePairingStart(
      deviceId: bleId,
      deviceName: name ?? 'PineTime',
      deviceType: 'pinetime',
      hardwareInfo: {
        'transport': 'ble',
        'gateway': 'thoth-app',
        'capabilities': {'motion': true, 'hr': true, 'steps': true, 'battery': true},
      },
    );
    final code = start['code'] as String?;
    final secret = start['pairing_secret'] as String?;
    if (code == null || secret == null) {
      throw StateError('pairing/start returned no code or secret');
    }
    // Same-account claim — the app user IS the owner; no code entry needed.
    await client.postJson('/device/pairing/claim', body: {'code': code});
    // Exchange the secret for the device-scoped JWT.
    final status = await client.devicePairingStatus(bleId, secret);
    if (status['status'] != 'paired') {
      throw StateError('pairing did not complete: ${status['status']}');
    }
    return WatchRecord(
      bleId: bleId,
      deviceUuid: deviceUuid,
      name: name ?? 'PineTime',
      deviceToken: status['access_token'] as String?,
    );
  }

  Future<void> start(WatchLink link) async {
    if (_running) return;
    _running = true;
    _link = link;
    _telemetrySub = link.telemetry.listen(_onTelemetry);
    // Link state transitions drive the watch.link.v1 context state —
    // the automation edge-trigger depends on this being pushed on BOTH
    // edges, not just connect.
    _connSub = link.connection.listen((s) {
      final connected = s == BluetoothConnectionState.connected;
      _pushState('watch.link.v1', {
        'connected': connected,
        if (_rssi != null) 'rssi': _rssi,
      }, transition: connected ? 'enter' : 'exit',);
      if (!connected) {
        _worn = null; // link-down → unknown, not "unworn"
      }
    });
    // Flush every 10 s — one live-chunk post keeps streams + online fresh.
    _flushTimer = Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_flush()));
    // Watch heartbeat carries pending_commands — 30 s cadence keeps the
    // command latency acceptable without spamming.
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_heartbeat()));
    unawaited(_heartbeat());
  }

  /// Inject phone-side telemetry (BLE RSSI, GPS) into the same stream →
  /// the samples ride the watch's live-chunks under prox/gps sensor ids.
  void addLocal(WatchTelemetry t) => _onTelemetry(t);

  void _onTelemetry(WatchTelemetry t) {
    _telemetryOut.add(t);
    _battery = t.battery ?? _battery;
    _steps = t.steps ?? _steps;
    _heartRate = t.heartRate ?? _heartRate;
    _rssi = t.rssi ?? _rssi;
    if (t.event != null) {
      if (t.event!.startsWith('info:firmware=')) {
        _firmware = t.event!.substring('info:firmware='.length);
      } else {
        _seenEvents.insert(0, t.event!);
        if (_seenEvents.length > 50) _seenEvents.removeLast();
      }
    }
    if (t.motion != null ||
        t.heartRate != null ||
        t.steps != null ||
        t.battery != null ||
        t.rssi != null ||
        t.lat != null) {
      _buffer.add(t);
    }
  }

  List<String> get recentEvents => List.unmodifiable(_seenEvents);

  /// SensorSampleV1 — Brain's chunk_to_samples expects ``timestamp`` as
  /// epoch seconds (float) and ``units`` as a map, not a bare string.
  Map<String, dynamic> _toSample(WatchTelemetry t) {
    final ts = (t.motion?.at ?? DateTime.now().toUtc())
            .millisecondsSinceEpoch /
        1000.0;
    if (t.motion != null) {
      final m = t.motion!;
      return {
        'sensor_id': kWatchSensorMotion,
        'sensor_type': 'imu',
        'timestamp': ts,
        'sequence': m.seq ?? _seq++,
        'payload': {
          'acc_x': m.x,
          'acc_y': m.y,
          'acc_z': m.z,
          if (m.tickMs != null) 'tick_ms': m.tickMs,
        },
        'units': {'acc_x': 'g', 'acc_y': 'g', 'acc_z': 'g', 'tick_ms': 'ms'},
      };
    }
    if (t.heartRate != null) {
      return {
        'sensor_id': kWatchSensorHr,
        'sensor_type': 'heart_rate',
        'timestamp': ts,
        'sequence': _seq++,
        'payload': {'bpm': t.heartRate},
        'units': {'bpm': 'bpm'},
      };
    }
    if (t.steps != null) {
      return {
        'sensor_id': kWatchSensorSteps,
        'sensor_type': 'steps',
        'timestamp': ts,
        'sequence': _seq++,
        'payload': {'count': t.steps},
        'units': {'count': 'steps'},
      };
    }
    if (t.lat != null) {
      return {
        'sensor_id': kWatchSensorGps,
        'sensor_type': 'gps',
        'timestamp': ts,
        'sequence': _seq++,
        'payload': {
          'lat': t.lat,
          'lon': t.lon,
          if (t.accuracyM != null) 'acc_m': t.accuracyM,
          if (t.speedMps != null) 'speed_mps': t.speedMps,
          if (t.rssi != null) 'rssi': t.rssi,
        },
        'units': {'lat': 'deg', 'lon': 'deg', 'acc_m': 'm',
            'speed_mps': 'm/s', 'rssi': 'dBm',},
      };
    }
    if (t.rssi != null) {
      return {
        'sensor_id': kWatchSensorProx,
        'sensor_type': 'rssi',
        'timestamp': ts,
        'sequence': _seq++,
        'payload': {
          'rssi': t.rssi,
          'est_m': t.rssi == null
              ? null
              : pow(10, (-59 - t.rssi!) / 20).toDouble(),
        },
        'units': {'rssi': 'dBm', 'est_m': 'm'},
      };
    }
    return {
      'sensor_id': kWatchSensorBattery,
      'sensor_type': 'battery',
      'timestamp': ts,
      'sequence': _seq++,
      'payload': {'percent': t.battery},
      'units': {'percent': '%'},
    };
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty || !BrainClient.instance.hasToken) return;
    final pending = List<WatchTelemetry>.from(_buffer);
    _buffer.clear();
    _flushStates(pending);
    final now = DateTime.now().toUtc();
    try {
      await BrainClient.instance.uploadLiveChunk(record.deviceUuid, {
        'minute': DateFormat('yyyyMMdd_HHmm').format(now),
        'second_index': now.second,
        'chunk_frames': pending.length,
        'status': 'collecting',
        'captured_at': now.toIso8601String(),
        'samples': pending.map(_toSample).toList(),
      });
      _lastError = null;
      _chunksSent++;
    } catch (e) {
      // Requeue the batch once — the link is still streaming either way.
      _buffer.insertAll(0, pending);
      _lastError = '$e';
      _chunksFailed++;
      debugPrint('[watch-relay] chunk upload failed: $e');
    }
  }

  /// Derive + publish context states from the flushed window —
  /// proximity (path-loss estimate) and worn/unworn (IMU variance with
  /// hysteresis). Cheap on the wire: proximity only moves on ≥0.5 m
  /// drift or 60 s stale; worn only flips on classification change.
  void _flushStates(List<WatchTelemetry> window) {
    // proximity — free-space path-loss, same model the stream payload uses.
    final rssi = _rssi;
    if (rssi != null) {
      final m = pow(10, (-59 - rssi) / 20).toDouble();
      final nowS = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final moved = _lastProxPushM == null ||
          (m - _lastProxPushM!).abs() >= 0.5;
      if (moved || nowS - _lastProxPushAt >= 60) {
        _lastProxPushM = m;
        _lastProxPushAt = nowS;
        _pushState('proximity.v1', {
          'distance_m': double.parse(m.toStringAsFixed(2)),
          'rssi': rssi,
        });
      }
    }

    // worn — std of accel over the window. A resting watch on a desk
    // sits at ~zero variance; a worn wrist never does. Hysteresis
    // keeps a wrist-held-still from flickering to "unworn".
    final motions =
        [for (final t in window) if (t.motion != null) t.motion!];
    if (motions.length >= 10) {
      double std(List<double> xs) {
        final mean = xs.reduce((a, b) => a + b) / xs.length;
        final v = xs.fold<double>(0, (s, x) => s + (x - mean) * (x - mean)) /
            xs.length;
        return v <= 0 ? 0.0 : pow(v, 0.5).toDouble();
      }
      final sx = std([for (final m in motions) m.x]);
      final sy = std([for (final m in motions) m.y]);
      final sz = std([for (final m in motions) m.z]);
      final accStd = double.parse(
          ((sx + sy + sz) / 3).toStringAsFixed(4),);
      final bool worn;
      if (accStd >= 0.02) {
        worn = true;
      } else if (accStd <= 0.008) {
        worn = false;
      } else {
        worn = _worn ?? false;
      }
      if (_worn != worn) {
        _worn = worn;
        _pushState('watch.worn.v1', {
          'worn': worn,
          'acc_std': accStd,
          'n': motions.length,
        }, transition: worn ? 'enter' : 'exit',);
      }
    }
  }

  /// Watch-side heartbeat: device-JWT bearer, drains pending_commands into
  /// typed GATT writes, then acks each one.
  Future<void> _heartbeat() async {
    final token = record.deviceToken;
    if (token == null || token.isEmpty) return;
    try {
      final res = await BrainClient.instance.deviceHeartbeat(token, {
        'device_id': record.deviceUuid,
        'device_name': record.name ?? 'PineTime',
        'device_type': 'pinetime',
        'battery_level': _battery,
        'online': true,
        'capabilities': {
          'motion': true, 'hr': true, 'steps': true, 'battery': true,
          'prox': true, 'gps': true,
        },
        'hardware_info': {
          'firmware': _firmware,
          'transport': 'ble',
          'ble_id': record.bleId,
          'gateway': 'thoth-app',
          // {id,type} dicts — bare strings get re-keyed to `<name>-0` by
          // Brain's sensors_from_hardware and lose the stream ids.
          'sensors': [
            {'id': kWatchSensorMotion, 'type': 'imu'},
            {'id': kWatchSensorHr, 'type': 'heart_rate'},
            {'id': kWatchSensorSteps, 'type': 'steps'},
            {'id': kWatchSensorBattery, 'type': 'battery'},
            {'id': kWatchSensorProx, 'type': 'rssi'},
            {'id': kWatchSensorGps, 'type': 'gps'},
          ],
        },
      });
      _lastError = null;
      final pending = (res['data']?['pending_commands'] as List?) ?? const [];
      for (final cmd in pending) {
        await _executeCommand(cmd);
      }
    } catch (e) {
      _lastError = '$e';
      debugPrint('[watch-relay] heartbeat failed: $e');
    }
  }

  /// Translate a queued DeviceCommand into a GATT write and acknowledge it.
  /// Commands: ``watch_notify`` {title, body, category}, ``watch_nav``
  /// {flag, narrative, distance, progress}, ``watch_alert`` {level} (a buzz),
  /// ``ble_gatt_write`` {service?, characteristic, data_b64}.
  Future<void> _executeCommand(Map<String, dynamic> cmd) async {
    final id = cmd['id'];
    final name = '${cmd['command']}';
    Map<String, dynamic> payload = const {};
    if (cmd['payload'] is String && (cmd['payload'] as String).isNotEmpty) {
      try {
        payload = Map<String, dynamic>.from(json.decode(cmd['payload']));
      } catch (_) {}
    } else if (cmd['payload'] is Map) {
      payload = Map<String, dynamic>.from(cmd['payload']);
    }

    var ok = false;
    String message = 'unsupported';
    final link = _link;
    try {
      switch (name) {
        case 'watch_notify':
          ok = await link?.sendAlert(
                category: (payload['category'] as num?)?.toInt() ?? 0,
                title: '${payload['title'] ?? 'Thoth'}',
                body: '${payload['body'] ?? ''}',
              ) ??
              false;
          message = ok ? 'alert written' : 'write failed';
        case 'watch_alert':
          ok = await link?.buzz() ?? false;
          message = ok ? 'buzzed' : 'write failed';
        case 'watch_nav':
          ok = await link?.setNavigation(
                flag: payload['flag']?.toString(),
                narrative: payload['narrative']?.toString(),
                distance: payload['distance']?.toString(),
                progress: (payload['progress'] as num?)?.toInt(),
              ) ??
              false;
          message = ok ? 'nav update sent' : 'write failed';
        case 'ble_gatt_write':
          final charUuid = Guid('${payload['characteristic'] ?? ''}');
          final data = payload['data_b64'] is String
              ? base64.decode(payload['data_b64'])
              : <int>[];
          ok = await link?.writeRaw(charUuid, data) ?? false;
          message = ok ? 'gatt write ok' : 'write failed';
        default:
          message = 'not a watch command';
      }
    } catch (e) {
      message = '$e';
    }

    try {
      await BrainClient.instance.ackDeviceCommand(
        record.deviceUuid,
        id is int ? id : int.parse('$id'),
        {'success': ok, 'message': message},
      );
    } catch (e) {
      debugPrint('[watch-relay] ack failed: $e');
    }
  }

  Future<void> dispose() async {
    _running = false;
    _flushTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _connSub?.cancel();
    await _telemetrySub?.cancel();
    await _flush(); // best-effort final drain
    await _link?.dispose();
    await _telemetryOut.close();
  }
}
