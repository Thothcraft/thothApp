import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/event_feed.dart';
import '../../../core/api/node_client.dart';

/// Per-device state fetched through Brain's node relay (CONTRACT §5).
/// All providers are family-keyed by device_uuid and auto-dispose so the
/// detail screen never leaks polling work.

final deviceStatusProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, deviceId) {
  return NodeClient.instance.status(deviceId);
});

final deviceSensorsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, deviceId) {
  return NodeClient.instance.sensors(deviceId);
});

final deviceCapturesProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, deviceId) {
  return NodeClient.instance.captures(deviceId);
});

final deviceAutomationsProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, deviceId) {
  return NodeClient.instance.automations(deviceId);
});

final deviceMetadataProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, deviceId) async {
  try {
    return await NodeClient.instance.metadata(deviceId);
  } catch (_) {
    return <String, dynamic>{}; // node may predate /api/v1/metadata
  }
});

/// Cached room/v1 doc — `{room: {...}|null, cached: bool}`.
final deviceRoomProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, deviceId) async {
  try {
    return await NodeClient.instance.room(deviceId);
  } catch (_) {
    return <String, dynamic>{};
  }
});

/// Node Wi-Fi state — `{state, wifi:{ssid,ip,…}}`; empty map when the
/// node predates /api/v1/net.
final deviceNetProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, deviceId) async {
  try {
    return await NodeClient.instance.netStatus(deviceId);
  } catch (_) {
    return <String, dynamic>{};
  }
});

/// Attached ESP32 (thoth_csi) boards — `{boards: [{name, mac, role,
/// ssid, ip, connected, serial_port}]}` as last reported on serial.
final deviceEsp32Provider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((ref, deviceId) async {
  try {
    return await NodeClient.instance.esp32Status(deviceId);
  } catch (_) {
    return <String, dynamic>{'boards': const []};
  }
});

/// Event feed (CONTRACT §6): shared SSE subscription to
/// `/v1/events/stream` — pushed, not polled. Each emission is a
/// one-element batch (the same `List<Map>` shape the listener expects),
/// filtered to this device.
final deviceEventFeedProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, deviceId) {
  return EventFeed.instance.events.map(
      (batch) => batch.where((e) =>
          (e['device_id'] as String?) == deviceId ||
          ((e['data'] as Map?)?['device_id'] as String?) == deviceId,)
          .toList(),
    ).where((batch) => batch.isNotEmpty);
});
