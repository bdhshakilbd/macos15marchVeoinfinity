import 'dart:io';
import 'package:path/path.dart' as path;

class FFmpegUtils {
  static String? _cachedFFmpegPath;
  static String? _cachedFFprobePath;

  /// Get the path to the FFmpeg executable
  /// Search order on macOS: Homebrew (correct arch) → bundled in .app → system PATH
  static Future<String> getFFmpegPath() async {
    if (_cachedFFmpegPath != null) return _cachedFFmpegPath!;

    String binaryName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    
    // 1. On Windows: Check app directory first (bundled next to exe)
    if (Platform.isWindows) {
      final exeDir = path.dirname(Platform.resolvedExecutable);
      final p = path.join(exeDir, binaryName);
      if (await File(p).exists()) {
        _cachedFFmpegPath = p;
        print('[FFmpeg] Found ffmpeg (app dir): $p');
        return p;
      }
    }
    
    // 2. On macOS: Check system Homebrew/standard locations FIRST
    //    (Homebrew installs the correct architecture - Intel or ARM)
    if (Platform.isMacOS) {
      final macPaths = [
        '/opt/homebrew/bin/ffmpeg',      // Homebrew on Apple Silicon
        '/usr/local/bin/ffmpeg',          // Homebrew on Intel
        '/usr/bin/ffmpeg',                // System
      ];
      for (final p in macPaths) {
        if (await File(p).exists()) {
          _cachedFFmpegPath = p;
          print('[FFmpeg] Found ffmpeg (system): $p');
          return p;
        }
      }
    }
    
    // 3. Check app bundle directory (bundled binary - fallback for macOS)
    final exeDir = path.dirname(Platform.resolvedExecutable);
    final bundlePaths = <String>[
      path.join(exeDir, binaryName),
    ];
    
    // macOS: Also check Contents/Resources inside .app bundle
    if (Platform.isMacOS) {
      final contentsDir = path.dirname(exeDir);
      bundlePaths.add(path.join(contentsDir, 'Resources', binaryName));
    }
    
    if (!Platform.isWindows) {
      bundlePaths.add(path.join(Directory.current.path, binaryName));
    }

    for (final p in bundlePaths) {
      if (await File(p).exists()) {
        _cachedFFmpegPath = p;
        print('[FFmpeg] Found ffmpeg (bundled): $p');
        return p;
      }
    }

    // 4. Fallback to system PATH
    print('[FFmpeg] Using system PATH fallback: $binaryName');
    _cachedFFmpegPath = binaryName;
    return binaryName;
  }

  /// Get the path to the FFprobe executable
  /// Search order on macOS: Homebrew (correct arch) → bundled in .app → system PATH
  static Future<String> getFFprobePath() async {
    if (_cachedFFprobePath != null) return _cachedFFprobePath!;

    String binaryName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    
    // 1. On Windows: Check app directory first
    if (Platform.isWindows) {
      final exeDir = path.dirname(Platform.resolvedExecutable);
      final p = path.join(exeDir, binaryName);
      if (await File(p).exists()) {
        _cachedFFprobePath = p;
        print('[FFmpeg] Found ffprobe (app dir): $p');
        return p;
      }
    }
    
    // 2. On macOS: Check system Homebrew/standard locations FIRST
    if (Platform.isMacOS) {
      final macPaths = [
        '/opt/homebrew/bin/ffprobe',
        '/usr/local/bin/ffprobe',
        '/usr/bin/ffprobe',
      ];
      for (final p in macPaths) {
        if (await File(p).exists()) {
          _cachedFFprobePath = p;
          print('[FFmpeg] Found ffprobe (system): $p');
          return p;
        }
      }
    }
    
    // 3. Check app bundle directory (bundled binary - fallback)
    final exeDir = path.dirname(Platform.resolvedExecutable);
    final bundlePaths = <String>[
      path.join(exeDir, binaryName),
    ];
    
    if (Platform.isMacOS) {
      final contentsDir = path.dirname(exeDir);
      bundlePaths.add(path.join(contentsDir, 'Resources', binaryName));
    }
    
    if (!Platform.isWindows) {
      bundlePaths.add(path.join(Directory.current.path, binaryName));
    }

    for (final p in bundlePaths) {
      if (await File(p).exists()) {
        _cachedFFprobePath = p;
        print('[FFmpeg] Found ffprobe (bundled): $p');
        return p;
      }
    }

    // 4. Fallback to system PATH
    print('[FFmpeg] Using system PATH fallback: $binaryName');
    _cachedFFprobePath = binaryName;
    return binaryName;
  }
}
