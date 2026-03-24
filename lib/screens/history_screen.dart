import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../providers/conversation_provider.dart';
import '../providers/language_provider.dart';
import '../providers/settings_provider.dart';
import '../models/conversation_turn.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(conversationProvider);
    final history = state.history;
    final languageState = ref.watch(languageProvider);
    final language = languageState.language;

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
    final languageState = ref.watch(languageProvider);
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

                // Query and Play Button
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        turn.query,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: (17 * settings.textSizeMultiplier).toDouble(),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    _AudioButton(
                      text: turn.query, 
                      language: languageState.language, 
                      isUser: true
                    ),
                  ],
                ),
                
                const SizedBox(height: 12),
                
                // Response with its own play button
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        turn.response,
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: (15 * settings.textSizeMultiplier).toDouble(),
                          height: 1.5,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.bottomRight,
                        child: _AudioButton(
                          text: turn.response, 
                          language: languageState.language, 
                          isUser: false
                        ),
                      ),
                    ],
                  ),
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

class _AudioButton extends ConsumerStatefulWidget {
  final String text;
  final dynamic language; // Use appropriate language type
  final bool isUser;

  const _AudioButton({
    required this.text,
    required this.language,
    required this.isUser,
  });

  @override
  ConsumerState<_AudioButton> createState() => _AudioButtonState();
}

class _AudioButtonState extends ConsumerState<_AudioButton> {
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
          // Use the speak method we just added
          await notifier.speak(widget.text, widget.language); 
          if (mounted) setState(() => _isPlaying = false);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: widget.isUser ? Colors.blue.withOpacity(0.2) : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 16,
            ),
            const SizedBox(width: 4),
            Icon(
              widget.isUser ? Icons.person_rounded : Icons.android_rounded,
              color: Colors.white70,
              size: 14,
            ),
          ],
        ),
      ),
    );
  }
}
