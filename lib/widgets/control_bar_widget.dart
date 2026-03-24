import 'package:flutter/material.dart';
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
    final isSpeaking = status == AppState.speaking;
    final isListening = status == AppState.listening;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // --- Camera Flip Button ---
          _GlassControl(
            key: cameraKey,
            icon: Icons.flip_camera_ios_rounded,
            onTap: () => ref.read(conversationProvider.notifier).switchCamera(),
          ),

          // --- PTT Mic Button ---
          _MicButton(
            key: micKey,
            isListening: isListening,
            isSpeaking: isSpeaking,
            onPressed: () {
              if (isSpeaking) {
                ref.read(conversationProvider.notifier).stopSpeaking();
              }
            },
            onLongPressStart: () {
              if (isSpeaking) {
                ref.read(conversationProvider.notifier).stopSpeaking();
              }
              ref.read(conversationProvider.notifier).startListening();
            },
            onLongPressEnd: () {
              ref.read(conversationProvider.notifier).stopListeningAndProcess();
            },
          ),

          // --- Flash Toggle Button ---
          _GlassControl(
            key: flashKey,
            icon: isFlashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
            isActive: isFlashOn,
            onTap: () => ref.read(conversationProvider.notifier).toggleFlash(),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
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
    );
  }
}

// ---------------------------------------------------------------------------
// PTT Mic Button — The heart of the control bar
// ---------------------------------------------------------------------------

class _MicButton extends StatefulWidget {
  final bool isListening;
  final bool isSpeaking;
  final VoidCallback onLongPressStart;
  final VoidCallback onLongPressEnd;
  final VoidCallback onPressed;

  const _MicButton({
    super.key,
    required this.isListening,
    required this.isSpeaking,
    required this.onLongPressStart,
    required this.onLongPressEnd,
    required this.onPressed,
  });

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton> with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) {
        _scaleController.forward();
        widget.onLongPressStart();
      },
      onLongPressEnd: (_) {
        _scaleController.reverse();
        widget.onLongPressEnd();
      },
      onTap: widget.onPressed,
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: widget.isListening
                      ? [const Color(0xFF6C8EFF), const Color(0xFFB06EFB)]
                      : [Colors.white.withOpacity(0.15), Colors.white.withOpacity(0.05)],
                ),
                boxShadow: widget.isListening
                    ? [
                        BoxShadow(
                          color: const Color(0xFF6C8EFF).withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 4,
                        )
                      ]
                    : [],
                border: Border.all(
                  color: widget.isListening 
                      ? Colors.white.withOpacity(0.5) 
                      : Colors.white.withOpacity(0.12),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Icon(
                  widget.isSpeaking ? Icons.stop_rounded : Icons.mic_rounded,
                  color: Colors.white,
                  size: 38,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
