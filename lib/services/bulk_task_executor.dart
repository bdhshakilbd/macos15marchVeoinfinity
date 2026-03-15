import 'dart:async' show Future, Timer, unawaited;
import 'dart:io' show File, Directory, Platform;
import 'dart:math';
import 'package:path/path.dart' as path;
import '../models/bulk_task.dart';
import '../models/scene_data.dart';
import '../models/poll_request.dart';
import '../services/video_generation_service.dart';
import '../services/profile_manager_service.dart';
import '../services/multi_profile_login_service.dart';
import '../services/foreground_service.dart';
import '../utils/config.dart';
import 'mobile/mobile_browser_service.dart';

/// Manages execution of heavy bulk tasks with multi-browser support
/// Uses direct API calls with batch polling and retry logic (up to 7 times)
/// Singleton to persist across screen navigations
class BulkTaskExecutor {
  // Singleton pattern
  static final BulkTaskExecutor _instance = BulkTaskExecutor._internal();
  factory BulkTaskExecutor({Function(BulkTask)? onTaskStatusChanged}) {
    if (onTaskStatusChanged != null) {
      _instance._onTaskStatusChanged = onTaskStatusChanged;
    }
    return _instance;
  }
  BulkTaskExecutor._internal();

  final Map<String, BulkTask> _runningTasks = {};
  final Map<String, int> _activeGenerations = {};
  final Map<String, List<_PendingPoll>> _pendingPolls = {};
  final Map<String, bool> _generationComplete = {};
  final Map<String, int> _activeDownloads = {};
  
  Timer? _schedulerTimer;
  Function(BulkTask)? _onTaskStatusChanged;
  
  /// Update callback when screen is recreated
  void setOnTaskStatusChanged(Function(BulkTask)? callback) {
    _onTaskStatusChanged = callback;
  }
  
  /// Get running task by ID (for reconnecting UI)
  BulkTask? getRunningTask(String taskId) => _runningTasks[taskId];
  
  /// Get all running tasks
  List<BulkTask> get runningTasks => _runningTasks.values.toList();
  
  /// Check if a task is running
  bool isTaskRunning(String taskId) => _runningTasks.containsKey(taskId);
  
  // Multi-browser support
  ProfileManagerService? _profileManager;
  MobileBrowserService? _mobileService;
  MultiProfileLoginService? _loginService;
  String _email = '';
  String _password = '';
  
  final Random _random = Random();
  DateTime? _last429Time; // Track last 429 error for cooldown

  /// Set multi-browser profile manager
  void setProfileManager(ProfileManagerService? manager) {
    _profileManager = manager;
    // Auto-create loginService if not already set
    if (manager != null && _loginService == null) {
      _loginService = MultiProfileLoginService(profileManager: manager);
      print('[BulkTaskExecutor] Auto-created loginService from profileManager');
    }
  }

  void setMobileBrowserService(MobileBrowserService? service) {
    _mobileService = service;
  }

  /// Set login service for re-login on 403
  void setLoginService(MultiProfileLoginService? service) {
    _loginService = service;
  }

  /// Set credentials for re-login
  void setCredentials(String email, String password) {
    _email = email;
    _password = password;
  }
  
  /// Set default account type (e.g. ai_pro, ai_ultra) for model key mapping
  void setAccountType(String type) {
    _accountType = type;
  }
  
  String _accountType = 'ai_ultra'; // Default to Ultra but configurable

  /// Start the task scheduler
  void startScheduler(List<BulkTask> tasks) {
    _schedulerTimer?.cancel();
    _schedulerTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkScheduledTasks(tasks);
    });
  }

  void stopScheduler() {
    _schedulerTimer?.cancel();
  }

  /// Check and start scheduled tasks
  void _checkScheduledTasks(List<BulkTask> tasks) {
    for (var task in tasks) {
      if (task.status == TaskStatus.scheduled) {
        bool shouldStart = false;

        switch (task.scheduleType) {
          case TaskScheduleType.immediate:
            shouldStart = true;
            break;
            
          case TaskScheduleType.scheduledTime:
            if (task.scheduledTime != null && 
                DateTime.now().isAfter(task.scheduledTime!)) {
              shouldStart = true;
            }
            break;
            
          case TaskScheduleType.afterTask:
            if (task.afterTaskId != null) {
              final afterTask = tasks.firstWhere(
                (t) => t.id == task.afterTaskId,
                orElse: () => task,
              );
              if (afterTask.status == TaskStatus.completed) {
                shouldStart = true;
              }
            }
            break;
        }

        if (shouldStart && !_isProfileBusy(task.profile)) {
          startTask(task);
        }
      }
    }
  }

  bool _isProfileBusy(String profile) {
    return _runningTasks.values.any((t) => t.profile == profile);
  }

  /// Cancel a running task by ID (immediate — does not wait for in-flight downloads).
  void cancelTask(String taskId) {
    final task = _runningTasks[taskId];
    if (task == null) {
      print('[TASK] Task $taskId not found in running tasks');
      return;
    }
    
    print('[TASK] ⏹ Cancelling task: ${task.name}');
    task.status = TaskStatus.cancelled;
    task.completedAt = DateTime.now();
    _onTaskStatusChanged?.call(task);
    
    // Immediate cleanup — skip download drain for cancel
    _runningTasks.remove(taskId);
    _activeGenerations.remove(taskId);
    _pendingPolls.remove(taskId);
    _generationComplete.remove(taskId);
    _activeDownloads.remove(taskId);
    
    print('[TASK] ✓ Task cancelled successfully');
  }
  
  /// Cancel all running tasks
  void cancelAllTasks() {
    final taskIds = _runningTasks.keys.toList();
    for (final taskId in taskIds) {
      cancelTask(taskId);
    }
  }

  /// Start executing a bulk task.
  ///
  /// This method is intentionally NON-BLOCKING: it registers the task and
  /// launches its generation+polling pipeline in a separate async chain so
  /// that multiple reels can run concurrently.  The caller does NOT need to
  /// await this method.
  Future<void> startTask(BulkTask task) async {
    print('\n');
    print('[TASK] ========================================');
    print('[TASK] START BULK TASK: ${task.name}');
    print('[TASK] Using Multi-Browser Direct API Mode');
    print('[TASK] Scenes: ${task.scenes.length}');
    print('[TASK] Model: ${task.model}');
    print('[TASK] ========================================');
    
    if (_runningTasks.containsKey(task.id)) {
      print('[TASK] Task ${task.name} is already running');
      return;
    }

    task.status = TaskStatus.running;
    task.startedAt = DateTime.now();
    _runningTasks[task.id] = task;
    _activeGenerations[task.id] = 0;
    _pendingPolls[task.id] = [];
    _generationComplete[task.id] = false;
    _activeDownloads[task.id] = 0;
    
    // Start foreground service to keep app running in background (Android)
    await ForegroundServiceHelper.startService(
      status: 'Starting: ${task.name} (${task.scenes.length} videos)'
    );
    
    _onTaskStatusChanged?.call(task);

    // Fire-and-forget: launch the pipeline in its own async chain so this
    // method returns immediately and the caller can start the next reel
    // without waiting for this one to finish.
    unawaited(_executeTaskMultiBrowser(task).then((_) async {
      task.status = TaskStatus.completed;
      task.completedAt = DateTime.now();
      print('[TASK] ✓ Task completed: ${task.name}');
      await ForegroundServiceHelper.updateStatus('✓ ${task.name} completed!');
    }).catchError((Object e, StackTrace stackTrace) async {
      print('[TASK] ✗ Task FAILED: ${task.name} — $e');
      print('[TASK] Stack trace: $stackTrace');
      task.status = TaskStatus.failed;
      task.error = e.toString();
      task.completedAt = DateTime.now();
      await ForegroundServiceHelper.updateStatus('✗ ${task.name} failed');
    }).whenComplete(() async {
      await _cleanup(task.id);
      _onTaskStatusChanged?.call(task);
      if (_runningTasks.isEmpty) {
        await ForegroundServiceHelper.stopService();
      }
    }));
  }
  
  /// Public method to trigger checking scheduled tasks immediately
  void checkScheduledTasksNow(List<BulkTask> tasks) {
    _checkScheduledTasks(tasks);
  }

  /// Execute task using multi-browser direct API
  Future<void> _executeTaskMultiBrowser(BulkTask task) async {
    print('\n${'=' * 60}');
    print('BULK TASK: ${task.name}');
    print('Profile: ${task.profile}');
    print('Scenes: ${task.totalScenes}');
    print('=' * 60);

    // Debug: Show configuration status
    print('\n[CONFIG] Profile Manager: ${_profileManager != null ? "SET" : "NULL"}');
    print('[CONFIG] Login Service: ${_loginService != null ? "SET" : "NULL"}');
    print('[CONFIG] Email: ${_email.isNotEmpty ? "SET (${_email.length} chars)" : "EMPTY"}');
    
    if (_profileManager != null) {
      print('[CONFIG] Connected browsers: ${_profileManager!.countConnectedProfiles()}');
      for (final profile in _profileManager!.profiles) {
        print('[CONFIG]   - ${profile.name}: ${profile.status} (Port: ${profile.debugPort})');
      }
    }
    
    // Debug: Show mobile service status
    if (_mobileService != null) {
      print('[CONFIG] Mobile Service: SET');
      print('[CONFIG] Mobile Connected: ${_mobileService!.countConnected()}');
      print('[CONFIG] Mobile Healthy: ${_mobileService!.countHealthy()}');
      for (final profile in _mobileService!.profiles) {
        print('[CONFIG]   - ${profile.name}: hasToken=${profile.accessToken != null}, 403Count=${profile.consecutive403Count}');
      }
    } else {
      print('[CONFIG] Mobile Service: NULL');
    }

    // Check for connected browsers
    int connectedCount = _countConnectedProfiles();
    print('[CONFIG] Total Connected Profiles: $connectedCount');
    
    if (connectedCount == 0) {
      print('[CONFIG] No profiles connected. Attempting auto-connect/refresh...');
      if (_profileManager != null) {
        await _profileManager!.refreshAllProfiles();
        connectedCount = _countConnectedProfiles();
        print('[CONFIG] After refresh: $connectedCount connected profiles');
      }
    }
    
    if (connectedCount == 0) {
      print('[ERROR] No connected browsers available!');
      final isMobile = Platform.isAndroid || Platform.isIOS;
      throw Exception(isMobile 
        ? 'No connected mobile browsers. Please login first on Browser tab.'
        : 'No connected browsers. Please connect using Profile Manager.');
    }

    // Convert model display name to API key
    final apiModelKey = AppConfig.getApiModelKey(task.model, _accountType);
    print('\n[MODEL] Display: ${task.model}');
    print('[MODEL] Account Type: $_accountType');
    print('[MODEL] API Key: $apiModelKey');
    print('[ASPECT RATIO] ${task.aspectRatio}');

    // Determine concurrency limit
    // Use unlimited concurrent for all models - let 429 errors naturally throttle
    // Relaxed models will hit 429 when quota is full, then wait 30s before retrying
    final isRelaxedModel = task.model.contains('Lower Priority') ||
                            apiModelKey.contains('relaxed');
    // Normal mode: 4 concurrent per reel (pipeline: generate → poll → download)
    // 10x Boost mode: unlimited (let 429 errors throttle naturally)
    final maxConcurrent = task.use10xBoostMode ? 999 : 4;
    print('[CONCURRENCY] ===============================');
    print('[CONCURRENCY] Model Display Name: "${task.model}"');
    print('[CONCURRENCY] API Model Key: "$apiModelKey"');
    print('[CONCURRENCY] Contains "Lower Priority": ${task.model.contains('Lower Priority')}');
    print('[CONCURRENCY] Contains "relaxed" in key: ${apiModelKey.contains('relaxed')}');
    print('[CONCURRENCY] Is Relaxed Mode: $isRelaxedModel');
    print('[CONCURRENCY] Strategy: ${task.use10xBoostMode ? "10x Boost (unlimited)" : "Normal (4 concurrent/reel)"}');
    print('[CONCURRENCY] Max Concurrent: $maxConcurrent');
    print('[CONCURRENCY] ===============================');


    // Start generation and polling workers
    print('\n[WORKERS] Scenes to process: ${task.scenes.where((s) => s.status == 'queued').length}');
    print('[WORKERS] Connected browsers: ${_countConnectedProfiles()}');

    try {
      await Future.wait([
        _processGenerationQueueMultiBrowser(task, maxConcurrent, apiModelKey),
        _processBatchPollingQueue(task, maxConcurrent),
      ]);
    } catch (e, stackTrace) {
      print('[WORKERS] ERROR: $e');
      print('[WORKERS] Stack: $stackTrace');
      rethrow;
    }

    print('\n${'=' * 60}');
    print('TASK COMPLETE: ${task.name}');
    print('Completed: ${task.completedScenes}/${task.totalScenes}');
    print('Failed: ${task.failedScenes}');
    print('=' * 60);
  }

  /// Process generation queue with multi-browser round-robin and retry logic.
  ///
  /// **10x Boost mode** (maxConcurrent == 999):
  ///   Fires every generation request as a fire-and-forget concurrent task with
  ///   a 2-second interval between each fire.  The loop does NOT wait for any
  ///   generation/poll/download to finish before moving to the next scene.
  ///   This means all scenes of a reel are submitted almost immediately, and
  ///   the caller (which is itself fire-and-forget per reel) returns to start
  ///   the next reel right away.
  ///
  /// **Normal mode** (maxConcurrent == 4):
  ///   Awaits each generation before firing the next, respecting the slot limit.
  ///
  /// Runs concurrently with [_processBatchPollingQueue] via [Future.wait].
  Future<void> _processGenerationQueueMultiBrowser(
    BulkTask task,
    int maxConcurrent,
    String apiModelKey,
  ) async {
    final isBoostMode = maxConcurrent >= 999;
    print('\n${'=' * 60}');
    print('GENERATION PRODUCER STARTED (Multi-Browser Direct API)');
    print('Mode: ${isBoostMode ? "10x BOOST (fire-and-forget, 2s interval)" : "Normal (4 concurrent)"}');
    print('=' * 60);

    while (task.status == TaskStatus.running || task.status == TaskStatus.paused) {
      // Wait if paused (relogin in progress)
      if (task.status == TaskStatus.paused) {
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      // Check for queued scenes
      final scenesToProcess = task.scenes.where((s) => s.status == 'queued').toList();
      
      if (scenesToProcess.isEmpty) {
        // Both modes: once all scenes are submitted (API response received or
        // fire-and-forget fired), the producer is done.  Polling and downloading
        // continue independently in _processBatchPollingQueue.
        //
        // Exception: if any scene was re-queued by a retry (status back to
        // 'queued'), we must keep looping.  The check above already handles
        // that because scenesToProcess would be non-empty in that case.
        break;
      }

      // Normal mode: respect concurrent slot limit (don't flood the API)
      if (!isBoostMode && (_activeGenerations[task.id] ?? 0) >= maxConcurrent) {
        print('\r[LIMIT] Waiting for slots (Active: ${_activeGenerations[task.id]}/$maxConcurrent)...');
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      final scene = scenesToProcess.first;
      // Mark scene as 'generating' immediately so it's not picked up again
      scene.status = 'generating';
      scene.error = null;
      _onTaskStatusChanged?.call(task);

      // Get next available browser (round-robin) - only gets healthy profiles (< 5 403s)
      final profile = _getNextAvailableProfile();
      if (profile == null) {
        // No browser available — revert scene to queued and handle relogin
        scene.status = 'queued';
        _onTaskStatusChanged?.call(task);

        if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
          final totalConnected = _countConnectedProfiles();
          final healthyCount = _countHealthyProfiles();
          final needsRelogin = _mobileService!.getProfilesNeedingRelogin();
          
          print('[GENERATE] No available browser. Connected: $totalConnected, Healthy: $healthyCount, NeedsRelogin: ${needsRelogin.length}');
          
          if (needsRelogin.isNotEmpty) {
            print('[GENERATE] Starting relogin for ${needsRelogin.length} unhealthy browsers...');
            _mobileService!.reloginAllNeeded(
              email: _email,
              password: _password,
              onAnySuccess: () => print('[GENERATE] ✓ A browser recovered!'),
            );
          }
          
          if (healthyCount == 0) {
            print('[GENERATE] ❌ ALL browsers unhealthy - PAUSING...');
            task.status = TaskStatus.paused;
            _onTaskStatusChanged?.call(task);
            
            int waitCount = 0;
            while (_countHealthyProfiles() == 0 && task.status == TaskStatus.paused && waitCount < 60) {
              await Future.delayed(const Duration(seconds: 5));
              waitCount++;
              print('[GENERATE] Waiting for relogin... (${waitCount * 5}s, Healthy: ${_countHealthyProfiles()})');
            }
            
            if (_countHealthyProfiles() > 0 && task.status == TaskStatus.paused) {
              task.status = TaskStatus.running;
              _onTaskStatusChanged?.call(task);
              print('[GENERATE] ✓ Resuming generation!');
            }
          }
        } else {
          print('[GENERATE] No available browsers, waiting...');
        }
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }

      // Compute current index for logging
      final queuedNow = task.scenes.where((s) => s.status == 'queued').length;
      final currentIndex = task.totalScenes - queuedNow;

      if (isBoostMode) {
        // ── 10x BOOST MODE ──────────────────────────────────────────────────
        // Fire the generation request as a concurrent task (don't await).
        // The loop immediately moves to the next scene after a 2s interval.
        // Retries are handled inside the async task itself.
        unawaited(_fireGenerationTask(task, scene, profile, currentIndex, apiModelKey));
        await Future.delayed(const Duration(seconds: 2));
      } else {
        // ── NORMAL MODE ─────────────────────────────────────────────────────
        // Await the generation so we respect the slot limit.
        await _runGenerationWithRetry(task, scene, profile, currentIndex, apiModelKey);
      }
    }

    // Mark generation as complete
    _generationComplete[task.id] = true;
    print('\n[PRODUCER] All scenes submitted for task: ${task.name}');
  }

  /// Fire-and-forget wrapper used in 10x Boost mode.
  /// Handles retries internally without blocking the producer loop.
  Future<void> _fireGenerationTask(
    BulkTask task,
    SceneData scene,
    dynamic profile,
    int currentIndex,
    String apiModelKey,
  ) async {
    const maxRetries = 5;
    int attempt = 0;
    dynamic currentProfile = profile;

    while (attempt < maxRetries && task.status == TaskStatus.running) {
      try {
        await _generateWithProfile(task, scene, currentProfile, currentIndex, task.totalScenes, apiModelKey);
        return; // success
      } on _RetryableException catch (e) {
        attempt++;
        int retryDelay = 3 + _random.nextInt(3);
        if (e.message.contains('429') || e.message.contains('quota')) {
          retryDelay = 30;
          print('[BOOST-RETRY] 429 quota — waiting 30s before retry...');
        }
        print('[BOOST-RETRY] Scene ${scene.sceneId} attempt $attempt/$maxRetries — ${e.message}');
        await Future.delayed(Duration(seconds: retryDelay));
        scene.status = 'queued';
        scene.retryCount = attempt;
        scene.error = 'Retrying ($attempt/$maxRetries): ${e.message}';
        _onTaskStatusChanged?.call(task);
        // Try a different browser on retry
        currentProfile = _getNextAvailableProfile() ?? currentProfile;
      } catch (e) {
        scene.status = 'failed';
        scene.error = e.toString();
        _onTaskStatusChanged?.call(task);
        print('[BOOST-RETRY] Scene ${scene.sceneId} non-retryable error: $e');
        return;
      }
    }

    if (attempt >= maxRetries) {
      scene.status = 'failed';
      scene.error = 'Failed after $maxRetries attempts';
      _onTaskStatusChanged?.call(task);
      print('[BOOST-RETRY] Scene ${scene.sceneId} failed after $maxRetries attempts');
    }
  }

  /// Synchronous retry wrapper used in Normal mode.
  Future<void> _runGenerationWithRetry(
    BulkTask task,
    SceneData scene,
    dynamic profile,
    int currentIndex,
    String apiModelKey,
  ) async {
    const maxRetries = 5;
    dynamic currentProfile = profile;

    for (int attempt = 0; attempt < maxRetries && task.status == TaskStatus.running; attempt++) {
      // On retry, get a fresh browser
      if (attempt > 0) {
        currentProfile = _getNextAvailableProfile();
        if (currentProfile == null) {
          // Handle mobile relogin
          if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
            final healthyCount = _countHealthyProfiles();
            if (healthyCount == 0) {
              print('[RETRY] ⏸ ALL browsers unhealthy - PAUSING for relogin...');
              _mobileService!.reloginAllNeeded(
                email: _email,
                password: _password,
                onAnySuccess: () => print('[RETRY] ✓ Browser recovered from relogin'),
              );
              int waitAttempts = 0;
              while (_countHealthyProfiles() == 0 && waitAttempts < 60 && task.status == TaskStatus.running) {
                await Future.delayed(const Duration(seconds: 5));
                waitAttempts++;
              }
              currentProfile = _getNextAvailableProfile();
            }
          }
          if (currentProfile == null) {
            await Future.delayed(const Duration(seconds: 3));
            currentProfile = _getNextAvailableProfile() ?? profile;
          }
        }
      }

      try {
        await _generateWithProfile(task, scene, currentProfile, currentIndex, task.totalScenes, apiModelKey);
        return; // success
      } on _RetryableException catch (e) {
        int retryDelay = 3 + _random.nextInt(3);
        if (e.message.contains('429') || e.message.contains('quota')) {
          retryDelay = 30;
          print('[429] Waiting 30s for quota refresh...');
        }
        print('[RETRY] Scene ${scene.sceneId} retry ${attempt + 1}/$maxRetries — waiting ${retryDelay}s...');
        print('[RETRY] Error was: ${e.message}');
        await Future.delayed(Duration(seconds: retryDelay));
        scene.status = 'queued';
        scene.retryCount = attempt + 1;
        scene.error = 'Retrying (${attempt + 1}/$maxRetries): ${e.message}';
        _onTaskStatusChanged?.call(task);

        if (attempt + 1 >= maxRetries) {
          scene.status = 'failed';
          scene.error = 'Failed after $maxRetries retries: ${e.message}';
          _onTaskStatusChanged?.call(task);
          print('[GENERATE] ✗ Scene ${scene.sceneId} failed after $maxRetries retries');
        }
      } catch (e) {
        scene.status = 'failed';
        scene.error = e.toString();
        _onTaskStatusChanged?.call(task);
        print('[GENERATE] ✗ Exception: $e');
        return;
      }
    }
  }

  /// Generate video using specific browser profile (direct API).
  ///
  /// Handles prompt validation, image uploads, model key conversion, reCAPTCHA,
  /// and the actual API call.  On success the scene is moved to 'polling' and
  /// added to [_pendingPolls].  On error a [_RetryableException] is thrown so
  /// the caller can retry with a different browser.
  Future<void> _generateWithProfile(
    BulkTask task,
    SceneData scene,
    dynamic profile, // Supported: ChromeProfile, MobileProfile
    int currentIndex,
    int totalScenes,
    String apiModelKey,
  ) async {
    // ── Prompt validation ────────────────────────────────────────────────────
    final hasImage = scene.firstFramePath != null || scene.lastFramePath != null;
    if (scene.prompt.trim().isEmpty) {
      if (hasImage) {
        scene.prompt = 'Animate this image with natural, fluid motion';
        print('[GENERATE] Using default I2V prompt for scene ${scene.sceneId}');
      } else {
        scene.status = 'failed';
        scene.error = 'No prompt or image provided';
        _onTaskStatusChanged?.call(task);
        return; // nothing to do
      }
    }

    // ── Image uploads (idempotent — skipped if mediaId already set) ──────────
    if (scene.firstFramePath != null && scene.firstFrameMediaId == null) {
      print('[GENERATE] Uploading first frame image...');
      final uploadResult = await profile.generator!.uploadImage(
        scene.firstFramePath!,
        profile.accessToken!,
      );
      if (uploadResult is String) {
        scene.firstFrameMediaId = uploadResult;
        print('[GENERATE] ✓ First frame uploaded: $uploadResult');
      } else if (uploadResult is Map && uploadResult['error'] == true) {
        print('[GENERATE] ✗ First frame upload failed: ${uploadResult['message']}');
        scene.error = 'Image upload failed: ${uploadResult['message']}';
      }
    }

    if (scene.lastFramePath != null && scene.lastFrameMediaId == null) {
      print('[GENERATE] Uploading last frame image...');
      final uploadResult = await profile.generator!.uploadImage(
        scene.lastFramePath!,
        profile.accessToken!,
      );
      if (uploadResult is String) {
        scene.lastFrameMediaId = uploadResult;
        print('[GENERATE] ✓ Last frame uploaded: $uploadResult');
      } else if (uploadResult is Map && uploadResult['error'] == true) {
        print('[GENERATE] ✗ Last frame upload failed: ${uploadResult['message']}');
        scene.error = 'Image upload failed: ${uploadResult['message']}';
      }
    }

    // ── Take generation slot ─────────────────────────────────────────────────
    _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 0) + 1;
    print('[SLOT] Took slot - Active: ${_activeGenerations[task.id]}');

    scene.status = 'generating';
    scene.error = null;
    _onTaskStatusChanged?.call(task);

    print('\n[GENERATE $currentIndex/$totalScenes] Scene ${scene.sceneId}');
    print('[GENERATE] Browser: ${profile.name} (Port: ${profile.debugPort})');
    print('[GENERATE] Using Direct API Method (batchAsyncGenerateVideoText)');
    print('[GENERATE] Model: $apiModelKey');
    print('[GENERATE] Aspect Ratio: ${task.aspectRatio}');
    print('[GENERATE] Prompt: ${scene.prompt.substring(0, scene.prompt.length > 100 ? 100 : scene.prompt.length)}...');
    
    // Convert model key to i2v variant if images are present
    String actualModel = apiModelKey;
    if (scene.firstFrameMediaId != null || scene.lastFrameMediaId != null) {
      // Convert t2v model to i2v model
      if (actualModel.contains('_t2v_')) {
        // Check if both frames are present - use _fl_ variant
        if (scene.firstFrameMediaId != null && scene.lastFrameMediaId != null) {
          // Both frames: convert t2v to i2v_s, then append _fl at end
          actualModel = actualModel.replaceFirst('_t2v_', '_i2v_s_');
          actualModel = '${actualModel}_fl';
        } else {
          // Single frame: use _i2v_s_ pattern
          actualModel = actualModel.replaceFirst('_t2v_', '_i2v_s_');
        }
        print('[GENERATE] Converted model to i2v: $actualModel');
      }
    }
    
    // Add portrait variant if aspect ratio is portrait
    if (task.aspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT') {
      // Replace _fast_ with _fast_portrait_ or _quality_ with _quality_portrait_
      if (actualModel.contains('_fast_') && !actualModel.contains('_portrait_')) {
        actualModel = actualModel.replaceFirst('_fast_', '_fast_portrait_');
        print('[GENERATE] Added portrait variant: $actualModel');
      } else if (actualModel.contains('_quality_') && !actualModel.contains('_portrait_')) {
        actualModel = actualModel.replaceFirst('_quality_', '_quality_portrait_');
        print('[GENERATE] Added portrait variant: $actualModel');
      }
    }
    
    // Get fresh reCAPTCHA token from the generator
    print('[GENERATE] Getting fresh reCAPTCHA token...');
    final recaptchaToken = await profile.generator!.getRecaptchaToken();
    if (recaptchaToken == null) {
      print('[GENERATE] ✗ Failed to get reCAPTCHA token');
      throw Exception('Failed to get reCAPTCHA token');
    }
    print('[GENERATE] ✓ Got reCAPTCHA token');
    
    print('[API REQUEST] Sending generation request...');

    final result = await profile.generator!.generateVideo(
      prompt: scene.prompt,
      accessToken: profile.accessToken!,
      aspectRatio: task.aspectRatio,
      model: actualModel,
      startImageMediaId: scene.firstFrameMediaId,
      endImageMediaId: scene.lastFrameMediaId,
      recaptchaToken: recaptchaToken,
    );

    print('[API RESPONSE] Result received: ${result != null ? "SUCCESS" : "NULL"}');
    if (result != null) {
      print('[API RESPONSE] Status: ${result['status']}');
      print('[API RESPONSE] Success: ${result['success']}');
      if (result['error'] != null) print('[API RESPONSE] Error: ${result['error']}');
    }

    if (result == null) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      print('[SLOT] Released slot (null result) - Active: ${_activeGenerations[task.id]}');
      throw _RetryableException('No result from generateVideo');
    }

    // Check for errors
    if (result['status'] != null && result['status'] != 200) {
      final statusCode = result['status'] as int;
      final errorMsg = result['error'] ?? result['statusText'] ?? 'API error';
      print('[API ERROR] Status Code: $statusCode');
      print('[API ERROR] Message: $errorMsg');

    // Check for 403 error (including reCAPTCHA errors - they are session-related)
    final errorStr = errorMsg.toLowerCase();
    if (statusCode == 403 || errorStr.contains('recaptcha')) {
      profile.consecutive403Count++;
      print('[403 DETECTED] ${profile.name} - Count: ${profile.consecutive403Count}/5');
      
      // Updated strategy: refresh browser after 5 consecutive 403 errors
      if (profile.consecutive403Count >= 5) {
        bool alreadyRefreshed = false;
        try { alreadyRefreshed = profile.browserRefreshedThisSession ?? false; } catch (_) {}
        
        if (!alreadyRefreshed) {
          print('[403 STRATEGY] \ud83d\udd04 ${profile.name} hit 5 consecutive 403s - refreshing browser...');
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
              print('[403] \u2705 ${profile.name} browser refreshed and counter reset.');
            }
          } catch (e) {
            print('[403] \u26a0\ufe0f Browser refresh failed for ${profile.name}: $e');
          }
        } else {
          print('[403] \u26a0\ufe0f ${profile.name} already refreshed - skipping additional refresh to avoid loop');
        }
      }
    }
    
    _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
    print('[SLOT] Released slot (reCAPTCHA error) - Active: ${_activeGenerations[task.id]}');
    throw _RetryableException('reCAPTCHA evaluation failed - will retry with fresh session');
  }
  
  if (result['success'] != true) {
    _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
    throw _RetryableException(result['error'] ?? 'Generation failed');
  }

    // Extract operation name from nested structure
    final responseData = result['data'] as Map<String, dynamic>;
    final operations = responseData['operations'] as List?;
    if (operations == null || operations.isEmpty) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException('No operations in response');
    }

    final operationWrapper = operations[0] as Map<String, dynamic>;
    final operation = operationWrapper['operation'] as Map<String, dynamic>?;
    if (operation == null) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException('No operation object in response');
    }

    final operationName = operation['name'] as String?;
    if (operationName == null) {
      _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
      throw _RetryableException('No operation name in response');
    }

    final sceneUuid = operationWrapper['sceneId'] as String? ?? result['sceneId'] as String?;

    scene.operationName = operationName;
    scene.status = 'polling';
    _onTaskStatusChanged?.call(task);

    // Add to pending polls with saved access token (for HTTP polling)
    _pendingPolls[task.id]!.add(_PendingPoll(scene, sceneUuid ?? operationName, profile.accessToken!));

    print('[GENERATE] ✓ Scene ${scene.sceneId} queued for polling (operation: $operationName)');
  }

  /// Batch polling queue (single API call for ALL videos)
  Future<void> _processBatchPollingQueue(BulkTask task, int maxConcurrent) async {
    print('\n${'=' * 60}');
    print('POLLING CONSUMER STARTED (Batch Mode)');
    print('=' * 60);

    // Continue polling while task is running OR paused (paused = waiting for relogin)
    // Only exit if task is stopped or completed
    while ((task.status == TaskStatus.running || task.status == TaskStatus.paused) && 
           (!_generationComplete[task.id]! || _pendingPolls[task.id]!.isNotEmpty || _activeGenerations[task.id]! > 0 || (_activeDownloads[task.id] ?? 0) > 0)) {
      
      // If paused, wait for resume
      if (task.status == TaskStatus.paused) {
        print('[POLLER] Task paused, waiting...');
        while (task.status == TaskStatus.paused) {
          await Future.delayed(const Duration(seconds: 2));
        }
        print('[POLLER] Task resumed, continuing...');
      }
      
      if (_pendingPolls[task.id]!.isEmpty) {
        await Future.delayed(const Duration(seconds: 1));
        
        // Check for retry scenes
        final retryScenes = task.scenes
            .where((s) => s.status == 'queued' && (s.retryCount ?? 0) > 0)
            .toList();
        
        if (retryScenes.isNotEmpty && _activeGenerations[task.id]! < maxConcurrent) {
          // These will be picked up by the generation loop
        }
        
        continue;
      }

      final pollInterval = 3 + _random.nextInt(3); // 3-5 seconds
      print('\n[POLLER] Monitoring ${_pendingPolls[task.id]!.length} active videos... (Next check in ${pollInterval}s)');

      try {
        // HTTP-BASED BATCH POLL (Python strategy - no browser needed!)
        // Extract access token from first pending poll (saved during generation)
        final firstPollToken = _pendingPolls[task.id]!.first.accessToken;
        
        // Build batch poll request
        final pollRequests = _pendingPolls[task.id]!.map((poll) =>
            PollRequest(poll.scene.operationName!, poll.sceneUuid)).toList();

        // Find generator for download (we still need it for download)
        dynamic pollGenerator;

        if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
          final healthyProfile = _mobileService!.getNextAvailableProfile();
          if (healthyProfile != null) {
            pollGenerator = healthyProfile.generator;
          }
        } else if (_profileManager != null) {
          for (final profile in _profileManager!.profiles) {
            if (profile.status == ProfileStatus.connected &&
                profile.generator != null) {
              pollGenerator = profile.generator;
              break;
            }
          }
        }

        // Use HTTP polling with saved token (continues working after relogin!)
        print('[HTTP POLL] Polling ${pollRequests.length} videos via HTTP...');
        
        // HTTP poll - doesn't need browser connection!
        List<Map<String, dynamic>>? results;
        if (pollGenerator != null) {
          results = await pollGenerator.pollVideoStatusBatchHTTP(pollRequests, firstPollToken);
        } else {
          // Fallback: use static HTTP client if no generator available
          print('[HTTP POLL] No generator, using static HTTP poll...');
          final generator = DesktopGenerator();
          results = await generator.pollVideoStatusBatchHTTP(pollRequests, firstPollToken);
        }

        if (results == null || results.isEmpty) {
          print('[HTTP POLL] No results from batch poll');
          await Future.delayed(Duration(seconds: pollInterval));
          continue;
        }

        // Process results
        final completedIndices = <int>[];

        for (var i = 0; i < results.length && i < _pendingPolls[task.id]!.length; i++) {
          final result = results[i];
          final poll = _pendingPolls[task.id]![i];
          final scene = poll.scene;
          final status = result['status'] as String?;

          if (status == 'MEDIA_GENERATION_STATUS_COMPLETE' || 
              status == 'MEDIA_GENERATION_STATUS_SUCCEEDED' ||
              status == 'MEDIA_GENERATION_STATUS_SUCCESSFUL') {
            _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;
            print('[SLOT] Video ready, freed slot - Active: ${_activeGenerations[task.id]}');

            String? videoUrl;
            String? videoMediaId;
            
            // Handle multiple possible response structures
            if (result.containsKey('video')) {
              videoUrl = result['video']?['uri'] as String?;
              final mediaGenId = result['video']?['mediaGenerationId'];
              if (mediaGenId != null) {
                videoMediaId = (mediaGenId is Map) ? mediaGenId['mediaGenerationId'] : mediaGenId.toString();
              }
            } 
            
            if (videoUrl == null && result.containsKey('operation')) {
              final op = result['operation'] as Map<String, dynamic>;
              final metadata = op['metadata'] as Map<String, dynamic>?;
              final video = (metadata != null) ? metadata['video'] : null;
              videoUrl = (video != null) ? (video['uri'] ?? video['fifeUrl']) : null;
              
              final mediaGenId = video?['mediaGenerationId'];
              if (mediaGenId != null) {
                videoMediaId = (mediaGenId is Map) ? mediaGenId['mediaGenerationId'] : mediaGenId.toString();
              }
            }

            if (videoUrl != null) {
              print('[POLLER] Scene ${scene.sceneId} READY -> Downloading...');
              if (videoMediaId != null) {
                scene.videoMediaId = videoMediaId;
                scene.downloadUrl = videoUrl;
                print('[POLLER] Video MediaId: $videoMediaId (saved for upscaling)');
              }
              _downloadVideo(task, scene, videoUrl, pollGenerator);
            } else {
              print('[POLLER] ✗ Scene ${scene.sceneId} COMPLETE but no video URL found');
              scene.status = 'failed';
              scene.error = 'No video URL';
              _onTaskStatusChanged?.call(task);
            }

            completedIndices.add(i);
          } else if (status == 'MEDIA_GENERATION_STATUS_FAILED') {
            String errorMsg = 'Generation failed';
            
            // Extract error message
            final errorData = result['error'] as Map<String, dynamic>?;
            if (errorData != null) {
              errorMsg = errorData['message'] ?? 'Generation failed';
            } else if (result.containsKey('operation')) {
              final op = result['operation'] as Map<String, dynamic>;
              final metadata = op['metadata'] as Map<String, dynamic>?;
              final errorDetails = (metadata != null) ? metadata['error'] : null;
              if (errorDetails != null) {
                errorMsg = '${errorDetails['message'] ?? 'No details'}';
              }
            }

            print('[POLLER] ✗ Scene ${scene.sceneId} FAILED: $errorMsg');
            
            scene.retryCount = (scene.retryCount ?? 0) + 1;
            _activeGenerations[task.id] = (_activeGenerations[task.id] ?? 1) - 1;

            if (scene.retryCount! < 5) {
              print('[RETRY] Scene ${scene.sceneId} poll failed (${scene.retryCount}/5) - pushing back for regeneration');
              scene.status = 'queued';
              scene.operationName = null;
              scene.error = 'Retrying (${scene.retryCount}/5): $errorMsg';
              _onTaskStatusChanged?.call(task);
            } else {
              print('[POLLER] ✗ Scene ${scene.sceneId} failed after 5 retries: $errorMsg');
              scene.status = 'failed';
              scene.error = 'Failed after 5 retries: $errorMsg';
              _onTaskStatusChanged?.call(task);
            }

            completedIndices.add(i);
          }
        }

        // Remove completed items
        for (final index in completedIndices.reversed) {
          _pendingPolls[task.id]!.removeAt(index);
        }
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('closed') || errorStr.contains('WebSocket')) {
          print('[POLLER] WebSocket closed (browser relogging?) - skipping poll');
        } else {
          print('[POLLER] Error during batch poll: $e');
        }
      }

      if (_pendingPolls[task.id]!.isNotEmpty) {
        await Future.delayed(Duration(seconds: pollInterval));
      }
    }

    print('[POLLER] Poll worker finished');
  }

  /// Download video
  Future<void> _downloadVideo(BulkTask task, SceneData scene, String videoUrl, dynamic generator) async {
    _activeDownloads[task.id] = (_activeDownloads[task.id] ?? 0) + 1;
    try {
      scene.status = 'downloading';
      _onTaskStatusChanged?.call(task);
      print('[DOWNLOAD] Scene ${scene.sceneId} STARTED');

      // Create output folder (use directly, don't nest with task.name)
      final projectFolder = task.outputFolder;
      await Directory(projectFolder).create(recursive: true);
      
      final outputPath = path.join(
        projectFolder,
        'scene_${scene.sceneId.toString().padLeft(4, '0')}.mp4',
      );

      // Download video using generator's downloadVideo method
      await generator.downloadVideo(videoUrl, outputPath);
      
      // Get file size after download
      final file = File(outputPath);
      final fileSize = await file.length();

      scene.videoPath = outputPath;
      scene.fileSize = fileSize;
      scene.downloadUrl = videoUrl;
      scene.generatedAt = DateTime.now().toIso8601String();
      
      // If downloaded file is too small, check and maybe trigger retry
      if (fileSize < 511488) {
        print('[DOWNLOAD] ⚠️ Scene ${scene.sceneId} file too small (${(fileSize / 1024).toStringAsFixed(1)} KB) - waiting 30s before retry...');
        await Future.delayed(const Duration(seconds: 30));
        
        print('[DOWNLOAD] 🔄 Retrying download for Scene ${scene.sceneId}...');
        await generator.downloadVideo(videoUrl, outputPath);
        
        final newFile = File(outputPath);
        final newFileSize = await newFile.length();
        
        if (newFileSize < 511488) {
          print('[DOWNLOAD] ❌ Scene ${scene.sceneId} file still too small (${(newFileSize / 1024).toStringAsFixed(1)} KB) after retry - triggering regeneration');
          final maxRetries = 5;
          final retryCount = scene.retryCount ?? 0;
          
          if (retryCount < maxRetries) {
            scene.retryCount = retryCount + 1;
            scene.status = 'queued';
            scene.error = 'Download failed (incomplete video file < 499KB) - retrying (${retryCount + 1}/$maxRetries)';
            _onTaskStatusChanged?.call(task);
            return;
          } else {
            throw Exception('Video file incomplete (<1MB) after retry');
          }
        } else {
          scene.fileSize = newFileSize;
        }
      }

      scene.status = 'completed';
      _onTaskStatusChanged?.call(task);

      // Update notification with progress (only every 5 videos or at completion to reduce spam)
      final completed = task.scenes.where((s) => s.status == 'completed').length;
      final total = task.scenes.length;
      if (completed % 5 == 0 || completed == total) {
        await ForegroundServiceHelper.updateStatus('$completed/$total | ${task.name}');
      }

      print('[DOWNLOAD] ✓ Scene ${scene.sceneId} Complete (${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB)');
    } catch (e) {
      scene.status = 'failed';
      scene.error = 'Download failed: $e';
      _onTaskStatusChanged?.call(task);
      print('[DOWNLOAD] ✗ Scene ${scene.sceneId} Failed: $e');
    } finally {
      if (_activeDownloads.containsKey(task.id)) {
        _activeDownloads[task.id] = (_activeDownloads[task.id] ?? 1) - 1;
      }
    }
  }

  /// Clean up state for a finished task.
  ///
  /// Waits for any in-flight fire-and-forget downloads to complete before
  /// removing the [_activeDownloads] entry so the counter is never leaked.
  Future<void> _cleanup(String taskId) async {
    _runningTasks.remove(taskId);
    _activeGenerations.remove(taskId);
    _pendingPolls.remove(taskId);
    _generationComplete.remove(taskId);

    // Drain in-flight downloads before removing the counter key
    int waitCycles = 0;
    while ((_activeDownloads[taskId] ?? 0) > 0 && waitCycles < 60) {
      await Future.delayed(const Duration(seconds: 1));
      waitCycles++;
    }
    _activeDownloads.remove(taskId);
  }

  void dispose() {
    _schedulerTimer?.cancel();
    _runningTasks.clear();
    _activeGenerations.clear();
    _pendingPolls.clear();
    _generationComplete.clear();
    _activeDownloads.clear();
  }
}

/// Helper class for pending poll tracking
class _PendingPoll {
  final SceneData scene;
  final String sceneUuid;
  final String accessToken; // Store token for HTTP-based polling

  _PendingPoll(this.scene, this.sceneUuid, this.accessToken);
}

/// Exception that can be retried on a different browser
class _RetryableException implements Exception {
  final String message;
  _RetryableException(this.message);

  @override
  String toString() => message;
}

// Helpers for cross-platform profile management
extension _BulkTaskExecutorHelpers on BulkTaskExecutor {
  int _countConnectedProfiles() {
    if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
      return _mobileService!.countConnected();
    }
    return _profileManager?.countConnectedProfiles() ?? 0;
  }

  dynamic _getNextAvailableProfile() {
    if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
      return _mobileService!.getNextAvailableProfile();
    }
    return _profileManager?.getNextAvailableProfile();
  }
  
  /// Count profiles that haven't hit 403 threshold
  int _countHealthyProfiles() {
    if ((Platform.isAndroid || Platform.isIOS) && _mobileService != null) {
      return _mobileService!.countHealthy();
    }
    // For desktop, return all connected count (no 403 filtering on PC)
    if (_profileManager != null) {
      return _profileManager!.countConnectedProfiles();
    }
    return 0;
  }
}
