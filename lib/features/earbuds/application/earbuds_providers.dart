import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/node_client.dart';
import '../../devices/application/devices_provider.dart';
import '../../watch/data/watch_link.dart' show WatchLink;
import '../data/earbuds_link.dart';
import '../data/earbuds_relay.dart';
import '../data/earbuds_store.dart';
import '../data/recording_service.dart';
import '../domain/earbuds_gatt.dart';

/// Paired buds persisted in secure storage.
final earbudsListProvider =
    AsyncNotifierProvider<EarbudsListNotifier, List<EarbudsRecord>>(
        EarbudsListNotifier.new);

class EarbudsListNotifier extends AsyncNotifier<List<EarbudsRecord>> {
  @override
  Future<List<EarbudsRecord>> build() => EarbudsStore.instance.load();

  Future<void> refresh() async {
    state = AsyncData(await EarbudsStore.instance.load());
  }

  Future<void> remove(String bleId) async {
    await EarbudsStore.instance.remove(bleId);
    await refresh();
  }
}

/// One relay per paired buds set — owns link + Brain uplink.
final earbudsManagerProvider =
    NotifierProvider<EarbudsManager, Map<String, EarbudsRelay>>(
        EarbudsManager.new);

class EarbudsManager extends Notifier<Map<String, EarbudsRelay>> {
  Timer? _rssiTimer;
  /// Thoth-action forwarding — one sub per connected link; a bud gesture
  /// mapped to 0x10 toggles the phone's recording session, 0x11 ends it.
  final Map<String, StreamSubscription<BudsTelemetry>> _actionSubs = {};

  @override
  Map<String, EarbudsRelay> build() {
    ref.onDispose(() {
      for (final relay in state.values) {
        relay.dispose();
      }
      for (final sub in _actionSubs.values) {
        sub.cancel();
      }
      _rssiTimer?.cancel();
    });
    ref.listen(earbudsListProvider, (_, next) {
      final records = next.value ?? const <EarbudsRecord>[];
      for (final key in state.keys.toList()) {
        if (!records.any((r) => r.bleId == key)) {
          _actionSubs.remove(key)?.cancel();
          state[key]?.dispose();
          state = {...state}..remove(key);
        }
      }
    });
    // Cold start: re-link every paired set without waiting for a tap —
    // the same "connect persists across app close" contract the watch
    // has. A bud in its case simply retries until it wakes.
    unawaited(_autoConnect());
    // Cheap prox sampling — STATUS is ≤1 Hz on-change, so this keeps
    // the pinebuds-prox stream alive on a deskbound session.
    _rssiTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      for (final r in state.values) {
        if (r.connected) unawaited(r.pollRssi());
      }
    });
    return {};
  }

  bool _autoConnected = false;
  Future<void> _autoConnect() async {
    if (_autoConnected) return;
    _autoConnected = true;
    try {
      final records = await ref.read(earbudsListProvider.future);
      for (final r in records) {
        try {
          await connect(r);
        } catch (e) {
          debugPrint('[buds] auto-connect ${r.bleId}: $e');
        }
      }
    } catch (e) {
      debugPrint('[buds] auto-connect list load: $e');
    }
  }

  EarbudsRelay? relayFor(String bleId) => state[bleId];

  /// Connect (or reuse) the BLE link and start the Brain relay. The
  /// relay is registered before the link lands — telemetry can never
  /// arrive with nowhere to go.
  Future<EarbudsRelay> connect(EarbudsRecord record) async {
    final existing = state[record.bleId];
    if (existing != null) {
      if (existing.connected) return existing;
      await _waitConnected(existing);
      return existing;
    }

    final device = BluetoothDevice.fromId(record.bleId);
    final link = EarbudsLink(device);
    final relay = EarbudsRelay(record);
    await relay.start(link);
    state = {...state, record.bleId: relay};
    // thoth actions → phone-side controls: 0x10 voice toggle (record),
    // 0x11 voice end. The bud emits these as EVENTs once a gesture is
    // mapped to them (Gestures tab).
    _actionSubs[record.bleId]?.cancel();
    _actionSubs[record.bleId] = link.telemetry.listen((t) {
      final ev = t.event;
      if (ev == null || !ev.thothAction) return;
      if (ev.actionCode == 0x10) {
        unawaited(RecordingService.instance
            .toggle(deviceUuid: record.deviceUuid));
      } else if (ev.actionCode == 0x11 &&
          RecordingService.instance.recording) {
        unawaited(RecordingService.instance.stop());
      }
    });
    unawaited(link.connect());
    unawaited(_enrollOnNodes(record));
    await _waitConnected(relay);
    return relay;
  }

  /// Enroll the buds on every online thoth node — a node's central
  /// session takes over streaming whenever the phone releases the link,
  /// which is exactly the "connection persists when the app is
  /// backgrounded / phone pocketed" story.
  Future<void> _enrollOnNodes(EarbudsRecord record) async {
    try {
      final devices = await ref.read(devicesProvider.future);
      for (final d in devices) {
        if (!d.online || d.deviceType == 'pinebuds') continue;
        try {
          await NodeClient.instance.post(d.uuid, '/api/v1/ble/enroll',
              body: {
                'address': record.bleId,
                'kind': 'earbuds',
                'name': record.name ?? 'PineBuds',
              });
        } catch (e) {
          debugPrint('[buds] enroll on ${d.name}: $e');
        }
      }
    } catch (e) {
      debugPrint('[buds] enroll device list: $e');
    }
  }

  Future<void> _waitConnected(EarbudsRelay relay) =>
      relay.link!.connection
          .firstWhere((s) => s == BluetoothConnectionState.connected)
          .timeout(const Duration(seconds: 60),
              onTimeout: () => throw TimeoutException(
                  'buds unreachable — open the case near the phone'));

  /// Non-blocking adopt: the record lands in secure storage immediately
  /// (the accessory list updates at once — no modal spinner), then the
  /// BLE connect runs in the background. Brain pairing is a deferred
  /// step: if it fails (offline), the link still streams locally and
  /// the device registers on next heartbeat tick once a token exists.
  Future<EarbudsRecord> adopt(String bleId, {String? name}) async {
    final rec = EarbudsRecord(
      bleId: bleId,
      deviceUuid: EarbudsRelay.deviceUuidFor(bleId),
      name: name ?? 'PineBuds',
    );
    await EarbudsStore.instance.upsert(rec);
    await ref.read(earbudsListProvider.notifier).refresh();
    unawaited(() async {
      try {
        await connect(rec);
      } catch (e) {
        debugPrint('[buds] adopt connect: $e');
      }
    }());
    unawaited(_pairInBackground(rec));
    return rec;
  }

  Future<void> _pairInBackground(EarbudsRecord rec) async {
    try {
      final paired = await EarbudsRelay.pair(rec.bleId, name: rec.name);
      await EarbudsStore.instance.upsert(paired);
      await ref.read(earbudsListProvider.notifier).refresh();
      // Inject the tokened record — heartbeat picks it up on the next
      // 30 s tick; the live link stays untouched.
      state[rec.bleId]?.record = paired;
    } catch (e) {
      debugPrint('[buds] background pairing failed (retries on '
          'next launch): $e');
    }
  }

  /// Blocking variant kept for flows that need a confirmed link (DFU).
  Future<EarbudsRecord> pairAndConnect(String bleId, {String? name}) async {
    final record = await EarbudsRelay.pair(bleId, name: name);
    await EarbudsStore.instance.upsert(record);
    await ref.read(earbudsListProvider.notifier).refresh();
    await connect(record);
    return record;
  }

  Future<void> disconnect(String bleId) async {
    await _actionSubs.remove(bleId)?.cancel();
    await state[bleId]?.dispose();
    state = {...state}..remove(bleId);
  }
}

/// Unified accessory scan — one BLE scan shared by watches and buds;
/// results carry a kind tag so the sheet can render them together.
enum AccessoryKind { watch, earbuds }

class AccessoryHit {
  const AccessoryHit(this.result, this.kind);
  final ScanResult result;
  final AccessoryKind kind;
}

final accessoryScanProvider =
    StreamProvider.autoDispose<List<AccessoryHit>>((ref) async* {
  final seen = <String, AccessoryHit>{};
  await for (final batch in EarbudsLink.scan()) {
    for (final r in batch) {
      AccessoryKind? kind;
      if (EarbudsGatt.looksLikeBuds(r)) {
        kind = AccessoryKind.earbuds;
      } else if (_looksLikeWatch(r)) {
        kind = AccessoryKind.watch;
      }
      if (kind != null) seen[r.device.remoteId.str] = AccessoryHit(r, kind);
    }
    yield seen.values.toList()
      ..sort((a, b) => b.result.rssi.compareTo(a.result.rssi));
  }
});

bool _looksLikeWatch(ScanResult r) =>
    classifyAccessoryName(r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName) ==
        AccessoryKind.watch;

/// Classify a wearable by advertised/bonded name. Shared by the BLE scan
/// filter and the system-device list — keep name patterns aligned with
/// `EarbudsGatt.looksLikeBuds` and `WatchLink.looksLikeWatch`.
AccessoryKind? classifyAccessoryName(String? name) {
  final n = (name ?? '').toLowerCase();
  if (n.contains('pinebuds') ||
      n.contains('bes_ble') ||
      n.contains('thothbuds') ||
      n == 'buds') {
    return AccessoryKind.earbuds;
  }
  if (n.contains('infinitime') ||
      n.contains('pinetime') ||
      n.contains('pinewatch')) {
    return AccessoryKind.watch;
  }
  return null;
}

/// A wearable the phone's own Bluetooth stack already knows — paired in
/// Android Bluetooth settings or connected at the system level (any
/// profile, e.g. PineBuds A2DP audio). Adopting one attaches the app's
/// GATT telemetry link in parallel; the system keeps owning pairing.
class SystemAccessory {
  const SystemAccessory({
    required this.device,
    required this.kind,
    required this.bonded,
    required this.systemConnected,
  });

  final BluetoothDevice device;
  final AccessoryKind? kind; // null = bonded device with no name match
  final bool bonded;
  final bool systemConnected;

  String get bleId => device.remoteId.str;
  String get displayName {
    final n = device.platformName;
    if (n.isNotEmpty) return n;
    return kind == AccessoryKind.earbuds
        ? 'PineBuds'
        : kind == AccessoryKind.watch
            ? 'PineTime'
            : bleId;
  }
}

/// System-level devices refreshed while watched — polled (binder calls,
/// cheap) so buds connecting/disconnecting in Android settings appear
/// and disappear live in the add sheet. The app-side GATT link state is
/// separate: a bonded PineBuds streaming audio counts as
/// system-connected even before the app attaches its telemetry link.
final systemAccessoriesProvider =
    StreamProvider.autoDispose<List<SystemAccessory>>((ref) async* {
  while (true) {
    yield await _listSystemAccessories();
    await Future<void>.delayed(const Duration(seconds: 3));
  }
});

Future<List<SystemAccessory>> _listSystemAccessories() async {
  try {
    await WatchLink.ensurePermissions();
  } catch (_) {}
  final out = <String, SystemAccessory>{};
  // Bonded (paired in system settings) — catches PineBuds on A2DP even
  // when they hold no LE link at all.
  try {
    for (final d in await FlutterBluePlus.bondedDevices) {
      out[d.remoteId.str] = SystemAccessory(
        device: d,
        kind: classifyAccessoryName(d.platformName),
        bonded: true,
        systemConnected: d.isConnected,
      );
    }
  } catch (e) {
    debugPrint('[accessory] bondedDevices: $e');
  }
  // Connected at the system level by any app (GATT-visible).
  try {
    for (final d
        in await FlutterBluePlus.systemDevices([Guid('1800')])) {
      final id = d.remoteId.str;
      final prev = out[id];
      out[id] = SystemAccessory(
        device: d,
        kind: classifyAccessoryName(d.platformName) ?? prev?.kind,
        bonded: prev?.bonded ?? false,
        systemConnected: true,
      );
    }
  } catch (e) {
    debugPrint('[accessory] systemDevices: $e');
  }
  final list = out.values.toList();
  // Wearables first, other paired devices after; connected before idle.
  list.sort((a, b) {
    final aw = a.kind != null ? 0 : 1;
    final bw = b.kind != null ? 0 : 1;
    if (aw != bw) return aw - bw;
    final ac = a.systemConnected ? 0 : 1;
    final bc = b.systemConnected ? 0 : 1;
    if (ac != bc) return ac - bc;
    return a.displayName.compareTo(b.displayName);
  });
  return list;
}

/// Latest telemetry per buds device.
final earbudsTelemetryProvider = StreamProvider.autoDispose
    .family<BudsTelemetry, String>((ref, bleId) {
  final relay = ref.watch(earbudsManagerProvider)[bleId];
  return relay?.telemetry ?? const Stream.empty();
});

/// Connection state per buds device.
final earbudsConnectionProvider = StreamProvider.autoDispose
    .family<BluetoothConnectionState, String>((ref, bleId) {
  final relay = ref.watch(earbudsManagerProvider)[bleId];
  return relay?.link?.connection ?? const Stream.empty();
});
