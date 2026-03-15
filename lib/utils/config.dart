import 'dart:io';
import 'package:path/path.dart' as path;

import 'package:veo3_another/utils/ffmpeg_utils.dart';

/// Configuration constants
class AppConfig {
  static String profilesDir = _getProfilesDir();
  static String chromePath = _getChromePath();
  // static Future<String> get ffmpegPath => _getFFmpegPath(); // Unused, commented out
  static const int debugPort = 9222;

  /// Get a writable app data directory for storing config, cache, keys, etc.
  /// - Windows: same as exe directory (portable app)
  /// - macOS: ~/Library/Application Support/VEO3_Infinity/ (writable)
  /// - Android/iOS: handled separately via path_provider
  static String getAppDataDir() {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      return '$home/Library/Application Support/VEO3_Infinity';
    }
    // Windows: next to executable
    return path.dirname(Platform.resolvedExecutable);
  }

  /// Get profiles directory
  /// - Windows: uses 'profiles' folder next to executable
  /// - macOS: uses ~/Library/Application Support/VEO3_Infinity/profiles (writable)
  /// - Android/iOS: temporary path, overridden by main.dart
  static String _getProfilesDir() {
    if (Platform.isAndroid || Platform.isIOS) {
      return '/data/local/tmp/profiles'; // Will be overridden in _initializeOutputFolder
    }
    
    if (Platform.isMacOS) {
      // macOS .app bundle is READ-ONLY (App Translocation).
      // Use ~/Library/Application Support/ which is always writable.
      final home = Platform.environment['HOME'] ?? '/tmp';
      return '$home/Library/Application Support/VEO3_Infinity/profiles';
    }
    
    // Windows: next to executable
    final exePath = Platform.resolvedExecutable;
    final exeDir = path.dirname(exePath);
    return path.join(exeDir, 'profiles');
  }

  /// Custom Chrome path set by user (overrides auto-detection)
  static String? _customChromePath;
  
  /// Check if Chrome exists at the configured path
  static bool get isChromeFound => File(chromePath).existsSync();

  static String _getChromePath() {
    // Check for user-saved custom path first
    if (_customChromePath != null && File(_customChromePath!).existsSync()) {
      return _customChromePath!;
    }
    
    // Try loading saved custom path from disk
    try {
      final savedPath = _loadSavedChromePath();
      if (savedPath != null && File(savedPath).existsSync()) {
        _customChromePath = savedPath;
        return savedPath;
      }
    } catch (_) {}
    
    if (Platform.isMacOS) {
      // Try common macOS Chrome locations
      const macPaths = [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Google Chrome.app',
      ];
      for (final p in macPaths) {
        if (File(p).existsSync()) return p;
      }
      return macPaths[0]; // Default (will show as "not found")
    }
    
    // Windows paths
    const path1 = r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe';
    const path2 = r'C:\Program Files\Google\Chrome\Application\chrome.exe';
    
    if (File(path1).existsSync()) return path1;
    if (File(path2).existsSync()) return path2;
    return path2; // Default
  }

  /// Set a custom Chrome path (persists to disk)
  static void setCustomChromePath(String newPath) {
    _customChromePath = newPath;
    chromePath = newPath;
    // Save to disk
    try {
      final appDataDir = getAppDataDir();
      final dir = Directory(appDataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final configFile = File(path.join(appDataDir, 'chrome_config.json'));
      configFile.writeAsStringSync('{"chromePath": "$newPath"}');
      print('[AppConfig] Saved custom Chrome path: $newPath');
    } catch (e) {
      print('[AppConfig] Error saving Chrome path: $e');
    }
  }

  /// Load saved Chrome path from disk
  static String? _loadSavedChromePath() {
    try {
      final configFile = File(path.join(getAppDataDir(), 'chrome_config.json'));
      if (configFile.existsSync()) {
        final content = configFile.readAsStringSync();
        final data = (content.contains('{')) ? content : '{}';
        final json = data.contains('chromePath') ? data : '{}';
        if (json != '{}') {
          // Simple parse - avoid importing dart:convert at top level
          final match = RegExp(r'"chromePath"\s*:\s*"([^"]+)"').firstMatch(json);
          if (match != null) return match.group(1);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Get FFmpeg path - robust lookup via FFmpegUtils
  static Future<String> _getFFmpegPath() async {
    return await FFmpegUtils.getFFmpegPath();
  }
  
  /// Test FFmpeg and get version
  static Future<String> testFFmpeg() async {
    final ffmpegPath = await _getFFmpegPath();
    print('[FFMPEG TEST] Testing path: $ffmpegPath');
    
    try {
      final result = await Process.run(ffmpegPath, ['-version'], runInShell: true);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        // Extract version line
        final firstLine = output.split('\n').first;
        return 'OK: $firstLine\nPath: $ffmpegPath';
      } else {
        return 'ERROR: FFmpeg returned exit code ${result.exitCode}\n${result.stderr}';
      }
    } catch (e) {
      return 'ERROR: $e\nPath checked: $ffmpegPath';
    }
  }

  // Model options (API-based generation)
  static const Map<String, String> modelOptions = {
    'Veo 3.1 Fast (API)': 'veo_3_1_t2v_fast_ultra',
    'Veo 3.1 Quality (API)': 'veo_3_1_t2v_quality_ultra',
    'Veo 2 Fast (API)': 'veo_2_t2v_fast',
    'Veo 2 Quality (API)': 'veo_2_t2v_quality',
  };

  // Flow UI model options - ALL accounts can pick any model
  // Display Name -> Flow UI Display Name
  static const Map<String, String> flowModelOptions = {
    'Veo 3.1 - Fast': 'Veo 3.1 - Fast',
    'Veo 3.1 - Fast [Lower Priority]': 'Veo 3.1 - Fast [Lower Priority]',
    'Veo 3.1 - Quality': 'Veo 3.1 - Quality',
    'Veo 2 - Fast': 'Veo 2 - Fast',
    'Veo 2 - Quality': 'Veo 2 - Quality',
  };

  // For AI Pro accounts (Excludes Lower Priority)
  static const Map<String, String> flowModelOptionsPro = {
    'Veo 3.1 - Fast': 'Veo 3.1 - Fast',
    'Veo 3.1 - Quality': 'Veo 3.1 - Quality',
    'Veo 2 - Fast': 'Veo 2 - Fast',
    'Veo 2 - Quality': 'Veo 2 - Quality',
  };

  // For Free Flow accounts (Excludes Lower Priority)
  static const Map<String, String> flowModelOptionsFree = flowModelOptionsPro;

  // Alias for backwards compatibility
  static const Map<String, String> flowModelOptionsUltra = flowModelOptions;

  // Grok Options
  static const Map<String, String> flowModelOptionsGrok = {
    'Grok 3 (Beta)': 'grok-3',
  };

  // RunwayML Video Options
  static const Map<String, String> flowModelOptionsRunway = {
    'Runway Gen-4.5': 'gen4_5',
    'Runway Gen-4 Turbo': 'gen4_turbo',
    'Runway Gen-4': 'gen4',
  };

  // ============================================================================
  // HARDCODED MODEL KEY MAPPINGS
  // Every combination is explicitly defined — NO string manipulation
  // ============================================================================

  // ---- AI ULTRA: Text-to-Video (T2V) ----
  static const Map<String, String> apiModelKeysUltra = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast_ultra',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_ultra_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_t2v',
    'Veo 2 - Fast': 'veo_2_t2v_fast',
    'Veo 2 - Quality': 'veo_2_t2v_quality',
  };
  static const Map<String, String> apiModelKeysUltraPortrait = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast_portrait_ultra',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_portrait_ultra_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_t2v_portrait',
    'Veo 2 - Fast': 'veo_2_t2v_fast_portrait',
    'Veo 2 - Quality': 'veo_2_t2v_quality_portrait',
  };

  // ---- AI ULTRA: Image-to-Video single frame (I2V) ----
  static const Map<String, String> apiModelKeysUltraI2V = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_ultra',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_ultra_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality',
  };
  static const Map<String, String> apiModelKeysUltraI2VPortrait = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_portrait_ultra',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_portrait_ultra_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_portrait',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast_portrait',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality_portrait',
  };

  // ---- AI ULTRA: Image-to-Video first+last frame (I2V FL) ----
  // Pattern from browser: base_speed[_portrait]_fl_tier[_relaxed]
  static const Map<String, String> apiModelKeysUltraI2VFL = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_ultra_fl',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_fl_ultra_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_fl',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast_fl',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality_fl',
  };
  static const Map<String, String> apiModelKeysUltraI2VFLPortrait = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_portrait_ultra_fl',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_portrait_fl_ultra_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_portrait_fl',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast_portrait_fl',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality_portrait_fl',
  };

  // ---- AI PRO: Text-to-Video (T2V) ----
  static const Map<String, String> apiModelKeysPro = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_t2v_quality',
    'Veo 2 - Fast': 'veo_2_t2v_fast',
    'Veo 2 - Quality': 'veo_2_t2v_quality',
  };
  static const Map<String, String> apiModelKeysProPortrait = {
    'Veo 3.1 - Fast': 'veo_3_1_t2v_fast_portrait',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_t2v_fast_portrait_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_t2v_quality_portrait',
    'Veo 2 - Fast': 'veo_2_t2v_fast_portrait',
    'Veo 2 - Quality': 'veo_2_t2v_quality_portrait',
  };

  // ---- AI PRO: Image-to-Video single frame (I2V) ----
  static const Map<String, String> apiModelKeysProI2V = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_quality',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality',
  };
  static const Map<String, String> apiModelKeysProI2VPortrait = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_portrait',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_portrait_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_quality_portrait',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast_portrait',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality_portrait',
  };

  // ---- AI PRO: Image-to-Video first+last frame (I2V FL) ----
  // Pattern from browser: base_speed[_portrait]_fl[_relaxed]
  static const Map<String, String> apiModelKeysProI2VFL = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_fl',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_fl_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_quality_fl',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast_fl',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality_fl',
  };
  static const Map<String, String> apiModelKeysProI2VFLPortrait = {
    'Veo 3.1 - Fast': 'veo_3_1_i2v_s_fast_portrait_fl',
    'Veo 3.1 - Fast [Lower Priority]': 'veo_3_1_i2v_s_fast_portrait_fl_relaxed',
    'Veo 3.1 - Quality': 'veo_3_1_i2v_s_quality_portrait_fl',
    'Veo 2 - Fast': 'veo_2_i2v_s_fast_portrait_fl',
    'Veo 2 - Quality': 'veo_2_i2v_s_quality_portrait_fl',
  };

  // ---- FREE accounts: same as Pro ----
  static const Map<String, String> apiModelKeysFree = apiModelKeysPro;
  static const Map<String, String> apiModelKeysFreePortrait = apiModelKeysProPortrait;
  static const Map<String, String> apiModelKeysFreeI2V = apiModelKeysProI2V;
  static const Map<String, String> apiModelKeysFreeI2VPortrait = apiModelKeysProI2VPortrait;
  static const Map<String, String> apiModelKeysFreeI2VFL = apiModelKeysProI2VFL;
  static const Map<String, String> apiModelKeysFreeI2VFLPortrait = apiModelKeysProI2VFLPortrait;

  // For Grok
  static const Map<String, String> apiModelKeysGrok = {
    'Grok 3 (Beta)': 'grok-3',
  };

  /// Legacy: Convert Flow UI display name to API model key (T2V or I2V only)
  /// Kept for backward compatibility with existing code
  static String getApiModelKey(String displayName, String accountType, {bool hasImages = false}) {
    return getFullModelKey(
      displayName: displayName,
      accountType: accountType,
      hasFirstFrame: hasImages,
      hasLastFrame: false,
      isPortrait: false,
    );
  }

  /// Full model key lookup — no string manipulation, pure map lookup
  /// Returns the exact API model key for any combination of parameters
  static String getFullModelKey({
    required String displayName,
    required String accountType,
    bool hasFirstFrame = false,
    bool hasLastFrame = false,
    bool isPortrait = false,
  }) {
    if (accountType == 'supergrok') return apiModelKeysGrok[displayName] ?? 'grok-3';

    final bool hasImages = hasFirstFrame || hasLastFrame;
    final bool hasBothFrames = hasFirstFrame && hasLastFrame;

    final Map<String, String> mapping;

    switch (accountType) {
      case 'ai_ultra':
        if (hasBothFrames) {
          mapping = isPortrait ? apiModelKeysUltraI2VFLPortrait : apiModelKeysUltraI2VFL;
        } else if (hasImages) {
          mapping = isPortrait ? apiModelKeysUltraI2VPortrait : apiModelKeysUltraI2V;
        } else {
          mapping = isPortrait ? apiModelKeysUltraPortrait : apiModelKeysUltra;
        }
        break;
      case 'ai_pro':
        if (hasBothFrames) {
          mapping = isPortrait ? apiModelKeysProI2VFLPortrait : apiModelKeysProI2VFL;
        } else if (hasImages) {
          mapping = isPortrait ? apiModelKeysProI2VPortrait : apiModelKeysProI2V;
        } else {
          mapping = isPortrait ? apiModelKeysProPortrait : apiModelKeysPro;
        }
        break;
      default: // free
        if (hasBothFrames) {
          mapping = isPortrait ? apiModelKeysFreeI2VFLPortrait : apiModelKeysFreeI2VFL;
        } else if (hasImages) {
          mapping = isPortrait ? apiModelKeysFreeI2VPortrait : apiModelKeysFreeI2V;
        } else {
          mapping = isPortrait ? apiModelKeysFreePortrait : apiModelKeysFree;
        }
        break;
    }

    final defaultKey = (accountType == 'ai_ultra') ? 'veo_3_1_t2v_fast_ultra' : 'veo_3_1_t2v_fast';
    return mapping[displayName] ?? defaultKey;
  }

  // Account type options (Flow UI automation)
  static const Map<String, String> accountTypeOptions = {
    'Free Flow (100 credits)': 'free',
    'AI Pro (1,000 credits)': 'ai_pro',
    'AI Ultra (Infinite credits)': 'ai_ultra',
    'SuperGrok': 'supergrok',
    'RunwayML': 'runway',
  };

  // Aspect ratio options
  static const Map<String, String> aspectRatioOptions = {
    'Landscape (16:9)': 'VIDEO_ASPECT_RATIO_LANDSCAPE',
    'Portrait (9:16)': 'VIDEO_ASPECT_RATIO_PORTRAIT',
  };

  // Flow UI aspect ratio options (for UI automation)
  static const Map<String, String> flowAspectRatioOptions = {
    'Landscape (16:9)': 'Landscape (16:9)',
    'Portrait (9:16)': 'Portrait (9:16)',
  };

  // Status colors
  static const Map<String, int> statusColors = {
    'queued': 0xFF9E9E9E,
    'uploading': 0xFFFF9800,
    'generating': 0xFF2196F3,
    'polling': 0xFF00BCD4,
    'downloading': 0xFFFFC107,
    'completed': 0xFF4CAF50,
    'failed': 0xFFF44336,
  };
}
