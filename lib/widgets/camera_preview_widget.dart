import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/conversation_provider.dart';
import '../models/language.dart';
import '../localization/app_localizations.dart';

class CameraPreviewWidget extends ConsumerStatefulWidget {
  const CameraPreviewWidget({super.key});

  @override
  ConsumerState<CameraPreviewWidget> createState() => _CameraPreviewWidgetState();
}

class _CameraPreviewWidgetState extends ConsumerState<CameraPreviewWidget> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(conversationProvider);
    final conversation = ref.read(conversationProvider.notifier);
    final controller = conversation.cameraService.controller;
    const language = Language.english;
    final localizations = AppLocalizations(language);

    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Full Screen Camera Preview
        FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.previewSize!.height,
            height: controller.value.previewSize!.width,
            child: CameraPreview(controller),
          ),
        ),

        // Subtile Dark Overlay for contrast
        Container(color: Colors.black12),


      ],
    );
  }
}
