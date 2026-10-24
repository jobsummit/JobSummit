import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/upload_specs.dart';

/// Your photo and signature, picked once and kept on this phone (never backed
/// up), made into the file each exam form wants (MainActivity's ImageMaker).
abstract final class FormImages {
  static const _channel = MethodChannel('jobsummit/media');

  static Future<Directory> _dir() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}/form_images');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// The picture you chose for [kind] before, if any.
  static Future<File?> original(UploadKind kind) async {
    final f = File('${(await _dir()).path}/${kind.wire}');
    return await f.exists() ? f : null;
  }

  /// Choose a picture for [kind] from the gallery or files; kept for next time.
  static Future<File?> choose(UploadKind kind) async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = picked?.files.single.path;
    if (path == null) return null;
    return File(path).copy('${(await _dir()).path}/${kind.wire}');
  }

  /// The JPEG for [spec], from [original].
  static Future<Uint8List> make(File original, UploadSpec spec) async {
    final bytes = await _channel.invokeMethod<Uint8List>('make', {
      'path': original.path,
      'width': spec.width,
      'height': spec.height,
      'minKb': spec.minKb,
      'maxKb': spec.maxKb,
    });
    if (bytes == null) throw StateError('no image');
    return bytes;
  }

  /// Into Pictures/JobSummit, where the form's "choose file" finds it. Returns
  /// where, or null when Android 9 or older said no to storage.
  static Future<String?> save(Uint8List bytes, String name) async {
    final android = await DeviceInfoPlugin().androidInfo;
    if (android.version.sdkInt < 29 && !await Permission.storage.request().isGranted) return null;
    return _channel.invokeMethod<String>('save', {'bytes': bytes, 'name': name});
  }

  static Future<void> share(Uint8List bytes, String name) async {
    final file = File('${(await getTemporaryDirectory()).path}/$name');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: 'image/jpeg')]));
  }

  /// "ssc-cgl-2026-photo.jpg"
  static String fileName(String examName, UploadKind kind) {
    final slug = examName.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
    final short = slug.length > 40 ? slug.substring(0, 40) : slug;
    return '${short.isEmpty ? 'exam' : short}-${kind.wire.replaceAll('_', '-')}.jpg';
  }
}
