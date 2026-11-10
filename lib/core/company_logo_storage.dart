import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as image;

class CompanyLogoStorage {
  CompanyLogoStorage._();

  static const int maxBytes = 8 * 1024 * 1024;
  static const int maxPixels = 24000000;
  static const Set<String> supportedExtensions = {'.png', '.jpg', '.jpeg'};
  static const List<int> _pngSignature = [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
  ];

  /// Returns an Arabic validation message, or null when the file is valid.
  static String? validateBytes(String fileName, List<int> bytes) {
    final extension = p.extension(fileName).toLowerCase();
    if (!supportedExtensions.contains(extension)) {
      return 'صيغة الشعار يجب أن تكون PNG أو JPG.';
    }
    if (bytes.isEmpty) return 'ملف الشعار فارغ.';
    if (bytes.length > maxBytes) {
      return 'حجم ملف الشعار يجب ألا يتجاوز 8 ميغابايت.';
    }

    if (extension == '.png') {
      var isPng = bytes.length >= _pngSignature.length;
      for (var i = 0; isPng && i < _pngSignature.length; i++) {
        isPng = bytes[i] == _pngSignature[i];
      }
      if (!isPng) return 'محتوى الملف لا يطابق صيغة PNG.';
    } else {
      final isJpeg =
          bytes.length >= 3 &&
          bytes[0] == 0xff &&
          bytes[1] == 0xd8 &&
          bytes[2] == 0xff;
      if (!isJpeg) return 'محتوى الملف لا يطابق صيغة JPEG.';
    }
    image.Image? decoded;
    try {
      decoded = image.decodeImage(Uint8List.fromList(bytes));
    } catch (_) {
      return 'تعذر فك ترميز الصورة؛ اختر ملف PNG أو JPG صالحاً.';
    }
    if (decoded == null) {
      return 'تعذر فك ترميز الصورة؛ اختر ملف PNG أو JPG صالحاً.';
    }
    if (decoded.width <= 0 ||
        decoded.height <= 0 ||
        decoded.width * decoded.height > maxPixels) {
      return 'أبعاد الشعار غير صالحة أو كبيرة جداً للاستخدام.';
    }
    return null;
  }

  static Future<File> saveCandidate({
    required String fileName,
    required Uint8List bytes,
    String? supportDirectory,
  }) async {
    final validationError = validateBytes(fileName, bytes);
    if (validationError != null) throw FormatException(validationError);

    final root =
        supportDirectory ?? (await getApplicationSupportDirectory()).path;
    final directory = Directory(p.join(root, 'aqari_erp', 'branding'));
    await directory.create(recursive: true);
    final nonce = Random.secure().nextInt(1 << 32).toRadixString(16);
    final target = File(
      p.join(
        directory.path,
        'company_logo_${DateTime.now().microsecondsSinceEpoch}_$nonce'
        '${p.extension(fileName).toLowerCase()}',
      ),
    );
    return target.writeAsBytes(bytes, flush: true);
  }

  /// Deletes only a file inside this app's managed branding directory.
  static Future<void> deleteManagedFile(
    String? path, {
    String? supportDirectory,
  }) async {
    if (path == null || path.trim().isEmpty) return;
    final root =
        supportDirectory ?? (await getApplicationSupportDirectory()).path;
    final managedDirectory = p.normalize(
      p.absolute(p.join(root, 'aqari_erp', 'branding')),
    );
    final target = p.normalize(p.absolute(path));
    if (!p.isWithin(managedDirectory, target)) return;
    final file = File(target);
    if (await file.exists()) await file.delete();
  }
}
