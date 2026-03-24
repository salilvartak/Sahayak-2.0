import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';
import '../providers/language_provider.dart';
import '../widgets/camera_preview_widget.dart';
import '../widgets/control_bar_widget.dart';
import '../widgets/response_panel_widget.dart';
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
    with TickerProviderStateMixin {
  
  // Tutorial Keys
  final GlobalKey _micKey = GlobalKey();
  final GlobalKey _cameraKey = GlobalKey();
  final GlobalKey _flashKey = GlobalKey();
  final GlobalKey _orbKey = GlobalKey();
  final GlobalKey _historyKey = GlobalKey();
  final GlobalKey _languageKey = GlobalKey();

  TutorialCoachMark? _tutorialCoachMark;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(conversationProvider.notifier).initialize();
      _checkAndShowTutorial();
    });
  }

  void _checkAndShowTutorial() {
    final settings = ref.read(settingsProvider);
    if (!settings.tutorialCompleted) {
      _showTutorial();
    }
  }

  void _showTutorial() {
    final language = ref.read(languageProvider).language;
    final localizations = AppLocalizations(language);
    final tts = ref.read(ttsServiceProvider);
    final settings = ref.read(settingsProvider);
    tts.setSpeed(settings.voiceSpeed);

    final List<String> stepIds = ['welcome', 'mic', 'camera', 'flash', 'orb', 'history', 'language'];

    void speakTutorial(String titleKey, String descKey, String identify) {
      final title = localizations.translate(titleKey);
      final desc = localizations.translate(descKey);
      final isLast = identify == stepIds.last;
      
      final swipeInstruction = localizations.translate(
        isLast ? 'tutorial_swipe_finish' : 'tutorial_swipe_next'
      );
      
      tts.speak("$title. $desc. $swipeInstruction", language);
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
              localizations,
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
              localizations,
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
              localizations,
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
              localizations,
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
              localizations,
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
              localizations,
              isLast: false,
            ),
          ),
        ],
      ),
      TargetFocus(
        identify: "language",
        keyTarget: _languageKey,
        contents: [
          TargetContent(
            align: ContentAlign.bottom,
            builder: (context, controller) => _buildTutorialStepContent(
              controller,
              localizations,
              isLast: true,
            ),
          ),
        ],
      ),
    ];

    _tutorialCoachMark = TutorialCoachMark(
      targets: targets,
      beforeFocus: (target) {
        final Map<String, List<String>> tutorialKeysMap = {
          'welcome': ['tutorial_welcome_title', 'tutorial_welcome_desc'],
          'mic': ['tutorial_mic_title', 'tutorial_mic_desc'],
          'camera': ['tutorial_camera_title', 'tutorial_camera_desc'],
          'flash': ['tutorial_flash_title', 'tutorial_flash_desc'],
          'orb': ['tutorial_orb_title', 'tutorial_orb_desc'],
          'history': ['tutorial_history_title', 'tutorial_history_desc'],
          'language': ['tutorial_language_title', 'tutorial_language_desc'],
        };
        final keys = tutorialKeysMap[target.identify];
        if (keys != null) {
          speakTutorial(keys[0], keys[1], target.identify);
        }
      },
      colorShadow: Colors.black.withOpacity(0.95),
      opacityShadow: 0.95,
      paddingFocus: 10,
      hideSkip: true,
      onClickOverlay: (target) {
        _tutorialCoachMark?.next();
      },
      onFinish: () {
        tts.stop();
        ref.read(settingsProvider.notifier).setTutorialCompleted(true);
      },
      onSkip: () {
        tts.stop();
        ref.read(settingsProvider.notifier).setTutorialCompleted(true);
        return true;
      },
    )..show(context: context);
  }

  Widget _buildTutorialStepContent(
    TutorialCoachMarkController controller,
    AppLocalizations localizations, {
    bool isLast = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        // Use horizontal drag for "next" to avoid Oplus "Scroll to Top" conflict
        if (details.velocity.pixelsPerSecond.dx.abs() > 150) {
          if (isLast) {
            ref.read(settingsProvider.notifier).setTutorialCompleted(true);
            controller.skip();
          } else {
            controller.next();
          }
        }
      },
      child: Container(
        width: MediaQuery.of(context).size.width,
        height: 300, // Make it big for easier swiping
        color: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Prominent Logo instead of text
            _TutorialBotIcon(),
            const SizedBox(height: 30),
            // Subtle animated swipe indicator
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(seconds: 2),
              curve: Curves.easeInOut,
              onEnd: () {},
              builder: (context, value, child) {
                return Opacity(
                  opacity: 0.3 + (math.sin(value * math.pi).abs() * 0.4),
                  child: const Icon(
                    Icons.swipe_outlined, 
                    color: Colors.white, 
                    size: 32
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
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
                    const ResponsePanelWidget(),
                    const SizedBox(height: 12),
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

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final languageState = ref.watch(languageProvider);
    final localizations = AppLocalizations(languageState.language);

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
          onTap: () => Navigator.pushNamed(context, '/history'),
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
        GestureDetector(
          onTap: () => Navigator.pushNamed(context, '/language_selection'),
          child: Container(
            key: _languageKey,
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.white.withOpacity(0.08),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: const Icon(Icons.language_rounded, color: Colors.white70, size: 18),
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

class _TutorialBotIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 120,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        // Using a simpler shadow to reduce overdraw
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
  late Animation<double> _pulseAnim;

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

    _pulseAnim = Tween<double>(begin: 0.92, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
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
    final languageState = ref.watch(languageProvider);
    final status = ref.watch(conversationProvider).status;
    final bool isListening = status == AppState.listening;
    final bool isThinking = status == AppState.thinking;
    final bool isSpeaking = status == AppState.speaking;
    final bool isActive = isListening || isThinking || isSpeaking;
    final localizations = AppLocalizations(languageState.language);

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