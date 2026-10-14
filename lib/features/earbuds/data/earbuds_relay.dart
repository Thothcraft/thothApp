import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../../core/api/brain_client.dart';
import 'earbuds_link.dart';
import 'earbuds_store.dart';

/// Brain-side sensor ids the buds relay under.
const kBudsSensorStatus = 'pinebuds-status';
const kBudsSensorGesture = 'pinebuds-gesture';
const kBudsSensorProx = 'pinebuds-prox'; // BLE RSSI → phone proximity

/// Gateway: PineBuds (BLE) ⇄ Brain (HTTPS). Mirrors `WatchRelay` —
/// buffers status telemetry into 10 s live-chunks, heartbeats the
/// device JWT, drains ``pending_commands`` into CONTROL/GATT writes.
class EarbudsRelay {
  EarbudsRelay(this.record);

  /// The Brain-paired record — `record` mutates when the deferred
  /// pairing lands so heartbeats pick up the device token without
  /// rebuilding the BLE link.
  EarbudsRecord record;
  EarbudsLink? _link;

  final _telemetryOut = StreamController<BudsTelemetry>.broadcast();
  final List<BudsTelemetry> _buffer = [];

  Timer? _flushTimer;
  Timer? _heartbeatTimer;
  StreamSubscription<BudsTelemetry>? _telemetrySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  int _seq = 0;
  int? _battery;
  int? _peerBattery;
  int? _rssi;
  String? _firmware;
  String? _session;
  String? _lastError;
  bool _connected = false;

  EarbudsLink? get link => _link;
  int? get battery => _battery;
  int? get peerBattery => _peerBattery;
  int? get rssi => _rssi;
  String? get firmware => _firmware;
  String? get session => _session;
  String? get lastError => _lastError;
  bool get connected => _link?.isConnected ?? false;

  Stream<BudsTelemetry> get telemetry => _telemetryOut.stream;

  static String deviceUuidFor(String bleId) =>
      const Uuid().v5(Namespace.dns.value, bleId);

  /// Brain pairing — identical flow to `WatchRelay.pair` but the device
  /// registers as ``pinebuds`` so it sorts separately on the dashboard.
  static Future<EarbudsRecord> pair(String bleId, {String? name}) async {
    final client = BrainClient.instance;
    final deviceUuid = deviceUuidFor(bleId);
    final start = await client.devicePairingStart(
      deviceId: bleId,
      deviceName: name ?? 'PineBuds',
      deviceType: 'pinebuds',
      hardwareInfo: {
        'transport': 'ble',
        'gateway': 'thoth-app',
        'capabilities': {
          'status': true, 'gestures': true, 'battery': true,
        },
      },
    );
    final code = start['code'] as String?;
    final secret = start['pairing_secret'] as String?;
    if (code == null || secret == null) {
      throw StateError('pairing/start returned no code or secret');
    }
    await client.postJson('/device/pairing/claim', body: {'code': code});
    final status = await client.devicePairingStatus(bleId, secret);
    if (status['status'] != 'paired') {
      throw StateError('pairing did not complete: ${status['status']}');
    }
    return EarbudsRecord(
      bleId: bleId,
      deviceUuid: deviceUuid,
      name: name ?? 'PineBuds',
      deviceToken: status['access_token'] as String?,
    );
  }

  Future<void> start(EarbudsLink link) async {
    _link = link;
    _telemetrySub = link.telemetry.listen(_onTelemetry);
    _connSub = link.connection.listen((s) {
      _connected = s == BluetoothConnectionState.connected;
      _pushState('earbuds.link.v1', {
        'connected': _connected,
        if (_rssi != null) 'rssi': _rssi,
      }, transition: _connected ? 'enter' : 'exit');
    });
    _flushTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => unawaited(_flush()));
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => unawaited(_heartbeat()));
    unawaited(_heartbeat());
  }

  void _pushState(String key, Map<String, dynamic> value,
      {String? transition}) {
    final client = BrainClient.instance;
    if (!client.hasToken) return;
    unawaited(client.postV1('/context/state', body: {
      'key': key,
      'entity_id': 'device:${record.deviceUuid}',
      'value': value,
      'estimator': 'thoth-app-earbuds-relay',
      if (transition != null) 'transition': transition,
    }).catchError((Object e) {
      debugPrint('[buds-relay] state $key: $e');
      return <String, dynamic>{};
    }));
  }

  void _onTelemetry(BudsTelemetry t) {
    _telemetryOut.add(t);
    final st = t.status;
    if (st != null) {
      _battery = st.batteryPct ?? _battery;
      _peerBattery = st.peerBatteryPct ?? _peerBattery;
      _session = st.session;
    }
    final info = t.info;
    if (info != null) _firmware = info.firmware;
    if (t.rssi != null) _rssi = t.rssi;
    if (st != null || t.event != null || t.rssi != null) _buffer.add(t);
  }

  Map<String, dynamic> _toSample(BudsTelemetry t) {
    final ts = DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0;
    if (t.status != null) {
      return {
        'sensor_id': kBudsSensorStatus,
        'sensor_type': 'wearable_status',
        'timestamp': ts,
        'sequence': t.status!.seq,
        'payload': t.status!.toJson(),
        'units': {'battery_pct': '%', 'peer_battery_pct': '%'},
      };
    }
    if (t.event != null) {
      return {
        'sensor_id': kBudsSensorGesture,
        'sensor_type': 'wearable_gesture',
        'timestamp': ts,
        'sequence': t.event!.seq,
        'payload': t.event!.toJson(),
        'units': const {},
      };
    }
    return {
      'sensor_id': kBudsSensorProx,
      'sensor_type': 'rssi',
      'timestamp': ts,
      'sequence': _seq++,
      'payload': {'rssi': t.rssi},
      'units': {'rssi': 'dBm'},
    };
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty || !BrainClient.instance.hasToken) return;
    final pending = List<BudsTelemetry>.from(_buffer);
    _buffer.clear();
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
    } catch (e) {
      _buffer.insertAll(0, pending);
      _lastError = '$e';
      debugPrint('[buds-relay] chunk upload failed: $e');
    }
  }

  /// Device heartbeat — drains pending_commands into GATT writes.
  /// Commands: ``buds_session`` {state}, ``buds_event_mask`` {all},
  /// ``ble_gatt_write`` {characteristic, data_b64}.
  Future<void> _heartbeat() async {
    final token = record.deviceToken;
    if (token == null || token.isEmpty) return;
    try {
      final res = await BrainClient.instance.deviceHeartbeat(token, {
        'device_id': record.deviceUuid,
        'device_name': record.name ?? 'PineBuds',
        'device_type': 'pinebuds',
        'battery_level': _battery,
        'online': _connected,
        'capabilities': {
          'status': true, 'gestures': true, 'battery': true, 'prox': true,
        },
        'hardware_info': {
          'firmware': _firmware,
          'transport': 'ble',
          'ble_id': record.bleId,
          'gateway': 'thoth-app',
          'sensors': [
            {'id': kBudsSensorStatus, 'type': 'wearable_status'},
            {'id': kBudsSensorGesture, 'type': 'wearable_gesture'},
            {'id': kBudsSensorProx, 'type': 'rssi'},
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
      debugPrint('[buds-relay] heartbeat failed: $e');
    }
  }

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
        case 'buds_session':
          ok = await link
                  ?.setSessionState('${payload['state'] ?? 'idle'}') ??
              false;
          message = ok ? 'session state sent' : 'write failed';
        case 'buds_event_mask':
          ok = await link?.setEventMask(payload['all'] == true) ?? false;
          message = ok ? 'event mask set' : 'write failed';
        case 'ble_gatt_write':
          final charUuid = Guid('${payload['characteristic'] ?? ''}');
          final data = payload['data_b64'] is String
              ? base64.decode(payload['data_b64'])
              : <int>[];
          ok = await link?.writeRaw(charUuid, data) ?? false;
          message = ok ? 'gatt write ok' : 'write failed';
        default:
          message = 'not an earbuds command';
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
      debugPrint('[buds-relay] ack failed: $e');
    }
  }

  /// Periodic link-RSSI push into the buffer so the prox sensor id
  /// keeps producing samples even when STATUS is quiet.
  Future<void> pollRssi() async {
    final r = await _link?.readRssi();
    if (r != null) _onTelemetry(BudsTelemetry(rssi: r));
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _heartbeatTimer?.cancel();
    await _connSub?.cancel();
    await _telemetrySub?.cancel();
    await _flush();
    await _link?.dispose();
    await _telemetryOut.close();
  }
}
