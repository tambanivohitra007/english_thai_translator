import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

import 'models/enums.dart';
import 'widgets/audio_waveform.dart';
import 'widgets/glass_container.dart';
import 'widgets/mic_button.dart';

// -----------------------------------------------------------------------------
// CONFIGURATION
// -----------------------------------------------------------------------------

// OpenAI Configuration
// API key is stored in secrets.dart (excluded from git)
import 'secrets.dart' as secrets;

const String _openAiApiKey = secrets.API_KEY;
const String _openAiUrl =
    'wss://api.openai.com/v1/realtime?model=gpt-realtime-mini-2025-10-06';

// System prompts
const Map<String, String> _prompts = {
  'en-th':
      '''You are a real-time interpreter for daily conversations in Thailand.
Translate spoken English into short, polite, natural Thai suitable for face-to-face speech.
Simplify complex sentences.
Preserve intent rather than literal wording.
Use casual but respectful Thai.
Add polite particles naturally.
Avoid formal, written, or academic Thai.''',

  'th-en':
      '''You are a real-time interpreter for daily conversations in Thailand.
Translate spoken Thai into clear, simple, natural English suitable for face-to-face conversation.
Preserve intent rather than literal wording.
Keep sentences short and conversational.
Avoid formal or academic English.
Do not explain the translation.''',
};

// Voice options for Thai TTS (female/male)
const Map<String, String> _thaiVoices = {
  'female': 'coral', // or 'shimmer'
  'male': 'sage', // or 'echo'
};

// -----------------------------------------------------------------------------
// CONVERSATION STATE
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// MAIN ENTRY POINT
// -----------------------------------------------------------------------------

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'English ↔ Thai Translator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white.withAlpha(150),
          surface: Colors.black.withAlpha(20),
        ),
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      home: const TranslatorScreen(),
    );
  }
}

// -----------------------------------------------------------------------------
// TRANSLATOR SCREEN
// -----------------------------------------------------------------------------

class TranslatorScreen extends StatefulWidget {
  const TranslatorScreen({super.key});

  @override
  State<TranslatorScreen> createState() => _TranslatorScreenState();
}

class _TranslatorScreenState extends State<TranslatorScreen> {
  // Services
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();

  // WebSocket to Cloud Run proxy
  WebSocketChannel? _websocket;

  // State
  ConversationState _state = ConversationState.idle;
  TranslationDirection _direction = TranslationDirection.englishToThai;
  String _thaiVoiceGender = 'female';

  String _inputText = '';
  String _outputText = '';

  // Audio buffers for proper PCM playback
  final List<Uint8List> _audioDeltas = [];
  bool _isReceivingAudio = false;

  // Text Mode State
  bool _isTextMode = false;
  final TextEditingController _textController = TextEditingController();

  // Stream management
  StreamSubscription? _audioStreamSubscription;

  // Waveform logic
  Timer? _amplitudeTimer;
  double _currentAmplitude = -160.0; // Min dB

  @override
  void initState() {
    super.initState();
    _initPermissions();
    _configureAudioSession();
  }

  Future<void> _configureAudioSession() async {
    // Configure audio player to respect audio focus and playback cleanly
    await _audioPlayer.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.assistant,
          audioFocus: AndroidAudioFocus.gain,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: {
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.allowBluetooth,
            AVAudioSessionOptions.allowBluetoothA2DP,
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _audioPlayer.dispose();
    _audioStreamSubscription?.cancel();
    _amplitudeTimer?.cancel();
    _websocket?.sink.close(status.goingAway);
    _textController.dispose();
    super.dispose();
  }

  Future<void> _initPermissions() async {
    await Permission.microphone.request();
  }

  // ---------------------------------------------------------------------------
  // WEBSOCKET CONNECTION
  // ---------------------------------------------------------------------------

  Future<void> _connectWebSocket() async {
    if (_state == ConversationState.connecting ||
        _websocket != null && _state != ConversationState.error) {
      return;
    }

    setState(() => _state = ConversationState.connecting);

    try {
      debugPrint('Connecting to OpenAI Realtime API...');

      // Connect directly to OpenAI with headers
      final ws = await WebSocket.connect(
        _openAiUrl,
        headers: {
          'Authorization': 'Bearer $_openAiApiKey',
          'OpenAI-Beta': 'realtime=v1',
        },
      );
      _websocket = IOWebSocketChannel(ws);

      debugPrint('WebSocket connection established');

      // Listen for messages from server
      _websocket!.stream.listen(
        (message) => _handleRealtimeMessage(message),
        onError: (error) {
          debugPrint('WebSocket error: $error');
          setState(() {
            _state = ConversationState.error;
            _outputText = 'Connection error';
          });
        },
        onDone: () {
          debugPrint('WebSocket closed');
          if (_state != ConversationState.error) {
            setState(() => _state = ConversationState.idle);
          }
        },
      );

      // Wait a moment for connection to establish
      await Future.delayed(const Duration(milliseconds: 300));

      // Send initial session configuration
      _updateSession();

      setState(() => _state = ConversationState.idle);
      debugPrint('Connected to Cloud Run proxy');
    } catch (e) {
      setState(() {
        _state = ConversationState.error;
        _outputText = 'Connection failed: $e';
      });
      debugPrint('Connection error: $e');
    }
  }

  void _updateSession() {
    if (_websocket == null) return;

    final directionKey = _direction == TranslationDirection.englishToThai
        ? 'en-th'
        : 'th-en';

    final voice = _direction == TranslationDirection.englishToThai
        ? _thaiVoices[_thaiVoiceGender]!
        : 'alloy'; // English voice for Thai->English translation (response is in English)

    final instructions = _prompts[directionKey]!;

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
          'silence_duration_ms': 800, // Increased to prevent premature cutoff
        },
        'temperature': 0.6,
      },
    };

    _websocket!.sink.add(jsonEncode(sessionConfig));
    debugPrint('Session updated: $directionKey, voice: $voice');
  }

  // ---------------------------------------------------------------------------
  // MESSAGE HANDLING
  // ---------------------------------------------------------------------------

  void _handleRealtimeMessage(dynamic message) {
    try {
      // 1️⃣ Binary frame (very important!)
      if (message is Uint8List) {
        // OpenAI may send binary audio frames or control frames
        // You can safely ignore them if you're not using them directly
        debugPrint('Received binary frame: ${message.length} bytes');
        return;
      }

      // 2️⃣ Text frame (JSON)
      if (message is! String) {
        debugPrint('Unknown message type: ${message.runtimeType}');
        return;
      }

      final data = jsonDecode(message);
      final type = data['type'] as String?;

      switch (type) {
        case 'session.created':
        case 'session.updated':
          debugPrint('Session ready');
          break;

        case 'input_audio_buffer.speech_started':
          setState(() => _inputText = 'Listening...');
          break;

        case 'input_audio_buffer.speech_stopped':
          setState(() => _state = ConversationState.processing);
          // Server VAD detected silence, so we stop recording locally.
          // We pass false because the server already committed the buffer.
          _stopRecording(sendCommit: false);
          debugPrint('VAD detected silence, stopped recording');
          break;

        case 'conversation.item.input_audio_transcription.completed':
          final transcript = data['transcript'] as String?;
          if (transcript != null && transcript.isNotEmpty) {
            setState(() => _inputText = transcript);
          }
          break;

        case 'response.audio_transcript.delta':
          final delta = data['delta'] as String?;
          if (delta != null) {
            setState(() => _outputText += delta);
          }
          break;

        case 'response.audio_transcript.done':
          final transcript = data['transcript'] as String?;
          if (transcript != null) {
            setState(() => _outputText = transcript);
          }
          break;

        case 'response.audio.delta':
          final delta = data['delta'] as String?;
          if (delta != null) {
            _isReceivingAudio = true;
            try {
              final bytes = base64Decode(delta);
              _audioDeltas.add(bytes);
              debugPrint('Received audio chunk: ${bytes.length} bytes');
            } catch (e) {
              debugPrint('Error decoding audio delta: $e');
              debugPrint('Trace: $delta');
            }
          }
          break;

        case 'response.audio.done':
          _playBufferedAudio();
          break;

        case 'response.done':
          setState(() => _state = ConversationState.idle);
          _isReceivingAudio = false;
          break;

        case 'error':
          final error = data['error'] as Map?;
          final errorMsg = error?['message'] as String? ?? 'Unknown error';
          setState(() {
            _state = ConversationState.error;
            _outputText = 'Error: $errorMsg';
          });
          break;

        default:
          debugPrint('Received event: $type');
      }
    } catch (e) {
      debugPrint('Error handling message: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // AUDIO PLAYBACK (PCM16 → WAV)
  // ---------------------------------------------------------------------------

  Future<void> _playBufferedAudio() async {
    if (_audioDeltas.isEmpty) return;

    setState(() => _state = ConversationState.speaking);

    try {
      // Combine all PCM16 chunks
      final totalLength = _audioDeltas.fold<int>(
        0,
        (sum, chunk) => sum + chunk.length,
      );
      final pcmData = Uint8List(totalLength);

      int offset = 0;
      for (final chunk in _audioDeltas) {
        pcmData.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }

      // Convert PCM16 to WAV
      final wavBytes = _pcm16ToWav(pcmData, sampleRate: 24000, channels: 1);

      debugPrint(
        'Playing audio: ${pcmData.length} bytes PCM -> ${wavBytes.length} bytes WAV',
      );

      // Play WAV audio
      await _audioPlayer.play(BytesSource(wavBytes));
      debugPrint('Audio playback started');

      // Clear buffer
      _audioDeltas.clear();

      // Wait for audio to finish
      await Future.delayed(
        Duration(milliseconds: (pcmData.length / 48) * 1000 ~/ 1000),
      );

      setState(() => _state = ConversationState.idle);
    } catch (e) {
      debugPrint('Error playing audio: $e');
      setState(() => _state = ConversationState.idle);
    }
  }

  /// Convert PCM16 bytes to WAV format
  Uint8List _pcm16ToWav(
    Uint8List pcmData, {
    required int sampleRate,
    required int channels,
  }) {
    final bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataSize = pcmData.length;
    final fileSize = 36 + dataSize;

    final buffer = BytesBuilder();

    // RIFF header
    buffer.add('RIFF'.codeUnits);
    buffer.add(_int32Bytes(fileSize));
    buffer.add('WAVE'.codeUnits);

    // fmt chunk
    buffer.add('fmt '.codeUnits);
    buffer.add(_int32Bytes(16)); // chunk size
    buffer.add(_int16Bytes(1)); // audio format (PCM)
    buffer.add(_int16Bytes(channels));
    buffer.add(_int32Bytes(sampleRate));
    buffer.add(_int32Bytes(byteRate));
    buffer.add(_int16Bytes(blockAlign));
    buffer.add(_int16Bytes(bitsPerSample));

    // data chunk
    buffer.add('data'.codeUnits);
    buffer.add(_int32Bytes(dataSize));
    buffer.add(pcmData);

    return buffer.toBytes();
  }

  Uint8List _int16Bytes(int value) {
    return Uint8List(2)..buffer.asByteData().setInt16(0, value, Endian.little);
  }

  Uint8List _int32Bytes(int value) {
    return Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);
  }

  // ---------------------------------------------------------------------------
  // RECORDING LOGIC
  // ---------------------------------------------------------------------------

  Future<void> _startRecording(TranslationDirection direction) async {
    // Connect if not connected
    if (_websocket == null || _state == ConversationState.error) {
      await _connectWebSocket();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // Update session if direction changed
    if (_direction != direction) {
      _direction = direction;
      _updateSession();
      await Future.delayed(const Duration(milliseconds: 200));
    }

    try {
      if (await _audioRecorder.hasPermission()) {
        final stream = await _audioRecorder.startStream(
          const RecordConfig(encoder: AudioEncoder.pcm16bits, numChannels: 1),
        );

        setState(() {
          _state = direction == TranslationDirection.englishToThai
              ? ConversationState.listeningEnglish
              : ConversationState.listeningThai;
          _inputText = 'Listening...';
          _outputText = '';
          _audioDeltas.clear();
        });

        _audioStreamSubscription = stream.listen((chunk) {
          if (_websocket != null &&
              (_state == ConversationState.listeningEnglish ||
                  _state == ConversationState.listeningThai)) {
            _sendAudioBuffer(chunk);
          }
        }, onError: (e) => debugPrint('Audio stream error: $e'));

        // Start amplitude polling
        _amplitudeTimer = Timer.periodic(const Duration(milliseconds: 50), (
          timer,
        ) async {
          if (!await _audioRecorder.hasPermission()) return;
          final isRecording = await _audioRecorder.isRecording();
          if (!isRecording) return;
          final amp = await _audioRecorder.getAmplitude();
          setState(() => _currentAmplitude = amp.current);
        });
      }
    } catch (e) {
      debugPrint('Error starting recording: $e');
      setState(() {
        _state = ConversationState.error;
        _outputText = 'Microphone error: $e';
      });
    }
  }

  Future<void> _stopRecording({bool sendCommit = true}) async {
    if (_state != ConversationState.listeningEnglish &&
        _state != ConversationState.listeningThai) {
      return;
    }

    try {
      await _audioRecorder.stop();
      _audioStreamSubscription?.cancel();
      _amplitudeTimer?.cancel();
      _currentAmplitude = -160.0;

      setState(() => _state = ConversationState.processing);

      if (_websocket != null && sendCommit) {
        _websocket!.sink.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
        _websocket!.sink.add(
          jsonEncode({
            'type': 'response.create',
            'response': {
              'modalities': ['text', 'audio'],
            },
          }),
        );
      }
    } catch (e) {
      debugPrint('Error stopping recording: $e');
      setState(() {
        _state = ConversationState.error;
        _outputText = 'Error: $e';
      });
    }
  }

  // ---------------------------------------------------------------------------
  // TEXT INPUT LOGIC
  // ---------------------------------------------------------------------------

  void _sendTextMessage(String text) {
    if (text.trim().isEmpty || _websocket == null) return;

    // Connect if needed
    if (_state == ConversationState.error || _websocket == null) {
      _connectWebSocket().then((_) => _sendTextMessage(text));
      return;
    }

    setState(() {
      _inputText = text;
      _outputText = '';
      _state = ConversationState.processing;
    });

    // 1. Create conversation item (User input)
    _websocket!.sink.add(
      jsonEncode({
        'type': 'conversation.item.create',
        'item': {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': text},
          ],
        },
      }),
    );

    // 2. Trigger response
    _websocket!.sink.add(
      jsonEncode({
        'type': 'response.create',
        'response': {
          'modalities': ['text', 'audio'],
        },
      }),
    );

    _textController.clear();
  }

  Future<void> _toggleRecording(TranslationDirection direction) async {
    if (_state == ConversationState.listeningEnglish ||
        _state == ConversationState.listeningThai) {
      // Currently recording
      if ((_state == ConversationState.listeningEnglish &&
              direction == TranslationDirection.englishToThai) ||
          (_state == ConversationState.listeningThai &&
              direction == TranslationDirection.thaiToEnglish)) {
        // Stop if clicking the active button
        await _stopRecording();
      } else {
        // If clicking the OTHER button, stop current and start new?
        // For simplicity, let's just ignore or stop current.
        // Let's stop current then start new (switch).
        await _stopRecording();
        // Allow a small delay for state to settle if needed, but simplest is just stop.
        // Or strictly: one active at a time.
        // Let's just stop the current one. User needs to tap again to start the other.
      }
    } else {
      // Not recording, start
      await _startRecording(direction);
    }
  }

  void _sendAudioBuffer(Uint8List buffer) {
    if (_websocket == null) return;

    try {
      _websocket!.sink.add(
        jsonEncode({
          'type': 'input_audio_buffer.append',
          'audio': base64Encode(buffer),
        }),
      );
    } catch (e) {
      debugPrint('Error sending audio: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isListening =
        _state == ConversationState.listeningEnglish ||
        _state == ConversationState.listeningThai;
    final isProcessing = _state == ConversationState.processing;
    final isSpeaking = _state == ConversationState.speaking;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'English ↔ Thai',
          style: TextStyle(fontWeight: FontWeight.w300, shadows: []),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withAlpha(50)),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _thaiVoiceGender == 'female' ? Icons.female : Icons.male,
              color: Colors.white,
            ),
            onPressed: () {
              setState(
                () => _thaiVoiceGender = _thaiVoiceGender == 'female'
                    ? 'male'
                    : 'female',
              );
              if (_websocket != null) {
                _updateSession();
              }
            },
            tooltip: 'Toggle Voice Gender',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF2C3E50), // Dark Blue/Grey
              Color(0xFF000000), // Black
              Color(0xFF4CA1AF), // Teal accent
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 16.0,
            ),
            child: Column(
              children: [
                const SizedBox(height: 16),
                // Status indicator
                _buildStatusIndicator(),
                const SizedBox(height: 32),

                // Conversation Area
                Expanded(
                  child: ListView(
                    children: [
                      if (_inputText.isNotEmpty)
                        _buildGlassCard(
                          label:
                              _direction == TranslationDirection.englishToThai
                              ? 'ENGLISH'
                              : 'THAI',
                          text: _inputText,
                          isActive: isListening,
                        ),

                      const SizedBox(height: 16),

                      if (_outputText.isNotEmpty)
                        _buildGlassCard(
                          label:
                              _direction == TranslationDirection.englishToThai
                              ? 'THAI'
                              : 'ENGLISH',
                          text: _outputText,
                          isHighlight: true,
                        ),

                      if (_inputText.isEmpty && _outputText.isEmpty)
                        Center(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 100),
                            child: Text(
                              'Tap a microphone to start',
                              style: TextStyle(
                                color: Colors.white.withAlpha(100),
                                fontSize: 16,
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                if (isProcessing || isSpeaking)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          isProcessing ? 'Translating...' : 'Speaking...',
                          style: const TextStyle(
                            color: Colors.white70,
                            letterSpacing: 1.2,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Waveform Visualizer
                if (isListening)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: AudioWaveform(amplitude: _currentAmplitude),
                  )
                else
                  const SizedBox(height: 50 + 24), // Placeholder height

                if (!_isTextMode)
                  // Two microphone buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      MicButton(
                        direction: TranslationDirection.englishToThai,
                        label: 'English',
                        icon: Icons.mic,
                        isActive:
                            isListening &&
                            _direction == TranslationDirection.englishToThai,
                        onTap: () => _toggleRecording(
                          TranslationDirection.englishToThai,
                        ),
                      ),
                      MicButton(
                        direction: TranslationDirection.thaiToEnglish,
                        label: 'Thai',
                        icon: Icons.mic,
                        isActive:
                            isListening &&
                            _direction == TranslationDirection.thaiToEnglish,
                        onTap: () => _toggleRecording(
                          TranslationDirection.thaiToEnglish,
                        ),
                      ),
                    ],
                  )
                else
                  // Text Input Field
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(
                      children: [
                        Expanded(
                          child: GlassContainer(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: TextField(
                              controller: _textController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Type a message...',
                                hintStyle: TextStyle(
                                  color: Colors.white.withAlpha(100),
                                ),
                                border: InputBorder.none,
                              ),
                              onSubmitted: (value) => _sendTextMessage(value),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: () => _sendTextMessage(_textController.text),
                          child: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00B4DB), Color(0xFF0083B0)],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF0083B0).withAlpha(100),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                const SizedBox(height: 16),

                // Toggle Mode Button
                Center(
                  child: TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _isTextMode = !_isTextMode;
                        // Stop any active recording when switching
                        if (isListening) _stopRecording(sendCommit: false);
                      });
                    },
                    icon: Icon(
                      _isTextMode ? Icons.mic : Icons.keyboard,
                      color: Colors.white70,
                      size: 18,
                    ),
                    label: Text(
                      _isTextMode ? 'Switch to Voice' : 'Switch to Keyboard',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusIndicator() {
    Color statusColor;
    String statusText;

    switch (_state) {
      case ConversationState.idle:
        statusColor = Colors.green;
        statusText = 'Ready';
        break;
      case ConversationState.connecting:
        statusColor = Colors.orange;
        statusText = 'Connecting...';
        break;
      case ConversationState.error:
        statusColor = Colors.red;
        statusText = 'Error';
        break;
      default:
        statusColor = Colors.blue;
        statusText = 'Active';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withAlpha(20),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: statusColor.withAlpha(50)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(color: statusColor.withAlpha(100), blurRadius: 6),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusText.toUpperCase(),
            style: TextStyle(
              color: statusColor,
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassCard({
    required String label,
    required String text,
    bool isHighlight = false,
    bool isActive = false,
  }) {
    return GlassContainer(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 2,
              fontWeight: FontWeight.bold,
              color: Colors.white.withAlpha(100),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            text,
            style: TextStyle(
              fontSize: isHighlight ? 28 : 20,
              fontWeight: isHighlight ? FontWeight.w600 : FontWeight.w300,
              color: Colors.white.withAlpha(240),
              height: 1.4,
            ),
          ),
          if (isActive) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(
                Colors.white.withAlpha(50),
              ),
              minHeight: 2,
            ),
          ],
        ],
      ),
    );
  }
}
