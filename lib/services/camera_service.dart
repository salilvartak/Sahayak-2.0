import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

class CameraService {
  CameraController? _controller;
  List<CameraDescription>? _cameras;
  int _selectedCameraIndex = 0;
  bool _isInitializing = false;

  CameraController? get controller => _controller;

  Future<void> initialize() async {
    if (_isInitializing) return;
    final c = _controller;
    if (c != null && c.value.isInitialized) return;
    _isInitializing = true;
    try {
      _cameras ??= await availableCameras();
      final cams = _cameras;
      if (cams != null && cams.isNotEmpty) {
        await _initController(cams[_selectedCameraIndex]);
      }
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _initController(CameraDescription camera) async {
    await _controller?.dispose();
    _controller = null;
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    
    try {
      await controller.initialize();
      // Only set flash off if supported
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (e) {
        debugPrint("Flash mode not supported on this camera: $e");
      }
      _controller = controller;
    } catch (e) {
      await controller.dispose();
      rethrow;
    }
  }

  Future<void> switchCamera() async {
    final cams = _cameras;
    if (cams == null || cams.length < 2) return;
    _selectedCameraIndex = (_selectedCameraIndex + 1) % cams.length;
    _isFlashOn = false; // Reset flash state on switch
    await _initController(cams[_selectedCameraIndex]);
  }

  Future<void> onAppResumed() async {
    await initialize();
  }

  Future<void> onAppInactiveOrPaused() async {
    await _controller?.dispose();
    _controller = null;
  }

  bool _isFlashOn = false;
  bool get isFlashOn => _isFlashOn;

  Future<void> toggleFlash() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    
    try {
      _isFlashOn = !_isFlashOn;
      await c.setFlashMode(_isFlashOn ? FlashMode.torch : FlashMode.off);
    } catch (e) {
      _isFlashOn = false; 
      debugPrint("Error toggling flash: $e");
    }
  }

  Future<XFile?> captureFrame() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return null;
    return await c.takePicture();
  }

  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }
}
