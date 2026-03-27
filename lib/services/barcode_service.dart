import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeService {
  // mobile_scanner v7: analyzeImage returns Future<BarcodeCapture?> directly
  // — no stream subscription needed, no race condition.
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.qrCode,
      BarcodeFormat.code128,
      BarcodeFormat.code39,
      BarcodeFormat.dataMatrix,
    ],
    detectionSpeed: DetectionSpeed.normal,
  );

  Future<String?> scanImagePath(String imagePath) async {
    debugPrint('[Barcode] Scanning: $imagePath');
    try {
      final capture = await _controller.analyzeImage(imagePath);
      if (capture == null || capture.barcodes.isEmpty) {
        debugPrint('[Barcode] No barcode detected in image');
        return null;
      }
      final value = capture.barcodes.first.rawValue;
      final format = capture.barcodes.first.format;
      debugPrint('[Barcode] Detected: $value (format: $format)');
      return value;
    } catch (e) {
      debugPrint('[Barcode] Error: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    await _controller.dispose();
  }
}
