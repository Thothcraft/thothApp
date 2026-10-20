import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/pinetime_gatt.dart';

/// BLE central link to one PineTime running InfiniTime.
///
/// Owns the physical connection only — Brain relay lives in
/// [WatchRelay]. Subscribes to every documented InfiniTime notify
/// characteristic; exposes decoded [WatchTelemetry] and typed writers.
class WatchLink {
  WatchLink(this.device);

  final BluetoothDevice device;

  final _telemetry = StreamController<WatchTelemetry>.broadcast();
  final _connection = StreamController<BluetoothConnectionState>.broadcast();

  final Map<Guid, BluetoothCharacteristic> _chars = {};
  StreamSubscription<BluetoothConnectionState>? _connSub;
  final List<StreamSubscription<List<int>>> _valueSubs = [];
  bool _disposed = false;
  bool _connecting = false;
  Timer? _motionPollTimer;
  Timer? _watchdog;
  int _watchdogRx = 0;
  int _watchdogMisses = 0;
  bool _stampedMotion = false;
  int _motionRx = 0;
  /// Stock InfiniTime stops sampling the BMA421 while dozing — reads
  /// return a latched register. Track identical consecutive payloads so
  /// the UI can say "parked" instead of showing a misleading flat line.
  List<int>? _lastMotionRaw;
  int _identicalMotion = 0;
  bool _motionStale = false;

  Stream<WatchTelemetry> get telemetry => _telemetry.stream;
  /// Last connection state — replayed to every listener before live
  /// events, so a screen opened after the link came up still resolves
  /// (broadcast streams don't replay; without this the detail page's
  /// `firstWhere(connected)` waits forever on an already-live link).
  BluetoothConnectionState _lastConn = BluetoothConnectionState.disconnected;

  Stream<BluetoothConnectionState> get connection async* {
    yield _lastConn;
    yield* _connection.stream;
  }
  /// when false the link falls back to polling reads of the legacy char.
  bool get stampedMotion => _stampedMotion;
  /// Motion samples received since connect — diagnostics for the
  /// screen-off stream check.
  int get motionRx => _motionRx;

  /// True once ≥20 consecutive motion payloads are byte-identical — the
  /// watch is dozing and the sensor register is parked. Resets on any
  /// changed sample (the watch woke or actually moved).
  bool get motionStale => _motionStale;

  /// Last connect/subscribe failure — surfaced on the accessory card so
  /// a stuck watch shows *why* instead of "connecting…" forever.
  String? _lastError;
  String? get lastError => _lastError;

  void _noteMotionPayload(List<int> v) {
    final last = _lastMotionRaw;
    final same = last != null &&
        last.length == v.length &&
        List.generate(v.length, (i) => v[i] == last[i])
            .every((e) => e);
    _lastMotionRaw = List.of(v);
    if (same) {
      _identicalMotion++;
      if (_identicalMotion >= 20 && !_motionStale) {
        _motionStale = true;
        debugPrint('[watch] motion parked — watch dozing');
      }
    } else {
      _identicalMotion = 0;
      _motionStale = false;
    }
  }
  String get bleId => device.remoteId.str;

  /// Android 12+ runtime permissions; no-op where already granted / on iOS.
  static Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final granted = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    return granted.values.every((s) => s.isGranted);
  }

  /// Scan for InfiniTime/PineTime advertisers.
  static Stream<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 15)}) {
    final controller = StreamController<List<ScanResult>>();
    StreamSubscription<List<ScanResult>>? sub;
    controller.onListen = () async {
      await ensurePermissions();
      sub = FlutterBluePlus.scanResults.listen(controller.add);
      await FlutterBluePlus.startScan(
        timeout: timeout,
        // InfiniTime advertises the full name; filter client-side too so
        // nothing valid is missed on platforms that drop the name field.
      );
      sub?.onDone(controller.close);
    };
    controller.onCancel = () async {
      await sub?.cancel();
      await FlutterBluePlus.stopScan();
    };
    return controller.stream;
  }

  static bool looksLikeWatch(ScanResult r) {
    final name = (r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName)
        .toLowerCase();
    return name.contains('infinitime') || name.contains('pinetime');
  }

  Future<void> connect() async {
    await ensurePermissions();
    _connSub = device.connectionState.listen((s) {
      _lastConn = s;
      _connection.add(s);
      if (s == BluetoothConnectionState.disconnected && !_disposed) {
        unawaited(_connectLoop());
      }
    });
    // Replay the current state — connectionState only emits on change,
    // so a watch that is already linked (lingering GATT connection)
    // would otherwise leave the UI waiting for an event that fired
    // before we subscribed.
    _lastConn = device.isConnected
        ? BluetoothConnectionState.connected
        : BluetoothConnectionState.disconnected;
    _connection.add(_lastConn);
    await _connectLoop();
  }

  /// Single flight path for connect → negotiate → subscribe, reused for the
  /// first connect and every reconnect. Guards against overlapping
  /// connect() calls when disconnect events arrive in bursts.
  ///
  /// The whole connect→subscribe cycle lives inside the retry loop:
  /// `device.isConnected` can already be true (lingering GATT link after
  /// an app restart / FBP's connectedDevices restore) — skipping
  /// `_subscribe()` in that case leaves a "connected" link with no
  /// telemetry, which is exactly the "loading never ends" symptom.
  /// A failed `_subscribe()` (transient GATT busy, discovery stall)
  /// retries the whole cycle instead of returning a half-open link.
  Future<void> _connectLoop() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    var backoff = const Duration(seconds: 2);
    try {
      while (!_disposed) {
        try {
          if (!device.isConnected) {
            // autoConnect:false keeps FBP from reconnecting under us —
            // the disconnect listener owns retries.
            await device.connect(
                autoConnect: false,
                mtu: 247,
                timeout: const Duration(seconds: 12),);
            // FBP can resolve connect() before its isConnected flag
            // flips — poll briefly instead of trusting it blindly.
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
        } catch (e) {
          if (_disposed) return;
          _lastError = '$e';
          // Exponential-ish backoff capped at 30 s — a watch left
          // overnight shouldn't get hammered every 2 s forever.
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

  /// Dead-link detector: with the stamped char OR the legacy poll the
  /// link produces motion samples continuously — if `motionRx` stalls
  /// for ~90 s while `isConnected` is true, the GATT session is wedged
  /// (a state Android can sit in for hours); drop it so the connect
  /// loop brings up a real one.
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdogRx = _motionRx;
    _watchdogMisses = 0;
    _watchdog = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_disposed || !device.isConnected) return;
      if (_motionRx == _watchdogRx) {
        _watchdogMisses++;
        if (_watchdogMisses >= 3) {
          debugPrint('[watch] telemetry silent — forcing reconnect');
          _watchdogMisses = 0;
          try {
            await device.disconnect();
          } catch (_) {}
        }
      } else {
        _watchdogMisses = 0;
        _watchdogRx = _motionRx;
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
      // First discovery right after connect occasionally races the phone's
      // service table — one short retry is enough on InfiniTime.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      services = await device.discoverServices();
    }
    for (final svc in services) {
      for (final c in svc.characteristics) {
        _chars[c.characteristicUuid] = c;
      }
    }

    Future<void> notify(Guid uuid, WatchTelemetry? Function(List<int>) decode) async {
      final c = _chars[uuid];
      if (c == null) return;
      try {
        await c.setNotifyValue(true);
        _valueSubs.add(c.onValueReceived.listen(
          (v) {
            final t = decode(v);
            if (t != null) _telemetry.add(t);
          },
        ),);
      } catch (e) {
        debugPrint('[watch] notify $uuid failed: $e');
      }
    }

    // Prefer the thoth-fork stamped char (tick+seq) when present — it
    // notifies unconditionally, so the stream survives a stationary watch.
    _stampedMotion = _chars.containsKey(PinetimeGatt.charMotionStamped);
    if (_stampedMotion) {
      // Firmware upgraded to the stamped char — stop the poll to avoid
      // double-sampling alongside unconditional notifications.
      _motionPollTimer?.cancel();
      _motionPollTimer = null;
      await notify(
          PinetimeGatt.charMotionStamped,
          (v) {
            _motionRx++;
            _noteMotionPayload(v);
            if (_motionRx % 50 == 0) {
              debugPrint('[watch] motionRx=$_motionRx (stamped)');
            }
            return WatchTelemetry(
                motion: PinetimeCodec.decodeMotionStamped(v),);
          });
    } else {
      // Stock InfiniTime only notifies 00030002 when x/y/z *change* — a
      // still watch sends nothing, which looks like the stream dying when
      // the phone screen is off. Poll the char at 10 Hz instead (matches
      // SystemTask's 100 ms motion period; reads work even while dozing).
      await notify(PinetimeGatt.charMotion,
          (v) => WatchTelemetry(motion: PinetimeCodec.decodeMotion(v)),);
      _motionPollTimer ??= Timer.periodic(
          const Duration(milliseconds: 100), (_) => _pollMotion(),);
    }
    await notify(PinetimeGatt.charSteps,
        (v) => WatchTelemetry(steps: PinetimeCodec.decodeSteps(v)),);
    await notify(PinetimeGatt.charHr,
        (v) => WatchTelemetry(heartRate: PinetimeCodec.decodeHeartRate(v)),);
    await notify(PinetimeGatt.charBattery,
        (v) => WatchTelemetry(battery: PinetimeCodec.decodeBattery(v)),);
    await notify(
        PinetimeGatt.charMusicEvent,
        (v) => WatchTelemetry(
            event: v.isEmpty ? null : PinetimeCodec.decodeMusicEvent(v.first),),);
    await notify(
        PinetimeGatt.charNotifEvent,
        (v) => WatchTelemetry(
            event: v.isEmpty ? null : PinetimeCodec.decodeCallEvent(v.first),),);

    // thoth-fork: watch-side neighbor scan — the watch reports what IT
    // hears so the fleet map has a wrist-level observer (triangulation).
    if (_chars.containsKey(PinetimeGatt.charScanResult)) {
      await notify(
          PinetimeGatt.charScanResult,
          (v) => WatchTelemetry(bleScan: PinetimeCodec.decodeScanResults(v)),);
      await _safeWrite(PinetimeGatt.charScanControl, [0x01],
          withoutResponse: true,);
    }

    debugPrint('[watch] subscribed'
        ' stamped=$_stampedMotion');

    // Time sync — InfiniTime reads CTS on connect; a direct write keeps it
    // honest after NTP drift without needing a peripheral-mode CTS server.
    await _safeWrite(PinetimeGatt.charCurrentTime,
        PinetimeCodec.encodeCurrentTime(DateTime.now()),);

    // One-shot reads to seed UI + heartbeat hardware_info.
    final fw = await _safeRead(PinetimeGatt.charFirmware);
    final battery = await _safeRead(PinetimeGatt.charBattery);
    _telemetry.add(WatchTelemetry(
      event: fw != null ? 'info:firmware=${utf8.decode(fw, allowMalformed: true)}' : null,
      battery: battery != null ? PinetimeCodec.decodeBattery(battery) : null,
    ),);
  }

  Future<List<int>?> _safeRead(Guid uuid) async {
    try {
      return await _chars[uuid]?.read();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _safeWrite(Guid uuid, List<int> bytes,
      {bool withoutResponse = false,}) async {
    try {
      final c = _chars[uuid];
      if (c == null) return false;
      await c.write(bytes, withoutResponse: withoutResponse);
      return true;
    } catch (e) {
      debugPrint('[watch] write $uuid failed: $e');
      return false;
    }
  }

  /// Suspend the link's periodic GATT traffic (motion poll) while a
  /// bulk transfer like DFU owns the connection — Android refuses a
  /// characteristic write while another op is still in flight, and the
  /// 10 Hz poll starves a packet stream.
  bool _suspended = false;
  void suspendTelemetry() {
    _suspended = true;
    _motionPollTimer?.cancel();
    _motionPollTimer = null;
  }

  /// Re-arm the motion poll after [suspendTelemetry] — only needed on
  /// the legacy (un-stamped) firmware path; stamped chars notify on
  /// their own. No-op if the poll never ran or DFU never suspended us.
  void resumeTelemetry() {
    _suspended = false;
    if (!_stampedMotion && !_disposed &&
        device.isConnected && _motionPollTimer == null) {
      _motionPollTimer = Timer.periodic(
          const Duration(milliseconds: 100), (_) => _pollMotion(),);
    }
  }

  /// Legacy-char poll — bypasses the watch's change-dedup so a still
  /// watch keeps producing samples. Overlapping reads are skipped.
  bool _motionReadInFlight = false;
  Future<void> _pollMotion() async {
    if (_disposed || _suspended || _motionReadInFlight || !device.isConnected) return;
    _motionReadInFlight = true;
    try {
      final v = await _chars[PinetimeGatt.charMotion]?.read();
      if (v != null && v.isNotEmpty) {
        _motionRx++;
        _noteMotionPayload(v);
        final m = PinetimeCodec.decodeMotion(v);
        if (_motionRx % 50 == 0) {
          debugPrint('[watch] motionRx=$_motionRx (poll) '
              'xyz=${m == null ? '-' : '${m.x.toStringAsFixed(3)},'
              '${m.y.toStringAsFixed(3)},${m.z.toStringAsFixed(3)}'}');
        }
        _telemetry.add(WatchTelemetry(motion: m));
      }
    } catch (_) {
      // Transient read failures (link busy with notify/flush) are normal.
    } finally {
      _motionReadInFlight = false;
    }
  }

  /// Current BLE link RSSI in dBm (negative; closer to 0 = closer).
  Future<int?> readRssi() async {
    try {
      return await device.readRssi();
    } catch (_) {
      return null;
    }
  }

  /// Raw GATT write by characteristic UUID — used by ``ble_gatt_write``
  /// device commands pushed from Brain.
  Future<bool> writeRaw(Guid uuid, List<int> bytes,
          {bool withoutResponse = false,}) =>
      _safeWrite(uuid, bytes, withoutResponse: withoutResponse);

  // ── Typed command writers (Brain commands → GATT) ────────────────────────

  /// ANS New Alert — category 0 simple, 3 call, 5 sms, 9 instant message.
  Future<bool> sendAlert({int category = 0, String title = '', String body = ''}) =>
      _safeWrite(PinetimeGatt.charNewAlert,
          PinetimeCodec.encodeAlert(category, [title, body]),);

  /// Music playback state shown on the watch music app.
  Future<bool> setMusic({bool? playing, String? artist, String? track, String? album}) async {
    var ok = true;
    if (playing != null) {
      ok &= await _safeWrite(PinetimeGatt.charMusicStatus, [playing ? 1 : 0]);
    }
    if (artist != null) {
      ok &= await _safeWrite(PinetimeGatt.charMusicArtist, utf8.encode(artist));
    }
    if (track != null) {
      ok &= await _safeWrite(PinetimeGatt.charMusicTrack, utf8.encode(track));
    }
    if (album != null) {
      ok &= await _safeWrite(PinetimeGatt.charMusicAlbum, utf8.encode(album));
    }
    return ok;
  }

  /// Navigation update (flag icon name, instruction, distance, % complete).
  Future<bool> setNavigation(
      {String? flag, String? narrative, String? distance, int? progress,}) async {
    var ok = true;
    if (flag != null) {
      ok &= await _safeWrite(PinetimeGatt.charNavFlag, utf8.encode(flag));
    }
    if (narrative != null) {
      ok &= await _safeWrite(PinetimeGatt.charNavNarrative, utf8.encode(narrative));
    }
    if (distance != null) {
      ok &= await _safeWrite(PinetimeGatt.charNavDistance, utf8.encode(distance));
    }
    if (progress != null) {
      ok &= await _safeWrite(PinetimeGatt.charNavProgress,
          [progress.clamp(0, 100)],);
    }
    return ok;
  }

  /// Vibrate the watch via a high-priority empty alert (stock firmware has
  /// no dedicated motor characteristic — ANS is the actuator).
  Future<bool> buzz() => sendAlert(category: 8, title: 'Thoth', body: '');

  /// Push the phone's current local time to the watch's CTS
  /// characteristic (0x2A2B). Runs automatically on every (re)subscribe;
  /// call from UI to force a re-sync. False when not connected.
  Future<bool> syncTime() async {
    if (!device.isConnected || _chars.isEmpty) return false;
    return _safeWrite(PinetimeGatt.charCurrentTime,
        PinetimeCodec.encodeCurrentTime(DateTime.now()),);
  }

  Future<void> dispose() async {
    _disposed = true;
    _watchdog?.cancel();
    _motionPollTimer?.cancel();
    _motionPollTimer = null;
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
