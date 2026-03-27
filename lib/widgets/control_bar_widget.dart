import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';

class ControlBarWidget extends ConsumerWidget {
  final GlobalKey? micKey;
  final GlobalKey? cameraKey;
  final GlobalKey? flashKey;

  const ControlBarWidget({
    super.key,
    this.micKey,
    this.cameraKey,
    this.flashKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationProvider);
    final status = state.status;
    final isFlashOn = state.isFlashOn;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // --- Camera Flip Button ---
          _GlassControl(
            key: cameraKey,
            icon: Icons.flip_camera_ios_rounded,
            onTap: () {
              HapticFeedback.lightImpact();
              ref.read(conversationProvider.notifier).switchCamera();
            },
          ),

          // --- PTT Mic Button ---
          _MicButton(
            key: micKey,
            status: status,
            onLongPressStart: () {
              final s = ref.read(conversationProvider).status;
              if (s == AppState.thinking) return;
              HapticFeedback.heavyImpact();
              if (s == AppState.speaking) {
                ref.read(conversationProvider.notifier).stopSpeaking();
              }
              ref.read(conversationProvider.notifier).startListening();
            },
            onLongPressEnd: () {
              final s = ref.read(conversationProvider).status;
              if (s == AppState.listening) {
                HapticFeedback.mediumImpact();
                ref.read(conversationProvider.notifier).stopListeningAndProcess();
              }
            },
            onTap: () {
              final s = ref.read(conversationProvider).status;
              if (s == AppState.thinking) return;
              if (s == AppState.speaking) {
                HapticFeedback.mediumImpact();
                ref.read(conversationProvider.notifier).stopSpeaking();
              }
            },
          ),

          // --- Flash Toggle Button ---
          _GlassControl(
            key: flashKey,
            icon: isFlashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
            isActive: isFlashOn,
            onTap: () {
              HapticFeedback.lightImpact();
              ref.read(conversationProvider.notifier).toggleFlash();
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Premium Glass Control Circle — used for auxiliary buttons
// ---------------------------------------------------------------------------

class _GlassControl extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;

  const _GlassControl({
    super.key,
    required this.icon,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      scale: isActive ? 1.06 : 1,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          splashColor: Colors.white24,
          highlightColor: Colors.white10,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive
                  ? Colors.white.withOpacity(0.2)
                  : Colors.white.withOpacity(0.08),
              border: Border.all(
                color: isActive
                    ? Colors.white.withOpacity(0.4)
                    : Colors.white.withOpacity(0.12),
              ),
            ),
            child: Icon(
              icon,
              color: isActive ? Colors.white : Colors.white70,
              size: 22,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PTT Mic Button
// Blue   = listening
// Purple = thinking (locked — no interaction)
// Green  = speaking
// Orange = interrupt flash (brief, on press during speaking)
// ---------------------------------------------------------------------------

class _MicButton extends StatefulWidget {
  final AppState status;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final VoidCallback onTap;

  const _MicButton({
    super.key,
    required this.status,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onTap,
  });

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  bool _interrupted = false;
  bool _didStartListening = false;
  Timer? _interruptTimer;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _interruptTimer?.cancel();
    _scaleController.dispose();
    super.dispose();
  }

  void _flashInterrupt() {
    _interruptTimer?.cancel();
    setState(() => _interrupted = true);
    _interruptTimer = Timer(const Duration(milliseconds: 450), () {
      if (mounted) setState(() => _interrupted = false);
    });
  }

  Color get _strokeColor {
    if (_interrupted) return const Color(0xFFFF8C42);
    switch (widget.status) {
      case AppState.listening:
        return const Color(0xFF6C8EFF); // blue
      case AppState.thinking:
        return const Color(0xFFB06EFB); // purple
      case AppState.speaking:
        return const Color(0xFF5ECFB1); // green
      default:
        return Colors.white.withOpacity(0.2);
    }
  }

  bool get _isActive =>
      _interrupted ||
      (widget.status != AppState.idle && widget.status != AppState.error);

  @override
  Widget build(BuildContext context) {
    final color = _strokeColor;
    final active = _isActive;
    final isThinking = widget.status == AppState.thinking;

    return GestureDetector(
      onLongPressStart: (_) {
        if (isThinking) return;
        _scaleController.forward();
        if (widget.status == AppState.speaking) _flashInterrupt();
        _didStartListening = true;
        widget.onLongPressStart();
      },
      onLongPressEnd: (_) {
        if (!_didStartListening) return;
        _didStartListening = false;
        _scaleController.reverse();
        widget.onLongPressEnd();
      },
      onTap: () {
        if (isThinking) return;
        if (widget.status == AppState.speaking) _flashInterrupt();
        widget.onTap();
      },
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) => Transform.scale(
          scale: _scaleAnimation.value,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: active
                    ? [color.withOpacity(0.45), color.withOpacity(0.2)]
                    : [
                        Colors.white.withOpacity(0.15),
                        Colors.white.withOpacity(0.05),
                      ],
              ),
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: color.withOpacity(0.45),
                        blurRadius: 22,
                        spreadRadius: 4,
                      )
                    ]
                  : [],
              border: Border.all(color: color, width: 2.0),
            ),
            child: Center(
              child: Icon(
                isThinking
                    ? Icons.hourglass_top_rounded
                    : (widget.status == AppState.speaking
                        ? Icons.stop_rounded
                        : Icons.mic_rounded),
                color: isThinking ? color : Colors.white,
                size: 36,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
