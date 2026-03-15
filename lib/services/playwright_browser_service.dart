import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Service that communicates with the Playwright server
/// to control Chrome browsers smoothly without CDP freezing.
///
/// The Flutter app calls this service instead of raw CDP.
/// The Playwright server handles all browser interactions internally.
///
/// Auto-starts the server on first use — no manual server start needed.
class PlaywrightBrowserService {
  static final PlaywrightBrowserService _instance = PlaywrightBrowserService._internal();
  factory PlaywrightBrowserService() => _instance;
  PlaywrightBrowserService._internal();

  String _serverUrl = 'http://127.0.0.1:9321';
  Process? _serverProcess;
  bool _isServerRunning = false;
  bool _isStarting = false;
  Completer<bool>? _startCompleter;

  /// Check if Playwright server is running
  bool get isRunning => _isServerRunning;

  /// Set server URL (default: http://127.0.0.1:9321)
  void setServerUrl(String url) {
    _serverUrl = url;
  }

  // ══════════════════════════════════════════════════════════════
  // Server Lifecycle
  // ══════════════════════════════════════════════════════════════

  /// Ensure the server is running (auto-start if needed).
  /// Safe to call from multiple places — only starts once.
  Future<bool> ensureRunning() async {
    if (_isServerRunning) return true;
    
    // If already starting, wait for it
    if (_isStarting && _startCompleter != null) {
      return _startCompleter!.future;
    }
    
    return await startServer();
  }

  /// Start the Playwright browser server as a subprocess
  Future<bool> startServer() async {
    if (_isServerRunning) return true;
    if (_isStarting) {
      if (_startCompleter != null) return _startCompleter!.future;
    }
    
    _isStarting = true;
    _startCompleter = Completer<bool>();

    try {
      // STEP 0: Kill any leftover server processes from previous app run
      // This prevents port conflicts if app was closed without proper cleanup
      print('[BrowserService] Killing any leftover server processes from previous run...');
      await killAllServerProcesses();
      // Brief delay to allow ports to be freed
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Check if server is already running externally (unlikely after kill, but just in case)
      if (await healthCheck()) {
        _isServerRunning = true;
        _isStarting = false;
        _startCompleter?.complete(true);
        print('[BrowserService] Server already running at $_serverUrl');
        return true;
      }

      // Find the playwright_server executable
      final scriptPath = _findServerScript();
      if (scriptPath == null) {
        print('[BrowserService] [FAIL] playwright_server exe not found!');
        print('[BrowserService] Searched in: exe dir, current dir, dist/, playwright_server/');
        _isStarting = false;
        _startCompleter?.complete(false);
        return false;
      }

      print('[Playwright] Starting server from: $scriptPath');
      
      // Launch server
      if (Platform.isWindows) {
        bool launched = false;
        
        // Strategy 1: PowerShell Start-Process -WindowStyle Hidden (truly hidden)
        try {
          final result = await Process.run(
            'powershell',
            ['-NoProfile', '-Command', 'Start-Process', '-FilePath', '"$scriptPath"', '-WindowStyle', 'Hidden'],
            runInShell: false,
          );
          if (result.exitCode == 0) {
            print('[Playwright] ✓ Server launched hidden via PowerShell Start-Process');
            launched = true;
          } else {
            print('[Playwright] PowerShell launch returned exit code: ${result.exitCode}');
          }
        } catch (e) {
          print('[Playwright] PowerShell launch error: $e');
        }
        
        // Strategy 2: Direct Process.start detached (fallback)
        if (!launched) {
          try {
            _serverProcess = await Process.start(
              scriptPath, [],
              mode: ProcessStartMode.detached,
            );
            print('[Playwright] ✓ Server launched via Process.start detached (PID: ${_serverProcess!.pid})');
            launched = true;
          } catch (e) {
            print('[Playwright] Process.start fallback error: $e');
          }
        }
        
        if (!launched) {
          print('[Playwright] [FAIL] All launch strategies failed');
          _isStarting = false;
          _startCompleter?.complete(false);
          return false;
        }
      } else {
        // On macOS/Linux
        _serverProcess = await Process.start(
          scriptPath, [],
          mode: ProcessStartMode.detachedWithStdio,
        );
        _serverProcess!.stdout.transform(const SystemEncoding().decoder).listen(
          (data) => print('[SE-Server] $data'),
        );
        _serverProcess!.stderr.transform(const SystemEncoding().decoder).listen(
          (data) => print('[SE-Server ERR] $data'),
        );
      }

      // Wait for server to be ready (max 20 seconds)
      for (int i = 0; i < 40; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (await healthCheck()) {
          _isServerRunning = true;
          _isStarting = false;
          _startCompleter?.complete(true);
          print('[Playwright] [OK] Server started successfully (took ${(i + 1) * 500}ms)');
          return true;
        }
      }

      print('[Playwright] [FAIL] Server failed to start within 20s');
      _isStarting = false;
      _startCompleter?.complete(false);
      return false;
    } catch (e) {
      print('[Playwright] [FAIL] Error starting server: $e');
      _isStarting = false;
      _startCompleter?.complete(false);
      return false;
    }
  }
  
  /// Start the server in the background (fire-and-forget).
  /// Call this early (e.g. when app opens) so the server is ready
  /// by the time browsers are needed.
  void startServerInBackground() {
    if (_isServerRunning || _isStarting) return;
    print('[Playwright] Starting server in background...');
    // Don't await — let it start while the app does other things
    startServer().then((success) {
      if (success) {
        print('[Playwright] [OK] Background server start complete');
      } else {
        print('[Playwright] [WARN] Background server start failed');
      }
    });
  }

  /// Stop the Playwright browser server
  Future<void> stopServer() async {
    // Strategy 1: Try graceful HTTP shutdown
    try {
      await http.post(
        Uri.parse('$_serverUrl/shutdown'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 2));
      print('[Playwright] Server shutdown via HTTP');
    } catch (_) {}

    // Strategy 2: Kill via process handle
    if (_serverProcess != null) {
      try {
        _serverProcess!.kill(ProcessSignal.sigterm);
        _serverProcess!.kill(ProcessSignal.sigkill);
      } catch (_) {}
      _serverProcess = null;
    }
    
    // Strategy 3: Force kill by process name (catches detached processes)
    // Kill BOTH server executables to ensure clean state when switching modes
    if (Platform.isWindows) {
      for (final exeName in ['selenium_server.exe', 'playwright_server.exe']) {
        try {
          await Process.run('taskkill', ['/F', '/IM', exeName], runInShell: true);
          print('[BrowserService] Server killed via taskkill: $exeName');
        } catch (_) {}
      }
    } else {
      for (final name in ['selenium_server', 'playwright_server']) {
        try {
          await Process.run('pkill', ['-f', name]);
        } catch (_) {}
      }
    }
    
    _isServerRunning = false;
    _isStarting = false;
  }

  /// Force-kill ALL server processes (both playwright_server.exe and selenium_server.exe)
  /// Call this on app close to prevent zombie processes on next run.
  static Future<void> killAllServerProcesses() async {
    if (Platform.isWindows) {
      // Kill both server executables
      for (final exeName in ['selenium_server.exe', 'playwright_server.exe']) {
        try {
          await Process.run('taskkill', ['/F', '/IM', exeName], runInShell: true);
          print('[BrowserService] Killed $exeName via taskkill');
        } catch (_) {}
      }
    } else {
      for (final name in ['selenium_server', 'playwright_server']) {
        try {
          await Process.run('pkill', ['-f', name]);
        } catch (_) {}
      }
    }
  }

  /// Health check
  Future<bool> healthCheck() async {
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl/health'),
      ).timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        _isServerRunning = true;
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Browser Management
  // ══════════════════════════════════════════════════════════════

  /// Launch a Chrome browser via Playwright server
  Future<Map<String, dynamic>> launchBrowser({
    int port = 9222,
    String profilePath = '',
    String url = 'https://labs.google/fx/tools/flow',
    bool headless = false,
  }) async {
    await ensureRunning();
    return await _post('/launch', {
      'port': port,
      'profilePath': profilePath,
      'url': url,
      'headless': headless,
    });
  }

  /// Launch multiple browsers with staggering
  Future<Map<String, dynamic>> launchMultiple({
    int count = 1,
    int basePort = 9222,
    String baseProfilePath = '',
    bool headless = false,
    int staggerSeconds = 3,
  }) async {
    await ensureRunning();
    return await _post('/launch-multi', {
      'count': count,
      'basePort': basePort,
      'baseProfilePath': baseProfilePath,
      'headless': headless,
      'staggerSeconds': staggerSeconds,
    });
  }

  /// Connect to an already-running Chrome browser
  Future<Map<String, dynamic>> connectBrowser({int port = 9222}) async {
    await ensureRunning();
    return await _post('/connect', {'port': port});
  }

  /// Close a browser
  Future<Map<String, dynamic>> closeBrowser({int port = 9222}) async {
    return await _post('/close', {'port': port});
  }

  /// Close all browsers
  Future<Map<String, dynamic>> closeAll() async {
    return await _post('/close-all', {});
  }

  // ══════════════════════════════════════════════════════════════
  // Login
  // ══════════════════════════════════════════════════════════════

  /// Login a single browser via Playwright (smooth, no CDP from Dart)
  Future<Map<String, dynamic>> login({
    int port = 9222,
    required String email,
    required String password,
  }) async {
    await ensureRunning();
    return await _post('/login', {
      'port': port,
      'email': email,
      'password': password,
    }, timeout: const Duration(seconds: 120));
  }

  /// Login multiple browsers
  Future<Map<String, dynamic>> loginMultiple({
    int count = 1,
    int basePort = 9222,
    required String email,
    required String password,
  }) async {
    await ensureRunning();
    return await _post('/login-multi', {
      'count': count,
      'basePort': basePort,
      'email': email,
      'password': password,
    }, timeout: const Duration(seconds: 300));
  }

  // ══════════════════════════════════════════════════════════════
  // Tokens
  // ══════════════════════════════════════════════════════════════

  /// Get access token from browser session
  Future<String?> getAccessToken({int port = 9222}) async {
    try {
      await ensureRunning();
      final result = await _get('/token?port=$port');
      if (result['success'] == true) {
        return result['token'] as String?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get reCAPTCHA token from browser (for video generation)
  Future<String?> getRecaptchaToken({int port = 9222}) async {
    try {
      await ensureRunning();
      final result = await _get('/recaptcha?port=$port');
      if (result['success'] == true) {
        return result['token'] as String?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Get reCAPTCHA token for IMAGE generation (action=IMAGE_GENERATION)
  Future<String?> getImageRecaptchaToken({int port = 9222}) async {
    try {
      await ensureRunning();
      final result = await _get('/recaptcha-image?port=$port');
      if (result['success'] == true) {
        return result['token'] as String?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// Execute JavaScript in a browser page via Playwright
  /// Uses Playwright's evaluate() which is smooth and non-blocking
  Future<dynamic> executeJs({int port = 9222, required String expression}) async {
    try {
      await ensureRunning();
      final result = await _post('/execute-js', {
        'port': port,
        'expression': expression,
      }, timeout: const Duration(seconds: 30));
      if (result['success'] == true) {
        return result['value'];
      }
      return null;
    } catch (e) {
      print('[Playwright] executeJs error: $e');
      return null;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Navigation
  // ══════════════════════════════════════════════════════════════

  /// Navigate browser to URL
  Future<Map<String, dynamic>> navigate({
    int port = 9222,
    required String url,
  }) async {
    await ensureRunning();
    return await _post('/navigate', {'port': port, 'url': url},
        timeout: const Duration(seconds: 45));
  }

  /// Refresh browser page
  Future<Map<String, dynamic>> refresh({int port = 9222}) async {
    return await _post('/refresh', {'port': port});
  }

  // ══════════════════════════════════════════════════════════════
  // Status
  // ══════════════════════════════════════════════════════════════

  /// Get all browser statuses
  Future<List<Map<String, dynamic>>> getStatus() async {
    try {
      final result = await _get('/status');
      final browsers = result['browsers'] as List? ?? [];
      return browsers.cast<Map<String, dynamic>>();
    } catch (e) {
      return [];
    }
  }

  // ══════════════════════════════════════════════════════════════
  // Internal HTTP helpers
  // ══════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    try {
      final response = await http.post(
        Uri.parse('$_serverUrl$path'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(timeout ?? const Duration(seconds: 60));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        return {'success': false, 'error': 'HTTP ${response.statusCode}: ${response.body}'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _get(String path) async {
    try {
      final response = await http.get(
        Uri.parse('$_serverUrl$path'),
      ).timeout(const Duration(seconds: 30));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else {
        return {'success': false, 'error': 'HTTP ${response.statusCode}'};
      }
    } catch (e) {
      return {'success': false, 'error': e.toString()};
    }
  }


  /// Find the playwright_server executable
  String? _findServerScript() {
    final sep = Platform.pathSeparator;
    final dirName = 'playwright_server';
    
    // Determine platform-specific executable names
    final exeNames = <String>[];
    if (Platform.isWindows) {
      exeNames.add('playwright_server.exe');
    } else if (Platform.isMacOS) {
      // Auto-detect architecture: arm64 (Apple Silicon) vs x86_64 (Intel)
      String arch = 'arm64'; // default to ARM64 for modern Macs
      try {
        final result = Process.runSync('uname', ['-m']);
        arch = result.stdout.toString().trim();
        print('[BrowserService] macOS architecture detected: $arch');
      } catch (e) {
        print('[BrowserService] Could not detect arch, defaulting to arm64: $e');
      }

      if (arch == 'arm64') {
        // Apple Silicon: try ARM64 first, then x64 (Rosetta 2 can run x64)
        exeNames.add('playwright_server_macos_arm64');
        exeNames.add('playwright_server_macos_x64');
      } else {
        // Intel: try x64 first, then ARM64 won't work on Intel
        exeNames.add('playwright_server_macos_x64');
      }
      exeNames.add('playwright_server'); // generic fallback
    } else {
      exeNames.add('playwright_server');
    }
    
    print('[BrowserService] Looking for Playwright server: $exeNames');
    
    final candidates = <String>[];
    
    for (final exeName in exeNames) {
      // 1. Next to the running executable
      try {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        candidates.add('$exeDir$sep$dirName$sep$exeName');
        candidates.add('$exeDir$sep$exeName');
        
        // On macOS, also look in Resources/ within the .app bundle
        if (Platform.isMacOS) {
          final bundleDir = File(Platform.resolvedExecutable).parent.parent.path;
          candidates.add('$bundleDir${sep}Resources$sep$dirName$sep$exeName');
          candidates.add('$bundleDir${sep}Resources$sep$exeName');
        }
      } catch (_) {}
      
      // 2. Current working directory / build paths
      candidates.add('$dirName${sep}dist$sep$exeName');
      candidates.add('$dirName$sep$exeName');
      candidates.add('dist$sep$dirName$sep$exeName');
      candidates.add('dist$sep$exeName');
      candidates.add(exeName);
      
      // 3. Common install locations
      if (Platform.isWindows) {
        final appData = Platform.environment['LOCALAPPDATA'] ?? '';
        if (appData.isNotEmpty) {
          candidates.add('$appData\\VEO3_Infinity\\$dirName\\$exeName');
          candidates.add('$appData\\VEO3 Infinity\\$dirName\\$exeName');
          candidates.add('$appData\\VEO3_Infinity\\$exeName');
        }
      } else if (Platform.isMacOS) {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          candidates.add('$home/Library/Application Support/VEO3_Infinity/$dirName/$exeName');
          candidates.add('$home/Library/Application Support/VEO3_Infinity/$exeName');
        }
        candidates.add('/Applications/VEO3_Infinity.app/Contents/MacOS/$dirName/$exeName');
        candidates.add('/Applications/VEO3_Infinity.app/Contents/Resources/$dirName/$exeName');
      }
    }
    
    for (final path in candidates) {
      if (File(path).existsSync()) {
        print('[BrowserService] Found server at: $path');
        return path;
      }
    }
    
    return null;
  }
}
