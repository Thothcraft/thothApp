import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// InfiniTime application-mode DFU — the watch's own DfuService
/// (``00001530`` Nordic legacy DFU layout, custom packet/control-point
/// protocol) receives the image into external flash while the BLE link
/// stays up, then reboots into mcuboot which swaps the image.
///
/// This is NOT Nordic Secure DFU — ``nordic_dfu`` cannot drive this
/// service, which is why the previous flow dropped the link and died.
/// Protocol per ``src/components/ble/DfuService.cpp``:
///
///   1. CP write ``[0x01, 0x04]``             → state Start (app image)
///   2. PACKET write 12 B LE sizes           → flash erase, then
///      CP notify ``{0x10,0x01,0x01}``        → state Init
///   3. PACKET write .dat init packet        → expectedCrc parsed
///   4. CP write ``[0x02, 0x01]``            → CP notify ``{0x10,0x02,0x01}``
///   5. CP write ``[0x08, n]``               → packet-receipt cadence
///   6. CP write ``[0x03]``                  → state Data
///   7. PACKET writes: .bin in ≤20 B chunks  → CP notify ``{0x10,0x03,0x01}``
///      (and ``{0x11, <bytes u32>}`` every n packets)
///   8. CP write ``[0x04]`` validate         → CP notify ``{0x10,0x04,0x01}``
///   9. CP write ``[0x05]`` activate         → device resets
class LegacyDfu {
  LegacyDfu(this.device);

  final BluetoothDevice device;

  static final _svcDfu =
      Guid('00001530-1212-efde-1523-785feabcd123');
  static final _charControlPoint =
      Guid('00001531-1212-efde-1523-785feabcd123');
  static final _charPacket =
      Guid('00001532-1212-efde-1523-785feabcd123');

  BluetoothCharacteristic? _cp;
  BluetoothCharacteristic? _pkt;
  StreamSubscription<List<int>>? _cpSub;
  final _cpValues = StreamController<List<int>>.broadcast();

  /// Progress callback: (percent 0-100, stage label).
  void Function(int percent, String stage)? onProgress;

  /// Extract (bin, dat) from a ``*-dfu.zip`` — mcuboot zips carry a
  /// manifest.json + the image + init packet.
  static (Uint8List bin, Uint8List dat) unpackZip(String zipPath) =>
      unpackBytes(File(zipPath).readAsBytesSync());

  /// Same as [unpackZip] but for bytes already in memory (app-bundled
  /// asset, downloaded buffer).
  static (Uint8List bin, Uint8List dat) unpackBytes(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);
    Uint8List? bin, dat;
    for (final f in zip.files) {
      if (!f.isFile) continue;
      final name = f.name.toLowerCase();
      if (name.endsWith('.bin')) bin = f.content;
      if (name.endsWith('.dat')) dat = f.content;
    }
    if (bin == null || dat == null) {
      throw StateError('DFU zip lacks .bin/.dat (found '
          '${zip.files.map((f) => f.name).join(', ')})');
    }
    return (bin, dat);
  }

  Future<void> _resolve() async {
    final services = await device.discoverServices();
    for (final s in services) {
      if (s.serviceUuid != _svcDfu) continue;
      for (final c in s.characteristics) {
        if (c.characteristicUuid == _charControlPoint) _cp = c;
        if (c.characteristicUuid == _charPacket) _pkt = c;
      }
    }
    if (_cp == null || _pkt == null) {
      throw StateError(
          'DFU service not on this watch (stock bootloader build?)',);
    }
  }

  /// Write honoring the char's declared properties, retrying the
  /// transient Android `writeCharacteristic() returned false` case — it
  /// means the request never entered the gatt queue (link busy with the
  /// link-layer's housekeeping ops), so a retry cannot double-apply.
  Future<void> _write(BluetoothCharacteristic c, List<int> bytes,
      {required bool preferNoResponse,}) async {
    final noRsp = preferNoResponse
        ? c.properties.writeWithoutResponse
        : !c.properties.write;
    Object? last;
    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await c.write(bytes, withoutResponse: noRsp);
        return;
      } catch (e) {
        last = e;
        if (!e.toString().contains('returned false')) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 20 + attempt * 40));
      }
    }
    throw last ?? StateError('DFU write failed');
  }

  Future<void> _cpWrite(List<int> bytes) =>
      _write(_cp!, bytes, preferNoResponse: false);

  Future<void> _pktWrite(List<int> bytes) =>
      _write(_pkt!, bytes, preferNoResponse: true);

  /// Wait for a control-point response ``{0x10, opcode, status}``.
  /// `firstWhere().timeout()` — the previous await-for checked its
  /// deadline only when a notification *arrived*, so a silent link
  /// (or a missed notify) hung the upload forever.
  Future<void> _awaitResp(int opcode,
      {Duration timeout = const Duration(seconds: 30),}) async {
    final v = await _cpValues.stream
        .firstWhere((v) =>
            v.isNotEmpty && v[0] == 0x10 && v.length >= 3 && v[1] == opcode,)
        .timeout(timeout, onTimeout: () => throw TimeoutException(
            'no response for DFU op 0x${opcode.toRadixString(16)}',),);
    if (v[2] != 0x01) {
      throw StateError('DFU op 0x${opcode.toRadixString(16)} '
          'rejected: status ${v[2]}');
    }
  }

  /// Full transfer. Throws on protocol error; the caller owns the
  /// post-reboot reconnect.
  Future<void> run(Uint8List bin, Uint8List dat) async {
    if (!device.isConnected) {
      throw StateError('watch is not connected — retry once the link is up');
    }
    await _resolve();
    await _cp!.setNotifyValue(true);
    _cpSub = _cp!.onValueReceived.listen(_cpValues.add);
    try {
      onProgress?.call(0, 'Starting DFU…');
      await _cpWrite([0x01, 0x04]); // StartDFU, image type Application
      // Sizes on the packet char kick off the flash erase — the ok
      // response only arrives after ~470 KB of sectors are cleared.
      final sizes = ByteData(12)
        ..setUint32(0, 0, Endian.little) // softdevice
        ..setUint32(4, 0, Endian.little) // bootloader
        ..setUint32(8, bin.length, Endian.little); // application
      await _pktWrite(sizes.buffer.asUint8List());
      await _awaitResp(0x01, timeout: const Duration(seconds: 45));
      onProgress?.call(1, 'Flash erased — sending init packet…');

      await _pktWrite(dat);
      await _cpWrite([0x02, 0x01]); // InitDFUParameters complete
      // PRN every 50 packets ≈ 1 kB — paces the write window and gives
      // firmware-side progress ticks. (0 would div-by-zero the counter.)
      await _cpWrite([0x08, 50]);
      await _awaitResp(0x02);
      onProgress?.call(2, 'Uploading firmware…');

      await _cpWrite([0x03]); // ReceiveFirmwareImage
      // Stream the image in ≤20-byte writes (DfuImage::Init rejects any
      // other chunk size). Pace on packet-receipt notifications so the
      // BLE write queue never overflows.
      var sent = 0;
      var ackedBytes = 0;
      for (var off = 0; off < bin.length; off += 20) {
        final end =
            (off + 20 > bin.length) ? bin.length : off + 20;
        await _pktWrite(bin.sublist(off, end));
        sent += end - off;
        if (sent % 1000 == 0) {
          // Yield to let PRN notifications land + report progress.
          await Future<void>.delayed(const Duration(milliseconds: 4));
          onProgress?.call(
              2 + (95 * sent ~/ bin.length),
              'Uploading… ${(sent / 1024).toStringAsFixed(0)}/'
              '${(bin.length / 1024).toStringAsFixed(0)} kB');
        }
      }
      // Completion response on the control point.
      final complete = Completer<void>();
      late StreamSubscription<List<int>> prnSub;
      prnSub = _cpValues.stream.listen((v) {
        if (v.isNotEmpty && v[0] == 0x11 && v.length >= 5) {
          ackedBytes = ByteData.sublistView(Uint8List.fromList(v))
              .getUint32(1, Endian.little);
        }
        if (v.length >= 3 && v[0] == 0x10 && v[1] == 0x03) {
          if (!complete.isCompleted) complete.complete();
        }
      });
      try {
        await complete.future
            .timeout(const Duration(seconds: 60));
      } finally {
        await prnSub.cancel();
      }
      onProgress?.call(98, 'Validating… acked=${ackedBytes}B');
      await _cpWrite([0x04]); // ValidateFirmware
      await _awaitResp(0x04);
      onProgress?.call(99, 'Activating — watch rebooting…');
      try {
        await _cpWrite([0x05]); // ActivateImageAndReset
      } catch (_) {
        // Link drops mid-write as the device resets — that's success.
      }
      onProgress?.call(100, 'Done — watch rebooting into new firmware');
    } finally {
      await _cpSub?.cancel();
      _cpSub = null;
    }
  }
}
