import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:uuid/uuid.dart';

import '../../context/data/context_repository.dart';
import '../../context/domain/models.dart';
import '../../settings/application/app_settings.dart';
import '../../watch/application/watch_providers.dart';
import '../../watch/domain/pinetime_gatt.dart';
import 'identity_beacon.dart';
import 'phone_relay.dart';

/// Mobile-device observation producers (Part 4).
///
/// Everything posted here is *evidence* (observations), never asserted
/// context state. BLE proximity is reported as RSSI — never as a
/// distance unless a localization estimator produces one. Unknown
/// neighboring BLE devices are never fingerprinted into identities.
class ObservationService {
  ObservationService._();
  static final ObservationService instance = ObservationService._();

  final _repo = ContextRepository();

  StreamSubscription<List<fbp.ScanResult>>? _bleSub;
  StreamSubscription<Position>? _gpsSub;
  StreamSubscription<AccelerometerEvent>? _motionSub;
  Timer? _flushTimer;

  final List<Map<String, dynamic>> _pending = [];
  final Map<String, double> _rssiByTarget = {};
  DateTime? _lastFlush;
  int _sent = 0;
  int _failed = 0;
  String? _lastError;
  bool _running = false;

  /// Cancellation generation for the duty-cycled BLE loop — `stop()`
  /// bumps it so an old loop sleeping between scans exits instead of
  /// waking up and re-scanning after a reconfigure. `configure()` calls
  /// are serialized through [_configureLock] so a second call can't set
  /// `_running` back to true underneath the first one's `stop()`.
  int _bleGeneration = 0;
  Future<void>? _configureLock;

  /// Whether BLE RSSI evidence is enabled — also gates watch-relayed
  /// sightings (same privacy semantics as the phone's own scan).
  bool _bleEnabled = false;

  /// Enrolled targets the BLE scanner reports on — Thoth devices the user
  /// owns (watch BLE ids, node ids).
  final Set<String> knownTargets = {};

  /// Observer id: this phone's logical source identity.
  String observerId = 'phone:this';

  /// Unenrolled advertisers seen in the current scan window — reported
  /// as `ble.discovery.v1` so unknown devices appear on the relation map
  /// (raw id stays on the user's own account; never a global fingerprint).
  final Map<String, double> _unknownRssi = {};
  final Map<String, String> _unknownName = {};

  /// Map-level geofences + the zone the phone is currently inside.
  List<GeoZone> _geoZones = const [];
  String? _insideZone;

  /// Person entity this phone's presence is attributed to.
  String get personEntity => 'person:${observerId.split(':').last}';

  int get sentBatches => _sent;
  int get failedBatches => _failed;
  String? get lastError => _lastError;
  DateTime? get lastFlush => _lastFlush;
  bool get running => _running;

  /// Battery-aware BLE scan policy — duty-cycled windows instead of a
  /// permanent scan; long gaps when the phone is not the relay source.
  static const bleWindow = Duration(seconds: 8);
  static const bleCycle = Duration(seconds: 45);

  Future<void> configure({
    required bool bleRssi,
    required bool gps,
    required bool motion,
    Set<String>? targets,
    String? observer,
    List<GeoZone>? geoZones,
  }) {
    final prev = _configureLock;
    final task = (prev ?? Future<void>.value()).then(
      (_) => _configure(
        bleRssi: bleRssi,
        gps: gps,
        motion: motion,
        targets: targets,
        observer: observer,
        geoZones: geoZones,
      ),
    );
    _configureLock = task.catchError((_) {});
    return task;
  }

  Future<void> _configure({
    required bool bleRssi,
    required bool gps,
    required bool motion,
    Set<String>? targets,
    String? observer,
    List<GeoZone>? geoZones,
  }) async {
    if (targets != null) {
      knownTargets
        ..clear()
        ..addAll(targets);
    }
    if (observer != null) observerId = observer;
    if (geoZones != null) _geoZones = geoZones;
    await stop();
    _running = bleRssi || gps || motion;
    _bleEnabled = bleRssi;
    _flushTimer ??= Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(flush()),
    );

    if (bleRssi) await _startBleScan();
    if (gps) await _startGps();
    if (motion) _startMotion();
    // Phone-as-device: when any source is live the handset also registers
    // on Brain and streams phone-gps/imu/ble live-chunks (whispy SDK).
    if (_running) {
      unawaited(PhoneRelay.instance.start(name: observerId));
    } else {
      unawaited(PhoneRelay.instance.stop());
    }
  }

  Future<void> stop() async {
    _running = false;
    _bleGeneration++; // kill any BLE loop sleeping between cycles
    await _bleSub?.cancel();
    _bleSub = null;
    await _gpsSub?.cancel();
    _gpsSub = null;
    await _motionSub?.cancel();
    _motionSub = null;
    try {
      await fbp.FlutterBluePlus.stopScan();
    } catch (_) {}
    _flushTimer?.cancel();
    _flushTimer = null;
    await PhoneRelay.instance.stop();
  }

  // ── BLE RSSI evidence ────────────────────────────────────────────────────

  Future<void> _startBleScan() async {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final granted = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
      if (!granted.values.every((s) => s.isGranted)) return;
    }
    // Duty-cycle: scan a short window each cycle. The generation is
    // captured now — if stop()/configure() runs while the loop sleeps,
    // it exits at the next await instead of resuming against the new
    // configuration.
    unawaited(_bleLoop(_bleGeneration));
  }

  Future<void> _bleLoop(int generation) async {
    bool alive() => _running && generation == _bleGeneration;
    while (alive()) {
      _rssiByTarget.clear();
      await _bleSub?.cancel();
      if (!alive()) return;
      _bleSub = fbp.FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final id = r.device.remoteId.str;
          if (knownTargets.contains(id)) {
            final prev = _rssiByTarget[id];
            if (prev == null || r.rssi > prev) {
              _rssiByTarget[id] = r.rssi.toDouble();
            }
          } else {
            // Unenrolled advertiser — remember the strongest reading and
            // any advertised name for the discovery map layer.
            final prev = _unknownRssi[id];
            if (prev == null || r.rssi > prev) {
              _unknownRssi[id] = r.rssi.toDouble();
            }
            final nm = r.advertisementData.advName;
            if (nm.isNotEmpty) _unknownName[id] = nm;
          }
        }
      });
      try {
        await fbp.FlutterBluePlus.startScan(timeout: bleWindow);
      } catch (e) {
        debugPrint('[observe] ble scan failed: $e');
        break;
      }
      await Future<void>.delayed(bleWindow + const Duration(seconds: 2));
      if (!alive()) return;
      for (final e in _rssiByTarget.entries) {
        PhoneRelay.instance.submitBleSighting(
          addr: e.key,
          rssi: e.value,
          known: true,
        );
        _pending.add({
          'key': ContextKeys.bleProximityEvidence,
          'value': {
            'observer': observerId,
            'target': e.key,
            'rssi_dbm': e.value, // RSSI only — no distance assertion
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch / 1000.0,
          'external_id': const Uuid().v4(),
          'source_id': 'mobile.ble_scan',
          'provenance': {
            'collector': 'thoth-app',
            'policy': 'duty_cycled',
          },
        });
      }
      // Unenrolled neighbors — strongest first, capped so random-MAC
      // churn in crowded places can't flood the spool.
      final unknowns = _unknownRssi.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      for (final e in unknowns.take(8)) {
        PhoneRelay.instance.submitBleSighting(
          addr: e.key,
          rssi: e.value,
          name: _unknownName[e.key],
          known: false,
        );
        _pending.add({
          'key': ContextKeys.bleDiscovery,
          'value': {
            'observer': observerId,
            'target': 'ble:${e.key}',
            'rssi_dbm': e.value,
            'adv_name': _unknownName[e.key],
            'known': false,
          },
          'timestamp': DateTime.now().millisecondsSinceEpoch / 1000.0,
          'external_id': const Uuid().v4(),
          'source_id': 'mobile.ble_scan',
          'provenance': {'collector': 'thoth-app', 'policy': 'discovery'},
        });
      }
      _unknownRssi.clear();
      _unknownName.clear();
      await flush();
      await Future<void>.delayed(bleCycle);
    }
  }

  /// Watch-side BLE sightings — the paired watch reports neighbors it
  /// hears; they land as ``ble.proximity.v1`` with the *watch's device
  /// uuid* as observer, giving the fleet map a wrist-level viewpoint
  /// (a second anchor for triangulating unknown advertisers).
  void submitWatchSightings({
    required String observer,
    required List<BleSighting> sightings,
  }) {
    if (!_bleEnabled || sightings.isEmpty) return;
    final ts = DateTime.now().millisecondsSinceEpoch / 1000.0;
    for (final s in sightings.take(8)) {
      _pending.add({
        'key': ContextKeys.bleProximityEvidence,
        'value': {
          'observer': observer,
          'target': 'ble:${s.mac}',
          'rssi_dbm': s.rssiDbm.toDouble(),
          'adv_name': s.name,
        },
        'timestamp': ts,
        'external_id': const Uuid().v4(),
        'source_id': 'watch.ble_scan',
        'provenance': {'collector': 'pinetime', 'policy': 'duty_cycled'},
      });
    }
  }

  // ── GPS evidence (geographic/site, not room positioning) ─────────────────

  Future<void> _startGps() async {
    final perm = await Permission.locationWhenInUse.request();
    if (!perm.isGranted) return;
    try {
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low, // site evidence — battery-first
          distanceFilter: 100,
        ),
      ).listen((p) {
        _pending.add({
          'key': ContextKeys.geoEvidence,
          'value': {
            'lat': p.latitude,
            'lon': p.longitude,
            'acc_m': p.accuracy,
            'speed_mps': p.speed,
          },
          'timestamp': p.timestamp.millisecondsSinceEpoch / 1000.0,
          'external_id': const Uuid().v4(),
          'source_id': 'mobile.gps',
          'provenance': {'collector': 'thoth-app', 'class': 'geographic'},
        });
        _checkGeoZones(p);
        PhoneRelay.instance.submitGps(
          lat: p.latitude,
          lon: p.longitude,
          accM: p.accuracy,
          speedMps: p.speed,
          at: p.timestamp,
        );
      });
    } catch (e) {
      debugPrint('[observe] gps failed: $e');
    }
  }

  // ── Map-level geofences → geo.zone.v1 evidence + location.zone state ────

  void _checkGeoZones(Position p) {
    if (_geoZones.isEmpty) return;
    String? inside;
    for (final z in _geoZones) {
      final d = Geolocator.distanceBetween(
        p.latitude,
        p.longitude,
        z.latitude,
        z.longitude,
      );
      if (d <= z.radiusM) {
        inside = z.name;
        break;
      }
    }
    if (inside == _insideZone) return;
    final prev = _insideZone;
    _insideZone = inside;
    _pending.add({
      'key': ContextKeys.geoZoneEvidence,
      'value': {
        'observer': observerId,
        'subject': personEntity,
        'event': inside != null ? 'enter' : 'exit',
        'zone': inside ?? prev,
        'lat': p.latitude,
        'lon': p.longitude,
        'acc_m': p.accuracy,
      },
      'timestamp': p.timestamp.millisecondsSinceEpoch / 1000.0,
      'external_id': const Uuid().v4(),
      'source_id': 'mobile.geofence',
      'provenance': {'collector': 'thoth-app', 'class': 'geofence'},
    });
    final ts = p.timestamp.millisecondsSinceEpoch / 1000.0;
    unawaited(
      _repo.postState(
        stateKey: ContextKeys.locationZone,
        entityId: personEntity,
        value: {'zone': inside ?? 'away'},
        since: ts,
        transition: inside != null ? 'entered' : 'exited',
        estimator: 'mobile.geofence',
        confidence: (p.accuracy <= 25 ? 0.9 : 0.6),
      ),
    );
  }

  // ── Phone motion evidence (optional generic source) ──────────────────────

  void _startMotion() {
    try {
      var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
      _motionSub = accelerometerEventStream().listen((e) {
        // Downsample to ~1 Hz — we ship coarse motion energy, not the raw
        // IMU stream (that's what wearables are for).
        final now = DateTime.now();
        if (now.difference(lastSent) < const Duration(seconds: 1)) return;
        lastSent = now;
        PhoneRelay.instance.submitImu(x: e.x, y: e.y, z: e.z, at: now);
        _pending.add({
          'key': ContextKeys.phoneMotionEvidence,
          'value': {'acc_x': e.x, 'acc_y': e.y, 'acc_z': e.z},
          'timestamp': now.millisecondsSinceEpoch / 1000.0,
          'external_id': const Uuid().v4(),
          'source_id': 'mobile.accelerometer',
          'provenance': {'collector': 'thoth-app'},
        });
      });
    } catch (e) {
      debugPrint('[observe] motion failed: $e');
    }
  }

  // ── App lifecycle → app.focus.v1 state ──────────────────────────────

  /// Posted on every foreground/background transition (and once at
  /// start-up) so the context map — and therefore the agent — knows
  /// whether Thothcraft is the open app on this phone.
  void appLifecycleChanged({required bool foreground}) {
    final ent = PhoneRelay.instance.deviceUuid != null
        ? 'device:${PhoneRelay.instance.deviceUuid}'
        : observerId;
    unawaited(Future(() async {
      try {
        await _repo.postState(
          stateKey: 'app.focus.v1',
          entityId: ent,
          value: {'app': 'thothcraft', 'foreground': foreground},
          transition: foreground ? 'enter' : 'exit',
          estimator: 'mobile.lifecycle',
          confidence: 1.0,
        );
      } catch (e) {
        debugPrint('[observe] focus state: $e');
      }
    }),);
  }

  /// Flush the pending batch to ``/v1/context/evidence`` — idempotent via
  /// per-item ``external_id`` so retries never double-count.
  Future<int> flush() async {
    if (_pending.isEmpty) return 0;
    final batch = List<Map<String, dynamic>>.from(_pending);
    _pending.clear();
    try {
      await _repo.postEvidence(batch);
      _lastFlush = DateTime.now();
      _lastError = null;
      _sent++;
      return batch.length;
    } catch (e) {
      _pending.insertAll(0, batch);
      if (_pending.length > 2000) {
        _pending.removeRange(0, _pending.length - 2000); // bound memory
      }
      _lastError = '$e';
      _failed++;
      return 0;
    }
  }
}

final observationServiceProvider =
    Provider<ObservationService>((_) => ObservationService.instance);

/// Applies the user's privacy toggles to the producers; watches the
/// settings provider so toggles take effect immediately.
final observationControllerProvider = Provider<void>((ref) {
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  if (settings == null) return;
  final watches =
      ref.watch(_watchTargetsProvider).valueOrNull ?? const <String>{};
  unawaited(
    ObservationService.instance.configure(
      bleRssi: settings.bleRssiCollection,
      gps: settings.gpsTrace && settings.gpsEvidence,
      motion: settings.phoneMotion,
      targets: watches,
      observer: 'phone:${settings.username ?? 'this'}',
      geoZones: settings.geoZones,
    ),
  );
  // Owner-tagged BLE advert — the other direction: lets the home's
  // scanners see this phone.
  unawaited(
    IdentityBeacon.instance.sync(settings.bleIdentityBeacon, settings.username),
  );
});

/// Enrolled wearable BLE ids — the only targets the RSSI scanner tracks.
final _watchTargetsProvider = FutureProvider<Set<String>>((ref) async {
  try {
    final watches = await ref.watch(watchListProvider.future);
    return watches.map((w) => w.bleId).toSet();
  } catch (_) {
    return <String>{};
  }
});
