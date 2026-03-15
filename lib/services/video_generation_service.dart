import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'profile_manager_service.dart';
import 'multi_profile_login_service.dart';
import 'mobile/mobile_browser_service.dart';
import 'settings_service.dart';
import 'playwright_browser_service.dart';
import '../models/scene_data.dart';
import '../models/poll_request.dart';
import '../utils/config.dart';
import '../utils/browser_utils.dart';
import '../utils/ffmpeg_utils.dart';
import 'foreground_service.dart';

/// Unified Video Generation Service
/// Following the same flow as BulkTaskExecutor with proper concurrent handling
class VideoGenerationService {
  static final VideoGenerationService _instance = VideoGenerationService._internal();
  factory VideoGenerationService() => _instance;
  VideoGenerationService._internal();

  ProfileManagerService? _profileManager;
  ProfileManagerService? get profileManager => _profileManager;
  MobileBrowserService? _mobileService;
  MultiProfileLoginService? _loginService;
  
  String _email = '';
  String _password = '';
  String _accountType = 'ai_ultra';
  String _projectFolder = ''; // Project folder for video downloads
  
  /// Set the project folder for video downloads
  void setProjectFolder(String folder) {
    _projectFolder = folder;
    print('[VideoGenerationService] Project folder set to: $folder');
  }
  
  /// Get the current project folder
  String get projectFolder => _projectFolder;
  
  /// Clear permanent failure status for a scene (allows manual retry)
  void clearPermanentFailure(int sceneId) {
    if (_permanentlyFailedSceneIds.contains(sceneId)) {
      _permanentlyFailedSceneIds.remove(sceneId);
      print('[VideoGenerationService] Cleared permanent failure for scene $sceneId - retry allowed');
    }
  }

  bool _isRunning = false;
  bool _isPaused = false;
  bool _generationComplete = false;
  
  // Queue and active tracking
  final List<SceneData> _queueToGenerate = [];
  final List<_ActiveVideo> _activeVideos = [];
  final Map<int, int> _videoRetryCounts = {};
  
  // Track active videos per account (for concurrency limiting)
  final Map<String, int> _activeVideosByAccount = {};
  
  // Track pending API calls (generation requests that haven't completed yet)
  int _pendingApiCalls = 0;
  
  // Track ongoing video downloads
  int _downloadingCount = 0;
  
  // Track scenes pending retry (waiting in 403/429 delay before re-queue)
  int _pendingRetries = 0;
  
  int _successCount = 0;
  int _failedCount = 0;
  int? _producerWaitCycles; // throttle producer "waiting" log spam
  
  final Random _random = Random();
  DateTime? _last429Time; // Global 429 time - deprecated, use per-profile tracking
  
  // PER-PROFILE 429 TRACKING - each profile has independent cooldown
  final Map<String, DateTime> _profile429Times = {}; // profileName -> cooldown end time
  
  int _requestsSinceRelogin = 0;
  bool _justReloggedIn = false;
  
  // Track profiles that completed login but are waiting for browser to be ready
  // Producer should NOT use these profiles until removed from this set
  final Set<String> _profilesWaitingForReady = {};
  
  // Track scenes that failed due to 403 (to retry after relogin)
  final List<SceneData> _403FailedScenes = [];
  
  // Track permanently failed scenes (UNSAFE content) - never retry these
  final Set<int> _permanentlyFailedSceneIds = {};
  
  // Auto-reconnect attempt counter for producer loop
  int? _autoConnectRetryCount;
  
  // Image upload concurrency limiter (max 5 concurrent, 10s delay between each)
  static const int _maxConcurrentUploads = 5;
  int _activeUploads = 0;
  final List<Completer<void>> _uploadWaiters = [];
  
  // Store interrupted polling videos for resume functionality
  final List<Map<String, dynamic>> _pendingPolls = [];
  
  /// Get pending polls count for UI
  int get pendingPollsCount => _pendingPolls.length;
  
  /// Check if there are pending polls to resume
  bool get hasPendingPolls => _pendingPolls.isNotEmpty;
  
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 120),
    sendTimeout: const Duration(seconds: 60),
  ));

  void _safeAdd(String msg) {
    try {
      if (!_statusController.isClosed) _statusController.add(msg);
    } catch (_) {}
  }
  
  /// Log message to both console and status stream
  /// Filters out recaptcha noise and reduces verbose logging
  void _log(String msg) {
    // Always print to console for debugging
    print(msg);
    
    // Filter messages for status stream (shown in UI logs viewer)
    final lowerMsg = msg.toLowerCase();
    
    // Skip recaptcha-related messages (very aggressive filtering)
    if (lowerMsg.contains('recaptcha') || 
        lowerMsg.contains('captcha') ||
        lowerMsg.contains('token obtained') ||
        lowerMsg.contains('fresh recaptcha') ||
        lowerMsg.contains('fetching fresh') ||
        (lowerMsg.contains('fresh') && lowerMsg.contains('token')) ||
        (lowerMsg.contains('fetching') && lowerMsg.contains('token')) ||
        (lowerMsg.contains('obtained') && lowerMsg.contains('token')) ||
        lowerMsg.contains('🔑') || // Key emoji used for token messages
        msg.contains('🔑') || // Check non-lowercase too
        (msg.contains('✅') && lowerMsg.contains('token')) || // Checkmark with token
        msg.contains('0cAFcWeA7QyZxr9AbZk3') || // Token samples
        msg.contains('0cAFcWeA')) { // Shorter token pattern
      return; // Don't add to UI stream
    }
    
    // Skip raw API response dumps
    if (lowerMsg.contains('api response:') || 
        lowerMsg.contains('"error"') && lowerMsg.contains('"code"') ||
        msg.startsWith('{') && msg.contains('"error"')) {
      return; // Don't show raw JSON responses
    }
    
    // Simplify retry messages
    if (lowerMsg.contains('retry')) {
      // Extract scene ID if present
      final sceneMatch = RegExp(r'scene (\d+)').firstMatch(msg);
      final sceneId = sceneMatch?.group(1) ?? '?';
      
      // Check if it's a retry attempt message
      if (lowerMsg.contains('attempt')) {
        final attemptMatch = RegExp(r'(\d+)/(\d+)').firstMatch(msg);
        if (attemptMatch != null) {
          _safeAdd('[RETRY] Scene $sceneId - Retrying (${attemptMatch.group(0)})...');
          return;
        }
      }
    }
    
    // Simplify generation scene assignment messages (e.g. "[GENERATE] 🎬 Scene 2001 -> dd")
    // but pass through upload, model, payload, and status messages
    if (msg.startsWith('[GENERATE]') && msg.contains('->') && !msg.contains('Model') && !msg.contains('Upload') && !msg.contains('Payload')) {
      final sceneMatch = RegExp(r'Scene (\d+)').firstMatch(msg);
      final profileMatch = RegExp(r'->\s*(.+)$').firstMatch(msg);
      if (sceneMatch != null && profileMatch != null) {
        _safeAdd('[GENERATE] Scene ${sceneMatch.group(1)} → ${profileMatch.group(1)?.trim()}');
        return;
      }
    }
    
    // Pass through all other messages
    _safeAdd(msg);
  }

  void initialize({
    ProfileManagerService? profileManager,
    MobileBrowserService? mobileService,
    MultiProfileLoginService? loginService,
    String? email,
    String? password,
    String accountType = 'ai_ultra',
  }) {
    _profileManager = profileManager;
    _mobileService = mobileService;
    _loginService = loginService;
    if (email != null) _email = email;
    if (password != null) _password = password;
    
    // CRITICAL FIX: Only update account type if it's the first initialization 
    // or if the new accountType is NOT the default 'ai_ultra'.
    // This prevents secondary tabs (SceneBuilder, etc.) from resetting the user's selection 
    // back to 'ai_ultra' when they call initialize() without a specific account type.
    if (_accountType == 'ai_ultra' || accountType != 'ai_ultra') {
      _accountType = accountType;
      print('[VideoGenerationService] 🔐 Initialized with Account Type: $_accountType');
    } else {
      print('[VideoGenerationService] ℹ️  Initialization skipped accountType reset. Keeping: $_accountType');
    }
  }
  
  /// Update account type (useful when user changes it in UI)
  void setAccountType(String accountType) {
    if (_accountType != accountType) {
      _accountType = accountType;
      print('[VideoGenerationService] 🔐 Account type UPDATED to: $accountType');
      _safeAdd('[INFO] Account type changed to: ${accountType.toUpperCase()}');
    }
  }

  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;

  /// Find a scene by ID in either the queue or active list
  SceneData? getScene(int sceneId) {
    // Check active
    for (var active in _activeVideos) {
      if (active.scene.sceneId == sceneId) return active.scene;
    }
    // Check queue
    for (var scene in _queueToGenerate) {
      if (scene.sceneId == sceneId) return scene;
    }
    return null;
  }

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  
  bool _stopRequested = false;  // New flag for stop
  
  void stop() {
    print('[VGEN] Stop requested - stopping generation immediately');
    
    // Set stop flag - this makes producer exit immediately
    _stopRequested = true;
    _generationComplete = true;
    
    // Clear queue to stop new generations
    _queueToGenerate.clear();
    print('[VGEN] Cleared generation queue');
    
    // Polling continues in background for active videos
    if (_activeVideos.isNotEmpty) {
      print('[VGEN] ⏳ ${_activeVideos.length} videos still polling in background');
    }
    
    _safeAdd('STOPPED');
  }
  
  /// Resume polling for interrupted videos
  Future<void> resumePolling() async {
    if (_pendingPolls.isEmpty) {
      print('[VGEN] No pending polls to resume');
      return;
    }
    
    if (_isRunning) {
      print('[VGEN] Cannot resume - generation already in progress');
      return;
    }
    
    print('[VGEN] Resuming polling for ${_pendingPolls.length} videos...');
    _isRunning = true;
    _generationComplete = true; // No new generation, just polling
    
    // Transfer pending polls to active videos
    for (final poll in _pendingPolls) {
      final scene = poll['scene'] as SceneData;
      final sceneUuid = poll['sceneUuid'] as String;
      final token = poll['accessToken'] as String;
      final port = poll['profileDebugPort'] as int;
      
      // Find or create profile connection
      dynamic profile;
      if (_profileManager != null) {
        profile = _profileManager!.profiles.firstWhere(
          (p) => p.debugPort == port,
          orElse: () => _profileManager!.profiles.isNotEmpty 
            ? _profileManager!.profiles.first 
            : throw Exception('No profiles available'),
        );
        
        // Refresh token if needed
        if (profile.accessToken != null) {
          _activeVideos.add(_ActiveVideo(
            scene: scene,
            sceneUuid: sceneUuid,
            profile: profile,
            accessToken: profile.accessToken!,
          ));
        } else {
          _activeVideos.add(_ActiveVideo(
            scene: scene,
            sceneUuid: sceneUuid,
            profile: profile,
            accessToken: token,
          ));
        }
      } else {
        // Use stored token
        _activeVideos.add(_ActiveVideo(
          scene: scene,
          sceneUuid: sceneUuid,
          profile: null,
          accessToken: token,
        ));
      }
    }
    
    _pendingPolls.clear();
    print('[VGEN] Loaded ${_activeVideos.length} videos for polling');
    _safeAdd('UPDATE');
    
    // Start polling
    try {
      await _runBatchPolling();
    } finally {
      _isRunning = false;
      _safeAdd('COMPLETED');
      print('[VGEN] Resume polling complete');
    }
  }
  
  /// Clear pending polls
  void clearPendingPolls() {
    _pendingPolls.clear();
    print('[VGEN] Cleared pending polls');
    _safeAdd('UPDATE');
  }

  Future<void> startBatch(List<SceneData> scenes, {
    required String model,
    required String aspectRatio,
    int? maxConcurrentOverride,
    bool use10xBoostMode = true,
    bool autoRetry = true, // Default to true (auto-retry on failure)
  }) async {
    // Allow concurrent batches - the queue system handles this properly
    // Don't check _isRunning - just add to queue and process
    
    if (!_isRunning) {
      _isRunning = true;
      _isPaused = false;
      _generationComplete = false;
    }
    
    // Don't clear these if a batch is already running - just add to them
    // _queueToGenerate.clear();
    // _activeVideos.clear();
    // _videoRetryCounts.clear();
    // _activeVideosByAccount.clear();
    // _successCount = 0;
    // _failedCount = 0;

    // Store the display name — getFullModelKey will resolve to correct API key per scene
    final displayName = model;
    
    // Quick check for relaxed status using display name
    final isRelaxedModel = displayName.toLowerCase().contains('lower priority') || displayName.toLowerCase().contains('relaxed');
    
    // Determine if this is an I2V batch (any scene has an image)
    final hasI2V = scenes.any((s) => 
      s.firstFramePath != null || s.lastFramePath != null || 
      s.firstFrameMediaId != null || s.lastFrameMediaId != null
    );
    
    // Concurrency strategy:
    // All models: unlimited concurrent per profile in 10x boost mode
    // On 429 error: 40s cooldown per profile, then resume
    final maxPollingPerProfile = use10xBoostMode ? 999 : 4;
    final maxConcurrentGeneration = !use10xBoostMode 
        ? 1  // Sequential when boost OFF
        : (maxConcurrentOverride ?? (hasI2V ? 4 : 999));  // Parallel when boost ON

    _log('${'=' * 60}');
    _log('[VGEN] 🚀 BATCH GENERATION STARTED');
    _log('[VGEN] 📊 Preparing ${scenes.length} scenes');
    _log('[VGEN] 🎬 Model: $displayName${isRelaxedModel ? " (Lower Priority)" : ""}');
    _log('[VGEN] ⚡ Mode: ${!use10xBoostMode ? "SEQUENTIAL (1 at a time)" : "BOOST (unlimited/profile)"}');
    _log('[VGEN] 🔄 Auto-Retry: $autoRetry');
    _log('${'=' * 60}');

    // Auto-connect browsers if needed (desktop only)
    if (!Platform.isAndroid && !Platform.isIOS) {
      await _autoConnectBrowsers();
    }

    await ForegroundServiceHelper.startService(status: 'Generating ${scenes.length} videos...');

    try {
      // CRITICAL: Clear any existing queue items to prevent duplicates
      _queueToGenerate.clear();
      
      // Initialize queue with all queued/failed scenes (excluding permanently failed, already processing, or duplicates)
      final scenesToProcess = scenes.where((s) => 
        // Only add queued or failed scenes
        (s.status == 'queued' || s.status == 'failed') &&
        // Skip permanently failed
        !_permanentlyFailedSceneIds.contains(s.sceneId) &&
        // Skip scenes already being polled (in _activeVideos)
        !_activeVideos.any((v) => v.scene.sceneId == s.sceneId)
      ).toList();
      
      // Configure scenes and reset retry counts
      for (var s in scenes) {
        // CRITICAL: Attach project folder to scene IF NOT SET so it doesn't get lost
        // if another batch starts with a different folder.
        if (_projectFolder.isNotEmpty && (s.targetFolder == null || s.targetFolder!.isEmpty)) {
          s.targetFolder = _projectFolder;
        }
      }

      for (var s in scenesToProcess) {
        s.autoRetry = autoRetry; // Set auto-retry based on batch setting
        _videoRetryCounts[s.sceneId] = 0; // RESET RETRY COUNT (Fix for manual retry)
        s.retryCount = 0; // Reset UI retry logic
      }
      
      _queueToGenerate.addAll(scenesToProcess);
      
      final skippedCount = scenes.length - scenesToProcess.length - scenes.where((s) => s.status == 'completed').length;
      final activeCount = _activeVideos.length;
      if (skippedCount > 0 || activeCount > 0) {
        if (activeCount > 0) {
          _log('[QUEUE] ⏭️ Skipped $activeCount scenes already being polled');
        }
        if (skippedCount > 0) {
          _log('[QUEUE] ⏭️ Skipped $skippedCount permanently failed/active scenes');
        }
      }
      
      _log('[QUEUE] 📝 Prepared ${_queueToGenerate.length} scenes');

      // Start polling in background (continues even after stop)
      _runBatchPolling(); // Not awaited - runs in background
      
      // Run generation — pass display name so _processScene can resolve the correct API model key
      await _runConcurrentGeneration(displayName, aspectRatio, maxPollingPerProfile, maxConcurrentGeneration, use10xBoostMode);

      // Only show complete message if not stopped
      if (!_stopRequested) {
        _log('');
        _log('${'=' * 60}');
        _log('[VGEN] ✅ BATCH COMPLETE');
        _log('[VGEN] 📊 Success: $_successCount | Failed: $_failedCount');
        _log('${'=' * 60}');
      } else {
        print('[VGEN] Generation stopped - polling continues in background for active videos');
      }
    } catch (e) {
      print('[VGEN] Batch failed: $e');
    } finally {
      print('[VGEN] Generation cleanup...');
      _isPaused = false;
      _generationComplete = true;
      
      // CRITICAL: Only clear queue if it's truly empty — don't wipe scenes
      // that were re-queued by download-retry (small file size) logic.
      if (_queueToGenerate.isNotEmpty) {
        print('[VGEN] ⚠️ Queue has ${_queueToGenerate.length} items after generation loop — keeping for polling to process.');
      } else {
        // Only fully cleanup if no active polling
        if (_activeVideos.isEmpty) {
          _isRunning = false;
          _activeVideosByAccount.clear();
          await ForegroundServiceHelper.stopService();
          _safeAdd('COMPLETED');
          print('[VGEN] All done - ready for next batch');
        } else {
          // Polling continues in background
          print('[VGEN] ${_activeVideos.length} videos still being polled in background');
          _safeAdd('POLLING_BACKGROUND');
        }
      }
      
      // Reset stop flag for next batch
      _stopRequested = false;
    }
  }

  /// Concurrent generation worker (PRODUCER)
  /// maxPollingPerProfile = how many videos can be in polling/active state per profile (always 4)
  /// maxConcurrentGeneration = how many generation requests to fire (1 = sequential, >1 = parallel)
  Future<void> _runConcurrentGeneration(String model, String aspectRatio, int maxPollingPerProfile, int maxConcurrentGeneration, bool use10xBoostMode) async {
    final isSequential = maxConcurrentGeneration == 1;
    
    print('\n[PRODUCER] Generation started');
    print('[PRODUCER] Mode: ${isSequential ? "SEQUENTIAL (await each)" : "PARALLEL ($maxConcurrentGeneration at a time)"}');
    print('[PRODUCER] Max polling per profile: $maxPollingPerProfile');

    while (_isRunning && !_stopRequested) {
      // Handle pause
      while (_isPaused && _isRunning && !_stopRequested) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_isRunning || _stopRequested) {
        print('[PRODUCER] Stop requested - exiting generation loop immediately');
        break;
      }

      // Wait for more scenes if queue is empty but active polling/downloads may re-queue
      if (_queueToGenerate.isEmpty) {
        // If nothing is active either, we're truly done
        if (_activeVideos.isEmpty && _pendingApiCalls <= 0 && _downloadingCount <= 0 && _pendingRetries <= 0) {
          print('[PRODUCER] Queue empty, no active polling, no downloads, no pending retries - exiting');
          break;
        }
        // Otherwise wait for download/retry to re-add scenes
        // Only log every 10 cycles (~30s) to avoid spam
        _producerWaitCycles = (_producerWaitCycles ?? 0) + 1;
        if (_producerWaitCycles! % 10 == 1) {
          print('[PRODUCER] ⏳ Queue empty but ${_activeVideos.length} active polls / $_pendingApiCalls pending / $_downloadingCount downloads / $_pendingRetries retries - waiting...');
        }
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }
      _producerWaitCycles = 0; // reset when queue is not empty

      // Get next available profile (automatically skips profiles in 429 cooldown)
      final profile = _getNextProfile();
      if (profile == null) {
        // Check if profiles are in 429 cooldown
        if (_profile429Times.isNotEmpty) {
          final now = DateTime.now();
          final cooldownsStr = _profile429Times.entries
              .where((e) => now.isBefore(e.value))
              .map((e) => '${e.key}(${e.value.difference(now).inSeconds}s)')
              .join(', ');
          if (cooldownsStr.isNotEmpty) {
            print('[PRODUCER] ⏸️ All profiles in 429 cooldown: $cooldownsStr - waiting 3s...');
            await Future.delayed(const Duration(seconds: 3));
            continue;
          }
        }
        
        // If no profiles are available, check if some are relogging or waiting for browser ready
        bool anyRelogging = _profileManager?.getProfilesByStatus(ProfileStatus.relogging).isNotEmpty ?? false;
        bool anyWaitingForReady = _profilesWaitingForReady.isNotEmpty;
        
        if (anyRelogging || anyWaitingForReady) {
          if (anyWaitingForReady) {
            print('[PRODUCER] ⏳ Profiles waiting for browser to be ready: ${_profilesWaitingForReady.join(", ")} - waiting...');
          } else {
            print('[PRODUCER] Profiles are relogging, waiting...');
          }
          await Future.delayed(const Duration(seconds: 3));
        } else {
          // No profiles available and nothing relogging — try auto-reconnect
          _autoConnectRetryCount = (_autoConnectRetryCount ?? 0) + 1;
          print('[PRODUCER] No available profiles (attempt $_autoConnectRetryCount), trying auto-connect...');
          
          // Every 5th attempt (~10s), try to reconnect browsers
          if (_autoConnectRetryCount! % 5 == 1) {
            await _autoConnectBrowsers();
          }
          await Future.delayed(const Duration(seconds: 2));
        }
        continue;
      }
      
      // Get profile identifier for tracking
      final profileKey = profile.name ?? profile.email ?? 'default';
      
      // Check if this profile has room for more active videos
      final activeForProfile = _activeVideosByAccount[profileKey] ?? 0;
      if (activeForProfile >= maxPollingPerProfile) {
        // This profile is at max, wait and try again
        print('[PRODUCER] Profile "$profileKey" at max ($activeForProfile/$maxPollingPerProfile), waiting...');
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      
      // CRITICAL: Check if profile has valid token before using it
      final token = profile.accessToken as String?;
      if (token == null || token.isEmpty) {
        print('[PRODUCER] Profile ${profile.name} has no token yet (relogin in progress), waiting...');
        await Future.delayed(const Duration(seconds: 3));
        continue;
      }
      
      // CRITICAL: Throttle requests after relogin
      if (_justReloggedIn) {
        if (_requestsSinceRelogin >= 4) {
          print('[PRODUCER] ⏸️  Sent 4 requests after relogin - waiting 10s before continuing...');
          await Future.delayed(const Duration(seconds: 10));
          _justReloggedIn = false;
          _requestsSinceRelogin = 0;
          print('[PRODUCER] ▶️  Resuming normal generation flow');
        }
      }

      // Get next scene from queue
      if (_queueToGenerate.isEmpty) {
        // We might have yielded in an await. Go back to top to check properly.
        continue;
      }
      final scene = _queueToGenerate.removeAt(0);
      
      // CRITICAL: Skip scenes that are already being processed/polled/completed
      if (scene.status == 'polling' || scene.status == 'generating' || 
          scene.status == 'completed' || scene.status == 'downloading') {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - already ${scene.status}');
        _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1; // Don't count slot
        continue;
      }
      
      // Skip scenes that are in activeVideos (race condition protection)
      if (_activeVideos.any((v) => v.scene.sceneId == scene.sceneId)) {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - already in active polling');
        _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
        continue;
      }
      
      // CRITICAL: Skip scenes that are permanently failed (UNSAFE content)
      if (_permanentlyFailedSceneIds.contains(scene.sceneId)) {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - permanently failed (UNSAFE)');
        continue;
      }
      
      // Also skip scenes already marked as failed status
      if (scene.status == 'failed' && scene.error?.contains('Unsafe') == true) {
        print('[PRODUCER] ⏭️ Skipping scene ${scene.sceneId} - already marked as failed (UNSAFE)');
        _permanentlyFailedSceneIds.add(scene.sceneId); // Add to set for future reference
        continue;
      }
      
      // Increment profile counter
      _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 0) + 1;
      print('[PRODUCER] Profile "$profileKey" active: ${_activeVideosByAccount[profileKey]}/$maxPollingPerProfile');
      
      // Increment pending API calls counter
      _pendingApiCalls++;
      print('[PRODUCER] Pending API calls: $_pendingApiCalls');
      
      if (isSequential) {
        // SEQUENTIAL MODE (Boost OFF): Await each generation before starting next
        print('[PRODUCER] SEQUENTIAL: Generating scene ${scene.sceneId}...');
        try {
          await _startSingleGeneration(scene, profile, model, aspectRatio, profileKey, use10xBoostMode);
          _pendingApiCalls--;
          print('[PRODUCER] Generation complete. Active polling: ${_activeVideosByAccount[profileKey]}/$maxPollingPerProfile');
        } catch (e) {
          _pendingApiCalls--;
          print('[PRODUCER] Generation failed: $e');
        }
        
        // Small delay between generations
        await Future.delayed(const Duration(seconds: 2));
      } else {
        // PARALLEL MODE (Boost ON): Fire and forget
        _startSingleGeneration(scene, profile, model, aspectRatio, profileKey, use10xBoostMode).then((_) {
          _pendingApiCalls--;
          print('[PRODUCER] API call completed. Pending: $_pendingApiCalls');
        }).catchError((e) {
          _pendingApiCalls--;
          print('[PRODUCER] API call failed: $e. Pending: $_pendingApiCalls');
        });
        
        // Increment relogin request counter if in post-relogin mode
        if (_justReloggedIn) {
          _requestsSinceRelogin++;
          print('[PRODUCER] Post-relogin requests: $_requestsSinceRelogin/4');
        }

        // Delay between API requests
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    _generationComplete = true;
    print('[PRODUCER] All scenes processed');
  }

  /// Sequential generation for Normal Mode - 100% reliable, slower
  Future<void> _runSequentialGeneration(String model, String aspectRatio) async {
    print('\n[NORMAL MODE] Sequential generation started');
    print('[NORMAL MODE] Processing scenes one by one - 100% reliable');

    final accountEmail = _email.isNotEmpty ? _email : 'default';

    while (_isRunning && _queueToGenerate.isNotEmpty) {
      // Handle pause
      while (_isPaused && _isRunning) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_isRunning) {
        print('[NORMAL MODE] Stop requested');
        break;
      }

      // Get next scene
      final scene = _queueToGenerate.removeAt(0);
      
      // Get profile
      final profile = _getNextProfile();
      if (profile == null || profile.accessToken == null) {
        print('[NORMAL MODE] No valid profile available, requeueing scene');
        _queueToGenerate.insert(0, scene); // Put back at front
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }

      print('[NORMAL MODE] 🎬 Starting Scene ${scene.sceneId} (${_queueToGenerate.length} remaining)');
      
      // CRITICAL: Wait for this scene to FULLY complete before moving to next
      try {
        await _startSingleGeneration(scene, profile, model, aspectRatio, accountEmail, false);
        print('[NORMALMODE] ✅ Scene ${scene.sceneId} completed successfully');
      } catch (e) {
        print('[NORMAL MODE] ❌ Scene ${scene.sceneId} failed: $e');
      }
      
      // Wait 3 seconds between videos for extra reliability
      print('[NORMAL MODE] ⏸️  Waiting 3s before next video...');
      await Future.delayed(const Duration(seconds: 3));
    }

    _generationComplete = true;
    print('[NORMAL MODE] All scenes processed');
  }

  /// Start generating a single video
  Future<void> _startSingleGeneration(
    SceneData scene,
    dynamic profile,
    String model,
    String aspectRatio,
    String accountEmail,
    bool use10xBoostMode,
  ) async {
    _log('[GENERATE] 🎬 Scene ${scene.sceneId} -> ${profile.name}');

    // Check retry limit (increased to 7 for better resilience)
    final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
    if (retryCount >= 7) {
      _log('[GENERATE] ❌ Scene ${scene.sceneId} exceeded max retries (7)');
      scene.status = 'failed';
      scene.error = 'Max retries exceeded';
      _failedCount++;
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
      _safeAdd('UPDATE');
      return;
    }

    try {
      scene.status = 'generating';
      scene.error = null;
      _safeAdd('UPDATE');

      // Ensure token is available (auto-navigate to Flow URL if needed)
      final tokenAvailable = await _ensureTokenAvailable(profile);
      if (!tokenAvailable) {
        throw Exception('Unable to obtain access token. Please check browser session.');
      }

      final token = profile.accessToken as String;
      // Token is guaranteed to exist at this point due to _ensureTokenAvailable check

      // Handle both DesktopGenerator (CDP) and MobileVideoGenerator (embedded)
      final generator = profile.generator; // Don't cast - use dynamic
      if (generator == null) throw Exception('No generator');
      
      // Check connection for DesktopGenerator (includes health monitoring for AMD Ryzen stability)
      if (generator is DesktopGenerator) {
        // Check connection health and auto-reconnect if needed (AMD Ryzen stability)
        if (!generator.isConnected || !generator.isHealthy) {
          _log('[GENERATE] ⚠️ Connection unhealthy, auto-reconnecting...');
          try {
            await generator.ensureConnected();
            _log('[GENERATE] ✅ Reconnected successfully');
          } catch (e) {
            throw Exception('Desktop browser connection failed: $e');
          }
        }
      } else if (generator is! MobileVideoGenerator) {
        // If it's not Desktop or Mobile, it's unknown
        throw Exception('Unknown generator type');
      }
      // Note: For MobileVideoGenerator, if we got the generator from profile, it's already ready

      // Upload images if needed (throttled, retry 3x with 15s wait)
      if (scene.firstFramePath != null && scene.firstFrameMediaId == null) {
        await _acquireUploadSlot();
        try {
          for (int uploadAttempt = 1; uploadAttempt <= 3; uploadAttempt++) {
            _log('[GENERATE] 📤 Uploading first frame for scene ${scene.sceneId} (attempt $uploadAttempt/3)...');
            scene.firstFrameMediaId = await _uploadImageHTTP(scene.firstFramePath!, token);
            if (scene.firstFrameMediaId != null) {
              _log('[GENERATE] ✅ First frame uploaded for scene ${scene.sceneId}');
              break;
            }
            if (uploadAttempt < 3) {
              _log('[GENERATE] ⚠️ First frame upload failed for scene ${scene.sceneId} — waiting 15s before retry...');
              await Future.delayed(const Duration(seconds: 15));
            }
          }
          if (scene.firstFrameMediaId == null) {
            throw Exception('First frame image upload failed after 3 attempts — not generating without image');
          }
        } finally {
          _releaseUploadSlot();
        }
      }
      if (scene.lastFramePath != null && scene.lastFrameMediaId == null) {
        await _acquireUploadSlot();
        try {
          for (int uploadAttempt = 1; uploadAttempt <= 3; uploadAttempt++) {
            _log('[GENERATE] 📤 Uploading last frame for scene ${scene.sceneId} (attempt $uploadAttempt/3)...');
            scene.lastFrameMediaId = await _uploadImageHTTP(scene.lastFramePath!, token);
            if (scene.lastFrameMediaId != null) {
              _log('[GENERATE] ✅ Last frame uploaded for scene ${scene.sceneId}');
              break;
            }
            if (uploadAttempt < 3) {
              _log('[GENERATE] ⚠️ Last frame upload failed for scene ${scene.sceneId} — waiting 15s before retry...');
              await Future.delayed(const Duration(seconds: 15));
            }
          }
          if (scene.lastFrameMediaId == null) {
            throw Exception('Last frame image upload failed after 3 attempts — not generating without image');
          }
        } finally {
          _releaseUploadSlot();
        }
      }

      // Get fresh reCAPTCHA token for this scene (never reuse tokens!)
      String? recaptchaToken;
      // _log('[GENERATE] 🔑 Fetching fresh reCAPTCHA token for scene ${scene.sceneId}...');
      
      if (use10xBoostMode) {
        // Boost Mode: Fail fast if token missing
        recaptchaToken = await generator.getRecaptchaToken();
      } else {
        // Normal Mode: Retry loop for reCAPTCHA failure (max 5 attempts, 10s interval)
        int recaptchaRetryCount = 0;
        const int maxRecaptchaRetries = 5;
        
        while (recaptchaToken == null && _isRunning && recaptchaRetryCount < maxRecaptchaRetries) {
          try {
            recaptchaToken = await generator.getRecaptchaToken();
          } catch (e) {
            print('[NORMAL MODE] Recaptcha attempt failed: $e');
          }
          
          if (recaptchaToken == null) {
            recaptchaRetryCount++;
            _log('[NORMAL MODE] ⚠️ Recaptcha fetch failed (attempt $recaptchaRetryCount/$maxRecaptchaRetries). Waiting 10s...');
            // Wait 10 seconds before retry
            await Future.delayed(const Duration(seconds: 10));
            _log('[NORMAL MODE] 🔄 Retrying reCAPTCHA...');
          }
        }
        
        // If stopped while waiting or max retries exceeded
        if (recaptchaToken == null && !_isRunning) return;
        if (recaptchaToken == null) {
          _log('[NORMAL MODE] ❌ reCAPTCHA failed after $maxRecaptchaRetries attempts');
        }
      }
      
      if (recaptchaToken == null) throw Exception('Failed to get reCAPTCHA token');
      // _log('[GENERATE] ✅ Fresh reCAPTCHA token obtained (${recaptchaToken.substring(0, 20)}...)');

      // Resolve the exact API model key using hardcoded maps — no string manipulation
      // 'model' here is the display name (e.g. 'Veo 3.1 - Fast [Lower Priority]')
      final hasFirstFrame = scene.firstFrameMediaId != null;
      final hasLastFrame = scene.lastFrameMediaId != null;
      final sceneAspectRatio = scene.aspectRatio ?? aspectRatio;
      final isPortrait = sceneAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT';
      
      final actualModel = AppConfig.getFullModelKey(
        displayName: model,
        accountType: _accountType,
        hasFirstFrame: hasFirstFrame,
        hasLastFrame: hasLastFrame,
        isPortrait: isPortrait,
      );
      
      _log('[GENERATE] 🎬 Model key resolved: $actualModel (display: $model, account: $_accountType, portrait: $isPortrait, firstFrame: $hasFirstFrame, lastFrame: $hasLastFrame)');

      // Use fallback prompt for I2V if no prompt provided
      String promptToUse = scene.prompt;
      if ((promptToUse.isEmpty || promptToUse.trim().isEmpty) && (hasFirstFrame || hasLastFrame)) {
        promptToUse = 'Animate this';
        _log('[GENERATE] Using fallback prompt for I2V: "$promptToUse"');
      }

      // Generate video via browser fetch
      final result = await generator.generateVideo(
        prompt: promptToUse,
        accessToken: token,
        aspectRatio: sceneAspectRatio,
        model: actualModel,
        startImageMediaId: scene.firstFrameMediaId,
        endImageMediaId: scene.lastFrameMediaId,
        recaptchaToken: recaptchaToken,
        accountType: _accountType,
      );

      // Note: Full response logged to console only (not shown in UI logs)

      // Check for 403 error (including reCAPTCHA errors as they are often session-related)
      final errorStr = result?['error']?.toString().toLowerCase() ?? '';
      if (result != null && (result['error']?.toString().contains('403') == true || 
          result['data']?['error']?['code'] == 403 ||
          errorStr.contains('recaptcha'))) {
        _handle403Error(scene, profile, accountEmail);
        return;
      }

      // Check for 429 error (quota exhausted)
      if (result != null && (result['error']?.toString().contains('429') == true ||
          result['error']?.toString().contains('exhausted') == true)) {
        final profileName = profile?.name ?? 'unknown';
        _handle429Error(scene, accountEmail, profileName: profileName);
        return;
      }

      if (result == null || result['success'] != true) {
        throw Exception(result?['error'] ?? 'Generation failed');
      }

      // Extract operation name
      final data = result['data'] as Map<String, dynamic>;
      final operations = data['operations'] as List?;
      if (operations == null || operations.isEmpty) {
        throw Exception('No operations in response');
      }

      final operation = operations[0] as Map<String, dynamic>;
      final opData = operation['operation'] as Map<String, dynamic>?;
      final operationName = opData?['name'] as String?;
      if (operationName == null) {
        throw Exception('No operation name in response');
      }

      scene.operationName = operationName;
      scene.status = 'polling';
      _safeAdd('UPDATE');

      // Reset 403 counter and refresh flag on success
      try { 
        profile.consecutive403Count = 0; 
        profile.browserRefreshedThisSession = false; // Allow refresh in future error cycles
      } catch (_) {}

      // Add to active videos for batch polling
      final sceneUuid = operation['sceneId']?.toString() ?? operationName;
      _activeVideos.add(_ActiveVideo(
        scene: scene,
        sceneUuid: sceneUuid,
        profile: profile,
        accessToken: token,
      ));

      _log('[GENERATE] ✅ Scene ${scene.sceneId} queued for polling');

    } catch (e) {
      _log('[GENERATE] ❌ Scene ${scene.sceneId} error: $e');
      
      // Increment retry counter
      _videoRetryCounts[scene.sceneId] = (_videoRetryCounts[scene.sceneId] ?? 0) + 1;
      final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
      
      // If within retry limit AND autoRetry is enabled, re-queue at front for instant retry
      if (scene.autoRetry && retryCount < 7) {
        scene.status = 'queued';
        scene.error = null;
        scene.retryCount = retryCount; // Sync UI counter
        _queueToGenerate.insert(0, scene); // Insert at front for priority
        _log('[RETRY] 🔄 Scene ${scene.sceneId} re-queued at FRONT (retry $retryCount/7)');
      } else {
        // Max retries exceeded or auto-retry disabled, mark as failed
        scene.status = 'failed';
        if (!scene.autoRetry) {
             scene.error = 'Failed: ${e.toString()} (Auto-retry disabled)';
        } else {
             scene.error = 'Failed after $retryCount attempts: ${e.toString()}';
        }
        _failedCount++;
        _log('[RETRY] ❌ Scene ${scene.sceneId} failed permanently (no retry)');
      }
      
      _safeAdd('UPDATE');
      
      // Decrement account counter on failure
      _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    }
  }

  /// Handle 403 or reCAPTCHA error: increment counter, trigger relogin, re-queue scene
  void _handle403Error(SceneData scene, dynamic profile, String accountEmail) async {
    // Decrement account counter
    _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
    
    // Track that a retry is pending (prevents producer from exiting during 5s delay)
    _pendingRetries++;
    
    // Increment retry counter
    _videoRetryCounts[scene.sceneId] = (_videoRetryCounts[scene.sceneId] ?? 0) + 1;
    
    // Increment 403 counter for this profile
    try {
      profile.consecutive403Count = (profile.consecutive403Count ?? 0) + 1;
      _log('[403] ⚠️ ${profile.name} 403 count: ${profile.consecutive403Count}/5 | Scene retry ${_videoRetryCounts[scene.sceneId]}/7');
    } catch (_) {}

    // Wait 5 seconds before retry to avoid spam
    _log('[403] ⏳ Waiting 5s before retry...');
    await Future.delayed(const Duration(seconds: 5));

    // Check if scene is already in queue or active to prevent duplicates
    final alreadyInQueue = _queueToGenerate.any((s) => s.sceneId == scene.sceneId);
    final alreadyActive = _activeVideos.any((v) => v.scene.sceneId == scene.sceneId);
    
    if (alreadyInQueue || alreadyActive) {
      _log('[403] ⚠️ Scene ${scene.sceneId} already ${alreadyInQueue ? "in queue" : "active"} - skipping re-queue');
      _pendingRetries--;
      return;
    }

    // Check if auto-retry is enabled
    if (!scene.autoRetry) {
      scene.status = 'failed';
      scene.error = 'Failed: 403 Forbidden (Auto-retry disabled)';
      _failedCount++;
      _pendingRetries--; // Not retrying, clear pending
      _log('[403] ❌ Scene ${scene.sceneId} failed (no auto-retry)');
      _safeAdd('UPDATE');
      return;
    }

    // Re-queue scene at FRONT for immediate retry with another profile
    scene.status = 'queued';
    scene.error = null;
    scene.retryCount = (_videoRetryCounts[scene.sceneId] ?? 0); // Sync UI counter
    _queueToGenerate.insert(0, scene); // Insert at front for priority
    _pendingRetries--; // Re-queued, no longer pending
    _log('[403] 🔄 Scene ${scene.sceneId} re-queued at FRONT for retry');
    _safeAdd('UPDATE');

    // Updated 403 strategy: refresh browser after 5 consecutive 403 errors
  try {
    if (profile.consecutive403Count >= 5) {
      bool alreadyRefreshed = false;
      try { alreadyRefreshed = profile.browserRefreshedThisSession ?? false; } catch (_) {}
      
      if (!alreadyRefreshed) {
        _log('[403] 🔄 ${profile.name} hit 5 consecutive 403s - refreshing browser...');
        try {
          final generator = profile.generator;
          if (generator != null && generator.isConnected) {
            // Use event-based navigation instead of JS reload + fixed delay
            await generator.navigateAndWait('https://labs.google/fx/tools/flow');
            await generator.waitForNetworkIdle(timeoutSeconds: 8);
            
            try { 
              profile.browserRefreshedThisSession = true; 
              profile.consecutive403Count = 0;
            } catch (_) {}
            _log('[403] ✅ ${profile.name} browser refreshed and counter reset.');
          }
        } catch (e) {
          _log('[403] ⚠️ Browser refresh failed for ${profile.name}: $e');
        }
      } else {
        _log('[403] ⚠️ ${profile.name} already refreshed - skipping additional refresh to avoid loop');
      }
    }
  } catch (e) {
    _log('[403] ❌ Error handling 403: $e');
  }

    // Add to retry tracking (if not already tracked)
    if (!_403FailedScenes.any((s) => s.sceneId == scene.sceneId)) {
      _403FailedScenes.add(scene);
      _log('[403] 🔄 Scene ${scene.sceneId} added to 403 retry tracking');
    }
  }
  
  /// Handle 429 rate limit error: wait 50s, mark profile for cooldown and requeue at front
Future<void> _handle429Error(SceneData scene, String accountEmail, {String? profileName}) async {
  _log('[429] ⚠️ Rate limit hit for scene ${scene.sceneId}');
  
  // Increment retry counter
  _videoRetryCounts[scene.sceneId] = (_videoRetryCounts[scene.sceneId] ?? 0) + 1;
  
  // Mark THIS PROFILE for 40s cooldown (not all profiles!)
  if (profileName != null && profileName.isNotEmpty) {
    final cooldownEnd = DateTime.now().add(const Duration(seconds: 40));
    _profile429Times[profileName] = cooldownEnd;
    _log('[429] ⏸️ Profile $profileName in cooldown for 40s (other profiles continue)');
  }
  
  // Also set global time for backward compatibility
  _last429Time = DateTime.now();
  
  // Decrement account counter
  _activeVideosByAccount[accountEmail] = (_activeVideosByAccount[accountEmail] ?? 1) - 1;
  
  // Check if auto-retry is enabled
  if (!scene.autoRetry) {
    scene.status = 'failed';
    scene.error = 'Failed: 429 Limit Exceeded (Auto-retry disabled)';
    _failedCount++; // Count as failure
    _pendingRetries--;
    _log('[429] ❌ Scene ${scene.sceneId} failed (no auto-retry)');
    _safeAdd('UPDATE');
    return;
  }

  // Show queued status with simple error message
  scene.status = 'queued';
  scene.error = '429 limit exceed';
  _safeAdd('UPDATE');
  
  // Wait 40 seconds then resume
  _log('[429] ⏳ Waiting 40s before retry...');
  await Future.delayed(const Duration(seconds: 40));
  
  // Check if stop was requested during wait
  if (_stopRequested) {
    _queueToGenerate.insert(0, scene);
    _pendingRetries--;
    _safeAdd('UPDATE');
    return;
  }
  
  // Clear error and re-queue for retry
  scene.error = null;
  _queueToGenerate.insert(0, scene); // Put at front for immediate retry
  _pendingRetries--;
  _log('[429] 🔄 Scene ${scene.sceneId} re-queued at FRONT for retry');
  _safeAdd('UPDATE');
}

  /// Convert raw API error codes into short human-readable phrases for the scene card
  String _friendlyErrorMessage(String? rawError) {
    if (rawError == null || rawError.isEmpty) return '';
    if (rawError.contains('MINOR_UPLOAD') || rawError.contains('IP_INPUT_IMAGE')) {
      return 'Image rejected by Google content policy';
    }
    if (rawError.contains('UNSAFE_GENERATION') || rawError.contains('unsafe')) {
      return 'Unsafe prompt/image';
    }
    if (rawError.contains('HIGH_TRAFFIC')) return 'Server busy — will retry';
    if (rawError.contains('429') || rawError.contains('exhausted')) return 'Rate limit hit';
    if (rawError.contains('403')) return 'Session expired';
    if (rawError.contains('INVALID_ARGUMENT')) return 'Invalid image format';
    // Trim to 60 chars max for very long raw errors
    final trimmed = rawError.replaceAll(RegExp(r'\{.*?\}'), '').trim();
    return trimmed.length > 60 ? '${trimmed.substring(0, 60)}...' : trimmed;
  }

  /// Batch polling worker (CONSUMER)
  Future<void> _runBatchPolling() async {
    print('\n[POLLER] Batch polling started');
    final Set<int> downloadingScenes = {};
    int emptyLoopCount = 0;

    // Continue polling as long as there are active videos, downloads, queued items, OR pending API calls
    // The poller should keep running until ALL work is truly done
    while (true) {
      final hasActiveWork = _activeVideos.isNotEmpty || downloadingScenes.isNotEmpty;
      final hasQueuedWork = _queueToGenerate.isNotEmpty;
      final hasPendingCalls = _pendingApiCalls > 0;
      final hasPendingRetries = _pendingRetries > 0;
      
      if (!hasActiveWork && !hasQueuedWork && !hasPendingCalls && !hasPendingRetries) {
        // No active work, no queued work, and no pending API calls
        if (_generationComplete) {
          // Wait a bit to catch any videos that are being added asynchronously
          emptyLoopCount++;
          if (emptyLoopCount >= 3) {
            print('[POLLER] No work for 3 cycles and generation complete - exiting');
            break;
          }
          print('[POLLER] Waiting for potential async additions... ($emptyLoopCount/3)');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        // Producer still running, wait for work
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      
      // Reset empty loop counter when we have work
      emptyLoopCount = 0;
      
      // If we have pending API calls but no active videos yet, wait
      if (_activeVideos.isEmpty && hasPendingCalls) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      
      // If we have active videos to poll, do the polling
      if (_activeVideos.isEmpty) {
        // No active videos yet, but queue has items - wait for producer
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }
      
      // CRITICAL: Pause polling if any profile is relogging
      // This prevents browser from becoming unresponsive during login
      bool anyRelogging = _profileManager?.getProfilesByStatus(ProfileStatus.relogging).isNotEmpty ?? false;
      if (anyRelogging) {
        print('[POLLER] ⏸️  Profile is relogging - pausing polling to avoid browser freeze...');
        await Future.delayed(const Duration(seconds: 5));
        continue; // Skip this poll cycle, check again after 5s
      }
      
      // Check if profiles have valid tokens before polling
      // This ensures we don't poll with expired/empty tokens
      bool allProfilesHaveTokens = true;
      for (final activeVideo in _activeVideos) {
        final token = activeVideo.accessToken;
        if (token == null || token.isEmpty) {
          allProfilesHaveTokens = false;
          print('[POLLER] ⏸️  Active video has no token - waiting for relogin to complete...');
          break;
        }
      }
      
      if (!allProfilesHaveTokens) {
        await Future.delayed(const Duration(seconds: 3));
        continue; // Skip this poll cycle
      }

      // 10s interval to reduce browser load
      print('[POLLER] Waiting 10s before batch poll...');
      await Future.delayed(const Duration(seconds: 10));

      await _pollAndUpdateActiveBatch(downloadingScenes);
    }

    // Poller finished - cleanup
    print('[POLLER] All videos polled and downloaded');
    _isRunning = false;
    _activeVideos.clear();
    _activeVideosByAccount.clear();
    await ForegroundServiceHelper.stopService();
    _safeAdd('COMPLETED');
  }

  /// Poll all active videos in a single batch and update statuses
  Future<void> _pollAndUpdateActiveBatch(Set<int> downloadingScenes) async {
    if (_activeVideos.isEmpty) return;

    print('\n[BATCH POLL] Polling ${_activeVideos.length} videos...');

    // Group by token for batch polling
    final Map<String, List<_ActiveVideo>> groups = {};
    for (final v in _activeVideos) {
      groups.putIfAbsent(v.accessToken, () => []).add(v);
    }

    // ── CHUNK SIZE: Poll max 10 videos at a time to avoid CDP timeouts ──
    const int chunkSize = 10;

    for (final entry in groups.entries) {
      final token = entry.key;
      final groupVideos = entry.value;
      
      // Split this group into sub-batches of chunkSize
      for (int chunkStart = 0; chunkStart < groupVideos.length; chunkStart += chunkSize) {
        final chunkEnd = (chunkStart + chunkSize).clamp(0, groupVideos.length);
        final chunk = groupVideos.sublist(chunkStart, chunkEnd);
        
        print('[BATCH POLL] Checking chunk ${chunkStart ~/ chunkSize + 1} (${chunk.length} videos, ${chunkStart + 1}-$chunkEnd of ${groupVideos.length})...');

      // Build poll requests
      final requests = chunk
          .map((v) => PollRequest(v.scene.operationName!, v.sceneUuid))
          .toList();

      try {
        List<Map<String, dynamic>>? results;
        
        // Use browser-based polling if available and connected
        final profile = chunk.first.profile;
        final generator = profile?.generator;
        final isProfileRelogging = profile?.status == ProfileStatus.relogging || 
                                   profile?.status == MobileProfileStatus.loading;
        
        if (isProfileRelogging) {
          print('[BATCH POLL] Skipping poll - profile is currently relogging');
          continue; // skip sending API request with invalid token
        } else if (generator != null && generator.isConnected) {
          print('[BATCH POLL] Using browser polling for ${chunk.length} videos');
          try {
            results = await generator.pollVideoStatusBatchHTTP(requests, token);
          } catch (browserErr) {
            // CDP timeout or browser error - fall back to direct HTTP poll
            print('[BATCH POLL] ⚠️ Browser poll failed (${browserErr.toString().split("\n").first}) - falling back to HTTP polling');
            try {
              results = await _pollVideoStatusBatchHTTP(requests, token);
            } catch (httpErr) {
              print('[BATCH POLL] ❌ HTTP fallback also failed: $httpErr');
            }
          }
        } else {
          final reason = !generator?.isConnected == true ? 'browser not connected' : 'no generator';
          print('[BATCH POLL] Using HTTP polling ($reason) for ${chunk.length} videos');
          results = await _pollVideoStatusBatchHTTP(requests, token);
        }

        if (results == null) {
          print('[BATCH POLL] No results from batch poll (chunk ${chunkStart ~/ chunkSize + 1})');
          continue;
        }

        // Process results
        for (var i = 0; i < results.length && i < chunk.length; i++) {
          final opData = results[i];
          final activeVideo = chunk[i];
          final scene = activeVideo.scene;

          // Get status from various possible locations
          String? status = opData['status']?.toString();
          if (status == null && opData['operation'] != null) {
            final metadata = opData['operation']['metadata'] as Map<String, dynamic>?;
            status = metadata?['status']?.toString();
          }
          
          _log('[POLL] 🔎 Scene ${scene.sceneId}: ${status ?? "IN_PROGRESS"}');

          if (status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL' ||
              (status?.toUpperCase().contains('SUCCESS') == true)) {
            
            // CRITICAL: Release slot using the correct profile key
            final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
            _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
            _activeVideos.remove(activeVideo);
            print('[POLL] ✅ Scene ${scene.sceneId} success - Profile "$profileKey" active: ${_activeVideosByAccount[profileKey]}');
            
            // CRITICAL: Remove from 403 retry list so it won't be re-queued after relogin
            _403FailedScenes.removeWhere((s) => s.sceneId == scene.sceneId);
            
            // Extract video URL and mediaId for upscaling
            String? videoUrl;
            String? mediaId;
            if (opData['operation'] != null) {
              final operation = opData['operation'] as Map<String, dynamic>?;
              final metadata = operation?['metadata'] as Map<String, dynamic>?;
              final video = metadata?['video'] as Map<String, dynamic>?;
              videoUrl = video?['fifeUrl'] ?? video?['uri'];
              
              // The mediaGenerationId is only available in successful responses
              // Try multiple locations:
              // 1. Top-level mediaGenerationId from opData
              mediaId = opData['mediaGenerationId'] as String?;
              
              // 2. Nested in video metadata
              if (mediaId == null || mediaId.isEmpty) {
                mediaId = video?['mediaGenerationId'] as String?;
              }
              
              // 3. Fallback to operation name (for pending/in-progress)
              if (mediaId == null || mediaId.isEmpty) {
                mediaId = operation?['name'] as String?;
              }
              
              // 4. Last fallback: use the operationName we already saved
              if (mediaId == null && scene.operationName != null) {
                mediaId = scene.operationName;
                print('[BATCH POLL] Scene ${scene.sceneId} using existing operationName as mediaId');
              }
              
              // Save mediaId for upscaling
              if (mediaId != null && mediaId.isNotEmpty) {
                scene.videoMediaId = mediaId;
                print('[BATCH POLL] Scene ${scene.sceneId} mediaId saved: ${mediaId.substring(0, min(50, mediaId.length))}...');
              } else {
                print('[BATCH POLL] Scene ${scene.sceneId} WARNING: No mediaId found in response');
              }
            }

            if (videoUrl != null) {
              _log('[POLL] ✅ Scene ${scene.sceneId} completed - starting download');
              downloadingScenes.add(scene.sceneId);
              _downloadVideo(scene, videoUrl, downloadingScenes);
            }
          } else if (status?.toUpperCase().contains('FAIL') == true) {
            // Extract error message from response
            String? errorMessage;
            try {
              // Try to get error from various locations in the response
              if (opData['operation'] != null) {
                final operation = opData['operation'] as Map<String, dynamic>?;
                final metadata = operation?['metadata'] as Map<String, dynamic>?;
                errorMessage = metadata?['error']?.toString() ?? 
                              metadata?['errorMessage']?.toString() ??
                              operation?['error']?.toString();
              }
              if (errorMessage == null && opData['error'] != null) {
                errorMessage = opData['error'].toString();
              }
            } catch (_) {}
            
            // Log the full response for debugging
            print('[BATCH POLL] Scene ${scene.sceneId} FAILED - Full response: $opData');
            if (errorMessage != null) {
              print('[BATCH POLL] Error message: $errorMessage');
            }
            
            // Check retry count before marking as failed
            final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
            
            // Special handling for HIGH_TRAFFIC
            final isHighTraffic = errorMessage?.contains('HIGH_TRAFFIC') == true || 
                                errorMessage?.contains('high traffic') == true;
            
            // UNSAFE_GENERATION - Mark as permanently failed (no retry - same prompt will always fail)
            final isUnsafeGeneration = errorMessage?.contains('UNSAFE_GENERATION') == true ||
                                       errorMessage?.contains('unsafe') == true;
            
            if (isUnsafeGeneration) {
              _log('[POLL] 🚫 Scene ${scene.sceneId} UNSAFE content - marking as permanently failed');
              scene.status = 'failed';
              scene.error = '🚫 Unsafe content detected — image will not be accepted. Change your image.';
              _failedCount++;
              _activeVideos.remove(activeVideo);
              _permanentlyFailedSceneIds.add(scene.sceneId);
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              _safeAdd('UPDATE');
              continue;
            }
            
            // MINOR / CHILD CONTENT in uploaded image — permanently failed, no retry
            final isMinorContent = errorMessage?.contains('PUBLIC_ERROR_MINOR_UPLOAD') == true ||
                                   errorMessage?.contains('MINOR_UPLOAD') == true;

            // IMAGE CONTENT POLICY violation (explicit / sensitive) — permanently failed, no retry
            final isImagePolicy = errorMessage?.contains('PUBLIC_ERROR_IP_INPUT_IMAGE') == true ||
                                  errorMessage?.contains('IP_INPUT_IMAGE') == true;

            if (isMinorContent) {
              _log('[POLL] 🔞 Scene ${scene.sceneId} MINOR content in image - permanently failed');
              scene.status = 'failed';
              scene.error = '⚠️ IMAGE REJECTED — Minor/Child Content Detected\n'
                  'Google\'s policy blocks images that may contain minors.\n'
                  'Do NOT upload images of: children, girls, women or any person under 18.\n'
                  'Please replace the image with a safe alternative.';
              _failedCount++;
              _activeVideos.remove(activeVideo);
              _permanentlyFailedSceneIds.add(scene.sceneId);
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              _safeAdd('UPDATE');
              continue;
            }

            if (isImagePolicy) {
              _log('[POLL] 🛑 Scene ${scene.sceneId} image violates content policy - permanently failed');
              scene.status = 'failed';
              scene.error = '⚠️ IMAGE REJECTED — Copyright / IP Violation\n'
                  'Google blocks copyrighted / trademarked characters.\n'
                  'Do NOT upload: Spider-Man, Hulk, Superman, Batman, Iron Man,\n'
                  'or any Marvel, DC, Disney, or other IP-protected characters.\n'
                  'Use original characters or royalty-free images only.';
              _failedCount++;
              _activeVideos.remove(activeVideo);
              _permanentlyFailedSceneIds.add(scene.sceneId);
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              _safeAdd('UPDATE');
              continue;
            }
            
            if (isHighTraffic) {
               print('[BATCH POLL] 🚦 High Traffic detected - triggering 30s cooldown...');
               _last429Time = DateTime.now(); // Triggers 30s wait in producer
            }
            
            final maxRetries = isHighTraffic ? 20 : 5; // Allow more retries for capacity issues

            if (scene.autoRetry && retryCount < maxRetries) {
              // Retry the failed video
              _videoRetryCounts[scene.sceneId] = retryCount + 1;
              scene.retryCount = retryCount + 1; // Sync to scene object for UI
              
              scene.status = 'queued';
              // Show a clean retry status (not raw server error code)
              final cleanErr = _friendlyErrorMessage(errorMessage);
              scene.error = '↻ Retrying (${retryCount + 1}/$maxRetries)${cleanErr.isNotEmpty ? " — $cleanErr" : ""}';
              
              // 5-second delay before retrying
              _pendingRetries++;
              Future.delayed(const Duration(seconds: 5), () {
                 _queueToGenerate.insert(0, scene); // Re-queue at front for immediate retry
                 _pendingRetries--;
              });
              
              _activeVideos.remove(activeVideo);
              
              // Decrement counter using correct profile key
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              
              _safeAdd('UPDATE');
              _log('[POLL] ⚠️ Scene ${scene.sceneId} failed - waiting 5s before retry (${retryCount + 1}/$maxRetries)');
            } else {
              // Max retries exceeded OR auto-retry disabled
              scene.status = 'failed';
              if (!scene.autoRetry) {
                 scene.error = _friendlyErrorMessage(errorMessage) + ' (Auto-retry disabled)';
              } else {
                 scene.error = '❌ Failed after $maxRetries retries. ${_friendlyErrorMessage(errorMessage)}';
              }
              _failedCount++;
              _activeVideos.remove(activeVideo);
              
              // Decrement counter using correct profile key
              final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
              _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
              
              _safeAdd('UPDATE');
              _log('[POLL] ❌ Scene ${scene.sceneId} failed permanently after $maxRetries retries');
            }
          }
        }
      } catch (e) {
        print('[BATCH POLL] Error polling chunk: $e');
      }
      
      // Small pause between chunks to avoid overwhelming CDP
      if (chunkStart + chunkSize < groupVideos.length) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      } // end chunk loop
    } // end groups loop
  }

  /// Download a video file with size check and retry logic
  Future<void> _downloadVideo(
    SceneData scene,
    String videoUrl,
    Set<int> downloadingScenes,
  ) async {
    _downloadingCount++;
    try {
      _log('[DOWNLOAD] 📥 Scene ${scene.sceneId} downloading...');
      scene.status = 'downloading';
      _safeAdd('UPDATE');

      final outputPath = await _getOutputPath(scene);
      
      // First attempt
      var response = await _dio.get(videoUrl, options: Options(responseType: ResponseType.bytes));
      var bytes = response.data as List<int>;
      
      // Check for small file size (potential black/incomplete video)
      if (bytes.length < 511488) {
        _log('[DOWNLOAD] ⚠️ Scene ${scene.sceneId} file too small (${(bytes.length / 1024).toStringAsFixed(1)} KB) - waiting 30s before retry...');
        await Future.delayed(const Duration(seconds: 30));
        
        // Retry download
        _log('[DOWNLOAD] 🔄 Retrying download for Scene ${scene.sceneId}...');
        response = await _dio.get(videoUrl, options: Options(responseType: ResponseType.bytes));
        bytes = response.data as List<int>;
        
        // If still small, fail and trigger regeneration
        if (bytes.length < 511488) {
           _log('[DOWNLOAD] ❌ Scene ${scene.sceneId} file still too small (${(bytes.length / 1024).toStringAsFixed(1)} KB) after retry - triggering regeneration');
           
           // Use standard retry logic if allowed
           final retryCount = _videoRetryCounts[scene.sceneId] ?? 0;
           final maxRetries = 5;
           
           if (scene.autoRetry && retryCount < maxRetries) {
               _videoRetryCounts[scene.sceneId] = retryCount + 1;
               scene.retryCount = retryCount + 1;
               scene.status = 'queued';
               scene.error = 'Download failed (incomplete video file < 499KB) - retrying (${retryCount + 1}/$maxRetries)';
               _queueToGenerate.insert(0, scene); // Re-queue at front
               
               // Decrement active count for the profile
               // Find the active video object to get the profile key
               final activeVideo = _activeVideos.firstWhere((v) => v.scene.sceneId == scene.sceneId, orElse: () => _ActiveVideo(scene: scene, sceneUuid: '', accessToken: '', profile: null));
               if (activeVideo.accessToken.isNotEmpty) {
                    _activeVideos.remove(activeVideo);
                    final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
                    _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
               }
               
               _safeAdd('UPDATE');
               downloadingScenes.remove(scene.sceneId);
               return;
           } else {
               throw Exception('Video file incomplete (<1MB) after retry');
           }
        }
      }

      if (response.statusCode == 200) {
        final file = File(outputPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);

        scene.videoPath = outputPath;
        scene.downloadUrl = videoUrl;
        scene.fileSize = bytes.length;
        scene.generatedAt = DateTime.now().toIso8601String();
        scene.status = 'completed';
        scene.error = null; // Clear any previous error
        _successCount++;
        _safeAdd('UPDATE');

        _log('[DOWNLOAD] ✅ Scene ${scene.sceneId} complete (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)');
        
        // Clean up from active list if present (it should have been active during polling)
        final activeVideoIdx = _activeVideos.indexWhere((v) => v.scene.sceneId == scene.sceneId);
        if (activeVideoIdx != -1) {
            final activeVideo = _activeVideos[activeVideoIdx];
            _activeVideos.removeAt(activeVideoIdx);
            final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
            _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
        }
        
      } else {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      // Remove from downloading set
      downloadingScenes.remove(scene.sceneId);
      
    } catch (e) {
      _log('[DOWNLOAD] ❌ Scene ${scene.sceneId} error: $e');
      scene.status = 'failed';
      scene.error = 'Download failed: $e';
      _failedCount++;
      _safeAdd('UPDATE');
      
      // Ensure we clean up active count on failure too
      final activeVideoIdx = _activeVideos.indexWhere((v) => v.scene.sceneId == scene.sceneId);
      if (activeVideoIdx != -1) {
          final activeVideo = _activeVideos[activeVideoIdx];
          _activeVideos.removeAt(activeVideoIdx);
          final profileKey = activeVideo.profile?.name ?? activeVideo.profile?.email ?? 'default';
          _activeVideosByAccount[profileKey] = (_activeVideosByAccount[profileKey] ?? 1) - 1;
      }

      downloadingScenes.remove(scene.sceneId);
    } finally {
      _downloadingCount--;
    }
  }

  /// Get next available profile (skips profiles in 429 cooldown and waiting for browser ready)
  dynamic _getNextProfile() {
    dynamic profile;
    if (Platform.isAndroid || Platform.isIOS) {
      profile = _mobileService?.getNextAvailableProfile();
    } else {
      profile = _profileManager?.getNextAvailableProfile();
    }
    
    // Check if this profile is waiting for browser to be ready after relogin
    if (profile != null) {
      final profileName = profile.name ?? 'unknown';
      
      // CRITICAL: Skip profiles that are still waiting for browser to fully load
      if (_profilesWaitingForReady.contains(profileName)) {
        print('[PROFILE] ⏳ Profile $profileName waiting for browser to be ready - skipping');
        return null; // Don't use this profile yet
      }
      
      // Check if this profile is in 429 cooldown
      final cooldownEnd = _profile429Times[profileName];
      
      if (cooldownEnd != null) {
        final now = DateTime.now();
        if (now.isBefore(cooldownEnd)) {
          final remaining = cooldownEnd.difference(now).inSeconds;
          print('[PROFILE] ⏸️ Profile $profileName in 429 cooldown ($remaining s remaining)');
          return null; // Don't use this profile yet
        } else {
          // Cooldown expired, clear it
          _profile429Times.remove(profileName);
          print('[PROFILE] ✅ Profile $profileName cooldown expired, ready to use');
        }
      }
    }
    
    return profile;
  }

  /// Auto-connect to browsers on startup if not connected
  Future<void> _autoConnectBrowsers() async {
    if (_profileManager == null) {
      print('[AUTO-CONNECT] No profile manager available');
      return;
    }

    // Count already fully connected (with tokens)
    final fullyConnected = _profileManager!.profiles.where((p) =>
      p.accessToken != null && p.accessToken!.isNotEmpty &&
      p.generator != null && p.generator is DesktopGenerator && (p.generator as DesktopGenerator).isConnected
    ).length;

    // If at least 1 browser is already connected with a token, do NOT reconnect
    // This prevents disconnecting working browsers when Start is clicked
    if (fullyConnected > 0) {
      _log('[AUTO-CONNECT] ✅ $fullyConnected browser(s) already connected — skipping auto-connect');
      return;
    }

    // No browsers connected — try to connect
    // Get desired browser count from settings
    final settings = SettingsService.instance;
    await settings.reload();
    final browserProfiles = settings.getBrowserProfiles();
    final desiredCount = browserProfiles.isNotEmpty ? browserProfiles.length : _profileManager!.profiles.length;

    _log('[AUTO-CONNECT] 🔗 No connected browsers — attempting to connect $desiredCount...');

    try {
      // Initialize profiles if needed (creates profile objects based on desired count)
      if (_profileManager!.profiles.isEmpty) {
        await _profileManager!.initializeProfiles(desiredCount);
      }

      // Try connecting to running Chrome instances on debug ports
      final connectedCount = await _profileManager!.connectToOpenProfiles(desiredCount);
      
      // After connecting CDP, try to fetch tokens on each connected profile
      for (final profile in _profileManager!.profiles) {
        if (profile.generator != null && (profile.accessToken == null || profile.accessToken!.isEmpty)) {
          try {
            final token = await profile.generator!.getAccessToken()
                .timeout(const Duration(seconds: 8));
            if (token != null && token.isNotEmpty) {
              profile.accessToken = token;
              profile.status = ProfileStatus.connected;
              _log('[AUTO-CONNECT] ✅ Token obtained for ${profile.name}');
            }
          } catch (_) {
            // Token not available — user may need to log in
          }
        }
      }

      final nowConnected = _profileManager!.profiles.where((p) =>
        p.accessToken != null && p.accessToken!.isNotEmpty
      ).length;

      if (nowConnected > 0) {
        _log('[AUTO-CONNECT] ✅ $nowConnected browser(s) ready with tokens');
      } else if (connectedCount > 0) {
        _log('[AUTO-CONNECT] ⚠️ $connectedCount browser(s) connected via CDP but no tokens — manual login may be needed');
      } else {
        _log('[AUTO-CONNECT] ⚠️ No browsers found on ports ${_profileManager!.baseDebugPort}-${_profileManager!.baseDebugPort + desiredCount - 1}. Launch browsers first.');
      }
    } catch (e) {
      _log('[AUTO-CONNECT] ⚠️ Auto-connect failed: $e');
    }
  }


  /// Ensure profile has a valid access token, navigate to Flow URL if needed
  Future<bool> _ensureTokenAvailable(dynamic profile) async {
    if (profile == null) return false;
    
    // Check if token already exists
    final token = profile.accessToken as String?;
    if (token != null && token.isNotEmpty) {
      return true; // Token already available
    }

    _log('[TOKEN] ⚠️ No access token found for profile ${profile.name}');
    
    // Only try auto-navigation for desktop generators
    final generator = profile.generator;
    if (generator == null || generator is! DesktopGenerator) {
      _log('[TOKEN] ❌ Cannot auto-navigate (not a desktop browser)');
      return false;
    }

    if (!generator.isConnected) {
      _log('[TOKEN] ❌ Browser not connected');
      return false;
    }

    try {
      _log('[TOKEN] 🔄 Navigating to Flow URL to fetch token...');
      
      // Navigate to Flow URL using JavaScript
      const flowUrl = 'https://labs.google/fx/tools/flow';
      await generator.executeJs('window.location.href = "$flowUrl"');
      
      // Wait for page to load
      _log('[TOKEN] ⏳ Waiting for page to load (5 seconds)...');
      await Future.delayed(const Duration(seconds: 5));
      
      // Try to fetch token again using the correct method
      _log('[TOKEN] 🔑 Attempting to fetch access token...');
      final newToken = await generator.getAccessToken();
      
      if (newToken != null && newToken.isNotEmpty) {
        profile.accessToken = newToken;
        _log('[TOKEN] ✅ Access token obtained successfully');
        return true;
      } else {
        _log('[TOKEN] ❌ Failed to fetch token after navigation');
        _safeAdd('[ERROR] Flow URL is not opened or session expired. Please open Flow manually and login.');
        return false;
      }
    } catch (e) {
      _log('[TOKEN] ❌ Error during token fetch: $e');
      _safeAdd('[ERROR] Failed to fetch token: $e. Please check browser session.');
      return false;
    }
  }

  Future<String> _getOutputPath(SceneData scene) async {
    // Use scene's own target folder if set, otherwise fallback to global, then v_output
    final String basePath;
    final String folder = scene.targetFolder ?? _projectFolder;
    if (folder.isNotEmpty) {
      // Use project folder with 'videos' subfolder
      basePath = path.join(folder, 'videos');
    } else {
      // Fallback to default v_output folder
      basePath = path.join(Directory.current.path, 'v_output');
    }
    
    final dir = Directory(basePath);
    if (!await dir.exists()) await dir.create(recursive: true);
    return path.join(dir.path, 'scene_${scene.sceneId.toString().padLeft(4, '0')}.mp4');
  }

  /// Acquire an upload slot (max 5 concurrent). Blocks until a slot is free.
  Future<void> _acquireUploadSlot() async {
    if (_activeUploads < _maxConcurrentUploads) {
      _activeUploads++;
      return;
    }
    // Wait for a slot to free up
    final completer = Completer<void>();
    _uploadWaiters.add(completer);
    _log('[UPLOAD] ⏳ Upload slot full ($_activeUploads/$_maxConcurrentUploads) — waiting...');
    await completer.future;
    _activeUploads++;
  }

  /// Release an upload slot and wake up the next waiter.
  void _releaseUploadSlot() {
    _activeUploads--;
    if (_uploadWaiters.isNotEmpty) {
      final next = _uploadWaiters.removeAt(0);
      if (!next.isCompleted) next.complete();
    }
  }

  /// Compress image to JPEG under 200KB locally using FFmpeg.
  /// Preserves original resolution, only reduces file size.
  /// Uses JPEG because Google's uploadUserImage API rejects WebP.
  Future<Map<String, dynamic>> _compressToWebP(Uint8List originalBytes, String filename) async {
    final originalSizeKB = originalBytes.length / 1024;
    
    // If already under 200KB, just base64 it as-is
    if (originalSizeKB <= 200) {
      final mime = filename.toLowerCase().endsWith('.png') ? 'image/png' 
          : filename.toLowerCase().endsWith('.webp') ? 'image/webp' 
          : 'image/jpeg';
      _log('[UPLOAD] 🖼️ ${filename}: ${originalSizeKB.toStringAsFixed(1)}KB (under 200KB, no conversion needed)');
      return {'b64': base64Encode(originalBytes), 'mime': mime};
    }
    
    // Use FFmpeg to compress to JPEG locally
    try {
      final ffmpegPath = await FFmpegUtils.getFFmpegPath();
      
      // Write original to temp file
      final tempDir = await Directory.systemTemp.createTemp('img_compress_');
      final inputPath = path.join(tempDir.path, filename);
      final outputPath = path.join(tempDir.path, 'compressed.jpg');
      await File(inputPath).writeAsBytes(originalBytes);
      
      // Try iterative quality reduction: 85 → 70 → 55 → 40 → 25
      for (final quality in [85, 70, 55, 40, 25]) {
        // Delete previous output if exists
        final outFile = File(outputPath);
        if (await outFile.exists()) await outFile.delete();
        
        final result = await Process.run(ffmpegPath, [
          '-y', '-i', inputPath,
          '-q:v', '${((100 - quality) * 31 / 100).round().clamp(1, 31)}', // FFmpeg JPEG quality: 1=best, 31=worst
          '-vframes', '1',
          outputPath,
        ], runInShell: true);
        
        if (result.exitCode == 0 && await File(outputPath).exists()) {
          final jpgBytes = await File(outputPath).readAsBytes();
          final jpgSizeKB = jpgBytes.length / 1024;
          
          if (jpgSizeKB <= 200) {
            _log('[UPLOAD] 🖼️ ${filename}: ${originalSizeKB.toStringAsFixed(0)}KB → ${jpgSizeKB.toStringAsFixed(0)}KB JPEG (q=${quality}%)');
            
            // Cleanup temp files
            try { await tempDir.delete(recursive: true); } catch (_) {}
            
            return {'b64': base64Encode(jpgBytes), 'mime': 'image/jpeg'};
          }
          
          _log('[UPLOAD] 🖼️ ${filename}: JPEG q=${quality}% = ${jpgSizeKB.toStringAsFixed(0)}KB (> 200KB, trying lower)');
        }
      }
      
      // Even lowest quality didn't reach 200KB — use the last result anyway (still smaller than original)
      if (await File(outputPath).exists()) {
        final jpgBytes = await File(outputPath).readAsBytes();
        final jpgSizeKB = jpgBytes.length / 1024;
        _log('[UPLOAD] ⚠️ ${filename}: Best JPEG = ${jpgSizeKB.toStringAsFixed(0)}KB (could not reach 200KB, using anyway)');
        try { await tempDir.delete(recursive: true); } catch (_) {}
        return {'b64': base64Encode(jpgBytes), 'mime': 'image/jpeg'};
      }
      
      // Cleanup on failure
      try { await tempDir.delete(recursive: true); } catch (_) {}
      _log('[UPLOAD] ⚠️ ${filename}: FFmpeg compression failed — uploading original');
    } catch (e) {
      _log('[UPLOAD] ⚠️ FFmpeg compression error: $e — uploading original');
    }
    
    // Fallback: upload original
    _log('[UPLOAD] 🖼️ ${filename}: uploading original ${originalSizeKB.toStringAsFixed(0)}KB');
    final mime = filename.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    return {'b64': base64Encode(originalBytes), 'mime': mime};
  }

  /// Direct HTTP upload with FFmpeg compression
  Future<String?> _uploadImageHTTP(String imagePath, String accessToken) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        _log('[UPLOAD] ❌ File not found: $imagePath');
        return null;
      }
      
      final originalBytes = await file.readAsBytes();
      final filename = imagePath.split(Platform.pathSeparator).last;
      
      // Compress via FFmpeg if > 200KB
      final compressed = await _compressToWebP(Uint8List.fromList(originalBytes), filename);
      final b64 = compressed['b64'] as String;
      final mime = compressed['mime'] as String;
      
      final payload = jsonEncode({
        'imageInput': {
          'rawImageBytes': b64, 
          'mimeType': mime, 
          'isUserUploaded': true,
          'aspectRatio': 'IMAGE_ASPECT_RATIO_LANDSCAPE'
        },
        'clientContext': {
          'sessionId': ';${DateTime.now().millisecondsSinceEpoch}', 
          'tool': 'ASSET_MANAGER'
        }
      });

      final res = await _dio.post('https://aisandbox-pa.googleapis.com/v1:uploadUserImage', 
        data: payload,
        options: Options(
          headers: {'Authorization': 'Bearer $accessToken', 'Content-Type': 'text/plain;charset=UTF-8'},
          sendTimeout: const Duration(seconds: 120),
          receiveTimeout: const Duration(seconds: 120),
          validateStatus: (status) => true,
        ));

      if (res.statusCode == 200) {
        final data = res.data is String ? jsonDecode(res.data) : res.data;
        final mediaId = data['mediaGenerationId']?['mediaGenerationId'] ?? data['mediaId'];
        _log('[UPLOAD] ✅ $filename uploaded → $mediaId');
        // 10s delay between uploads to avoid rate limits
        await Future.delayed(const Duration(seconds: 10));
        return mediaId;
      } else {
        final errBody = res.data?.toString() ?? '';
        _log('[UPLOAD] ❌ HTTP ${res.statusCode}: ${errBody.length > 200 ? errBody.substring(0, 200) : errBody}');
      }
    } catch (e) {
      _log('[UPLOAD] ❌ Upload error: $e');
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> _pollVideoStatusBatchHTTP(List<PollRequest> requests, String accessToken) async {
    if (requests.isEmpty) return [];
    try {
      final payload = {
        'operations': requests.map((r) => {'operation': {'name': r.operationName}, 'status': 'MEDIA_GENERATION_STATUS_ACTIVE'}).toList()
      };

      final response = await _dio.post('https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus',
        data: jsonEncode(payload),
        options: Options(headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $accessToken'}));

      if (response.statusCode == 200) {
        final data = response.data is String ? jsonDecode(response.data) : response.data;
        if (data['operations'] != null) {
          return List<Map<String, dynamic>>.from(data['operations']);
        }
      }
    } catch (e) {
      if (e.toString().contains('DioException [bad response]')) {
         print('[HTTP POLL] HTTP Error: ${e.toString().split('\n').first}');
      } else {
         print('[HTTP POLL] Error: $e');
      }
    }
    return null;
  }

  /// Call when a profile is about to start relogin - marks it as waiting for browser ready
  void onProfileStartingRelogin(String profileName) {
    if (profileName.isEmpty) return;
    _profilesWaitingForReady.add(profileName);
    print('[Relogin] Profile $profileName marked as waiting for browser ready');
  }
  
  /// Call when browser is fully ready after relogin - allows profile to be used for generation
  void markProfileReady(String profileName) {
    if (profileName.isEmpty) return;
    _profilesWaitingForReady.remove(profileName);
    print('[Relogin] Profile $profileName browser is ready - generation allowed');
  }

  void onProfileRelogin(dynamic profile, String newAccessToken) {
    if (newAccessToken.isEmpty) return;
    
    final profileName = profile?.name ?? profile?.email ?? 'unknown';
    
    // Mark that we just relogged in - will throttle next requests
    _justReloggedIn = true;
    _requestsSinceRelogin = 0;
    print('[Relogin] Relogin completed - will send 4 requests, then wait 10s');
    
    // CRITICAL: Add profile to waiting list - will be removed when browser is fully ready
    _profilesWaitingForReady.add(profileName);
    print('[Relogin] Profile $profileName added to waiting list until browser is ready');
    
    print('[Relogin] Updating active videos with new token...');
    for (final v in _activeVideos) {
      try {
        if (v.profile == profile) v.accessToken = newAccessToken;
      } catch (_) {}
    }
    
    // Re-queue all 403-failed scenes with fresh retry counters
    if (_403FailedScenes.isNotEmpty) {
      print('[Relogin] Re-queueing ${_403FailedScenes.length} scenes that failed due to 403...');
      
      for (final scene in List.from(_403FailedScenes)) { // Make a copy to iterate
        // CRITICAL: Skip scenes that are already completed
        if (scene.status == 'completed' || scene.status == 'downloading') {
          print('[Relogin] Scene ${scene.sceneId} already ${scene.status} - skipping re-queue');
          _403FailedScenes.remove(scene);
          continue;
        }
        
        // Skip scenes already in queue
        if (_queueToGenerate.any((s) => s.sceneId == scene.sceneId)) {
          print('[Relogin] Scene ${scene.sceneId} already in queue - skipping re-queue');
          _403FailedScenes.remove(scene);
          continue;
        }
        
        // Skip scenes currently being polled (active videos)
        if (_activeVideos.any((v) => v.scene.sceneId == scene.sceneId)) {
          print('[Relogin] Scene ${scene.sceneId} currently active/polling - skipping re-queue');
          _403FailedScenes.remove(scene);
          continue;
        }
        
        // Reset retry counter to give fresh attempts with new token
        _videoRetryCounts[scene.sceneId] = 0;
        
        // Re-queue at front for immediate retry
        scene.status = 'queued';
        scene.error = null;
        _queueToGenerate.insert(0, scene);
        
        print('[Relogin] Scene ${scene.sceneId} re-queued (fresh retry counter: 0/5)');
      }
      
      _403FailedScenes.clear();
      _safeAdd('UPDATE');
    }
  }
}

class _ActiveVideo {
  final SceneData scene;
  final String sceneUuid;
  final dynamic profile;
  String accessToken;

  _ActiveVideo({
    required this.scene,
    required this.sceneUuid,
    required this.profile,
    required this.accessToken,
  });
}

/// Desktop Generator — uses Playwright server for browser control, HTTP for API calls
/// NO direct CDP from Dart. All browser interactions go through the Python Playwright server.
class DesktopGenerator {
  final int debugPort;
  
  // ══════════════════════════════════════════════════════════════
  // Playwright-based browser control (NO direct CDP)
  // All browser interactions go through the Playwright Python server
  // which handles CDP smoothly in a separate process.
  // ══════════════════════════════════════════════════════════════

  DesktopGenerator({this.debugPort = 9222});
  
  bool _connected = false;

  /// Connect — just verify Playwright server has this browser, or connect to it
  Future<void> connect() async {
    await Future.delayed(Duration.zero); // Yield to UI
    
    final pw = PlaywrightBrowserService();
    await pw.ensureRunning();
    
    // Try to connect Playwright to this browser port
    final result = await pw.connectBrowser(port: debugPort);
    _connected = result['success'] == true || result['already_connected'] == true;
    
    if (_connected) {
      print('[Desktop] Connected via Playwright server on port $debugPort');
    } else {
      // If Playwright can't connect, the browser might not be running yet
      // That's OK — launchBrowser handles this
      print('[Desktop] Playwright connect pending for port $debugPort');
      _connected = true; // Mark as "connected" — Playwright will handle it
    }
  }

  void close() { 
    _connected = false;
  }

  bool get isConnected => _connected;
  bool get isHealthy => _connected;
  
  /// Ensure connection is available
  Future<void> ensureConnected() async {
    if (!_connected) {
      await connect();
    }
  }
  
  /// Navigate to URL via Playwright (smooth, event-based, no CDP from Dart)
  Future<void> navigateAndWait(String url, {int timeoutSeconds = 30}) async {
    final pw = PlaywrightBrowserService();
    await pw.navigate(port: debugPort, url: url);
  }
  
  /// Wait for network idle via Playwright
  Future<void> waitForNetworkIdle({int timeoutSeconds = 15, int idleMs = 500}) async {
    // Playwright's goto already waits for networkidle
    // Just add a small delay for any remaining async activity
    await Future.delayed(const Duration(seconds: 1));
  }
  
  /// Wait for a CSS selector — delegated to Playwright
  Future<bool> waitForSelector(String selector, {int timeoutSeconds = 15}) async {
    // Playwright handles this via its own waitForSelector
    // For now, we rely on Playwright's login flow which handles all selectors
    await Future.delayed(const Duration(seconds: 2));
    return true;
  }
  
  /// Wait for URL pattern — delegated to Playwright
  Future<bool> waitForUrl(String pattern, {int timeoutSeconds = 20}) async {
    // Playwright handles this via its own waitForURL
    await Future.delayed(const Duration(seconds: 2));
    return true;
  }

  /// Get access token via Playwright server (no CDP)
  Future<String?> getAccessToken() async {
    final pw = PlaywrightBrowserService();
    return await pw.getAccessToken(port: debugPort);
  }

  /// Get reCAPTCHA token via Playwright server (no CDP) — for VIDEO generation
  Future<String?> getRecaptchaToken() async {
    final pw = PlaywrightBrowserService();
    return await pw.getRecaptchaToken(port: debugPort);
  }
  
  /// Get reCAPTCHA token for IMAGE generation via Playwright server
  Future<String?> getImageRecaptchaToken() async {
    final pw = PlaywrightBrowserService();
    return await pw.getImageRecaptchaToken(port: debugPort);
  }
  
  /// Execute JavaScript in the browser via Playwright server
  /// This replaces direct CDP Runtime.evaluate calls.
  Future<dynamic> executeJs(String expression) async {
    final pw = PlaywrightBrowserService();
    return await pw.executeJs(port: debugPort, expression: expression);
  }

  Future<String> getCurrentUrl() async {
    try {
      final result = await executeJs('window.location.href');
      return result is String ? result : '';
    } catch (_) {
      return '';
    }
  }

  // For compatibility
  Future<void> prefetchRecaptchaTokens([int count = 1]) async {}
  String? getNextPrefetchedToken() => null;
  void clearPrefetchedTokens() {}

  Future<dynamic> uploadImage(String path, String token, {String? aspectRatio}) async {
    final imageAspectRatio = aspectRatio ?? 'IMAGE_ASPECT_RATIO_LANDSCAPE';
    
    // Read image bytes
    final bytes = await File(path).readAsBytes();
    final originalSizeKB = bytes.length / 1024;
    
    String b64;
    String mime;
    
    // Convert to WebP via browser Canvas (keeps resolution, reduces file size)
    if (isConnected) {
      try {
        final rawB64 = base64Encode(bytes);
        final rawMime = path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
        
        final webpResult = await executeJs('''
          (async () => {
            try {
              const img = new Image();
              const blob = await fetch("data:$rawMime;base64,$rawB64").then(r => r.blob());
              const url = URL.createObjectURL(blob);
              await new Promise((resolve, reject) => {
                img.onload = resolve;
                img.onerror = reject;
                img.src = url;
              });
              URL.revokeObjectURL(url);
              const canvas = document.createElement('canvas');
              canvas.width = img.naturalWidth;
              canvas.height = img.naturalHeight;
              const ctx = canvas.getContext('2d');
              ctx.drawImage(img, 0, 0);
              const webpDataUrl = canvas.toDataURL('image/webp', 0.85);
              return webpDataUrl.split(',')[1];
            } catch(e) {
              return null;
            }
          })()
        ''').timeout(const Duration(seconds: 15), onTimeout: () => null);
        
        if (webpResult is String && webpResult.isNotEmpty) {
          b64 = webpResult;
          mime = 'image/webp';
          final webpSizeKB = (base64Decode(b64).length / 1024).toStringAsFixed(1);
          print('[UPLOAD] 🖼️ WebP: ${originalSizeKB.toStringAsFixed(1)}KB → ${webpSizeKB}KB');
        } else {
          b64 = base64Encode(bytes);
          mime = path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
        }
      } catch (e) {
        b64 = base64Encode(bytes);
        mime = path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
        print('[UPLOAD] WebP skipped: $e');
      }
    } else {
      b64 = base64Encode(bytes);
      mime = path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      print('[UPLOAD] Browser not connected, skipping WebP conversion');
    }
    
    // Upload via HTTP directly (no JS string interpolation issues)
    final payload = jsonEncode({
      'imageInput': {
        'rawImageBytes': b64, 
        'mimeType': mime, 
        'isUserUploaded': true,
        'aspectRatio': imageAspectRatio
      },
      'clientContext': {
        'sessionId': ';${DateTime.now().millisecondsSinceEpoch}', 
        'tool': 'ASSET_MANAGER'
      }
    });
    
    // Try upload with retry on failure
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        final response = await http.post(
          Uri.parse('https://aisandbox-pa.googleapis.com/v1:uploadUserImage'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'text/plain;charset=UTF-8',
          },
          body: payload,
        ).timeout(const Duration(seconds: 60));
        
        if (response.statusCode == 200) {
          final res = jsonDecode(response.body);
          return res['mediaGenerationId']?['mediaGenerationId'] ?? res['mediaId'];
        } else {
          print('[UPLOAD] HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}');
          if (attempt == 1) {
            print('[UPLOAD] 🔄 Retrying...');
            try { await ensureConnected(); } catch (_) {}
            continue;
          }
          return {'error': true, 'message': 'HTTP ${response.statusCode}'};
        }
      } catch (e) {
        print('[UPLOAD] Attempt $attempt error: $e');
        if (attempt == 1) {
          print('[UPLOAD] 🔄 Retrying after reconnect...');
          try { await ensureConnected(); } catch (_) {}
          continue;
        }
        return {'error': true, 'message': e.toString()};
      }
    }
    return {'error': true, 'message': 'Upload failed after retries'};
  }

  Future<Map<String, dynamic>?> generateVideo({
    required String prompt, 
    required String accessToken, 
    required String aspectRatio, 
    required String model,
    String? startImageMediaId, 
    String? endImageMediaId, 
    String? recaptchaToken,
    String accountType = 'ai_ultra',
  }) async {
    // Generate UUID for sceneId
    final random = Random();
    String generateUuid() {
      String hex(int length) => List.generate(length, (_) => random.nextInt(16).toRadixString(16)).join();
      return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
    }
    
    final sceneUuid = generateUuid();
    final projectId = generateUuid();
    final batchId = generateUuid();
    
    // Model key is already fully resolved by caller (AppConfig.getFullModelKey)
    // No additional portrait/square adjustment needed here
    final adjustedModel = model;
    
    final requestObj = {
      'aspectRatio': aspectRatio,
      'seed': Random().nextInt(50000),
      'textInput': {'structuredPrompt': {'parts': [{'text': prompt}]}},
      'videoModelKey': adjustedModel,
      if (startImageMediaId != null) 'startImage': {'mediaId': startImageMediaId},
      if (endImageMediaId != null) 'endImage': {'mediaId': endImageMediaId},
      'metadata': {},
    };
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';
    
    final payloadMap = {
      'mediaGenerationContext': {'batchId': batchId},
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken ?? '', 
          'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB'
        },
        'sessionId': sessionId,
        'projectId': projectId,
        'tool': 'PINHOLE',
        'userPaygateTier': accountType == 'ai_ultra' ? 'PAYGATE_TIER_TWO' : 'PAYGATE_TIER_ONE'
      },
      'requests': [requestObj],
      'useV2ModelConfig': true,
    };
    final payload = jsonEncode(payloadMap);
    
    // Select endpoint based on which frames are present
    final String endpoint;
    if (startImageMediaId != null && endImageMediaId != null) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartAndEndImage';
    } else if (startImageMediaId != null) {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoStartImage';
    } else {
      endpoint = 'https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoText';
    }
    
    // Debug: Log the exact payload being sent
    print('[GENERATE] 📦 Payload for Scene:');
    print('[GENERATE]   - Model: $adjustedModel (raw: $model)');
    print('[GENERATE]   - AccountType: $accountType');
    print('[GENERATE]   - PaygateTier: ${accountType == 'ai_ultra' ? 'PAYGATE_TIER_TWO' : 'PAYGATE_TIER_ONE'}');
    print('[GENERATE]   - AspectRatio: $aspectRatio');
    print('[GENERATE]   - HasStartImage: ${startImageMediaId != null}');
    print('[GENERATE]   - HasEndImage: ${endImageMediaId != null}');
    print('[GENERATE]   - Endpoint: $endpoint');

    
    final js = '''
      fetch("$endpoint", {
        method: "POST", 
        headers: {
          "authorization": "Bearer $accessToken", 
          "content-type": "text/plain;charset=UTF-8"
        }, 
        body: JSON.stringify($payload)
      }).then(async r => {
        const text = await r.text();
        if (!r.ok) return { error: { message: "HTTP " + r.status + ": " + text.substring(0, 100), status: r.status }, data: text };
        try {
          return JSON.parse(text);
        } catch(e) {
          return { error: { message: "Failed to parse JSON: " + text.substring(0, 100) } };
        }
      }).catch(e => ({ error: { message: e.message } }))
    ''';
    final res = await executeJs(js);
    
    if (res == null) return {'success': false, 'error': 'No response'};
    if (res['error'] != null) return {'success': false, 'error': res['error']['message'] ?? res['error'].toString(), 'data': res};
    if (res['operations'] != null) return {'success': true, 'data': res};
    
    // Fallback if the response is unexpected but not explicitly an error
    return {'success': false, 'error': 'Invalid response (missing operations)', 'data': res};
  }

  Future<List<Map<String, dynamic>>?> pollVideoStatusBatchHTTP(List<PollRequest> requests, String token) async {
    final payload = jsonEncode({
      'operations': requests.map((r) => {'operation': {'name': r.operationName}, 'status': 'MEDIA_GENERATION_STATUS_ACTIVE'}).toList()
    });
    final js = 'fetch("https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus", {method:"POST", headers:{"authorization":"Bearer $token", "content-type":"application/json"}, body:JSON.stringify($payload)}).then(r=>r.json())';
    final res = await executeJs(js);
    return res?['operations'] != null ? List<Map<String, dynamic>>.from(res['operations']) : null;
  }

  // Alias for upscale polling compatibility
  Future<List<Map<String, dynamic>>?> pollVideoStatusBatch(List<PollRequest> requests, String token) async {
    return pollVideoStatusBatchHTTP(requests, token);
  }

  // Single video polling for upscale
  Future<Map<String, dynamic>?> pollVideoStatus(String operationName, String sceneId, String token) async {
    final payload = jsonEncode({
      'operations': [{'operation': {'name': operationName}, 'status': 'MEDIA_GENERATION_STATUS_ACTIVE'}]
    });
    final js = 'fetch("https://aisandbox-pa.googleapis.com/v1/video:batchCheckAsyncVideoGenerationStatus", {method:"POST", headers:{"authorization":"Bearer $token", "content-type":"application/json"}, body:JSON.stringify($payload)}).then(r=>r.json())';
    final res = await executeJs(js);
    if (res?['operations'] != null && res['operations'].isNotEmpty) {
      return res['operations'][0] as Map<String, dynamic>;
    }
    return null;
  }

  Future<void> downloadVideo(String url, String path) async {
    final bytes = await http.readBytes(Uri.parse(url));
    await File(path).writeAsBytes(bytes);
  }

  Future<Map<String, dynamic>> upscaleVideo({
    required String accessToken,
    required String videoMediaId,
    required String aspectRatio,
    required String resolution,
  }) async {
    // Get recaptcha token
    final recaptchaToken = await getRecaptchaToken();
    
    // Select correct model based on resolution
    final modelKey = resolution == 'VIDEO_RESOLUTION_4K' 
        ? 'veo_3_1_upsampler_4k' 
        : 'veo_3_1_upsampler_1080p';
    
    final payload = jsonEncode({
      'requests': [{
        'aspectRatio': aspectRatio,
        'resolution': resolution,
        'seed': Random().nextInt(100000),
        'videoInput': {
          'mediaId': videoMediaId,
        },
        'videoModelKey': modelKey,
      }],
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken ?? '',
        },
        'sessionId': ';${DateTime.now().millisecondsSinceEpoch}',
      },
    });
    
    final js = '''
      fetch("https://aisandbox-pa.googleapis.com/v1/video:batchAsyncGenerateVideoUpsampleVideo", {
        method: "POST",
        headers: {
          "authorization": "Bearer $accessToken",
          "content-type": "application/json"
        },
        body: JSON.stringify($payload)
      }).then(r => r.json())
    ''';
    
    final res = await executeJs(js);
    if (res == null) return {'success': false, 'error': 'No response from upscale API'};
    if (res['error'] != null) return {'success': false, 'error': res['error']['message'] ?? res['error'].toString(), 'data': res};
    if (res['operations'] != null) return {'success': true, 'data': res};
    return {'success': false, 'error': 'Invalid response', 'data': res};
  }
}
