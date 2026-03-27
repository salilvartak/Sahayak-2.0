import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Plays short audio chimes to signal state transitions.
/// Tones are generated programmatically as WAV bytes — no asset files needed.
/// Bytes are written to temp files once and played via DeviceFileSource,
/// which is more reliable than BytesSource on Android.
///
/// Three distinct sounds:
///   listening  → two ascending tones (660 Hz → 880 Hz)  "I'm ready"
///   thinking   → single soft low tone (440 Hz)           "processing"
///   speaking   → two descending tones (880 Hz → 660 Hz)  "here it comes"
class SoundService {
  final AudioPlayer _player = AudioPlayer()..setAudioContext(
    AudioContext(
      android: AudioContextAndroid(
        isSpeakerphoneOn: false,
        stayAwake: false,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.gain,
      ),
    ),
  );

  // Pre-generate bytes once
  final Uint8List _listeningBytes = _generate([
    _Tone(frequency: 660, durationMs: 150, amplitude: 0.80),
    _Tone(frequency: 880, durationMs: 200, amplitude: 0.85),
  ]);

  final Uint8List _thinkingBytes = _generate([
    _Tone(frequency: 440, durationMs: 220, amplitude: 0.70),
  ]);

  final Uint8List _speakingBytes = _generate([
    _Tone(frequency: 880, durationMs: 150, amplitude: 0.80),
    _Tone(frequency: 660, durationMs: 200, amplitude: 0.75),
  ]);

  // Cached temp file paths (written during initialize)
  String? _listeningPath;
  String? _thinkingPath;
  String? _speakingPath;

  /// Write all WAV files to temp storage once at startup.
  Future<void> initialize() async {
    debugPrint('[Sound] initialize() start');
    _listeningPath = await _writeTempFile('chime_listening.wav', _listeningBytes);
    _thinkingPath  = await _writeTempFile('chime_thinking.wav',  _thinkingBytes);
    _speakingPath  = await _writeTempFile('chime_speaking.wav',  _speakingBytes);
    debugPrint('[Sound] initialize() done — paths: $_listeningPath | $_thinkingPath | $_speakingPath');

    // Log player state changes
    _player.onPlayerStateChanged.listen((s) => debugPrint('[Sound] Player state → $s'));
    _player.onLog.listen((msg) => debugPrint('[Sound] audioplayers log: $msg'));
  }

  Future<void> playListening() async {
    if (_listeningPath == null) await initialize();
    await _play(_listeningPath!);
  }

  Future<void> playThinking() async {
    if (_thinkingPath == null) await initialize();
    await _play(_thinkingPath!);
  }

  Future<void> playSpeaking() async {
    if (_speakingPath == null) await initialize();
    await _play(_speakingPath!);
  }

  Future<String> _writeTempFile(String name, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true, mode: FileMode.writeOnly);
    final exists = await file.exists();
    debugPrint('[Sound] Wrote $name — ${bytes.length} bytes — exists=$exists — path=${file.path}');
    return file.path;
  }

  Future<void> _play(String path) async {
    try {
      final file = File(path);
      final exists = await file.exists();
      debugPrint('[Sound] _play() path=$path exists=$exists playerState=${_player.state}');
      if (!exists) {
        debugPrint('[Sound] File missing — re-initializing');
        await initialize();
      }
      await _player.stop();
      await _player.setVolume(1.0);
      await _player.play(DeviceFileSource(path));
      debugPrint('[Sound] _play() called play() successfully');
    } catch (e, st) {
      debugPrint('[Sound] Playback error: $e\n$st');
    }
  }

  void dispose() => _player.dispose();

  // ── WAV generation ─────────────────────────────────────────────────────────

  static const int _sampleRate = 44100;

  /// Generates a WAV byte buffer from a sequence of tone segments.
  /// Each segment runs its full duration; a 10% fade-in and 10% fade-out
  /// envelope is applied to each segment to avoid clicks.
  static Uint8List _generate(List<_Tone> tones) {
    int total = 0;
    for (final t in tones) {
      total += (_sampleRate * t.durationMs / 1000).round();
    }

    final pcm = Int16List(total);
    int offset = 0;

    for (final tone in tones) {
      final int n = (_sampleRate * tone.durationMs / 1000).round();
      for (int i = 0; i < n; i++) {
        final double phase = i / n;

        final double env = phase < 0.10
            ? phase / 0.10
            : phase > 0.90
                ? (1.0 - phase) / 0.10
                : 1.0;

        final double sample =
            math.sin(2 * math.pi * tone.frequency * i / _sampleRate);
        pcm[offset + i] =
            (sample * env * tone.amplitude * 32767).round().clamp(-32767, 32767);
      }
      offset += n;
    }

    return _wavWrap(pcm);
  }

  /// Wraps raw 16-bit mono PCM samples in a minimal WAV header.
  static Uint8List _wavWrap(Int16List pcm) {
    final Uint8List data = pcm.buffer.asUint8List();
    final int dataLen = data.length;
    final ByteData hdr = ByteData(44 + dataLen);

    // RIFF chunk
    hdr
      ..setUint8(0, 0x52) ..setUint8(1, 0x49)  // 'R' 'I'
      ..setUint8(2, 0x46) ..setUint8(3, 0x46)  // 'F' 'F'
      ..setUint32(4, 36 + dataLen, Endian.little)
      ..setUint8(8, 0x57) ..setUint8(9, 0x41)  // 'W' 'A'
      ..setUint8(10, 0x56) ..setUint8(11, 0x45) // 'V' 'E'
      // fmt sub-chunk
      ..setUint8(12, 0x66) ..setUint8(13, 0x6D) // 'f' 'm'
      ..setUint8(14, 0x74) ..setUint8(15, 0x20) // 't' ' '
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)          // PCM
      ..setUint16(22, 1, Endian.little)          // mono
      ..setUint32(24, _sampleRate, Endian.little)
      ..setUint32(28, _sampleRate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      // data sub-chunk
      ..setUint8(36, 0x64) ..setUint8(37, 0x61) // 'd' 'a'
      ..setUint8(38, 0x74) ..setUint8(39, 0x61) // 't' 'a'
      ..setUint32(40, dataLen, Endian.little);

    final Uint8List out = hdr.buffer.asUint8List();
    out.setRange(44, 44 + dataLen, data);
    return out;
  }
}

class _Tone {
  final double frequency;
  final int durationMs;
  final double amplitude; // 0.0–1.0

  const _Tone({
    required this.frequency,
    required this.durationMs,
    required this.amplitude,
  });
}
