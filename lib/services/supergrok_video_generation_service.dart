import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../services/log_service.dart';
import '../services/playwright_browser_service.dart';
import '../utils/config.dart';
import '../models/scene_data.dart';

/// Service for SuperGrok generation using Playwright Server for all browser tasks.
/// No more direct CDP — everything goes through the Playwright REST API.
class SuperGrokVideoGenerationService {
  static final SuperGrokVideoGenerationService _instance = SuperGrokVideoGenerationService._internal();
  factory SuperGrokVideoGenerationService() => _instance;
  SuperGrokVideoGenerationService._internal();

  bool _isRunning = false;
  bool _stopRequested = false;

  // Playwright server reference
  final PlaywrightBrowserService _pw = PlaywrightBrowserService();
  static const String _pwUrl = 'http://127.0.0.1:9321';
  static const int _browserPort = 9222;

  // Settings & State
  final Map<String, SceneData> _activeScenes = {};
  String? _currentOutputFolder;
  String _cookies = "";
  String? cookieStatus = 'ok';

  // --- Cookie Management ---
  void setCookies(String cookies) {
    _cookies = cookies;
    LogService().info('[SuperGrok] Cookies set manually (${cookies.length} chars)');
  }

  Future<void> refreshCookies() async {
    cookieStatus = 'loading';
    try {
      LogService().info('[SuperGrok] Fetching cookies via Playwright Server...');
      
      // Ensure Playwright server is running
      await _pw.ensureRunning();
      
      // Get cookies from the browser context
      final response = await http.get(
        Uri.parse('$_pwUrl/get-cookies?port=$_browserPort&urls=https://grok.com'),
      ).timeout(const Duration(seconds: 10));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final cookies = data['cookies'] as List? ?? [];
          final grokCookies = cookies.where((c) => c['domain'].toString().contains('grok.com'));
          _cookies = grokCookies.map((c) => "${c['name']}=${c['value']}").join('; ');
          
          LogService().info('[SuperGrok] Grok cookies: ${grokCookies.length}, string length: ${_cookies.length}');
          await _saveCookiesToDisk(_cookies);
          cookieStatus = 'ok';
          LogService().success('[SuperGrok] Cookies fetched successfully.');
        } else {
          cookieStatus = 'error';
          LogService().error('[SuperGrok] Cookie fetch: ${data['error']}');
        }
      } else {
        cookieStatus = 'error';
        LogService().error('[SuperGrok] Cookie fetch HTTP ${response.statusCode}');
      }
    } catch (e) {
      cookieStatus = 'error';
      LogService().error('[SuperGrok] Cookie fetch failed: $e');
    }
  }

  Future<void> _saveCookiesToDisk(String cookies) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(path.join(dir.path, "grok_cookies.json"));
      await file.writeAsString(cookies);
      if (await file.exists()) {
        final size = await file.length();
        LogService().success('[SuperGrok] Cookies saved (${size} bytes) at ${file.path}');
      }
    } catch (e) {
      LogService().error('[SuperGrok] Save Exception: $e');
    }
  }

  Future<void> _tryLoadCookies() async {
    if (_cookies.isNotEmpty) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(path.join(dir.path, "grok_cookies.json"));
      if (await file.exists()) {
        _cookies = await file.readAsString();
        LogService().info('[SuperGrok] Loaded cookies from stored file.');
      }
    } catch (_) {}
  }

  // --- Playwright Server Helpers ---

  /// POST to Playwright server
  Future<Map<String, dynamic>> _pwPost(String endpoint, Map<String, dynamic> body, {Duration? timeout}) async {
    try {
      final response = await http.post(
        Uri.parse('$_pwUrl$endpoint'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(timeout ?? const Duration(seconds: 120));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'success': false, 'error': 'HTTP ${response.statusCode}'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// GET from Playwright server
  Future<Map<String, dynamic>> _pwGet(String endpoint) async {
    try {
      final response = await http.get(
        Uri.parse('$_pwUrl$endpoint'),
      ).timeout(const Duration(seconds: 30));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return {'success': false, 'error': 'HTTP ${response.statusCode}'};
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Execute JS on a specific tab via Playwright (with retry for navigation context errors)
  Future<dynamic> _executeEval(String tabId, String expression, {int maxRetries = 3}) async {
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      final res = await _pwPost('/execute-js-tab', {
        'port': _browserPort,
        'tabId': tabId,
        'expression': expression,
      });
      
      if (res['success'] == true) {
        return res['value'];
      }
      
      final error = res['error']?.toString() ?? '';
      // Retry if context was destroyed (page was navigating)
      if (error.contains('context was destroyed') || error.contains('navigat')) {
        if (attempt < maxRetries) {
          LogService().info('[SuperGrok] JS context destroyed, retrying in 3s (attempt $attempt/$maxRetries)...');
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }
      }
      throw Exception('JS Execution Error: $error');
    }
    throw Exception('JS Execution Error: max retries exceeded');
  }

  /// Wait for a selector to appear
  Future<void> _waitForSelector(String tabId, String selector, {int timeout = 30000}) async {
    final res = await _pwPost('/wait-for-selector', {
      'port': _browserPort,
      'tabId': tabId,
      'selector': selector,
      'timeout': timeout,
    });
    
    if (res['success'] != true) {
      throw Exception('Timeout waiting for selector: $selector');
    }
  }

  /// Get URL of a specific tab
  Future<String?> _getTabUrl(String tabId) async {
    final res = await _pwGet('/get-url?port=$_browserPort&tabId=$tabId');
    if (res['success'] == true) {
      return res['url'] as String?;
    }
    return null;
  }

  /// Bring a tab to front
  Future<void> _bringToFront(String tabId) async {
    await _pwPost('/bring-to-front', {
      'port': _browserPort,
      'tabId': tabId,
    });
  }

  // --- Main Execution ---

  Future<void> startBatch(List<SceneData> scenes, {
    String model = 'grok-3',
    String aspectRatio = '16:9',
    String resolution = '720p',
    int videoLength = 6,
    String? outputFolder,
    int browserTabCount = 2,
    bool usePrompt = false,
  }) async {
    if (_isRunning) {
      LogService().error('[SuperGrok] Already running a batch.');
      return;
    }
    
    _isRunning = true;
    _stopRequested = false;
    _currentOutputFolder = outputFolder;
    _activeScenes.clear();

    final allBrowserTasks = <SceneData>[];

    for (final scene in scenes) {
      _activeScenes[scene.sceneId.toString()] = scene;
      scene.status = 'queued';
      scene.progress = 0;
      scene.error = null;

      if (scene.firstFramePath != null && scene.firstFramePath!.isNotEmpty) {
        if (await File(scene.firstFramePath!).exists()) {
           allBrowserTasks.add(scene);
        } else {
           LogService().add('[SuperGrok] Scene ${scene.sceneId} skipped broken image', type: 'WARNING');
           scene.status = 'failed';
           scene.error = 'Image file missing';
        }
      } else {
        allBrowserTasks.add(scene);
      }
    }

    LogService().info('[SuperGrok] Starting Batch: ${allBrowserTasks.length} tasks');

    try {
      // Ensure Playwright server is running
      await _pw.ensureRunning();

      // Connect to browser via Playwright (or launch if not running)
      if (!await _connectBrowser()) {
        throw Exception('Could not connect to Chrome via Playwright. Ensure Chrome is launched.');
      }

      // Run Batch via Playwright
      await _runBatch(
        allBrowserTasks,
        aspectRatio: aspectRatio,
        resolution: resolution,
        videoLength: videoLength,
        usePrompt: usePrompt,
        browserTabCount: browserTabCount
      );

    } catch (e) {
       LogService().error('[SuperGrok] Batch execution error: $e');
       for (var scene in allBrowserTasks) {
         if (scene.status != 'completed') {
           scene.status = 'failed';
           scene.error = e.toString();
         }
       }
    } finally {
      _isRunning = false;
    }
  }

  // --- Browser Connection via Playwright ---

  Future<bool> _connectBrowser() async {
    final profilePath = path.join(AppConfig.profilesDir, 'Browser_1');

    // Step 1: Check if browser is already tracked and alive
    final statusRes = await _pwGet('/status');
    if (statusRes['browsers'] != null) {
      final browsers = statusRes['browsers'] as List;
      final existing = browsers.where((b) => b['port'] == _browserPort).toList();
      
      if (existing.isNotEmpty) {
        final connected = existing.first['connected'] == true;
        if (connected) {
          // Verify it's actually alive by trying a health-check JS eval
          final testRes = await _pwPost('/execute-js', {
            'port': _browserPort,
            'expression': '1 + 1',
          });
          if (testRes['success'] == true) {
            LogService().success('[SuperGrok] Browser on port $_browserPort is alive');
            return true;
          }
        }
        
        // Stale reference — close it so we can re-launch cleanly
        LogService().info('[SuperGrok] Stale browser reference on port $_browserPort, clearing...');
        await _pwPost('/close', {'port': _browserPort});
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    // Step 2: Try connecting to a Chrome that might be running but not tracked
    var res = await _pwPost('/connect', {'port': _browserPort});
    if (res['success'] == true) {
      // Verify connection is actually alive
      final testRes = await _pwPost('/execute-js', {
        'port': _browserPort,
        'expression': '1 + 1',
      });
      if (testRes['success'] == true) {
        LogService().success('[SuperGrok] Connected to existing Chrome via Playwright');
        return true;
      }
      // Still stale, close and re-launch
      await _pwPost('/close', {'port': _browserPort});
      await Future.delayed(const Duration(seconds: 2));
    }

    // Step 3: Launch a fresh browser with the same profile as "Open No Login"
    LogService().info('[SuperGrok] Launching Chrome with profile: $profilePath');
    res = await _pwPost('/launch', {
      'port': _browserPort,
      'profilePath': profilePath,
      'url': 'https://grok.com/imagine',
      'headless': false,
    });

    if (res['success'] == true) {
      LogService().success('[SuperGrok] Chrome launched (PID: ${res['pid']}, profile: $profilePath)');
      // Wait for browser to be fully ready
      await Future.delayed(const Duration(seconds: 5));
      return true;
    }

    LogService().error('[SuperGrok] Failed to launch Chrome: ${res['error']}');
    return false;
  }

  // --- Batch Logic ---

  Future<void> _runBatch(
    List<SceneData> tasks, {
    required String aspectRatio,
    required String resolution,
    required int videoLength,
    required bool usePrompt,
    required int browserTabCount,
  }) async {
    final semaphore = _Semaphore(browserTabCount);
    final futures = <Future<void>>[];

    for (var task in tasks) {
      if (_stopRequested) break;
      futures.add(_runSingleTask(task, aspectRatio, resolution, videoLength, semaphore));
    }

    await Future.wait(futures);
  }

  Future<void> _runSingleTask(SceneData task, String aspectRatio, String resolution, int videoLength, _Semaphore semaphore) async {
    await semaphore.acquire();
    String? tabId;
    try {
      LogService().info('[SuperGrok] Processing Scene ${task.sceneId}...');
      
      // 1. Create a new tab via Playwright (returns stable tabId)
      final tabRes = await _pwPost('/new-tab', {
        'port': _browserPort,
        'url': 'https://grok.com/imagine',
      }, timeout: const Duration(seconds: 60));
      
      if (tabRes['success'] != true) {
        throw Exception('Failed to open new tab: ${tabRes['error']}');
      }
      tabId = tabRes['tabId'] as String;
      LogService().info('[SuperGrok] Scene ${task.sceneId} opened in $tabId');
      
      // Wait for page to fully settle before any JS execution
      await Future.delayed(const Duration(seconds: 5));
      
      try {
        await _processFlow(tabId, task, aspectRatio, resolution, videoLength);
      } finally {
        // Close the tab by its unique ID (won't affect other tabs)
        await _pwPost('/close-tab', {
          'port': _browserPort,
          'tabId': tabId,
        });
        LogService().info('[SuperGrok] Scene ${task.sceneId} tab closed.');
      }
      
    } catch (e) {
      LogService().error('[SuperGrok] Scene ${task.sceneId} failed: $e');
      task.status = 'failed';
      task.error = e.toString();
    } finally {
      semaphore.release();
    }
  }

  Future<void> _processFlow(String tabId, SceneData task, String aspectRatio, String resolution, int videoLength) async {
    task.status = 'generating';
    _updateProgress(task, 10);

    // Wait for page to load (60s — Grok pages can be slow)
    await _waitForSelector(tabId, '.ProseMirror', timeout: 60000);
    _updateProgress(task, 15);

    // --- Image Upload (I2V) ---
    if (task.firstFramePath != null && task.firstFramePath!.isNotEmpty) {
      LogService().info('[SuperGrok] Uploading image for Scene ${task.sceneId}: ${task.firstFramePath}');
      task.status = 'uploading';
      try {
        final absPath = File(task.firstFramePath!).absolute.path;
        final uploadRes = await _pwPost('/upload-file', {
          'port': _browserPort,
          'tabId': tabId,
          'selector': 'input[type="file"]',
          'filePath': absPath,
        });
        
        if (uploadRes['success'] != true) {
          throw Exception('Upload failed: ${uploadRes['error']}');
        }
        LogService().success('[SuperGrok] Image uploaded for Scene ${task.sceneId}');
        await Future.delayed(const Duration(seconds: 2));
      } catch (e) {
        LogService().error('[SuperGrok] Image upload failed for Scene ${task.sceneId}: $e');
        throw Exception('Image upload failed: $e');
      }
    }

    // 3. Apply Settings (Aspect Ratio, Resolution, Duration)
    await _applySettings(tabId, task, aspectRatio, resolution, videoLength);
    _updateProgress(task, 30);
    
    // 4. Paste Prompt
    LogService().info('[SuperGrok] Pasting prompt for Scene ${task.sceneId}...');
    final prompt = task.prompt ?? '';
    final escapedPrompt = prompt.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('\n', '\\n');
    await _executeEval(tabId, '''
      (() => {
        const text = '$escapedPrompt';
        const editor = document.querySelector('.ProseMirror');
        if (editor) {
          editor.focus();
          editor.innerHTML = '<p>' + text + '</p>';
          const events = ['input', 'change', 'compositionend', 'keyup', 'focus', 'blur'];
          events.forEach(type => {
            editor.dispatchEvent(new Event(type, { bubbles: true }));
          });
        }
      })()
    ''');
    
    await Future.delayed(const Duration(seconds: 1));
    _updateProgress(task, 40);

    // 5. Click Submit
    LogService().info('[SuperGrok] Submitting Scene ${task.sceneId}...');
    await _executeEval(tabId, '''
      (() => {
        const selector = 'button[aria-label="Submit"], button[aria-label="Make video"], button:has(path[d="M6 11L12 5M12 5L18 11M12 5V19"])';
        const btns = Array.from(document.querySelectorAll(selector));
        if (btns.length > 0) {
          const btn = btns[btns.length - 1];
          if (btn.disabled || btn.getAttribute('aria-disabled') === 'true') {
             const editor = document.querySelector('.ProseMirror');
             if (editor) editor.dispatchEvent(new Event('input', { bubbles: true }));
          }
          btn.click();
          return "clicked";
        }
        return "not_found";
      })()
    ''');
    
    await Future.delayed(const Duration(seconds: 1));
    
    // 6. Poll for URL change
    LogService().info('[SuperGrok] Waiting for post ID for Scene ${task.sceneId}...');
    String? postUrl;
    for (int i = 0; i < 90; i++) {
       final url = await _getTabUrl(tabId);
       if (url != null && url.contains('/post/')) {
         postUrl = url;
         break;
       }
       if (i % 20 == 0 && i > 0) {
          await _bringToFront(tabId);
       }
       if (i % 15 == 0 && i > 0) {
          LogService().info('[SuperGrok] Retry click for Scene ${task.sceneId}...');
          try {
            await _executeEval(tabId, '(() => { const b = document.querySelector(\'button[aria-label="Submit"], button[aria-label="Make video"]\'); if(b) b.click(); })()');
          } catch (_) {}
       }
       await Future.delayed(const Duration(seconds: 2));
    }
    
    if (postUrl == null) {
      throw Exception('Generation redirect timeout: Still on /imagine.');
    }
    
    _updateProgress(task, 60);
    LogService().info('[SuperGrok] Scene ${task.sceneId} generating at $postUrl');

    // 7. Wait for Video URL and Download
    LogService().info('[SuperGrok] Waiting for video URL for Scene ${task.sceneId}...');
    String? videoSrc;
    for (int i = 0; i < 240; i++) {
       videoSrc = await _executeEval(tabId, '''
         (() => {
           const v = document.querySelector('video');
           if (!v) return null;
           const s = v.currentSrc || v.src;
           return (s && s.includes('assets.grok.com')) ? s : null;
         })()
       ''');
       
       if (videoSrc != null) {
         LogService().info('[SuperGrok] Video source detected: $videoSrc');
         break;
       }
       
       if (i % 15 == 0 && i > 0) {
          await _bringToFront(tabId);
       }
       
       if (_stopRequested) throw Exception('User cancelled');
       await Future.delayed(const Duration(seconds: 1));
    }

    if (videoSrc == null) {
      throw Exception('Video URL not found after 240s');
    }

    // 8. Download video
    task.status = 'downloading';
    _updateProgress(task, 95);
    
    try {
      // Get cookies from context for download auth
      final cookieRes = await _pwGet('/get-cookies?port=$_browserPort&urls=${Uri.encodeComponent(videoSrc!)}');
      String cookieHeader = '';
      if (cookieRes['success'] == true) {
        final cookies = cookieRes['cookies'] as List? ?? [];
        cookieHeader = cookies.map((c) => "${c['name']}=${c['value']}").join('; ');
      }
      
      // Get user agent
      final ua = await _executeEval(tabId, 'navigator.userAgent');
      
      LogService().info('[SuperGrok] Downloading Scene ${task.sceneId}...');
      
      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(videoSrc));
      
      if (cookieHeader.isNotEmpty) {
        request.headers.add('Cookie', cookieHeader);
      }
      request.headers.add('User-Agent', ua ?? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36');
      request.headers.add('Referer', 'https://grok.com/');
      
      final response = await request.close();
      if (response.statusCode != 200) {
        throw Exception('Download failed with status: ${response.statusCode}');
      }
      
      final filename = 't2v_scene_${task.sceneId}_${DateTime.now().millisecondsSinceEpoch}.mp4';
      final savePath = path.join(_currentOutputFolder ?? Directory.current.path, filename);
      
      final file = File(savePath);
      final sink = file.openWrite();
      await sink.addStream(response);
      await sink.close();
      
      task.status = 'completed';
      task.videoPath = savePath;
      _updateProgress(task, 100);
      LogService().success('[SuperGrok] Scene ${task.sceneId} completed: $filename (${await file.length()} bytes)');
      
    } catch (e) {
      LogService().error('[SuperGrok] Download failed for Scene ${task.sceneId}: $e');
      throw Exception('Video download failed: $e');
    }
  }

  Future<void> _applySettings(String tabId, SceneData task, String aspectRatio, String resolution, int duration) async {
    LogService().info('[SuperGrok] Applying settings for Scene ${task.sceneId}...');
    final durStr = '${duration}s';
    final escapedAr = aspectRatio.replaceAll("'", "\\'");
    final escapedRes = resolution.replaceAll("'", "\\'");
    final escapedDur = durStr.replaceAll("'", "\\'");
    
    await _executeEval(tabId, '''
      (async () => {
        const sleep = (ms) => new Promise(r => setTimeout(r, ms));
        
        let settingsBtn = document.querySelector('button[aria-label="Settings"]');
        if (settingsBtn) {
          settingsBtn.click();
          await sleep(500);
          
          const videoBtn = Array.from(document.querySelectorAll('button')).find(b => b.innerText.includes('Video'));
          if (videoBtn) {
            videoBtn.click();
            await sleep(300);
          }
          
          const clickByText = (text) => {
            const btn = Array.from(document.querySelectorAll('button')).find(b => b.innerText.trim() === text);
            if (btn) btn.click();
          };
          
          clickByText('$escapedAr');
          await sleep(300);
          clickByText('$escapedRes');
          await sleep(300);
          clickByText('$escapedDur');
          await sleep(300);
          
          await sleep(1000);
          settingsBtn.click();
        }
      })()
    ''');
  }

  void _updateProgress(SceneData task, int progress) {
    task.progress = progress;
    _notifyUpdate(task);
  }

  void _notifyUpdate(SceneData scene) {
    LogService().info('[SuperGrok] Scene ${scene.sceneId}: ${scene.status} (${scene.progress}%) ${scene.error ?? ""}');
  }

  Future<void> _downloadVideo(SceneData scene, String url) async {
    // Handled inline in _processFlow
  }

  void stop() async {
    _stopRequested = true;
    _isRunning = false;
    LogService().info('[SuperGrok] Stop requested. Current tasks will wind down.');
  }

  void cancelTask(String taskId) async {
    // Task level cancellation — tabs are closed when tasks finish
  }
}

// --- Internal Helper Classes ---

class _Semaphore {
  final int max;
  int _current = 0;
  final List<Completer<void>> _waiters = [];

  _Semaphore(this.max);

  Future<void> acquire() async {
    if (_current < max) {
      _current++;
      return;
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      waiter.complete();
    } else {
      _current--;
    }
  }
}

// Minimal UUID Utils
class UuidUtils {
  static String generateUuid() {
    final r = Random();
    return List.generate(16, (i) => r.nextInt(16).toRadixString(16)).join();
  }
}
