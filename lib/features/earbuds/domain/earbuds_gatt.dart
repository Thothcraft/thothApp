import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// thoth.wear/v1 — PineBuds Pro (thothBuds firmware) GATT surface.
///
/// Mirrors ``thoth/thoth/bluetooth/pinebuds.py`` — keep payload layouts
/// in sync with ``architecture/wearables-integration.md`` §3. All value
/// attributes require an encrypted link; pairing is Just Works (the buds
/// have no IO), so flutter_blue_plus's default bond flow suffices.
class EarbudsGatt {
  EarbudsGatt._();

  static const _base = '-01c4-4d1e-9b2f-0011778899aa';
  static final service = Guid('a0630200$_base');
  static final charInfo = Guid('a0630201$_base');    // READ
  static final charStatus = Guid('a0630202$_base');  // READ + NOTIFY
  static final charEvent = Guid('a0630203$_base');   // NOTIFY
  static final charControl = Guid('a0630204$_base'); // WRITE

  /// Stock OpenPineBuds config service — its presence on a scan result
  /// also identifies the buds before ours is connected.
  static final opbConfigService =
      Guid('0000ffc0-0000-1000-8000-00805f9b34fb');

  /// Advertised name on current firmware builds.
  static bool looksLikeBuds(ScanResult r) {
    final name = (r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName)
        .toLowerCase();
    if (name.contains('pinebuds') || name.contains('bes_ble') ||
        name == 'buds') {
      return true;
    }
    final uuids = r.advertisementData.serviceUuids;
    return uuids.contains(service) || uuids.contains(opbConfigService);
  }
}

class BudsInfo {
  const BudsInfo(
      {required this.proto, required this.firmware, this.side, this.caps = 0});

  final int proto;
  final String firmware;
  final String? side; // null | 'left' | 'right'
  final int caps;

  bool get gestureEvents => (caps & 1) != 0;
  bool get battery => (caps & 2) != 0;
  bool get sessionFeedback => (caps & 4) != 0;
  bool get anc => (caps & 8) != 0;
  bool get twsPeerStatus => (caps & 0x10) != 0;
  bool get micHfp => (caps & 0x20) != 0;
}

class BudsStatus {
  const BudsStatus({
    required this.seq,
    required this.tickMs,
    this.batteryPct,
    this.peerBatteryPct,
    this.twsLinked = false,
    this.a2dpStreaming = false,
    this.scoCall = false,
    this.ancOn = false,
    this.charging = false,
    this.roleMaster = false,
    this.session = 'idle',
  });

  final int seq;
  final int tickMs;
  final int? batteryPct;
  final int? peerBatteryPct;
  final bool twsLinked;
  final bool a2dpStreaming;
  final bool scoCall;
  final bool ancOn;
  final bool charging;
  final bool roleMaster;
  final String session;

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'tick_ms': tickMs,
        'battery_pct': batteryPct,
        'peer_battery_pct': peerBatteryPct,
        'tws_linked': twsLinked,
        'a2dp_streaming': a2dpStreaming,
        'sco_call': scoCall,
        'anc_on': ancOn,
        'charging': charging,
        'role_master': roleMaster,
        'session': session,
        'kind': 'earbuds',
        'model': 'pinebuds-pro',
      };
}

class BudsEvent {
  const BudsEvent({
    required this.seq,
    required this.tickMs,
    this.side,
    this.gesture,
    this.action,
    this.actionCode = 0,
    this.thothAction = false,
  });

  final int seq;
  final int tickMs;
  final String? side;
  final String? gesture;
  final String? action;
  final int actionCode;
  final bool thothAction;

  Map<String, dynamic> toJson() => {
        'seq': seq,
        'tick_ms': tickMs,
        'side': side,
        'gesture': gesture,
        'action': action,
        'action_code': actionCode,
        'thoth_action': thothAction,
        'kind': 'earbuds',
        'model': 'pinebuds-pro',
      };
}

class EarbudsCodec {
  EarbudsCodec._();

  static const _sides = {0: null, 1: 'left', 2: 'right'};
  static const _sessions = {
    0: 'idle', 1: 'listening', 2: 'processing', 3: 'speaking',
  };
  static const _gestures = {
    1: 'single_tap', 2: 'double_tap', 3: 'triple_tap', 4: 'long_press',
  };
  static const _actions = {
    0x0000: 'none', 0x0001: 'play_pause', 0x0002: 'next_track',
    0x0003: 'previous_track', 0x0004: 'volume_up', 0x0005: 'volume_down',
    0x0006: 'toggle_anc', 0x0007: 'voice_assistant', 0x0008: 'answer_call',
    0x0009: 'reject_call', 0x000A: 'end_call', 0x000B: 'mute_mic',
    0x000C: 'transparency', 0x000D: 'anc_off', 0x000E: 'custom_1',
    0x000F: 'custom_2',
    0x0010: 'thoth_voice_toggle', 0x0011: 'thoth_voice_end',
    0x0012: 'thoth_context', 0x0013: 'thoth_automation_1',
    0x0014: 'thoth_automation_2', 0x0015: 'thoth_automation_3',
  };

  /// INFO `<BBBBBHB` — proto, fw major/minor/patch, side, caps, rsv.
  static BudsInfo? decodeInfo(List<int> v) {
    if (v.length < 8) return null;
    final b = ByteData.sublistView(Uint8List.fromList(v));
    return BudsInfo(
      proto: b.getUint8(0),
      firmware: '${b.getUint8(1)}.${b.getUint8(2)}.${b.getUint8(3)}',
      side: _sides[b.getUint8(4)],
      caps: b.getUint16(5, Endian.little),
    );
  }

  /// STATUS `<BIBBBB` — seq, tick_ms, batt_local, batt_peer, flags, session.
  static BudsStatus? decodeStatus(List<int> v) {
    if (v.length < 9) return null;
    final b = ByteData.sublistView(Uint8List.fromList(v));
    final flags = b.getUint8(7);
    return BudsStatus(
      seq: b.getUint8(0),
      tickMs: b.getUint32(1, Endian.little),
      batteryPct: b.getUint8(5) <= 100 ? b.getUint8(5) : null,
      peerBatteryPct: b.getUint8(6) <= 100 ? b.getUint8(6) : null,
      twsLinked: (flags & 1) != 0,
      a2dpStreaming: (flags & 2) != 0,
      scoCall: (flags & 4) != 0,
      ancOn: (flags & 8) != 0,
      charging: (flags & 0x10) != 0,
      roleMaster: (flags & 0x20) != 0,
      session: _sessions[b.getUint8(8)] ?? 'unknown_${b.getUint8(8)}',
    );
  }

  /// EVENT `<BIBBH` — seq, tick_ms, side, gesture, action.
  static BudsEvent? decodeEvent(List<int> v) {
    if (v.length < 9) return null;
    final b = ByteData.sublistView(Uint8List.fromList(v));
    final action = b.getUint16(7, Endian.little);
    return BudsEvent(
      seq: b.getUint8(0),
      tickMs: b.getUint32(1, Endian.little),
      side: _sides[b.getUint8(5)],
      gesture: _gestures[b.getUint8(6)] ?? 'gesture_${b.getUint8(6)}',
      action: _actions[action] ??
          'action_0x${action.toRadixString(16).padLeft(4, '0')}',
      actionCode: action,
      thothAction: action >= 0x0010,
    );
  }

  static const opSessionState = 0x01;
  static const opEventMask = 0x02;
  static const opEpoch = 0x03;

  static Uint8List encodeSessionState(String state) {
    final code = _sessions.entries
        .firstWhere((e) => e.value == state, orElse: () => const MapEntry(0, ''))
        .key;
    return Uint8List.fromList([opSessionState, code]);
  }

  static Uint8List encodeEventMask(bool allGestures) =>
      Uint8List.fromList([opEventMask, allGestures ? 1 : 0]);

  static Uint8List encodeEpoch([int? epochMs]) {
    final b = ByteData(9)..setUint8(0, opEpoch);
    b.setUint64(1, epochMs ?? DateTime.now().millisecondsSinceEpoch,
        Endian.little);
    return b.buffer.asUint8List();
  }
}
