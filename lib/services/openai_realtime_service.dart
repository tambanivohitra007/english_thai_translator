import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

/// Events emitted by the service
abstract class RealtimeEvent {}

class AudioEvent extends RealtimeEvent {
  final Uint8List bytes;
  AudioEvent(this.bytes);
}

class TextEvent extends RealtimeEvent {
  final String text;
  final bool isUser;
  TextEvent(this.text, {this.isUser = false});
}

class StatusEvent extends RealtimeEvent {
  final String message;
  final bool isError;
  StatusEvent(this.message, {this.isError = false});
}

class BargeInEvent extends RealtimeEvent {}

class OpenAIRealtimeService {
  final String apiKey;
  final String model;

  WebSocketChannel? _websocket;
  StreamSubscription? _wsSubscription;

  // Stream Controllers
  final _eventController = StreamController<RealtimeEvent>.broadcast();
  Stream<RealtimeEvent> get events => _eventController.stream;

  bool get isConnected => _websocket != null;

  OpenAIRealtimeService({
    required this.apiKey,
    this.model = 'gpt-4o-realtime-preview-2025-06-03',
  });

  Future<void> connect() async {
    if (isConnected) return;

    try {
      _emitStatus('Connecting...');
      final url = 'wss://api.openai.com/v1/realtime?model=$model';

      final ws = await WebSocket.connect(
        url,
        headers: {
          'Authorization': 'Bearer $apiKey',
          'OpenAI-Beta': 'realtime=v1',
        },
      );

      _websocket = IOWebSocketChannel(ws);
      _wsSubscription = _websocket!.stream.listen(
        _handleMessage,
        onError: (e) {
          _emitStatus('Connection error: $e', isError: true);
          disconnect();
        },
        onDone: () {
          _emitStatus('Disconnected');
          disconnect();
        },
      );

      _emitStatus('Connected');
    } on SocketException catch (_) {
      _emitStatus('Network Error: Check Internet', isError: true);
      rethrow;
    } on WebSocketException catch (e) {
      _emitStatus('Connection Failed: ${e.message}', isError: true);
      rethrow;
    } catch (e) {
      _emitStatus('Connection Failed', isError: true);
      rethrow;
    }
  }

  void disconnect() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    _websocket?.sink.close(status.goingAway);
    _websocket = null;
  }

  // ---------------------------------------------------------------------------
  // SESSION MANAGEMENT
  // ---------------------------------------------------------------------------

  Future<void> updateSession({
    required String instructions,
    required String voice,
  }) async {
    if (!isConnected) return;

    // SAFE UPDATE: Cancel any ongoing response before updating
    // This prevents the "cannot update voice if audio is present" error
    await cancelResponse();

    final sessionConfig = {
      'type': 'session.update',
      'session': {
        'modalities': ['text', 'audio'],
        'instructions': instructions,
        'voice': voice,
        'input_audio_format': 'pcm16',
        'output_audio_format': 'pcm16',
        'input_audio_transcription': {'model': 'whisper-1'},
        'turn_detection': {
          'type': 'server_vad',
          'threshold': 0.5,
          'prefix_padding_ms': 300,
          'silence_duration_ms': 800,
        },
        'temperature': 0.6,
      },
    };

    _send(sessionConfig);
  }

  // ---------------------------------------------------------------------------
  // AUDIO & TEXT INPUT
  // ---------------------------------------------------------------------------

  void sendAudioChunk(Uint8List bytes) {
    if (!isConnected) return;
    _send({'type': 'input_audio_buffer.append', 'audio': base64Encode(bytes)});
  }

  void sendText(String text) {
    if (!isConnected) return;

    // Cancel any previous response
    cancelResponse();

    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });

    _send({
      'type': 'response.create',
      'response': {
        'modalities': ['text', 'audio'],
      },
    });
  }

  Future<void> cancelResponse() async {
    if (!isConnected) return;

    // Stop server generation
    _send({'type': 'response.cancel'});

    // Clear server buffer
    _send({'type': 'input_audio_buffer.clear'});

    // Wait a brief moment for server to process
    await Future.delayed(const Duration(milliseconds: 50));
  }

  // ---------------------------------------------------------------------------
  // INTERNAL MESSAGE HANDLING
  // ---------------------------------------------------------------------------

  void _handleMessage(dynamic message) {
    if (message is! String) return;

    try {
      final data = jsonDecode(message);
      final type = data['type'] as String?;

      switch (type) {
        case 'error':
          final error = data['error'] as Map?;
          final msg = (error?['message'] as String? ?? 'Unknown error')
              .toLowerCase();
          // Ignore harmless cancellation errors (handling various formats)
          if (msg.contains('cancellation') ||
              msg.contains('not active response') ||
              msg.contains('no active response')) {
            return;
          }
          _emitStatus('API Error: ${error?['message']}', isError: true);
          break;

        case 'input_audio_buffer.speech_started':
          // BARGE-IN: User started speaking, interrupt the AI
          _emitBargeIn();
          cancelResponse();
          break;

        case 'conversation.item.input_audio_transcription.completed':
          final transcript = data['transcript'] as String?;
          if (transcript != null && transcript.isNotEmpty) {
            _eventController.add(TextEvent(transcript, isUser: true));
          }
          break;

        case 'response.audio_transcript.delta':
          final delta = data['delta'] as String?;
          if (delta != null) {
            _eventController.add(TextEvent(delta));
          }
          break;

        case 'response.audio_transcript.done':
          final transcript = data['transcript'] as String?;
          if (transcript != null) {
            // Full transcript update (optional, delta is usually enough)
          }
          break;

        case 'response.audio.delta':
          final delta = data['delta'] as String?;
          if (delta != null) {
            _eventController.add(AudioEvent(base64Decode(delta)));
          }
          break;
      }
    } catch (e) {
      debugPrint('Error parsing message: $e');
    }
  }

  void _send(Map<String, dynamic> data) {
    try {
      _websocket?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('Error sending data: $e');
    }
  }

  void _emitStatus(String msg, {bool isError = false}) {
    _eventController.add(StatusEvent(msg, isError: isError));
  }

  void _emitBargeIn() {
    _eventController.add(BargeInEvent());
  }

  void dispose() {
    disconnect();
    _eventController.close();
  }
}
