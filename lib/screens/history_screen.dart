import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../providers/conversation_provider.dart';
import '../providers/settings_provider.dart';
import '../models/conversation_turn.dart';
import '../models/language.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationProvider);
    final history = state.history;
    const language = Language.english;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          'HISTORY',
          style: const TextStyle(
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
            onPressed: () => ref.read(conversationProvider.notifier).initialize(),
          ),
          const SizedBox(width: 8),
        ],
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          // Background Gradient
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xFF1A1A1A),
                    Colors.black,
                  ],
                ),
              ),
            ),
          ),

          // History List
          SafeArea(
            child: history.isEmpty
                ? Center(
                    child: Text(
                      'No history yet',
                      style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                    physics: const BouncingScrollPhysics(),
                    itemCount: history.length,
                    itemBuilder: (context, index) {
                      final turn = history[index];
                      return _HistoryCard(turn: turn);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _HistoryCard extends ConsumerWidget {
  final ConversationTurn turn;

  const _HistoryCard({required this.turn});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    const language = Language.english;
    final dateStr = DateFormat('MMM d, h:mm a').format(turn.timestamp);

    final bool isNetworkImage = turn.imagePath?.startsWith('http') ?? false;

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: Colors.white.withOpacity(0.12)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      dateStr.toUpperCase(),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Icon(Icons.history_toggle_off_rounded, color: Colors.white24, size: 16),
                  ],
                ),
                const SizedBox(height: 16),
                
                // Image Handling (Network or File)
                if (turn.imagePath != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 16),
                    width: double.infinity,
                    height: 220,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: isNetworkImage 
                        ? Image.network(
                            turn.imagePath!,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => _ImageError(),
                          )
                        : Image.file(
                            File(turn.imagePath!),
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) => _ImageError(),
                          ),
                    ),
                  ),

                // Voice Note players instead of text
                _VoicePlayerBubble(
                  text: turn.query,
                  language: language,
                  isUser: true,
                ),
                const SizedBox(height: 12),
                _VoicePlayerBubble(
                  text: turn.response,
                  language: language,
                  isUser: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageError extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white.withOpacity(0.05),
      child: const Icon(Icons.broken_image_rounded, color: Colors.white24, size: 30),
    );
  }
}

class _VoicePlayerBubble extends ConsumerStatefulWidget {
  final String text;
  final dynamic language;
  final bool isUser;

  const _VoicePlayerBubble({
    required this.text,
    required this.language,
    required this.isUser,
  });

  @override
  ConsumerState<_VoicePlayerBubble> createState() => _VoicePlayerBubbleState();
}

class _VoicePlayerBubbleState extends ConsumerState<_VoicePlayerBubble> {
  bool _isPlaying = false;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(conversationProvider.notifier);
    
    return InkWell(
      onTap: () async {
        if (_isPlaying) {
          notifier.stopSpeaking();
          setState(() => _isPlaying = false);
        } else {
          setState(() => _isPlaying = true);
          await notifier.speak(widget.text, widget.language); 
          if (mounted) setState(() => _isPlaying = false);
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: widget.isUser ? Colors.blueAccent.withOpacity(0.12) : Colors.greenAccent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: widget.isUser ? Colors.blueAccent.withOpacity(0.3) : Colors.greenAccent.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.isUser ? Colors.blueAccent.withOpacity(0.2) : Colors.greenAccent.withOpacity(0.2),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                color: widget.isUser ? Colors.blueAccent.shade100 : Colors.greenAccent.shade100,
                size: 22,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              // The fixed height prevents the bounding box from jumping up and down during the animation
              child: SizedBox(
                height: 24,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _WaveLine(isAnimating: _isPlaying, height: 12),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 16),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 10),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 18),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 14),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 8),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 16),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 12),
                    const SizedBox(width: 3),
                    _WaveLine(isAnimating: _isPlaying, height: 18),
                  ],
                ),
              ),
            ),
            Icon(
              widget.isUser ? Icons.person_outline_rounded : Icons.smart_toy_outlined,
              color: widget.isUser ? Colors.blueAccent.withOpacity(0.4) : Colors.greenAccent.withOpacity(0.3),
              size: 24,
            ),
          ],
        ),
      ),
    );
  }
}

class _WaveLine extends StatefulWidget {
  final bool isAnimating;
  final double height;
  
  const _WaveLine({required this.isAnimating, required this.height});

  @override
  State<_WaveLine> createState() => _WaveLineState();
}

class _WaveLineState extends State<_WaveLine> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    // Offset the duration slightly based on the initial height to create an organic, non-uniform wave effect
    final speed = 300 + (widget.height * 15).toInt();
    _controller = AnimationController(
      vsync: this, 
      duration: Duration(milliseconds: speed)
    );
    
    _animation = Tween<double>(begin: widget.height * 0.3, end: widget.height * 1.5).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine)
    );
    
    if (widget.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_WaveLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isAnimating != oldWidget.isAnimating) {
      if (widget.isAnimating) {
        _controller.repeat(reverse: true);
      } else {
        _controller.stop();
        _controller.animateTo(0.0); // Reset exactly where we started smoothly
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 3,
          height: widget.isAnimating ? _animation.value : widget.height * 0.7,
          margin: const EdgeInsets.symmetric(horizontal: 1.5),
          decoration: BoxDecoration(
            color: widget.isAnimating ? Colors.white : Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        );
      },
    );
  }
}
