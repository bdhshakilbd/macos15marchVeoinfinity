import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'win32_api.dart';

class BrowserUtils {
  /// Chrome arguments for desktop browsers to ensure they don't throttle in background
  /// and work reliably for automation/polling.
  /// 
  /// AMD Ryzen optimizations:
  /// - Added --disable-features=RendererCodeIntegrity for better Ryzen compatibility
  /// - Added --disable-hang-monitor to prevent false "not responding" detection
  static List<String> getChromeArgs({
    required int debugPort,
    required String profilePath,
    String? url,
    String? windowPosition,
    String? windowSize,
    bool headless = false,
  }) {
    // ABSOLUTE MINIMUM FLAGS: A real human launches Chrome with zero special flags.
    // The only flags we MUST add are the debug port (for CDP) and profile path.
    // Everything else (--no-first-run, --excludeSwitches, --user-agent, etc.)
    // is detectable by sites like Google Flow and marks the browser as automated.
    final args = <String>[
      '--remote-debugging-port=$debugPort',
      '--remote-allow-origins=*',
      '--user-data-dir=$profilePath',
    ];

    if (headless) {
      // Normal GUI launch — window hidden AFTER launch via hideWindow(pid)
      args.addAll([
        '--window-size=1280,720',
      ]);
    } else {
      args.addAll([
        '--window-size=${windowSize ?? "800,600"}',
        if (windowPosition != null) '--window-position=$windowPosition',
      ]);
    }

    if (url != null) {
      args.add(url);
    }

    return args;
  }


  /// Inject stealth patches via CDP to bypass bot detection (e.g. navigator.webdriver)
  /// without triggering the "unsupported command-line flag" warning bar.
  static Future<void> injectStealthPatches(int debugPort) async {
    try {
      print('[BrowserUtils] Injecting stealth patches on port $debugPort...');
      
      final response = await HttpClient()
          .getUrl(Uri.parse('http://localhost:$debugPort/json'))
          .then((request) => request.close())
          .then((response) => response.transform(utf8.decoder).join())
          .timeout(const Duration(seconds: 5));
      
      final tabs = json.decode(response) as List;
      if (tabs.isEmpty) return;
      
      final webSocketUrl = tabs[0]['webSocketDebuggerUrl'] as String?;
      if (webSocketUrl == null) return;
      
      final ws = await WebSocket.connect(webSocketUrl);
      
      // Patch navigator.webdriver to false for ALL existing and NEW pages
      ws.add(json.encode({
        'id': 1,
        'method': 'Page.addScriptToEvaluateOnNewDocument',
        'params': {
          'source': '''
            // Hide the 'webdriver' property
            Object.defineProperty(navigator, 'webdriver', {
              get: () => false,
            });
            
            // Mask other automation signals
            window.chrome = { runtime: {} };
            Object.defineProperty(navigator, 'plugins', {
              get: () => [1, 2, 3, 4, 5], 
            });
            Object.defineProperty(navigator, 'languages', {
              get: () => ['en-US', 'en'],
            });
          '''
        }
      }));

      // Also execute immediately on the current page
      ws.add(json.encode({
        'id': 2,
        'method': 'Runtime.evaluate',
        'params': {
          'expression': 'Object.defineProperty(navigator, "webdriver", { get: () => false });',
          'returnByValue': true,
        }
      }));

      await Future.delayed(const Duration(milliseconds: 300));
      await ws.close();
      print('[BrowserUtils] ✓ Stealth patches injected on port $debugPort');
    } catch (e) {
      print('[BrowserUtils] Warning: Stealth injection failed: $e');
    }
  }

  /// Hide all Chrome windows for a given PID using native Win32 API (dart:ffi).
  /// No PowerShell needed — calls user32.dll directly.
  static Future<void> hideWindow(int pid) async {
    if (!Platform.isWindows) return;
    try {
      final hidden = await Win32Api.hideAllChromeWindows(pid);
      if (hidden > 0) {
        print('[BrowserUtils] ✓ Hidden $hidden windows for PID $pid (native FFI)');
      } else {
        print('[BrowserUtils] ✗ No windows found for PID $pid');
      }
    } catch (e) {
      print('[BrowserUtils] ⚠️ hideWindow failed for PID $pid: $e');
    }
  }


  /// Force a window to be Always-On-Top and optionally position it at the bottom-left (Windows only)
  /// Uses native Win32 API via dart:ffi — no PowerShell needed.
  static Future<void> forceAlwaysOnTop(int pid, {int? width, int? height, int offsetIndex = 0}) async {
    if (!Platform.isWindows) return;

    try {
      final result = await Win32Api.forceAlwaysOnTopByPid(
        pid,
        width: width ?? 200,
        height: height ?? 350,
        offsetIndex: offsetIndex,
      );
      if (result) {
        print('[BrowserUtils] ✓ Always-on-top set for PID $pid (native FFI)');
      }
    } catch (e) {
      print('[BrowserUtils] Error applying Always-On-Top/Position: $e');
    }
  }
  
  /// Apply mobile device emulation via CDP
  /// DISABLED: Mobile emulation causes 500 errors. Using desktop mode instead.
  static Future<void> applyMobileEmulation(int debugPort) async {
    // DISABLED - Mobile emulation causes 500 Internal Server errors
    // Using desktop mode with larger window instead
    print('[MobileEmulation] Skipped - using desktop mode');
    return;
  }


  
  /// Set high performance process affinity for Chrome (AMD Ryzen optimization)
  /// Uses native Win32 API via dart:ffi — no PowerShell needed.
  static Future<void> setHighPerformanceAffinity(int pid) async {
    if (!Platform.isWindows) return;
    
    try {
      final result = Win32Api.setHighPerformanceAffinity(pid);
      if (result) {
        print('[BrowserUtils] ✓ High performance affinity set for PID $pid (native FFI)');
      } else {
        print('[BrowserUtils] ⚠️ Could not set affinity for PID $pid');
      }
    } catch (e) {
      print('[BrowserUtils] Error setting affinity: $e');
    }
  }
  
  /// Prevent CPU throttling on AMD Ryzen by disabling core parking temporarily
  /// NOTE: This previously used PowerShell + powercfg which triggered Defender.
  /// Now it's a no-op — performance is handled via per-process affinity instead.
  static Future<void> preventCpuThrottling() async {
    // REMOVED: powercfg commands triggered Windows Defender.
    // Per-process priority via setHighPerformanceAffinity() is sufficient.
    print('[BrowserUtils] CPU throttling prevention: using per-process affinity instead');
  }
  
  /// Run PowerShell command asynchronously in isolate to avoid blocking main thread
  /// This is especially important on AMD Ryzen where PowerShell can be slower
  @Deprecated('Use Win32Api directly instead of PowerShell to avoid Defender issues')
  static Future<String> runPowerShellAsync(String command) async {
    if (!Platform.isWindows) return '';
    
    try {
      final result = await compute(_runPowerShellIsolate, command);
      return result;
    } catch (e) {
      print('[BrowserUtils] PowerShell async error: $e');
      return '';
    }
  }
  
  /// Internal function to run PowerShell in isolate
  static Future<String> _runPowerShellIsolate(String command) async {
    try {
      final result = await Process.run('powershell', ['-Command', command])
          .timeout(const Duration(seconds: 30));
      return result.stdout.toString();
    } catch (e) {
      return 'Error: $e';
    }
  }
}
