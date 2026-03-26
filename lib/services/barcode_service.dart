import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class BarcodeService {
  final MobileScannerController _controller = MobileScannerController(
    autoStart: false,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.qrCode,
    ],
    detectionSpeed: DetectionSpeed.normal,
  );

  StreamSubscription<BarcodeCapture>? _sub;
  String? _lastBarcode;

  String? get lastBarcode => _lastBarcode;

  Future<String?> scanImagePath(String imagePath) async {
    try {
      _sub ??= _controller.barcodes.listen((capture) {
        for (final barcode in capture.barcodes) {
          final raw = barcode.rawValue?.trim();
          if (raw != null && raw.isNotEmpty) {
            _lastBarcode = raw;
            break;
          }
        }
      });
      await _controller.analyzeImage(imagePath);
      return _lastBarcode;
    } catch (e) {
      debugPrint('[Barcode] scanImagePath error: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.dispose();
  }
}
