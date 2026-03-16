import 'dart:io';
import 'package:path/path.dart' as path;

class FFmpegUtils {
  static String? _cachedFFmpegPath;
  static String? _cachedFFprobePath;

  /// Get the path to the FFmpeg executable
  static Future<String> getFFmpegPath() async {
    if (_cachedFFmpegPath != null) return _cachedFFmpegPath!;

    String binaryName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    
    // 1. Check local directory (App dir)
    final localPaths = <String>[];
    final exeDir = path.dirname(Platform.resolvedExecutable);
    localPaths.add(path.join(exeDir, binaryName));
    
    // macOS: Also check inside the .app bundle (Contents/MacOS and Contents/Resources)
    if (Platform.isMacOS) {
      // exeDir is already Contents/MacOS/ for bundled apps
      final contentsDir = path.dirname(exeDir); // Contents/
      localPaths.add(path.join(contentsDir, 'Resources', binaryName));
    }
    
    if (!Platform.isWindows) {
      localPaths.add(path.join(Directory.current.path, binaryName));
    }

    for (final p in localPaths) {
      if (await File(p).exists()) {
        _cachedFFmpegPath = p;
        print('[FFmpeg] Found ffmpeg at: $p');
        return p;
      }
    }

    // 2. Check standard macOS locations
    if (Platform.isMacOS) {
      final macPaths = [
        '/opt/homebrew/bin/ffmpeg',
        '/usr/local/bin/ffmpeg',
        '/usr/bin/ffmpeg',
      ];
      for (final p in macPaths) {
        if (await File(p).exists()) {
          _cachedFFmpegPath = p;
          print('[FFmpeg] Found ffmpeg at: $p');
          return p;
        }
      }
    }

    // 3. Fallback to system PATH
    print('[FFmpeg] Using system PATH fallback: $binaryName');
    _cachedFFmpegPath = binaryName;
    return binaryName;
  }

  /// Get the path to the FFprobe executable
  static Future<String> getFFprobePath() async {
    if (_cachedFFprobePath != null) return _cachedFFprobePath!;

    String binaryName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    
    // 1. Check local directory
    final localPaths = <String>[];
    final exeDir = path.dirname(Platform.resolvedExecutable);
    localPaths.add(path.join(exeDir, binaryName));
    
    // macOS: Also check inside the .app bundle
    if (Platform.isMacOS) {
      final contentsDir = path.dirname(exeDir);
      localPaths.add(path.join(contentsDir, 'Resources', binaryName));
    }
    
    if (!Platform.isWindows) {
      localPaths.add(path.join(Directory.current.path, binaryName));
    }

    for (final p in localPaths) {
      if (await File(p).exists()) {
        _cachedFFprobePath = p;
        print('[FFmpeg] Found ffprobe at: $p');
        return p;
      }
    }

    // 2. Check standard macOS locations
    if (Platform.isMacOS) {
      final macPaths = [
        '/opt/homebrew/bin/ffprobe',
        '/usr/local/bin/ffprobe',
        '/usr/bin/ffprobe',
      ];
      for (final p in macPaths) {
        if (await File(p).exists()) {
          _cachedFFprobePath = p;
          print('[FFmpeg] Found ffprobe at: $p');
          return p;
        }
      }
    }

    // 3. Fallback to system PATH
    print('[FFmpeg] Using system PATH fallback: $binaryName');
    _cachedFFprobePath = binaryName;
    return binaryName;
  }
}
