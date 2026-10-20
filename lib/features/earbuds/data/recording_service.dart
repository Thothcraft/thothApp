import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../../core/api/brain_client.dart';

/// Phone-side audio capture driven by the buds' thoth actions.
///
/// A long-press mapped to ``thoth_voice`` (0x10) toggles a session:
/// mic → AAC file in app documents. [syncEnabled] uploads the finished
/// file to Brain ``/api/file/upload`` against the buds' device uuid.
/// Mic on/off pauses/resumes the stream inside a session so a single
/// recording can cover a conversation with gaps cut out.
///
/// Android exposes no playback-capture API to a normal app — "speaker"
/// is only ever ambient pickup through the mic.
class RecordingService extends ChangeNotifier {
  RecordingService._();
  static final RecordingService instance = RecordingService._();

  final AudioRecorder _recorder = AudioRecorder();

  bool _recording = false;
  bool _paused = false;
  bool _micEnabled = true;
  bool _syncEnabled = false;
  String? _path;
  String? _deviceUuid;
  String? _captureId;
  String? _lastFile;
  String? _lastError;
  String? _uploadState;
  DateTime? _startedAt;
  Timer? _tick;

  bool get recording => _recording;
  bool get paused => _paused;
  bool get micEnabled => _micEnabled;
  bool get syncEnabled => _syncEnabled;
  String? get lastFile => _lastFile;
  String? get lastError => _lastError;
  String? get uploadState => _uploadState;
  Duration get elapsed =>
      _startedAt == null ? Duration.zero : DateTime.now().difference(_startedAt!);

  /// Long-press entry point — toggles the session on/off.
  Future<void> toggle({String? deviceUuid}) async =>
      _recording ? await stop() : await start(deviceUuid: deviceUuid);

  Future<void> setSyncEnabled(bool v) async {
    _syncEnabled = v;
    notifyListeners();
  }

  /// Mic switch mid-session — pause/resume so the file has no gaps,
  /// rather than splitting one conversation across many files.
  Future<void> setMicEnabled(bool v) async {
    _micEnabled = v;
    if (_recording) {
      try {
        if (v && _paused) {
          await _recorder.resume();
          _paused = false;
        } else if (!v && !_paused) {
          await _recorder.pause();
          _paused = true;
        }
      } catch (e) {
        _lastError = '$e';
      }
    }
    notifyListeners();
  }

  Future<void> start({String? deviceUuid}) async {
    if (_recording) return;
    _lastError = null;
    try {
      final perm = await Permission.microphone.request();
      if (!perm.isGranted) {
        _lastError = 'microphone permission denied';
        notifyListeners();
        return;
      }
      final dir = await getApplicationDocumentsDirectory();
      final recDir = Directory('${dir.path}/recordings');
      await recDir.create(recursive: true);
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      _path = '${recDir.path}/buds_$stamp.m4a';
      _deviceUuid = deviceUuid;

      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _path!,
      );
      _startedAt = DateTime.now();
      _recording = true;
      _paused = !_micEnabled;
      if (_paused) await _recorder.pause();
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        notifyListeners();
      });

      // Register a Brain capture for the session so the timeline shows
      // the same collect→upload lifecycle other devices produce.
      if (deviceUuid != null && BrainClient.instance.hasToken) {
        unawaited(BrainClient.instance
            .startCapture(deviceUuid, sensors: const ['microphone'])
            .then((c) {
          _captureId = '${c['id'] ?? ''}';
        }).catchError((Object _) {}));
      }
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      _recording = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!_recording) return;
    _tick?.cancel();
    _tick = null;
    _recording = false;
    _paused = false;
    try {
      final out = await _recorder.stop();
      _lastFile = out ?? _path;
    } catch (e) {
      _lastError = '$e';
    }
    final cap = _captureId;
    _captureId = null;
    if (cap != null && cap.isNotEmpty && BrainClient.instance.hasToken) {
      unawaited(BrainClient.instance
          .stopCapture(cap)
          .catchError((Object _) => <String, dynamic>{}));
    }
    notifyListeners();
    if (_syncEnabled && _lastFile != null) {
      unawaited(_sync(_lastFile!));
    }
  }

  Future<void> _sync(String path) async {
    _uploadState = 'uploading';
    notifyListeners();
    try {
      final bytes = await File(path).readAsBytes();
      await BrainClient.instance.postJson('/file/upload', body: {
        'filename': path.split(Platform.pathSeparator).last,
        'content': base64.encode(bytes),
        'content_type': 'audio/mp4',
        'is_base64': true,
        if (_deviceUuid != null) 'device_id': _deviceUuid,
        'metadata': {
          'source': 'pinebuds-longpress',
          'kind': 'audio',
          if (_captureId != null) 'capture_id': _captureId,
        },
      });
      _uploadState = 'synced';
    } catch (e) {
      _uploadState = 'failed';
      _lastError = '$e';
    }
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _tick?.cancel();
    await _recorder.dispose();
    super.dispose();
  }
}
