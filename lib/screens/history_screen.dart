import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';
import '../models/language.dart';
import '../localization/app_localizations.dart';
import '../services/tts_service.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen>
    with TickerProviderStateMixin {
  int _index = 0;
  bool _isPlaying = false;
  int _playToken = 0;

  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _announceCount());
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  Language get _deviceLanguage {
    final code = ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    for (final lang in Language.values) {
      if (lang.code == code) return lang;
    }
    return Language.english;
  }

  AppLocalizations get _loc => AppLocalizations(_deviceLanguage);

  TTSService get _tts => ref.read(ttsServiceProvider);

  void _stop() {
    _playToken++;
    _tts.stop();
    if (mounted) {
      setState(() => _isPlaying = false);
      _waveController.stop();
      _waveController.reset();
    }
  }

  Future<void> _announceCount() async {
    final history = ref.read(conversationProvider).history;
    if (history.isEmpty) {
      await _tts.speak(_loc.translate('history_empty'), _deviceLanguage);
      return;
    }
    final msg = _loc.translate('history_count').replaceAll('{n}', '${history.length}');
    final prompt = _loc.translate('history_play_prompt');
    await _tts.speak('$msg $prompt', _deviceLanguage);
  }

  Future<void> _playCurrentTurn() async {
    final history = ref.read(conversationProvider).history;
    if (history.isEmpty) return;

    _stop();
    final token = ++_playToken;
    final turn = history[_index];
    final turnLang = Language.fromBcp47(turn.language);

    setState(() => _isPlaying = true);
    _waveController.repeat(reverse: true);

    try {
      // Announce "You asked:" in device language
      await _tts.speak(_loc.translate('history_you_asked'), _deviceLanguage);
      if (token != _playToken) return;

      // Speak the user query in the turn's language
      await _tts.speak(turn.query, turnLang);
      if (token != _playToken) return;

      // Announce "I said:" in device language
      await _tts.speak(_loc.translate('history_i_said'), _deviceLanguage);
      if (token != _playToken) return;

      // Speak the AI response in the turn's language
      await _tts.speak(turn.response, turnLang);
    } finally {
      if (token == _playToken && mounted) {
        setState(() => _isPlaying = false);
        _waveController.stop();
        _waveController.reset();
      }
    }
  }

  Future<void> _navigate(int delta) async {
    final history = ref.read(conversationProvider).history;
    if (history.isEmpty) return;

    _stop();
    final newIndex = _index + delta;

    if (newIndex < 0) {
      await _tts.speak(_loc.translate('history_newest_reached'), _deviceLanguage);
      return;
    }
    if (newIndex >= history.length) {
      await _tts.speak(_loc.translate('history_oldest_reached'), _deviceLanguage);
      return;
    }

    setState(() => _index = newIndex);
    final cue = delta > 0
        ? _loc.translate('history_older')
        : _loc.translate('history_newer');
    await _tts.speak(cue, _deviceLanguage);
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(conversationProvider).history;
    final isEmpty = history.isEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text(
          'HISTORY',
          style: TextStyle(
            fontSize: 16,
            letterSpacing: 4,
            fontWeight: FontWeight.w300,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 22),
            onPressed: () {
              _stop();
              ref.read(conversationProvider.notifier).initialize(skipWelcome: true);
              Future.delayed(const Duration(milliseconds: 400), _announceCount);
            },
          ),
          const SizedBox(width: 8),
        ],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () {
            _stop();
            Navigator.pop(context);
          },
        ),
      ),
      body: Stack(
        children: [
          // Background gradient
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1A1A1A), Colors.black],
                ),
              ),
            ),
          ),

          if (isEmpty)
            Center(
              child: Text(
                _loc.translate('history_empty'),
                style: TextStyle(color: Colors.white.withValues(alpha: 0.3), fontSize: 16),
              ),
            )
          else
            SafeArea(
              child: Column(
                children: [
                  const SizedBox(height: 24),

                  // Entry counter
                  Text(
                    '${_index + 1} / ${history.length}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.3),
                      fontSize: 12,
                      letterSpacing: 3,
                    ),
                  ),

                  const SizedBox(height: 8),

                  // Progress bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: history.isEmpty ? 0 : (_index + 1) / history.length,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF6C8EFF)),
                        minHeight: 2,
                      ),
                    ),
                  ),

                  const Spacer(),

                  // Wave visualiser
                  SizedBox(
                    height: 60,
                    child: AnimatedBuilder(
                      animation: _waveController,
                      builder: (context, child) => _buildWave(_waveController.value),
                    ),
                  ),

                  const SizedBox(height: 48),

                  // Navigation row: older ← [play] → newer
                  // Index 0 = newest, higher = older
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Newer (decrease index)
                        _CircleButton(
                          icon: Icons.skip_previous_rounded,
                          size: 56,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _navigate(-1);
                          },
                        ),

                        // Play / Stop
                        _CircleButton(
                          icon: _isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                          size: 80,
                          primary: true,
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            if (_isPlaying) {
                              _stop();
                            } else {
                              _playCurrentTurn();
                            }
                          },
                        ),

                        // Older (increase index)
                        _CircleButton(
                          icon: Icons.skip_next_rounded,
                          size: 56,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            _navigate(1);
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Subtle date label
                  Text(
                    _formatDate(history[_index].timestamp),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.25),
                      fontSize: 11,
                      letterSpacing: 2,
                    ),
                  ),

                  const Spacer(),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWave(double t) {
    final heights = [12.0, 20.0, 14.0, 28.0, 18.0, 10.0, 24.0, 16.0, 22.0, 12.0, 18.0];
    final bars = <Widget>[];
    for (int i = 0; i < heights.length; i++) {
      final base = heights[i];
      final animated = _isPlaying
          ? base * 0.3 + base * 1.2 * (0.5 + 0.5 * _waveSample(t, i))
          : base * 0.4;
      bars.add(
        AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          width: 4,
          height: animated,
          margin: const EdgeInsets.symmetric(horizontal: 2.5),
          decoration: BoxDecoration(
            color: _isPlaying
                ? const Color(0xFF6C8EFF).withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      );
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: bars);
  }

  double _waveSample(double t, int i) {
    return (math.sin(t * math.pi * 2 + i * 0.7) + 1) / 2;
  }

  String _formatDate(DateTime dt) {
    final months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '${months[dt.month - 1]} ${dt.day}  ·  $h:$m $ampm';
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool primary;
  final VoidCallback onTap;

  const _CircleButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary
              ? const Color(0xFF6C8EFF).withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.07),
          border: Border.all(
            color: primary
                ? const Color(0xFF6C8EFF).withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.15),
            width: primary ? 1.5 : 1,
          ),
        ),
        child: Icon(
          icon,
          color: primary ? const Color(0xFF6C8EFF) : Colors.white60,
          size: size * 0.45,
        ),
      ),
    );
  }
}
