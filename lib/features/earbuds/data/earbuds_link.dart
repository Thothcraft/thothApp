import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../watch/data/watch_link.dart' show WatchLink;
import '../domain/earbuds_gatt.dart';

/// One telemetry item from the buds (status change or gesture event).
class BudsTelemetry {
  const BudsTelemetry({this.status, this.event, this.info, this.rssi});

  final BudsStatus? status;
  final BudsEvent? event;
  final BudsInfo? info;
  final int? rssi;
}

/// BLE central link to PineBuds Pro running the thothBuds image.
///
/// Same contract as [WatchLink]: owns only the physical connection —
/// the Brain relay lives in `EarbudsRelay`. The connect loop retries
/// forever with bounded backoff, so a bud that went back into its case
/// re-links the moment it comes out — no user tap required.
class EarbudsLink {
  EarbudsLink(this.device);

  final BluetoothDevice device;

  final _telemetry = StreamController<BudsTelemetry>.broadcast();
  final _connection = StreamController<BluetoothConnectionState>.broadcast();

  final Map<Guid, BluetoothCharacteristic> _chars = {};
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription<List<int>>> _valueSubs = [];
  bool _disposed = false;
  bool _connecting = false;
  Timer? _watchdog;
  int _rx = 0;
  int _watchdogRx = 0;
  int _watchdogMisses = 0;

  Stream<BudsTelemetry> get telemetry => _telemetry.stream;

  BluetoothConnectionState _lastConn = BluetoothConnectionState.disconnected;

  /// Replays the last state first — a screen opened after the link came
  /// up still resolves (broadcast streams don't replay).
  Stream<BluetoothConnectionState> get connection async* {
    yield _lastConn;
    yield* _connection.stream;
  }

  bool get isConnected => device.isConnected;
  String get bleId => device.remoteId.str;

  /// BLE scan for buds advertisers — same entry point shape as
  /// [WatchLink.scan] so the unified accessory sheet can merge them.
  static Stream<List<ScanResult>> scan(
      {Duration timeout = const Duration(seconds: 15)}) {
    return WatchLink.scan(timeout: timeout);
  }

  Future<void> connect() async {
    await WatchLink.ensurePermissions();
    _connSub = device.connectionState.listen((s) {
      _lastConn = s;
      _connection.add(s);
      if (s == BluetoothConnectionState.disconnected && !_disposed) {
        unawaited(_connectLoop());
      }
    });
    _lastConn = device.isConnected
        ? BluetoothConnectionState.connected
        : BluetoothConnectionState.disconnected;
    _connection.add(_lastConn);
    await _connectLoop();
  }

  /// Single-flight connect → subscribe, reused for every reconnect. A
  /// failed subscribe retries the whole cycle instead of leaving a
  /// half-open link (the "connected but silent" state).
  Future<void> _connectLoop() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    var backoff = const Duration(seconds: 2);
    try {
      while (!_disposed) {
        try {
          if (!device.isConnected) {
            await device.connect(
              autoConnect: false,
              mtu: 247,
              timeout: const Duration(seconds: 12),
            );
            for (var i = 0; i < 40 && !device.isConnected; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 125));
              if (_disposed) return;
            }
            if (!device.isConnected) {
              throw StateError('connect resolved but link not up');
            }
          }
          await _subscribe().timeout(const Duration(seconds: 30));
          _armWatchdog();
          return;
        } catch (_) {
          if (_disposed) return;
          await Future<void>.delayed(backoff);
          backoff = backoff * 2 > const Duration(seconds: 30)
              ? const Duration(seconds: 30)
              : backoff * 2;
        }
      }
    } finally {
      _connecting = false;
    }
  }

  /// Dead-link detector: STATUS notifies ≤1 Hz only on change, so silence
  /// is legitimately possible — but a GATT wedge is indistinguishable.
  /// Force a reconnect after ~5 min without ANY characteristic traffic.
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdogRx = _rx;
    _watchdogMisses = 0;
    _watchdog = Timer.periodic(const Duration(seconds: 60), (_) async {
      if (_disposed || !device.isConnected) return;
      if (_rx == _watchdogRx) {
        _watchdogMisses++;
        if (_watchdogMisses >= 5) {
          debugPrint('[buds] silent link — forcing reconnect');
          _watchdogMisses = 0;
          try {
            await device.disconnect();
          } catch (_) {}
        }
      } else {
        _watchdogMisses = 0;
        _watchdogRx = _rx;
      }
    });
  }

  Future<void> _subscribe() async {
    for (final s in _valueSubs) {
      await s.cancel();
    }
    _valueSubs.clear();
    _chars.clear();

    List<BluetoothService> services = const [];
    try {
      services = await device.discoverServices();
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 600));
      services = await device.discoverServices();
    }
    for (final svc in services) {
      for (final c in svc.characteristics) {
        _chars[c.characteristicUuid] = c;
      }
    }

    Future<void> notify(
        Guid uuid, BudsTelemetry? Function(List<int>) decode) async {
      final c = _chars[uuid];
      if (c == null) return;
      try {
        await c.setNotifyValue(true);
        _valueSubs.add(c.onValueReceived.listen((v) {
          _rx++;
          final t = decode(v);
          if (t != null) _telemetry.add(t);
        }));
      } catch (e) {
        debugPrint('[buds] notify $uuid failed: $e');
      }
    }

    await notify(EarbudsGatt.charStatus,
        (v) => BudsTelemetry(status: EarbudsCodec.decodeStatus(v)));
    await notify(EarbudsGatt.charEvent,
        (v) => BudsTelemetry(event: EarbudsCodec.decodeEvent(v)));

    // Seed: INFO (firmware/side/caps) + a gateway time reference.
    final info = await _safeRead(EarbudsGatt.charInfo);
    if (info != null) {
      final parsed = EarbudsCodec.decodeInfo(info);
      if (parsed != null) _telemetry.add(BudsTelemetry(info: parsed));
    }
    await _safeWrite(EarbudsGatt.charControl, EarbudsCodec.encodeEpoch());
    // Default: all gestures emit EVENTs — the relay filters to
    // thoth_action for Brain anyway; keeping the mask wide lets the app
    // show stock actions (play/pause etc.) in the UI for free.
    await _safeWrite(
        EarbudsGatt.charControl, EarbudsCodec.encodeEventMask(true));

    debugPrint('[buds] subscribed');
  }

  Future<List<int>?> _safeRead(Guid uuid) async {
    try {
      return await _chars[uuid]?.read();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _safeWrite(Guid uuid, List<int> bytes,
      {bool withoutResponse = false}) async {
    try {
      final c = _chars[uuid];
      if (c == null) return false;
      await c.write(bytes, withoutResponse: withoutResponse);
      return true;
    } catch (e) {
      debugPrint('[buds] write $uuid failed: $e');
      return false;
    }
  }

  /// Voice-session feedback (idle/listening/processing/speaking).
  Future<bool> setSessionState(String state) => _safeWrite(
      EarbudsGatt.charControl, EarbudsCodec.encodeSessionState(state));

  Future<bool> setEventMask(bool allGestures) => _safeWrite(
      EarbudsGatt.charControl, EarbudsCodec.encodeEventMask(allGestures));

  Future<int?> readRssi() async {
    try {
      return await device.readRssi();
    } catch (_) {
      return null;
    }
  }

  /// Raw GATT write — ``ble_gatt_write`` commands from Brain.
  Future<bool> writeRaw(Guid uuid, List<int> bytes,
          {bool withoutResponse = false}) =>
      _safeWrite(uuid, bytes, withoutResponse: withoutResponse);

  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    await _connSub?.cancel();
    for (final s in _valueSubs) {
      await s.cancel();
    }
    try {
      await device.disconnect();
    } catch (_) {}
    await _telemetry.close();
    await _connection.close();
  }
}
