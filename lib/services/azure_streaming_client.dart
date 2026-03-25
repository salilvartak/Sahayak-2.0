import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

class AzureStreamingClient {
  final String _key = dotenv.env['AZURE_SPEECH_KEY'] ?? '';
  final String _region = dotenv.env['AZURE_SPEECH_REGION'] ?? 'eastus';
  
  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  
  final Function(String partialText) onPartialResult;
  final Function(String finalResult, String language) onFinalResult;
  final Function(String error) onError;

  AzureStreamingClient({
    required this.onPartialResult,
    required this.onFinalResult,
    required this.onError,
  });

  Future<void> startStream({String language = 'en-US'}) async {
    final connectionId = const Uuid().v4().replaceAll('-', '');
    final url =
        'wss://$_region.stt.speech.microsoft.com/speech/recognition/interactive/cognitiveservices/v1'
        '?language=$language&format=detailed&Ocp-Apim-Subscription-Key=$_key&X-ConnectionId=$connectionId';

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));

      _channelSub = _channel!.stream.listen((message) {
        if (message is String) {
          _handleTextMessage(message);
        }
      }, onError: (e) {
        onError('Socket Error: $e');
      }, onDone: () {
        debugPrint('Azure WS Stream Closed');
      });

      // 1. Send speech.config message
      _sendSpeechConfig(connectionId);
      
      // 2. Send WAV header so Azure knows the format
      final builder = BytesBuilder();
      _writeWavHeader(builder, 0, 16000, 1, 16);
      sendAudioChunk(builder.toBytes());
      
    } catch (e) {
      onError('Connection Error: $e');
    }
  }

  void _handleTextMessage(String message) {
    // Azure messages contain HTTP-like headers followed by JSON
    final headerEnd = message.indexOf('\r\n\r\n');
    if (headerEnd == -1) return;

    final headerText = message.substring(0, headerEnd);
    final bodyText = message.substring(headerEnd + 4);

    if (headerText.contains('Path: speech.hypothesis')) {
      // Partial result
      try {
        final json = jsonDecode(bodyText);
        final text = json['Text'] ?? '';
        if (text.isNotEmpty) onPartialResult(text);
      } catch (_) {}
    } else if (headerText.contains('Path: speech.phrase')) {
      // Final result for this utterance
      try {
        final json = jsonDecode(bodyText);
        if (json['RecognitionStatus'] == 'Success') {
          final text = json['DisplayText'] ?? '';
          if (text.isNotEmpty) onFinalResult(text, 'en-US'); // Fallback language identifier
        }
      } catch (_) {}
    }
  }

  void _sendSpeechConfig(String connectionId) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final message = 'Path: speech.config\r\n'
        'Content-Type: application/json; charset=utf-8\r\n'
        'X-Timestamp: $timestamp\r\n\r\n'
        '{"context":{"system":{"name":"SpeechSDK","version":"1.0.0","build":"Custom","lang":"Dart"}}}';
    _channel?.sink.add(message);
  }

  void sendAudioChunk(Uint8List chunk) {
    if (_channel == null) return;
    
    // Azure expects a 2-byte length header for the ASCII text headers, then the binary payload
    const headers = 'Path: audio\r\nContent-Type: audio/x-wav\r\n\r\n';
    final headerBytes = utf8.encode(headers);
    final headerLengthBytes = ByteData(2)..setInt16(0, headerBytes.length, Endian.big);
    
    final builder = BytesBuilder();
    builder.add(headerLengthBytes.buffer.asUint8List());
    builder.add(headerBytes);
    builder.add(chunk);
    
    _channel?.sink.add(builder.toBytes());
  }

  void stopStream() {
    _channel?.sink.close();
    _channelSub?.cancel();
    _channel = null;
  }

  void _writeWavHeader(BytesBuilder builder, int dataSize, int sampleRate, int channels, int bitDepth) {
    final byteRate = sampleRate * channels * (bitDepth ~/ 8);
    final blockAlign = channels * (bitDepth ~/ 8);

    builder.add(utf8.encode('RIFF'));
    builder.add([0, 0, 0, 0]); // Data size logic ignores length for streaming
    builder.add(utf8.encode('WAVE'));
    builder.add(utf8.encode('fmt '));
    builder.add([16, 0, 0, 0]);
    builder.add([1, 0]);
    builder.add([channels, 0]);
    builder.add([sampleRate & 0xff, (sampleRate >> 8) & 0xff, (sampleRate >> 16) & 0xff, (sampleRate >> 24) & 0xff]);
    builder.add([byteRate & 0xff, (byteRate >> 8) & 0xff, (byteRate >> 16) & 0xff, (byteRate >> 24) & 0xff]);
    builder.add([blockAlign, 0]);
    builder.add([bitDepth, 0]);
    builder.add(utf8.encode('data'));
    builder.add([0, 0, 0, 0]);
  }
}
