import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:flutter/foundation.dart';

class ImageUtils {
  /// Compresses image in a background isolate to keep main thread responsive (no UI lag).
  static Future<File> compressImage(String path) async {
    return await compute(_processImage, path);
  }

  /// Internal worker function for compute()
  static File _processImage(String path) {
    final bytes = File(path).readAsBytesSync();
    img.Image? image = img.decodeImage(bytes);
    
    if (image == null) return File(path);

    // Resize to reasonable size for mobile AI
    if (image.width > 1200) {
      image = img.copyResize(image, width: 1200);
    }

    // Compress to JPEG with 70% quality
    final compressedBytes = img.encodeJpg(image, quality: 70);
    
    // Create a new file for the compressed image to avoid path conflict
    int dotIndex = path.lastIndexOf('.');
    final String newPath = dotIndex != -1 
        ? path.substring(0, dotIndex) + '_compressed.jpg'
        : path + '_compressed.jpg';
        
    final compressedFile = File(newPath)..writeAsBytesSync(compressedBytes);
    return compressedFile;
  }
}
