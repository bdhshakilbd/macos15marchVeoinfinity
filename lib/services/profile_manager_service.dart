import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'video_generation_service.dart';
import 'settings_service.dart';
import 'playwright_browser_service.dart';
import '../utils/browser_utils.dart';
import '../utils/win32_api.dart';
import '../utils/config.dart';

/// Status of a Chrome profile/browser instance
enum ProfileStatus {
  disconnected,
  launching,
  connected,
  relogging,
  error,
}

/// Represents a Chrome profile/browser instance for multi-profile video generation
class ChromeProfile {
  final String name;
  final String profilePath;
  final int debugPort;

  ProfileStatus status;
  DesktopGenerator? generator;
  String? accessToken;
  int consecutive403Count;
   Process? chromeProcess;
  int? chromePid; // PID for headless processes launched via PowerShell
  bool headless = false; // Track if browser was launched in headless mode
  
  // Track if browser has been refreshed this session (to prevent infinite refresh loops)
  bool browserRefreshedThisSession = false;

  ChromeProfile({
    required this.name,
    required this.profilePath,
    required this.debugPort,
    this.status = ProfileStatus.disconnected,
    this.consecutive403Count = 0,
    this.activeTasks = 0,
  });

  int activeTasks;

  bool get isConnected => status == ProfileStatus.connected;
  bool get isAvailable => status == ProfileStatus.connected && accessToken != null && status != ProfileStatus.relogging && consecutive403Count < 5;

  @override
  String toString() => 'ChromeProfile($name, port: $debugPort, status: $status, 403: $consecutive403Count/5)';
}

/// Manages multiple Chrome profiles for concurrent video generation
class ProfileManagerService {
  final List<ChromeProfile> profiles = [];
  final String profilesDirectory;
  final int baseDebugPort;
  int _currentBrowserIndex = 0;
  
  ProfileManagerService({
    required this.profilesDirectory,
    this.baseDebugPort = 9222,
  }) {
    // Ensure profiles directory exists
    final dir = Directory(profilesDirectory);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
  }

  /// Create a new Chrome profile directory
  Future<bool> createProfile(String name) async {
    try {
      final profilePath = path.join(profilesDirectory, name);
      final dir = Directory(profilePath);

      if (dir.existsSync()) {
        print('[ProfileManager] Profile "$name" already exists');
        return false;
      }

      dir.createSync(recursive: true);
      print('[ProfileManager] ✓ Created profile: $name at $profilePath');
      return true;
    } catch (e) {
      print('[ProfileManager] ✗ Error creating profile "$name": $e');
      return false;
    }
  }

  /// Launch Chrome with the specified profile
  /// Applies AMD Ryzen optimizations automatically
  Future<bool> launchProfile(
    ChromeProfile profile, {
    String url = 'https://labs.google/fx/tools/flow',
    bool headless = false,
  }) async {
    try {
      profile.status = ProfileStatus.launching;
      print('[ProfileManager] Launching ${profile.name} on port ${profile.debugPort}...');

      // Ensure profile directory exists
      final dir = Directory(profile.profilePath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      // Find Chrome executable
      final chromePath = await _findChromeExecutable();
      if (chromePath == null) {
        print('[ProfileManager] ✗ Chrome executable not found');
        profile.status = ProfileStatus.error;
        return false;
      }

      // AMD Ryzen optimization: Prevent CPU throttling before launching browsers
      // This is done once per launch session to set the power plan appropriately
      await BrowserUtils.preventCpuThrottling();

      // Launch Chrome with remote debugging (includes AMD Ryzen optimized args)
       final args = BrowserUtils.getChromeArgs(
        debugPort: profile.debugPort,
        profilePath: profile.profilePath,
        url: url,
        headless: headless,
      );
      
      profile.headless = headless; // Save for nuclear clear restarts

      if (headless && Platform.isWindows) {
        // ═══════════════════════════════════════════════════════════
        // HEADLESS: Launch Chrome directly and hide window via Win32 FFI
        // No PowerShell needed — uses native user32.dll calls.
        // ═══════════════════════════════════════════════════════════
        
        profile.chromeProcess = await Process.start(chromePath, args);
        final chromePid = profile.chromeProcess!.pid;
        profile.chromePid = chromePid;
        print('[ProfileManager] ✓ Chrome launched for ${profile.name} (PID: $chromePid), hiding window...');
        
        // Hide the window using native Win32 API (no PowerShell)
        // This waits for the Chrome window to appear then hides it
        unawaited(Win32Api.hideAllChromeWindows(chromePid).then((hidden) {
          if (hidden > 0) {
            print('[ProfileManager] ✓ Chrome window hidden for ${profile.name} (native FFI)');
          }
        }));
        
        await Future.wait([
          Future.delayed(const Duration(seconds: 5)),
          BrowserUtils.setHighPerformanceAffinity(chromePid),
        ]);
        
      } else {
        // NORMAL GUI LAUNCH
        profile.chromeProcess = await Process.start(chromePath, args);
        print('[ProfileManager] ✓ Chrome launched for ${profile.name}');

        if (Platform.isWindows) {
          final profileIndex = profile.debugPort - baseDebugPort;
          await BrowserUtils.forceAlwaysOnTop(
            profile.chromeProcess!.pid,
            width: 800,
            height: 600,
            offsetIndex: profileIndex,
          );
          await BrowserUtils.setHighPerformanceAffinity(profile.chromeProcess!.pid);
        }
        await Future.delayed(const Duration(seconds: 5));
      }



      // Verify Chrome is responding
      final isReady = await _waitForChromeReady(profile.debugPort);
      if (!isReady) {
        print('[ProfileManager] ✗ Chrome not responding on port ${profile.debugPort}');
        profile.status = ProfileStatus.error;
        return false;
      }

      print('[ProfileManager] ✓ Chrome ready for ${profile.name}');
      
      profile.status = ProfileStatus.connected;
      return true;
    } catch (e) {
      print('[ProfileManager] ✗ Error launching ${profile.name}: $e');
      profile.status = ProfileStatus.error;
      return false;
    }
  }

  /// Connect to an already-running Chrome instance via Playwright
  Future<bool> connectToProfile(ChromeProfile profile) async {
    try {
      print('[ProfileManager] Connecting to ${profile.name} on port ${profile.debugPort} via Playwright...');
      
      final pw = PlaywrightBrowserService();
      await pw.ensureRunning();
      
      // Connect Playwright to this browser
      final result = await pw.connectBrowser(port: profile.debugPort);
      if (result['success'] != true && result['already_connected'] != true) {
        print('[ProfileManager] ✗ Playwright could not connect to port ${profile.debugPort}');
        profile.status = ProfileStatus.disconnected;
        return false;
      }
      
      // Create generator for HTTP operations (generateVideo, pollVideo, etc.)
      final generator = DesktopGenerator(debugPort: profile.debugPort);
      generator.close(); // No CDP needed
      await generator.connect(); // This now just calls Playwright
      profile.generator = generator;

      // Try to get access token via Playwright
      String? token;
      for (int attempts = 0; attempts < 4; attempts++) {
        await Future.delayed(const Duration(seconds: 2));
        try {
          token = await pw.getAccessToken(port: profile.debugPort);
          if (token != null && token.isNotEmpty) break;
        } catch (e) {
          print('[ProfileManager] Token check attempt ${attempts + 1}: $e');
        }
      }

      profile.accessToken = token;
      profile.status = token != null ? ProfileStatus.connected : ProfileStatus.disconnected;

      if (token != null) {
        print('[ProfileManager] ✓ Connected to ${profile.name} with token');
        return true;
      } else {
        print('[ProfileManager] ✗ Connected to ${profile.name} but no token found');
        return false;
      }
    } catch (e) {
      print('[ProfileManager] ✗ Error connecting to ${profile.name}: $e');
      profile.status = ProfileStatus.error;
      return false;
    }
  }

  /// Connect to a profile's Chrome instance WITHOUT waiting for token
  /// Used for auto-login where token will be obtained after login
  Future<bool> connectToProfileWithoutToken(ChromeProfile profile) async {
    try {
      print('[ProfileManager] Connecting to ${profile.name} on port ${profile.debugPort} (no token)...');
      
      final pw = PlaywrightBrowserService();
      await pw.ensureRunning();
      
      // Connect Playwright to this browser
      final result = await pw.connectBrowser(port: profile.debugPort);
      if (result['success'] != true && result['already_connected'] != true) {
        print('[ProfileManager] ✗ Playwright could not connect to port ${profile.debugPort}');
        profile.status = ProfileStatus.disconnected;
        return false;
      }
      
      // Create generator for HTTP operations
      final generator = DesktopGenerator(debugPort: profile.debugPort);
      await generator.connect();
      profile.generator = generator;
      profile.status = ProfileStatus.disconnected; // Will be updated after login
      print('[ProfileManager] ✓ Connected to ${profile.name} via Playwright (ready for login)');
      return true;
    } catch (e) {
      print('[ProfileManager] ✗ Error connecting to ${profile.name}: $e');
      profile.status = ProfileStatus.error;
      return false;
    }
  }

  /// Get next available profile using round-robin selection
  ChromeProfile? getNextAvailableProfile() {
    if (profiles.isEmpty) return null;

    // Try to find a connected profile starting from current index
    for (var i = 0; i < profiles.length; i++) {
      final idx = (_currentBrowserIndex + i) % profiles.length;
      final profile = profiles[idx];

      // CRITICAL: Skip profiles that are relogging
      if (profile.status == ProfileStatus.relogging) {
        continue; // Don't use this profile - it's being relogged
      }

      if (profile.isAvailable) {
        _currentBrowserIndex = (idx + 1) % profiles.length;
        return profile;
      }
    }

    return null; // No available profiles
  }

  /// Check if any profile is connected and available
  bool hasAnyConnectedProfile() {
    return profiles.any((p) => p.isAvailable);
  }

  /// Count connected profiles
  int countConnectedProfiles() {
    return profiles.where((p) => p.isConnected).length;
  }

  /// Kill all launched Chrome profiles managed by this service
  Future<void> killAllProfiles() async {
    print('[ProfileManager] ============================');
    print('[ProfileManager] KILLING ALL MANAGED PROFILES');
    print('[ProfileManager] ============================');
    for (final profile in profiles) {
      try {
        if (profile.chromeProcess != null) {
          print('[ProfileManager] Killing ${profile.name} (PID: ${profile.chromeProcess!.pid})...');
          profile.chromeProcess!.kill();
          profile.chromeProcess = null;
        } else if (profile.chromePid != null) {
          // Headless launched via PowerShell — kill by PID
          print('[ProfileManager] Killing hidden ${profile.name} (PID: ${profile.chromePid})...');
          Process.killPid(profile.chromePid!);
          profile.chromePid = null;
        }
        profile.generator?.close();
        profile.generator = null;
        profile.status = ProfileStatus.disconnected;
      } catch (e) {
        print('[ProfileManager] Error killing ${profile.name}: $e');
      }
    }
    // Also kill ALL chrome.exe processes bound to our debug ports (headless ones)
    await killAllChromeProcesses();
    print('[ProfileManager] ✓ All profiles killed');
  }

  /// Kill ALL chrome.exe processes that are using our debug ports (9222-9232)
  /// This handles headless Chrome instances that may not be tracked by chromeProcess
  /// Uses native Dart Process.killPid — no PowerShell needed.
  static Future<void> killAllChromeProcesses() async {
    if (!Platform.isWindows) {
      // On Linux/Mac, use pkill
      for (int port = 9222; port <= 9232; port++) {
        await Process.run('pkill', ['-f', 'remote-debugging-port=$port'])
            .catchError((_) => ProcessResult(0, 0, '', ''));
      }
      return;
    }
    try {
      int killed = 0;
      // Check each debug port for a running Chrome instance
      for (int port = 9222; port <= 9232; port++) {
        try {
          // Try to connect to the debug port to see if Chrome is running
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 1);
          final request = await client.getUrl(Uri.parse('http://localhost:$port/json/version'));
          final response = await request.close().timeout(const Duration(seconds: 2));
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body) as Map<String, dynamic>;
          
          // Extract PID from the webSocketDebuggerUrl or Browser field
          // Chrome is running on this port — try to find its PID
          final wsUrl = data['webSocketDebuggerUrl'] as String?;
          if (wsUrl != null) {
            // Connect and get the browser's PID via CDP
            try {
              final ws = await WebSocket.connect(wsUrl);
              ws.add(json.encode({'id': 1, 'method': 'SystemInfo.getProcessInfo'}));
              // Just close the browser via CDP
              ws.add(json.encode({'id': 2, 'method': 'Browser.close'}));
              await Future.delayed(const Duration(milliseconds: 500));
              await ws.close();
              killed++;
              print('[ProfileManager] Closed Chrome on port $port via CDP');
            } catch (e) {
              print('[ProfileManager] Could not close Chrome on port $port via CDP: $e');
            }
          }
          client.close();
        } catch (_) {
          // Port not responding — no Chrome here
        }
      }
      print('[ProfileManager] Total killed: $killed');
    } catch (e) {
      print('[ProfileManager] Error killing Chrome processes: $e');
    }
  }

  /// COMPLETELY wipes a profile folder (nuclear clear)
  /// kills the browser first if it is running
  Future<void> nuclearClearProfileData(ChromeProfile profile) async {
    print('[ProfileManager] NUCLEAR CLEAR for ${profile.name}...');
    
    // 1. Ensure browser is killed
    try {
      if (profile.chromeProcess != null) {
        profile.chromeProcess!.kill();
        profile.chromeProcess = null;
      } else if (profile.chromePid != null) {
        Process.killPid(profile.chromePid!);
        profile.chromePid = null;
      }
      
      // Secondary check - kill any process on its port
      await _killAnyProcessOnPort(profile.debugPort);
      
      profile.generator?.close();
      profile.generator = null;
      profile.status = ProfileStatus.disconnected;
    } catch (e) {
      print('[ProfileManager] Warning during kill for nuclear clear: $e');
    }

    await Future.delayed(const Duration(milliseconds: 1500));

    // 2. Delete the directory
    final dir = Directory(profile.profilePath);
    if (dir.existsSync()) {
      try {
        // Retry logic for deletion (sometimes files are locked by Windows)
        int attempts = 0;
        bool deleted = false;
        while (attempts < 5 && !deleted) {
          try {
            // Delete the directory and all its contents
            await dir.delete(recursive: true);
            deleted = true;
          } catch (e) {
            attempts++;
            print('[ProfileManager] Deletion attempt $attempts failed for ${profile.name}, retrying...');
            await Future.delayed(Duration(seconds: 1));
          }
        }
        
        if (!deleted) {
          // If recursive delete fails, try deleting subfolders individually
          print('[ProfileManager] Warning: Recursive delete failed, trying manual subfolder wipe...');
          final subDirs = ['Default', 'Cache', 'Code Cache', 'GPUCache', 'Local Storage', 'Session Storage'];
          for (final sub in subDirs) {
             final subDir = Directory(path.join(profile.profilePath, sub));
             if (subDir.existsSync()) {
               try { await subDir.delete(recursive: true); } catch(_) {}
             }
          }
        }

        // Recreate the directory
        await dir.create(recursive: true);
        print('[ProfileManager] ✓ Nuclear wipe complete for ${profile.name}');
      } catch (e) {
        print('[ProfileManager] ✗ NUCLEAR WIPE FAILED for ${profile.name}: $e');
      }
    }
  }

  Future<void> _killAnyProcessOnPort(int port) async {
    try {
      if (Platform.isWindows) {
        // Use CDP Browser.close to gracefully close Chrome on this port
        try {
          final client = HttpClient();
          client.connectionTimeout = const Duration(seconds: 2);
          final request = await client.getUrl(Uri.parse('http://localhost:$port/json/version'));
          final response = await request.close().timeout(const Duration(seconds: 2));
          final body = await response.transform(utf8.decoder).join();
          final data = json.decode(body) as Map<String, dynamic>;
          final wsUrl = data['webSocketDebuggerUrl'] as String?;
          if (wsUrl != null) {
            final ws = await WebSocket.connect(wsUrl);
            ws.add(json.encode({'id': 1, 'method': 'Browser.close'}));
            await Future.delayed(const Duration(milliseconds: 500));
            await ws.close();
          }
          client.close();
        } catch (_) {}
      } else {
        await Process.run('fuser', ['-k', '$port/tcp']).catchError((_) => ProcessResult(0, 0, '', ''));
      }
    } catch (e) {
      print('[ProfileManager] Error killing process on port $port: $e');
    }
  }

  /// Get all profiles with a specific status
  List<ChromeProfile> getProfilesByStatus(ProfileStatus status) {
    return profiles.where((p) => p.status == status).toList();
  }

  /// Initialize multiple profiles
  /// Uses profile names from Settings when available.
  /// Also starts the Playwright server in the background.
  Future<void> initializeProfiles(int count) async {
    profiles.clear();
    _currentBrowserIndex = 0;

    // Start Playwright server in background EARLY so it's ready by launch time
    PlaywrightBrowserService().startServerInBackground();

    // Get profile names from Settings
    final settingsProfiles = SettingsService.instance.getBrowserProfiles();
    print('[ProfileManager] Settings has ${settingsProfiles.length} configured profiles');

    for (var i = 0; i < count; i++) {
      // Use name from Settings if available, otherwise use default naming
      String name;
      if (i < settingsProfiles.length) {
        name = (settingsProfiles[i]['name'] ?? 'Browser_${i + 1}').toString();
        print('[ProfileManager] Browser ${i + 1} using Settings profile: "$name"');
      } else {
        name = 'Browser_${i + 1}';
        print('[ProfileManager] Browser ${i + 1} using default name: "$name" (no Settings profile at index $i)');
      }
      
      final profilePath = path.join(profilesDirectory, 'Browser_${i + 1}'); // Keep folder names consistent
      final debugPort = baseDebugPort + i;

      final profile = ChromeProfile(
        name: name,
        profilePath: profilePath,
        debugPort: debugPort,
      );

      profiles.add(profile);

      // Create profile directory if it doesn't exist
      await createProfile('Browser_${i + 1}');
    }

    print('[ProfileManager] ✓ Initialized $count profiles');
  }

  /// Connect to already-opened browser instances (assumes already logged in)
  /// Staggered to prevent UI freezing
  Future<int> connectToOpenProfiles(int count) async {
    await initializeProfiles(count);
    
    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Connecting to $count opened browsers (STAGGERED)');
    print('[ProfileManager] ========================================');
    
    int connectedCount = 0;

    for (var i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      
      // Stagger connections: 1s gap
      if (i > 0) await Future.delayed(const Duration(seconds: 1));
      
      print('\n[ProfileManager] [${i + 1}/$count] Checking port ${profile.debugPort}...');
      
      // Check if Chrome is running on this port
      final isRunning = await _isChromeRunning(profile.debugPort);
      if (!isRunning) {
        print('[ProfileManager] [${i + 1}/$count] \u2717 No browser on port ${profile.debugPort}');
        continue;
      }
      // Connect to browser (fast - no token check)
      final connected = await connectToProfileWithoutToken(profile);
      
      if (connected) {
        connectedCount++;
        
        // Try to get token: instant first try, then 8s wait before retry (up to 3 attempts = 24s max)
        String? foundToken;
        const int maxTokenAttempts = 3;
        const int tokenIntervalSec = 8;
        
        for (int attempt = 1; attempt <= maxTokenAttempts; attempt++) {
          // Only wait 4s BEFORE attempt 2 (not before attempt 1)
          if (attempt > 1) {
            print('[ProfileManager] [${i + 1}/$count] No token yet, retrying in ${tokenIntervalSec}s...');
            await Future.delayed(Duration(seconds: tokenIntervalSec));
          }
          
          // Brief network idle wait (shorter on first attempt for snappy feel)
          try {
            if (profile.generator != null && profile.generator!.isConnected) {
              await profile.generator!.waitForNetworkIdle(timeoutSeconds: attempt == 1 ? 2 : 3);
            }
          } catch (_) {}
          
          // Check for token
          try {
            foundToken = await profile.generator!.getAccessToken();
            if (foundToken != null) {
              profile.accessToken = foundToken;
              profile.status = ProfileStatus.connected;
              print('[ProfileManager] [${i + 1}/$count] \u2713 Connected with token (attempt $attempt)');
              break;
            }
          } catch (e) {
            print('[ProfileManager] [${i + 1}/$count] Token check attempt $attempt failed: $e');
          }
        }
        
        if (foundToken == null) {
          print('[ProfileManager] [${i + 1}/$count] \u2713 Connected (ready for manual login)');
        }
        
        // Yield to UI thread
        await Future.delayed(Duration.zero);
      }
    }

    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Connected to $connectedCount/$count browsers');
    print('[ProfileManager] ========================================');
    
    return connectedCount;
  }

  /// Try to connect to any disconnected profiles that are already running as Chrome instances
  Future<void> refreshAllProfiles() async {
    for (final profile in profiles) {
      if (profile.status == ProfileStatus.disconnected) {
        final isRunning = await _isChromeRunning(profile.debugPort);
        if (isRunning) {
          print('[ProfileManager] Attempting to auto-connect to running profile: ${profile.name}');
          await connectToProfile(profile);
        }
      }
    }
  }

  /// Launch browsers without auto-login (user must login manually)
  /// After launch, tries ONCE to get a token - if already logged in it auto-connects,
  /// otherwise keeps the browser open for manual login.
  /// Browsers are staggered to prevent "Not Responding" from simultaneous launches.
  Future<int> launchProfilesWithoutLogin(int count, {bool headless = false, String url = 'https://labs.google/fx/tools/flow'}) async {
    await initializeProfiles(count);
    
    // Always use Playwright server for browser management
    return await _launchProfilesViaPlaywright(count, headless: headless, url: url);
  }

  /// Launch browsers via Playwright server (smooth, no CDP freezes)
  Future<int> _launchProfilesViaPlaywright(int count, {bool headless = false, String url = 'https://labs.google/fx/tools/flow'}) async {
    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Opening $count browsers via PLAYWRIGHT SERVER');
    print('[ProfileManager] ========================================');
    
    final pwService = PlaywrightBrowserService();
    
    // Ensure Playwright server is running
    if (!pwService.isRunning) {
      print('[ProfileManager] Starting Playwright server...');
      final started = await pwService.startServer();
      if (!started) {
        print('[ProfileManager] [FAIL] Browser server failed to start!');
        print('[ProfileManager] Please check server executable is present');
        return 0;
      }
    }
    
    int launchedCount = 0;
    int autoConnectedCount = 0;
    
    for (var i = 0; i < profiles.length; i++) {
      final profile = profiles[i];
      profile.status = ProfileStatus.launching;
      
      print('\n[ProfileManager] [${i + 1}/$count] Opening browser for ${profile.name}...');
      
      // Launch via Playwright server
      final result = await pwService.launchBrowser(
        port: profile.debugPort,
        profilePath: profile.profilePath,
        headless: headless,
        url: url,
      );
      
      if (result['success'] != true) {
        // On macOS, Playwright launch may fail due to sandbox — try launching Chrome independently
        if (Platform.isMacOS) {
          print('[ProfileManager] [${i + 1}/$count] Playwright launch failed, trying macOS independent launch...');
          final macLaunched = await _launchChromeIndependentlyMacOS(profile);
          if (!macLaunched) {
            print('[ProfileManager] [${i + 1}/$count] [FAIL] macOS independent launch also failed');
            profile.status = ProfileStatus.error;
            continue;
          }
          print('[ProfileManager] [${i + 1}/$count] [OK] Chrome launched independently on macOS');
        } else {
          print('[ProfileManager] [${i + 1}/$count] [FAIL] Launch failed: ${result['error']}');
          profile.status = ProfileStatus.error;
          continue;
        }
      }
      
      launchedCount++;
      profile.chromePid = result['pid'] as int?;
      print('[ProfileManager] [${i + 1}/$count] [OK] Browser opened');
      
      // Quick connection + token check with 2 attempts, 15s interval
      // If browser is logged in, it will get token on first or second try
      // If not logged in, just move on to next browser
      bool connected = false;
      String? token;
      
      const int maxAttempts = 2;
      const int intervalSec = 15;
      
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        // Wait 15s before each attempt (network idle time)
        print('[ProfileManager] [${i + 1}/$count] Connection attempt $attempt/$maxAttempts (waiting ${intervalSec}s)...');
        await Future.delayed(Duration(seconds: intervalSec));
        
        // Try to create generator and connect (only on first attempt)
        if (!connected) {
          if (profile.generator == null) {
            final generator = DesktopGenerator(debugPort: profile.debugPort);
            try {
              await generator.connect();
              profile.generator = generator;
              connected = true;
              print('[ProfileManager] [${i + 1}/$count] [OK] Connected via Playwright');
            } catch (e) {
              print('[ProfileManager] [${i + 1}/$count] Connect failed: $e');
            }
          } else {
            connected = true;
          }
        }
        
        // Try to fetch token
        if (connected) {
          try {
            token = await pwService.getAccessToken(port: profile.debugPort);
            if (token != null && token.isNotEmpty) {
              profile.accessToken = token;
              profile.status = ProfileStatus.connected;
              print('[ProfileManager] [${i + 1}/$count] [OK] Session found - auto-connected! (attempt $attempt)');
              break;
            } else {
              print('[ProfileManager] [${i + 1}/$count] No token on attempt $attempt');
            }
          } catch (e) {
            print('[ProfileManager] [${i + 1}/$count] Token check failed on attempt $attempt: $e');
          }
        }
      }
      
      // Final status after all attempts
      if (!connected) {
        profile.status = ProfileStatus.error;
        print('[ProfileManager] [${i + 1}/$count] [FAIL] Could not connect');
      } else if (token == null || token.isEmpty) {
        profile.status = ProfileStatus.disconnected;
        print('[ProfileManager] [${i + 1}/$count] No session after $maxAttempts attempts - browser open for manual login');
      } else {
        autoConnectedCount++;
      }
      
      // Brief stagger between browser launches (just 1s)
      if (i < profiles.length - 1) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    
    print('\n[ProfileManager] ========================================');
    print('[ProfileManager] Opened $launchedCount/$count browsers');
    if (autoConnectedCount > 0) {
      print('[ProfileManager] [OK] Auto-connected: $autoConnectedCount (had existing sessions)');
    }
    if (launchedCount - autoConnectedCount > 0) {
      print('[ProfileManager] Awaiting manual login: ${launchedCount - autoConnectedCount}');
    }
    print('[ProfileManager] ========================================');
    
    return launchedCount;
  }

  /// macOS fallback: Launch Chrome independently using `open` command.
  /// This avoids sandbox inheritance by starting Chrome as its own process.
  Future<bool> _launchChromeIndependentlyMacOS(ChromeProfile profile) async {
    try {
      final chromePath = AppConfig.chromePath;
      final port = profile.debugPort;
      final profileDir = profile.profilePath;
      
      print('[ProfileManager] [macOS] Launching Chrome independently:');
      print('[ProfileManager] [macOS]   Chrome: $chromePath');
      print('[ProfileManager] [macOS]   Port: $port');
      print('[ProfileManager] [macOS]   Profile: $profileDir');
      
      // Ensure profile directory exists
      final dir = Directory(profileDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      
      // Use 'open' command which launches Chrome as an independent process.
      // The -a flag specifies the app, --args passes arguments to Chrome.
      final result = await Process.run('open', [
        '-na', 'Google Chrome',
        '--args',
        '--remote-debugging-port=$port',
        '--user-data-dir=$profileDir',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-popup-blocking',
        '--disable-translate',
        '--disable-features=TranslateUI',
        'https://labs.google/fx/tools/flow',
      ]);
      
      if (result.exitCode != 0) {
        print('[ProfileManager] [macOS] open command failed: ${result.stderr}');
        return false;
      }
      
      print('[ProfileManager] [macOS] Chrome launched, waiting for CDP on port $port...');
      
      // Wait for Chrome to be ready on the debug port
      final ready = await _waitForChromeReady(port, maxAttempts: 10);
      if (!ready) {
        print('[ProfileManager] [macOS] Chrome did not become ready on port $port');
        return false;
      }
      
      print('[ProfileManager] [macOS] ✓ Chrome ready on port $port');
      return true;
    } catch (e) {
      print('[ProfileManager] [macOS] Independent launch error: $e');
      return false;
    }
  }

  /// Close all connections and cleanup
  Future<void> dispose() async {
    for (final profile in profiles) {
      try {
        profile.generator?.close();
        profile.chromeProcess?.kill();
      } catch (e) {
        print('[ProfileManager] Warning: Error disposing ${profile.name}: $e');
      }
    }
    profiles.clear();
    print('[ProfileManager] ✓ Disposed all profiles');
  }

  /// Calculate window position for vertical stacking on left side
  String _calculateWindowPosition(ChromeProfile profile) {
    // Calculate profile index from debug port
    final profileIndex = profile.debugPort - baseDebugPort;
    
    // Stack vertically: x=0 (left edge), y = index * 650 (window height)
    final xPos = 0;
    final yPos = profileIndex * 650;
    
    return '$xPos,$yPos';
  }

  /// Find Chrome executable path
  Future<String?> _findChromeExecutable() async {
    if (Platform.isWindows) {
      final paths = [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
      ];

      for (final path in paths) {
        if (File(path).existsSync()) {
          return path;
        }
      }
    } else if (Platform.isMacOS) {
      return '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
    } else if (Platform.isLinux) {
      return 'google-chrome';
    }

    return null;
  }

  /// Wait for Chrome to be ready on the specified port
  Future<bool> _waitForChromeReady(int port, {int maxAttempts = 5}) async {
    for (var i = 0; i < maxAttempts; i++) {
      if (await _isChromeRunning(port)) {
        return true;
      }
      await Future.delayed(Duration(seconds: 2));
    }
    return false;
  }

  /// Check if Chrome is running on the specified port
  /// Uses short timeout and async-friendly http package to prevent UI blocking
  Future<bool> _isChromeRunning(int port) async {
    try {
      // Use http package with explicit timeout instead of blocking HttpClient
      final response = await http.get(
        Uri.parse('http://localhost:$port/json'),
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () => http.Response('', 408), // Return timeout status
      );

      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Apply mobile-like emulation via CDP to enforce small window dimensions
  Future<void> _applyMobileEmulation(int port) async {
    try {
      print('[ProfileManager] Applying mobile emulation (500x650, 40% zoom)...');
      
      // Get the first available tab
      final response = await HttpClient()
          .getUrl(Uri.parse('http://localhost:$port/json'))
          .then((request) => request.close())
          .then((response) => response.transform(utf8.decoder).join());
      
      final tabs = json.decode(response) as List;
      if (tabs.isEmpty) {
        print('[ProfileManager] ✗ No tabs found for emulation');
        return;
      }
      
      final webSocketUrl = tabs[0]['webSocketDebuggerUrl'] as String;
      final ws = await WebSocket.connect(webSocketUrl);
      
      // Set device metrics override (500x650 viewport, 40% scale)
      ws.add(json.encode({
        'id': 1,
        'method': 'Emulation.setDeviceMetricsOverride',
        'params': {
          'width': 1250,          // Logical width (will be scaled to 500px by deviceScaleFactor)
          'height': 1625,         // Logical height (will be scaled to 650px)
          'deviceScaleFactor': 0.4, // 40% zoom
          'mobile': true,
          'screenOrientation': {'type': 'portraitPrimary', 'angle': 0},
        }
      }));
      
      await Future.delayed(Duration(milliseconds: 500));
      await ws.close();
      
      print('[ProfileManager] ✓ Mobile emulation applied');
    } catch (e) {
      print('[ProfileManager] Warning: Could not apply mobile emulation: $e');
    }
  }
}
