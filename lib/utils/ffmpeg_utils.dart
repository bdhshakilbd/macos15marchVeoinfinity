import 'dart:io';
import 'package:path/path.dart' as path;

class FFmpegUtils {
  static String? _cachedFFmpegPath;
  static String? _cachedFFprobePath;

  /// Get the path to the FFmpeg executable
  static Future<String> getFFmpegPath() async {
    if (_cachedFFmpegPath != null) return _cachedFFmpegPath!;

    String binaryName = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    
    // 1. Check local directory (App dir or Current dir)
    // Windows: Only check App dir (debug/release folder) to avoid CWD issues
    // Client requested: "remove all the method only try to get ffmpeg.exe... from the folder where the flutter veo app exe runs... and just use fallback to system path"
    final localPaths = <String>[];
    localPaths.add(path.join(path.dirname(Platform.resolvedExecutable), binaryName));
    
    if (!Platform.isWindows) {
      // For non-Windows, keep checking current directory as before
      localPaths.add(path.join(Directory.current.path, binaryName));
    }

    for (final p in localPaths) {
      if (await File(p).exists()) {
        _cachedFFmpegPath = p;
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
          return p;
        }
      }
    }

    // 3. Fallback to system PATH
    _cachedFFmpegPath = binaryName;
    return binaryName;
  }

  /// Get the path to the FFprobe executable
  static Future<String> getFFprobePath() async {
    if (_cachedFFprobePath != null) return _cachedFFprobePath!;

    String binaryName = Platform.isWindows ? 'ffprobe.exe' : 'ffprobe';
    
    // 1. Check local directory
    final localPaths = <String>[];
    localPaths.add(path.join(path.dirname(Platform.resolvedExecutable), binaryName));
    
    if (!Platform.isWindows) {
      localPaths.add(path.join(Directory.current.path, binaryName));
    }

    for (final p in localPaths) {
      if (await File(p).exists()) {
        _cachedFFprobePath = p;
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
          return p;
        }
      }
    }

    // 3. Fallback to system PATH
    _cachedFFprobePath = binaryName;
    return binaryName;
  }
}
