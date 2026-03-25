import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';

/// PART 11 — UI: No interaction model.
/// Voice IS the interface. All buttons removed except hardware utility controls
/// (camera flip, flash). The mic area is replaced by a live state indicator.
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
    final isFlashOn = state.isFlashOn;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Camera flip — hardware utility, not interaction
          _GlassControl(
            key: cameraKey,
            icon: Icons.flip_camera_ios_rounded,
            onTap: () => ref.read(conversationProvider.notifier).switchCamera(),
          ),

          // State indicator — replaces PTT mic button
          _VoiceStateIndicator(key: micKey, status: state.status),

          // Flash toggle — hardware utility
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
// Voice State Indicator — animated circle showing current pipeline state
// ---------------------------------------------------------------------------

class _VoiceStateIndicator extends StatefulWidget {
  final AppVoiceState status;

  const _VoiceStateIndicator({super.key, required this.status});

  @override
  State<_VoiceStateIndicator> createState() => _VoiceStateIndicatorState();
}

class _VoiceStateIndicatorState extends State<_VoiceStateIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.88, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, shouldPulse) = _stateVisual(widget.status);

    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (context, _) {
        final scale = shouldPulse ? _pulseAnim.value : 1.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.12),
              border: Border.all(color: color.withValues(alpha: 0.35), width: 1.5),
              boxShadow: shouldPulse
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.25),
                        blurRadius: 18,
                        spreadRadius: 2,
                      )
                    ]
                  : [],
            ),
            child: _buildInnerContent(widget.status, icon, color),
          ),
        );
      },
    );
  }

  Widget _buildInnerContent(
      AppVoiceState status, IconData icon, Color color) {
    // Waveform for capturing
    if (status == AppVoiceState.capturing) {
      return Center(child: _MiniWaveform(color: color));
    }
    // Spinner for thinking/transcribing
    if (status == AppVoiceState.thinking ||
        status == AppVoiceState.transcribing) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      );
    }
    return Center(child: Icon(icon, color: color, size: 34));
  }

  (IconData, Color, bool) _stateVisual(AppVoiceState status) {
    switch (status) {
      case AppVoiceState.listening:
        return (Icons.graphic_eq_rounded, const Color(0xFF6C8EFF), true);
      case AppVoiceState.capturing:
        return (Icons.mic_rounded, const Color(0xFF6C8EFF), true);
      case AppVoiceState.transcribing:
        return (Icons.transcribe_rounded, const Color(0xFFB06EFB), true);
      case AppVoiceState.thinking:
        return (Icons.psychology_rounded, const Color(0xFFB06EFB), true);
      case AppVoiceState.streaming:
      case AppVoiceState.speaking:
        return (Icons.volume_up_rounded, const Color(0xFF5ECFB1), true);
      case AppVoiceState.interrupted:
        return (Icons.bolt_rounded, Colors.orange, true);
      case AppVoiceState.error:
        return (Icons.error_outline_rounded, Colors.redAccent, false);
      case AppVoiceState.idle:
        return (Icons.mic_none_rounded, Colors.white30, false);
    }
  }
}

// ---------------------------------------------------------------------------
// Mini waveform — shown inside indicator during capturing state
// ---------------------------------------------------------------------------

class _MiniWaveform extends StatefulWidget {
  final Color color;
  const _MiniWaveform({required this.color});

  @override
  State<_MiniWaveform> createState() => _MiniWaveformState();
}

class _MiniWaveformState extends State<_MiniWaveform>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
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
      builder: (context2, child) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(5, (i) {
            final phase =
                math.sin((i / 5) * math.pi + _ctrl.value * math.pi).abs();
            final h = 6.0 + phase * 22;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              width: 3,
              height: h,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: (0.6 + phase * 0.4).clamp(0.0, 1.0)),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Glass Control — camera flip, flash
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
              ? Colors.white.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.08),
          border: Border.all(
            color: isActive
                ? Colors.white.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.12),
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
