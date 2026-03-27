import 'dart:math' as math;
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';
import '../widgets/camera_preview_widget.dart';
import '../widgets/control_bar_widget.dart';
import '../localization/app_localizations.dart';
import '../providers/settings_provider.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import '../services/tts_service.dart';
import '../models/language.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  
  // Tutorial Keys
  final GlobalKey _micKey = GlobalKey();
  final GlobalKey _cameraKey = GlobalKey();
  final GlobalKey _flashKey = GlobalKey();
  final GlobalKey _orbKey = GlobalKey();
  final GlobalKey _historyKey = GlobalKey();
  final TextEditingController _textController = TextEditingController();
  bool _isSilentMode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(conversationProvider.notifier).initialize();
      _checkAndShowTutorial();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final notifier = ref.read(conversationProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      notifier.handleAppResumed();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      notifier.handleAppPausedOrInactive();
    }
  }

  void _checkAndShowTutorial() {
    final settings = ref.read(settingsProvider);
    if (!settings.tutorialCompleted) {
      _showTutorial();
    }
  }

  void _showTutorial() {
    final language = _tutorialLanguageFromDevice();
    final localizations = AppLocalizations(language);
    final tts = ref.read(ttsServiceProvider);
    final settings = ref.read(settingsProvider);
    tts.setSpeed('Slow');

    final List<String> stepIds = ['welcome', 'mic', 'camera', 'flash', 'orb', 'history'];
    final Map<String, List<String>> tutorialKeysMap = {
      'welcome': ['tutorial_welcome_title', 'tutorial_welcome_desc'],
      'mic': ['tutorial_mic_title', 'tutorial_mic_desc'],
      'camera': ['tutorial_camera_title', 'tutorial_camera_desc'],
      'flash': ['tutorial_flash_title', 'tutorial_flash_desc'],
      'orb': ['tutorial_orb_title', 'tutorial_orb_desc'],
      'history': ['tutorial_history_title', 'tutorial_history_desc'],
    };

    Future<void> speakTutorial(String titleKey, String descKey, String identify) async {
      final title = localizations.translate(titleKey);
      final desc = localizations.translate(descKey);
      final isLast = identify == stepIds.last;
      final isWelcome = identify == stepIds.first;
      final gestureHint = (isWelcome || isLast)
          ? _tutorialGestureHint(language, isLast: isLast)
          : '';

      final detailedMessage = gestureHint.isEmpty
          ? "$title. $desc. ${_tutorialDetailTail(language)}"
          : "$title. $desc. $gestureHint ${_tutorialDetailTail(language)}";
      await tts.speak(detailedMessage, language);
    }

    void repeatCurrentStep(String identify) {
      final keys = tutorialKeysMap[identify];
      if (keys != null) {
        tts.stop();
        unawaited(speakTutorial(keys[0], keys[1], identify));
      }
    }

    List<TargetFocus> targets = [
      TargetFocus(
        identify: "welcome",
        keyTarget: null,
        targetPosition: TargetPosition(const Size(100, 100), Offset(MediaQuery.of(context).size.width / 2 - 50, MediaQuery.of(context).size.height / 2 - 50)),
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              identify: "welcome",
              onRepeat: () => repeatCurrentStep("welcome"),
              isLast: false,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: "mic",
        keyTarget: _micKey,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              identify: "mic",
              onRepeat: () => repeatCurrentStep("mic"),
              isLast: false,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: "camera",
        keyTarget: _cameraKey,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              identify: "camera",
              onRepeat: () => repeatCurrentStep("camera"),
              isLast: false,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: "flash",
        keyTarget: _flashKey,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              identify: "flash",
              onRepeat: () => repeatCurrentStep("flash"),
              isLast: false,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: "orb",
        keyTarget: _orbKey,
        contents: [
          TargetContent(
            align: ContentAlign.top,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              identify: "orb",
              onRepeat: () => repeatCurrentStep("orb"),
              isLast: false,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: "history",
        keyTarget: _historyKey,
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              identify: "history",
              onRepeat: () => repeatCurrentStep("history"),
              isLast: true,
            ),
          ),
        ],
      ),
    ];

    final tutorialCoachMark = TutorialCoachMark(
      targets: targets,
      beforeFocus: (target) {
        final keys = tutorialKeysMap[target.identify];
        if (keys != null) {
          tts.stop();
          unawaited(speakTutorial(keys[0], keys[1], target.identify));
        }
      },
      colorShadow: Colors.black.withOpacity(0.95),
      opacityShadow: 0.95,
      paddingFocus: 10,
      hideSkip: true,
      onClickOverlay: (target) {},
      onFinish: () {
        tts.stop();
        tts.setSpeed(settings.voiceSpeed);
        ref.read(settingsProvider.notifier).setTutorialCompleted(true);
      },
      onSkip: () {
        tts.stop();
        tts.setSpeed(settings.voiceSpeed);
        ref.read(settingsProvider.notifier).setTutorialCompleted(true);
        return true;
      },
    );
    tutorialCoachMark.show(context: context);
  }

  Language _tutorialLanguageFromDevice() {
    final code = ui.PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    for (final language in Language.values) {
      if (language.code == code) return language;
    }
    return Language.english;
  }

  String _tutorialGestureHint(Language language, {required bool isLast}) {
    switch (language) {
      case Language.hindi:
        return isLast
            ? "इस आइकन पर एक बार टैप करें, निर्देश दोबारा सुने। डबल टैप करें, ट्यूटोरियल पूरा करें।"
            : "इस आइकन पर एक बार टैप करें, निर्देश दोबारा सुने। डबल टैप करें, अगले स्टेप पर जाएं।";
      case Language.marathi:
        return isLast
            ? "या आयकॉनवर एकदा टॅप करा, सूचना पुन्हा ऐका. डबल टॅप करा, ट्यूटोरियल पूर्ण करा."
            : "या आयकॉनवर एकदा टॅप करा, सूचना पुन्हा ऐका. डबल टॅप करा, पुढच्या स्टेपला जा.";
      case Language.telugu:
        return isLast
            ? "ఈ ఐకాన్‌పై ఒకసారి ట్యాప్ చేస్తే సూచన మళ్లీ వింటారు. డబుల్ ట్యాప్ చేస్తే ట్యుటోరియల్ పూర్తవుతుంది."
            : "ఈ ఐకాన్‌పై ఒకసారి ట్యాప్ చేస్తే సూచన మళ్లీ వింటారు. డబుల్ ట్యాప్ చేస్తే తదుపరి దశకు వెళ్తారు.";
      default:
        return isLast
            ? "Single tap this avatar to hear this step again. Double tap this avatar to finish the tutorial."
            : "Single tap this avatar to repeat this instruction. Double tap this avatar to go to the next step.";
    }
  }

  String _tutorialDetailTail(Language language) {
    switch (language) {
      case Language.hindi:
        return "यह गाइड थोड़ी विस्तार से है। आराम से हर स्टेप फॉलो करें।";
      case Language.marathi:
        return "ही मार्गदर्शिका थोडी सविस्तर आहे. शांतपणे प्रत्येक स्टेप फॉलो करा.";
      case Language.telugu:
        return "ఈ గైడ్ కొంచెం వివరంగా ఉంటుంది. ఆతురపడకుండా ప్రతి దశను అనుసరించండి.";
      default:
        return "This guide is detailed. Take your time and follow each step.";
    }
  }

  Widget _buildTutorialStepContent(
    TutorialCoachMarkController controller,
    {
    required String identify,
    required VoidCallback onRepeat,
    bool isLast = false,
  }) {
    final tts = ref.read(ttsServiceProvider);
    return SizedBox(
      width: MediaQuery.of(context).size.width,
      height: 300,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _TutorialSpeakingAvatar(
            onSingleTap: onRepeat,
            onDoubleTap: () {
              tts.stop();
              if (isLast) {
                ref.read(settingsProvider.notifier).setTutorialCompleted(true);
                controller.skip();
              } else {
                controller.next();
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          ref.read(conversationProvider.notifier).clearResponse();
        },
        child: Stack(
          children: [
            // Full-screen camera feed
            const Positioned.fill(child: CameraPreviewWidget()),

            // Ambient dark overlay for depth
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: Alignment.topCenter,
                      radius: 1.8,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.55),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Bottom vignette so UI elements sit cleanly
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 420,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.92),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Central Voice Orb
            Center(
              child: VoiceOrbWidget(key: _orbKey),
            ),

            // Bottom UI stack
            Align(
              alignment: Alignment.bottomCenter,
              child: GestureDetector(
                onTap: () {}, // Catch taps on the UI area so they don't bubble to the dismiss handler
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SizeTransition(
                          sizeFactor: animation,
                          axisAlignment: -1,
                          child: child,
                        ),
                      ),
                      child: _isSilentMode
                          ? _buildSilentInputArea()
                          : const SizedBox.shrink(),
                    ),
                    ControlBarWidget(
                      micKey: _micKey,
                      cameraKey: _cameraKey,
                      flashKey: _flashKey,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSilentInputArea() {
    const language = Language.english;
    return Container(
      key: const ValueKey('silent_input'),
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: const InputDecoration(
                hintText: 'Type your message...',
                hintStyle: TextStyle(color: Colors.white30, fontSize: 16),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _handleSilentSubmit(language),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt_rounded, color: Color(0xFF6C8EFF)),
            onPressed: () => _handleSilentSubmit(language),
          ),
        ],
      ),
    );
  }

  void _handleSilentSubmit(Language language) {
    if (_textController.text.trim().isEmpty) return;
    ref.read(conversationProvider.notifier).processTextQuery(
      _textController.text.trim(),
      language,
    );
    _textController.clear();
    // Keep silent mode on, but the provider will update the status to thinking
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    const language = Language.english;
    final localizations = AppLocalizations(language);

    return AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Colors.transparent,
      elevation: 0,
      flexibleSpace: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withOpacity(0.6),
              Colors.transparent,
            ],
          ),
        ),
      ),
      title: SizedBox(
        height: 38,
        child: Image.asset(
          'assets/images/logo.png',
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => Text(
            localizations.translate('app_name'),
            style: const TextStyle(
              fontFamily: 'Georgia',
              fontWeight: FontWeight.w400,
              color: Colors.white,
              fontSize: 20,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
      actions: [
        GestureDetector(
          onTap: () {
            HapticFeedback.selectionClick();
            setState(() {
              _isSilentMode = !_isSilentMode;
            });
          },
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: _isSilentMode ? const Color(0xFF6C8EFF).withOpacity(0.15) : Colors.white.withOpacity(0.08),
              border: Border.all(color: _isSilentMode ? const Color(0xFF6C8EFF).withOpacity(0.4) : Colors.white.withOpacity(0.12)),
            ),
            child: Icon(
              _isSilentMode ? Icons.keyboard_rounded : Icons.keyboard_hide_rounded, 
              color: _isSilentMode ? const Color(0xFF6C8EFF) : Colors.white70, 
              size: 18
            ),
          ),
        ),
        GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            Navigator.pushNamed(context, '/history');
          },
          child: Container(
            key: _historyKey,
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.white.withOpacity(0.08),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: const Icon(Icons.history_rounded, color: Colors.white70, size: 18),
          ),
        ),
      ],
    );
  }
}

/// Animated monogram-style logo
class _SahayakLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const SweepGradient(
          colors: [
            Color(0xFF6C8EFF),
            Color(0xFFB06EFB),
            Color(0xFFFF6EC4),
            Color(0xFFFF9F68),
            Color(0xFF6C8EFF),
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(1.5),
        child: Container(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.black,
          ),
          child: ClipOval(
            child: Image.asset(
              'assets/images/logo.png',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Text(
                  'S',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w300,
                    fontFamily: 'Georgia',
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TutorialSpeakingAvatar extends StatefulWidget {
  final VoidCallback onSingleTap;
  final VoidCallback onDoubleTap;

  const _TutorialSpeakingAvatar({
    required this.onSingleTap,
    required this.onDoubleTap,
  });

  @override
  State<_TutorialSpeakingAvatar> createState() => _TutorialSpeakingAvatarState();
}

class _TutorialSpeakingAvatarState extends State<_TutorialSpeakingAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ringController;

  @override
  void initState() {
    super.initState();
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1700),
    )..repeat();
  }

  @override
  void dispose() {
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onSingleTap,
      onDoubleTap: widget.onDoubleTap,
      child: AnimatedBuilder(
        animation: _ringController,
        builder: (context, child) {
          final t = _ringController.value;
          final pulse = 0.94 + (math.sin(t * 2 * math.pi).abs() * 0.14);
          return SizedBox(
            width: 160,
            height: 160,
            child: Stack(
              alignment: Alignment.center,
              children: [
                _TutorialRing(scale: 1.05 + (t * 0.22), opacity: 0.26 * (1 - t)),
                _TutorialRing(scale: 1.18 + (t * 0.24), opacity: 0.16 * (1 - t)),
                Transform.scale(
                  scale: pulse,
                  child: const _TutorialBotIcon(),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _TutorialRing extends StatelessWidget {
  final double scale;
  final double opacity;

  const _TutorialRing({required this.scale, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: Container(
        width: 108,
        height: 108,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFF6C8EFF).withOpacity(opacity),
            width: 2.2,
          ),
        ),
      ),
    );
  }
}

class _TutorialBotIcon extends StatelessWidget {
  const _TutorialBotIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 112,
      height: 112,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 15,
            spreadRadius: 2,
          )
        ],
      ),
      child: _SahayakLogo(),
    );
  }
}

// ---------------------------------------------------------------------------
// Voice Orb — the premium centrepiece
// ---------------------------------------------------------------------------

class VoiceOrbWidget extends ConsumerStatefulWidget {
  const VoiceOrbWidget({super.key});

  @override
  ConsumerState<VoiceOrbWidget> createState() => _VoiceOrbWidgetState();
}

class _VoiceOrbWidgetState extends ConsumerState<VoiceOrbWidget>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _rotateController;
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _rotateController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotateController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(conversationProvider).status;
    final bool isListening = status == AppState.listening;
    final bool isThinking = status == AppState.thinking;
    final bool isSpeaking = status == AppState.speaking;
    final bool isActive = isListening || isThinking || isSpeaking;
    const language = Language.english;
    final localizations = AppLocalizations(language);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // --- Outer ring glow when active ---
        AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          width: isActive ? 220 : 0,
          height: isActive ? 220 : 0,
          child: isActive
              ? AnimatedBuilder(
                  animation: _rotateController,
                  builder: (_, __) => Transform.rotate(
                    angle: _rotateController.value * 2 * math.pi,
                    child: CustomPaint(
                      painter: _ArcRingPainter(
                        color: _orbColor(status),
                        progress: _pulseController.value,
                      ),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),

        if (isActive) const SizedBox(height: 0)
        else const SizedBox(height: 220),

        // --- Status label ---
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: isActive
              ? Text(
                  _statusLabel(status, localizations),
                  key: ValueKey(status),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.75),
                    fontSize: 13,
                    fontWeight: FontWeight.w300,
                    letterSpacing: 5,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Color _orbColor(AppState? status) {
    switch (status) {
      case AppState.listening:
        return const Color(0xFF6C8EFF);
      case AppState.thinking:
        return const Color(0xFFB06EFB);
      case AppState.speaking:
        return const Color(0xFF5ECFB1);
      default:
        return Colors.white24;
    }
  }

  String _statusLabel(AppState? status, AppLocalizations localizations) {
    switch (status) {
      case AppState.listening:
        return localizations.translate('listening').toUpperCase();
      case AppState.thinking:
        return localizations.translate('thinking').toUpperCase();
      case AppState.speaking:
        return localizations.translate('speaking').toUpperCase();
      default:
        return '';
    }
  }
}

/// Draws elegant dashed arc rings that rotate around the orb
class _ArcRingPainter extends CustomPainter {
  final Color color;
  final double progress;

  _ArcRingPainter({required this.color, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;

    final paint = Paint()
      ..color = color.withOpacity(0.5 + progress * 0.3)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // Three arcs at different offsets
    for (int i = 0; i < 3; i++) {
      final startAngle = (i * (2 * math.pi / 3));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - i * 8),
        startAngle,
        math.pi * 0.6,
        false,
        paint..color = color.withOpacity((0.5 - i * 0.12).clamp(0, 1)),
      );
    }

    // Centre glow dot
    canvas.drawCircle(
      center,
      4 + progress * 3,
      Paint()
        ..color = color.withOpacity(0.9)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  @override
  bool shouldRepaint(_ArcRingPainter old) => old.progress != progress || old.color != color;
}

// ---------------------------------------------------------------------------
// Premium Waveform — used optionally inside listening state
// ---------------------------------------------------------------------------

class WaveformVisualizer extends StatefulWidget {
  const WaveformVisualizer({super.key});

  @override
  State<WaveformVisualizer> createState() => _WaveformVisualizerState();
}

class _WaveformVisualizerState extends State<WaveformVisualizer>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(7, (i) {
            final t = _ctrl.value;
            final phase = math.sin((i / 7) * math.pi + t * math.pi);
            final h = 8.0 + phase.abs() * 28;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2.5),
              width: 3,
              height: h,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.55 + phase.abs() * 0.45),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}