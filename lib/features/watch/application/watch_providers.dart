import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/node_client.dart';
import '../../devices/application/devices_provider.dart';
import '../../observe/data/observation_service.dart';
import '../../settings/application/app_settings.dart';
import '../data/trace_service.dart';
import '../data/watch_link.dart';
import '../data/watch_relay.dart';
import '../data/watch_store.dart';
import '../domain/pinetime_gatt.dart';

/// Paired watches persisted in secure storage.
final watchListProvider =
    AsyncNotifierProvider<WatchListNotifier, List<WatchRecord>>(
        WatchListNotifier.new,);

class WatchListNotifier extends AsyncNotifier<List<WatchRecord>> {
  @override
  Future<List<WatchRecord>> build() => WatchStore.instance.load();

  Future<void> refresh() async {
    state = AsyncData(await WatchStore.instance.load());
  }

  Future<void> remove(String bleId) async {
    await WatchStore.instance.remove(bleId);
    await refresh();
  }
}

/// Live connection/telemetry manager — one relay per paired watch.
final watchManagerProvider =
    NotifierProvider<WatchManager, Map<String, WatchRelay>>(WatchManager.new);

class WatchManager extends Notifier<Map<String, WatchRelay>> {
  /// Watch-scan telemetry forwarding — one sub per connected link.
  final Map<String, StreamSubscription<WatchTelemetry>> _scanSubs = {};

  @override
  Map<String, WatchRelay> build() {
    ref.onDispose(() {
      for (final relay in state.values) {
        relay.dispose();
      }
      for (final sub in _scanSubs.values) {
        sub.cancel();
      }
    });
    ref.listen(watchListProvider, (_, next) {
      final watches = next.value ?? const <WatchRecord>[];
      // Dispose relays for watches that were unpaired.
      for (final key in state.keys.toList()) {
        if (!watches.any((w) => w.bleId == key)) {
          _scanSubs.remove(key)?.cancel();
          state[key]?.dispose();
          state = {...state}..remove(key);
        }
      }
    });
    // Settings toggles apply live to the trace/background service.
    ref.listen(appSettingsProvider, (_, next) {
      final s = next.value;
      if (s == null) return;
      unawaited(TraceService.instance.setBackgroundRelay(s.backgroundRelay));
      unawaited(TraceService.instance.setGpsTrace(s.gpsTrace));
    });
    // Cold start: re-link every paired watch without waiting for a tap.
    // A process kill drops the BLE connection with the app and nothing
    // re-established it on relaunch — the "watch disconnects when I
    // leave the app" symptom.
    unawaited(_autoConnect());
    return {};
  }

  bool _autoConnected = false;
  Future<void> _autoConnect() async {
    if (_autoConnected) return;
    _autoConnected = true;
    try {
      final watches = await ref.read(watchListProvider.future);
      for (final w in watches) {
        try {
          await connect(w);
        } catch (e) {
          // Watch asleep / out of range — WatchLink's reconnect loop
          // keeps trying in the background anyway.
          debugPrint('[watch] auto-connect ${w.bleId}: $e');
        }
      }
    } catch (e) {
      debugPrint('[watch] auto-connect list load: $e');
    }
  }

  WatchRelay? relayFor(String bleId) => state[bleId];

  /// Connect (or reuse) the BLE link and start the Brain relay.
  ///
  /// The relay registers + starts BEFORE the link completes so a slow or
  /// out-of-range watch never leaves an unowned [WatchLink] retrying in
  /// the void — whenever its connect loop lands, telemetry buffering,
  /// the scan-forward sub, and heartbeats are already attached.
  Future<WatchRelay> connect(WatchRecord record) async {
    final existing = state[record.bleId];
    if (existing != null) {
      if (existing.connected) return existing;
      // Relay exists; its link's connect loop is still running. Wait for
      // it instead of disposing an in-flight connect under the caller.
      await _waitConnected(existing.link!, record);
      return existing;
    }

    final device = BluetoothDevice.fromId(record.bleId);
    final link = WatchLink(device);
    final relay = WatchRelay(record);
    await relay.start(link);
    state = {...state, record.bleId: relay};
    // Watch-side neighbor scan → Brain proximity evidence with the
    // watch as observer — the wrist-level viewpoint the map needs to
    // triangulate devices the phone itself can't hear.
    _scanSubs[record.bleId]?.cancel();
    _scanSubs[record.bleId] = link.telemetry.listen((t) {
      final scan = t.bleScan;
      if (scan != null && scan.isNotEmpty) {
        ObservationService.instance.submitWatchSightings(
            observer: record.deviceUuid, sightings: scan,);
      }
    });
    // Foreground service + GPS/RSSI trace attach once the link is
    // actually live — no "watch relay active" notification for a watch
    // that never came up. attach() is idempotent across reconnects.
    unawaited(link.connection
        .firstWhere((s) => s == BluetoothConnectionState.connected)
        .then((_) async {
      final s = ref.read(appSettingsProvider).valueOrNull ??
          const AppSettings();
      unawaited(TraceService.instance.attach(relay,
          backgroundRelay: s.backgroundRelay, gpsTrace: s.gpsTrace,),);
      // First connect ever: ask for the doze exemption. FGS + wakelock
      // keep the process alive, but only the whitelist keeps uploads
      // flowing when the phone sits unplugged and still for a long
      // stretch.
      if (!s.batteryOptPrompted) {
        await ref.read(appSettingsProvider.notifier).setBatteryOptPrompted();
        unawaited(
            TraceService.instance.requestBatteryOptimizationExemption(),);
      }
    }).catchError((Object e) => debugPrint('[watch] trace attach: $e')),);

    unawaited(link.connect());
    unawaited(_enrollWatchOnNodes(record));
    // Bounded wait for the first live link so pairing + DFU callers get
    // a usable connection or a clear failure; the registered relay keeps
    // retrying in the background either way.
    await _waitConnected(link, record);
    return relay;
  }

  /// Enroll the watch as a ``kind=watch`` device on every online thoth
  /// node — the node's central session then connects whenever the phone
  /// releases the link (watch stops advertising while it's held), so
  /// whispy keeps streaming IMU + the watch's own neighbor scan to Brain.
  Future<void> _enrollWatchOnNodes(WatchRecord record) async {
    try {
      final devices = await ref.read(devicesProvider.future);
      for (final d in devices) {
        if (!d.online || d.deviceType == 'pinetime') continue;
        try {
          await NodeClient.instance.post(d.uuid, '/api/v1/ble/enroll',
              body: {
                'address': record.bleId,
                'kind': 'watch',
                'name': record.name ?? 'PineTime',
              },);
        } catch (e) {
          // Offline/no-tunnel nodes: they can still be enrolled later
          // from the node's own API once they're back.
          debugPrint('[watch] enroll on ${d.name}: $e');
        }
      }
    } catch (e) {
      debugPrint('[watch] enroll device list: $e');
    }
  }

  Future<void> _waitConnected(WatchLink link, WatchRecord record) =>
      link.connection
          .firstWhere((s) => s == BluetoothConnectionState.connected)
          .timeout(const Duration(seconds: 60),
              onTimeout: () => throw TimeoutException(
                  '${record.name ?? 'watch'} unreachable — keep it awake '
                  'and in range'),);

  /// Non-blocking adopt — the record lands in secure storage
  /// immediately (the card appears at once, no modal spinner), then the
  /// BLE connect runs in the background. Brain pairing is deferred: on
  /// failure the link still streams locally and the token is retried on
  /// next launch.
  Future<WatchRecord> adopt(String bleId, {String? name}) async {
    final rec = WatchRecord(
      bleId: bleId,
      deviceUuid: WatchRelay.deviceUuidFor(bleId),
      name: name ?? 'PineTime',
    );
    await WatchStore.instance.upsert(rec);
    await ref.read(watchListProvider.notifier).refresh();
    unawaited(() async {
      try {
        await connect(rec);
      } catch (e) {
        debugPrint('[watch] adopt connect: $e');
      }
    }());
    unawaited(_pairInBackground(rec));
    return rec;
  }

  Future<void> _pairInBackground(WatchRecord rec) async {
    try {
      final paired = await WatchRelay.pair(rec.bleId, name: rec.name);
      await WatchStore.instance.upsert(paired);
      await ref.read(watchListProvider.notifier).refresh();
      state[rec.bleId]?.record = paired;
    } catch (e) {
      debugPrint('[watch] background pairing failed (retries on '
          'next launch): $e');
    }
  }

  /// Pair + connect a newly scanned watch in one shot. [onStage]
  /// reports progress ('pairing' → 'connecting') for the dialog.
  Future<WatchRecord> pairAndConnect(String bleId,
      {String? name, void Function(String stage)? onStage,}) async {
    onStage?.call('pairing');
    final record = await WatchRelay.pair(bleId, name: name);
    await WatchStore.instance.upsert(record);
    await ref.read(watchListProvider.notifier).refresh();
    onStage?.call('connecting');
    await connect(record);
    return record;
  }

  Future<void> disconnect(String bleId) async {
    await _scanSubs.remove(bleId)?.cancel();
    await state[bleId]?.dispose();
    state = {...state}..remove(bleId);
    if (state.isEmpty) await TraceService.instance.detach();
  }
}

/// BLE scan results filtered to InfiniTime/PineTime advertisers.
final watchScanProvider =
    StreamProvider.autoDispose<List<ScanResult>>((ref) => WatchLink.scan());

/// Latest telemetry per watch (broadcast, replayed to late listeners).
final watchTelemetryProvider = StreamProvider.autoDispose
    .family<WatchTelemetry, String>((ref, bleId) {
  final relay = ref.watch(watchManagerProvider)[bleId];
  return relay?.telemetry ?? const Stream.empty();
});

/// Connection state per watch.
final watchConnectionProvider = StreamProvider.autoDispose
    .family<BluetoothConnectionState, String>((ref, bleId) {
  final relay = ref.watch(watchManagerProvider)[bleId];
  return relay?.link?.connection ?? const Stream.empty();
});
