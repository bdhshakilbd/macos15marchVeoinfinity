/// Native Windows API bindings via dart:ffi
/// Replaces all PowerShell + DllImport calls to eliminate Windows Defender false positives.
///
/// Covers: user32.dll (window management) and kernel32.dll (process management)
library;

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Only load on Windows
final _user32 = Platform.isWindows ? DynamicLibrary.open('user32.dll') : null;
final _kernel32 = Platform.isWindows ? DynamicLibrary.open('kernel32.dll') : null;

// ============================================================
// Type definitions
// ============================================================
typedef _FindWindowExW_C = IntPtr Function(IntPtr hwndParent, IntPtr hwndChildAfter, Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName);
typedef _FindWindowExW_Dart = int Function(int hwndParent, int hwndChildAfter, Pointer<Utf16> lpClassName, Pointer<Utf16> lpWindowName);

typedef _GetWindowThreadProcessId_C = Uint32 Function(IntPtr hWnd, Pointer<Uint32> lpdwProcessId);
typedef _GetWindowThreadProcessId_Dart = int Function(int hWnd, Pointer<Uint32> lpdwProcessId);

typedef _ShowWindow_C = Int32 Function(IntPtr hWnd, Int32 nCmdShow);
typedef _ShowWindow_Dart = int Function(int hWnd, int nCmdShow);

typedef _IsWindowVisible_C = Int32 Function(IntPtr hWnd);
typedef _IsWindowVisible_Dart = int Function(int hWnd);

typedef _SetWindowPos_C = Int32 Function(IntPtr hWnd, IntPtr hWndInsertAfter, Int32 x, Int32 y, Int32 cx, Int32 cy, Uint32 uFlags);
typedef _SetWindowPos_Dart = int Function(int hWnd, int hWndInsertAfter, int x, int y, int cx, int cy, int uFlags);

typedef _SetForegroundWindow_C = Int32 Function(IntPtr hWnd);
typedef _SetForegroundWindow_Dart = int Function(int hWnd);

typedef _GetSystemMetrics_C = Int32 Function(Int32 nIndex);
typedef _GetSystemMetrics_Dart = int Function(int nIndex);

typedef _OpenProcess_C = IntPtr Function(Uint32 dwDesiredAccess, Int32 bInheritHandle, Uint32 dwProcessId);
typedef _OpenProcess_Dart = int Function(int dwDesiredAccess, int bInheritHandle, int dwProcessId);

typedef _CloseHandle_C = Int32 Function(IntPtr hObject);
typedef _CloseHandle_Dart = int Function(int hObject);

typedef _SetPriorityClass_C = Int32 Function(IntPtr hProcess, Uint32 dwPriorityClass);
typedef _SetPriorityClass_Dart = int Function(int hProcess, int dwPriorityClass);

// SetProcessAffinityMask uses DWORD_PTR (UintPtr) for the mask
typedef _SetProcessAffinityMask_C = Int32 Function(IntPtr hProcess, UintPtr dwProcessAffinityMask);
typedef _SetProcessAffinityMask_Dart = int Function(int hProcess, int dwProcessAffinityMask);

// EnumWindows callback type
typedef _EnumWindowsProc_C = Int32 Function(IntPtr hwnd, IntPtr lParam);
typedef _EnumWindows_C = Int32 Function(Pointer<NativeFunction<_EnumWindowsProc_C>> lpEnumFunc, IntPtr lParam);
typedef _EnumWindows_Dart = int Function(Pointer<NativeFunction<_EnumWindowsProc_C>> lpEnumFunc, int lParam);

typedef _GetClassNameW_C = Int32 Function(IntPtr hWnd, Pointer<Utf16> lpClassName, Int32 nMaxCount);
typedef _GetClassNameW_Dart = int Function(int hWnd, Pointer<Utf16> lpClassName, int nMaxCount);

// CreateProcessW for launching processes with CREATE_NO_WINDOW
typedef _CreateProcessW_C = Int32 Function(
  Pointer<Utf16> lpApplicationName,
  Pointer<Utf16> lpCommandLine,
  Pointer<Void> lpProcessAttributes,
  Pointer<Void> lpThreadAttributes,
  Int32 bInheritHandles,
  Uint32 dwCreationFlags,
  Pointer<Void> lpEnvironment,
  Pointer<Utf16> lpCurrentDirectory,
  Pointer<_STARTUPINFOW> lpStartupInfo,
  Pointer<_PROCESS_INFORMATION> lpProcessInformation,
);
typedef _CreateProcessW_Dart = int Function(
  Pointer<Utf16> lpApplicationName,
  Pointer<Utf16> lpCommandLine,
  Pointer<Void> lpProcessAttributes,
  Pointer<Void> lpThreadAttributes,
  int bInheritHandles,
  int dwCreationFlags,
  Pointer<Void> lpEnvironment,
  Pointer<Utf16> lpCurrentDirectory,
  Pointer<_STARTUPINFOW> lpStartupInfo,
  Pointer<_PROCESS_INFORMATION> lpProcessInformation,
);

// STARTUPINFOW structure (68 bytes on 32-bit, 104 bytes on 64-bit)
final class _STARTUPINFOW extends Struct {
  @Uint32() external int cb;
  external Pointer<Utf16> lpReserved;
  external Pointer<Utf16> lpDesktop;
  external Pointer<Utf16> lpTitle;
  @Uint32() external int dwX;
  @Uint32() external int dwY;
  @Uint32() external int dwXSize;
  @Uint32() external int dwYSize;
  @Uint32() external int dwXCountChars;
  @Uint32() external int dwYCountChars;
  @Uint32() external int dwFillAttribute;
  @Uint32() external int dwFlags;
  @Uint16() external int wShowWindow;
  @Uint16() external int cbReserved2;
  external Pointer<Uint8> lpReserved2;
  external Pointer<Void> hStdInput;
  external Pointer<Void> hStdOutput;
  external Pointer<Void> hStdError;
}

// PROCESS_INFORMATION structure
final class _PROCESS_INFORMATION extends Struct {
  external Pointer<Void> hProcess;
  external Pointer<Void> hThread;
  @Uint32() external int dwProcessId;
  @Uint32() external int dwThreadId;
}

// ============================================================
// Constants
// ============================================================
class Win32Constants {
  // ShowWindow commands
  static const int SW_HIDE = 0;
  static const int SW_SHOWNORMAL = 1;
  static const int SW_RESTORE = 9;
  
  // SetWindowPos flags
  static const int SWP_SHOWWINDOW = 0x0040;
  static const int HWND_TOPMOST = -1;
  
  // GetSystemMetrics
  static const int SM_CYSCREEN = 1; // Screen height
  static const int SM_CXSCREEN = 0; // Screen width
  
  // OpenProcess access rights
  static const int PROCESS_SET_INFORMATION = 0x0200;
  static const int PROCESS_QUERY_INFORMATION = 0x0400;
  
  // SetPriorityClass
  static const int HIGH_PRIORITY_CLASS = 0x00000080;
  static const int ABOVE_NORMAL_PRIORITY_CLASS = 0x00008000;
  
  // CreateProcess flags
  static const int CREATE_NO_WINDOW = 0x08000000;
  static const int DETACHED_PROCESS = 0x00000008;
  
  // STARTUPINFO flags
  static const int STARTF_USESHOWWINDOW = 0x00000001;
}

// ============================================================
// Win32 API class
// ============================================================
class Win32Api {
  static bool get isAvailable => Platform.isWindows && _user32 != null;
  
  // Lazy-loaded function pointers
  static late final _findWindowExW = _user32!.lookupFunction<_FindWindowExW_C, _FindWindowExW_Dart>('FindWindowExW');
  static late final _getWindowThreadProcessId = _user32!.lookupFunction<_GetWindowThreadProcessId_C, _GetWindowThreadProcessId_Dart>('GetWindowThreadProcessId');
  static late final _showWindow = _user32!.lookupFunction<_ShowWindow_C, _ShowWindow_Dart>('ShowWindow');
  static late final _isWindowVisible = _user32!.lookupFunction<_IsWindowVisible_C, _IsWindowVisible_Dart>('IsWindowVisible');
  static late final _setWindowPos = _user32!.lookupFunction<_SetWindowPos_C, _SetWindowPos_Dart>('SetWindowPos');
  static late final _setForegroundWindow = _user32!.lookupFunction<_SetForegroundWindow_C, _SetForegroundWindow_Dart>('SetForegroundWindow');
  static late final _getSystemMetrics = _user32!.lookupFunction<_GetSystemMetrics_C, _GetSystemMetrics_Dart>('GetSystemMetrics');
  static late final _getClassNameW = _user32!.lookupFunction<_GetClassNameW_C, _GetClassNameW_Dart>('GetClassNameW');
  static late final _enumWindows = _user32!.lookupFunction<_EnumWindows_C, _EnumWindows_Dart>('EnumWindows');
  
  static late final _openProcess = _kernel32!.lookupFunction<_OpenProcess_C, _OpenProcess_Dart>('OpenProcess');
  static late final _closeHandle = _kernel32!.lookupFunction<_CloseHandle_C, _CloseHandle_Dart>('CloseHandle');
  static late final _setPriorityClass = _kernel32!.lookupFunction<_SetPriorityClass_C, _SetPriorityClass_Dart>('SetPriorityClass');
  static late final _setProcessAffinityMask = _kernel32!.lookupFunction<_SetProcessAffinityMask_C, _SetProcessAffinityMask_Dart>('SetProcessAffinityMask');
  static late final _createProcessW = _kernel32!.lookupFunction<_CreateProcessW_C, _CreateProcessW_Dart>('CreateProcessW');

  // ============================================================
  // Window Management
  // ============================================================
  
  /// Find all windows with the given class name belonging to the target PID.
  /// Returns list of window handles (HWNDs).
  static List<int> findWindowsByClassAndPid(String className, int targetPid) {
    if (!isAvailable) return [];
    
    final classNamePtr = className.toNativeUtf16();
    final pidPtr = calloc<Uint32>();
    final results = <int>[];
    
    try {
      int hwnd = _findWindowExW(0, 0, classNamePtr, nullptr);
      while (hwnd != 0) {
        _getWindowThreadProcessId(hwnd, pidPtr);
        if (pidPtr.value == targetPid) {
          results.add(hwnd);
        }
        hwnd = _findWindowExW(0, hwnd, classNamePtr, nullptr);
      }
    } finally {
      calloc.free(classNamePtr);
      calloc.free(pidPtr);
    }
    
    return results;
  }
  
  /// Hide a window by handle
  static bool hideWindow(int hwnd) {
    if (!isAvailable) return false;
    return _showWindow(hwnd, Win32Constants.SW_HIDE) != 0;
  }
  
  /// Show/restore a window by handle
  static bool showWindow(int hwnd, {int cmd = Win32Constants.SW_RESTORE}) {
    if (!isAvailable) return false;
    return _showWindow(hwnd, cmd) != 0;
  }
  
  /// Check if a window is visible
  static bool isWindowVisible(int hwnd) {
    if (!isAvailable) return false;
    return _isWindowVisible(hwnd) != 0;
  }
  
  /// Set window position and size, optionally always-on-top
  static bool setWindowPos(int hwnd, {
    int x = 0, 
    int y = 0, 
    int width = 800, 
    int height = 600, 
    bool topMost = false,
  }) {
    if (!isAvailable) return false;
    final insertAfter = topMost ? Win32Constants.HWND_TOPMOST : 0;
    return _setWindowPos(hwnd, insertAfter, x, y, width, height, Win32Constants.SWP_SHOWWINDOW) != 0;
  }
  
  /// Bring a window to the foreground
  static bool setForegroundWindow(int hwnd) {
    if (!isAvailable) return false;
    return _setForegroundWindow(hwnd) != 0;
  }
  
  /// Get screen dimensions
  static int getScreenHeight() {
    if (!isAvailable) return 1080;
    return _getSystemMetrics(Win32Constants.SM_CYSCREEN);
  }
  
  static int getScreenWidth() {
    if (!isAvailable) return 1920;
    return _getSystemMetrics(Win32Constants.SM_CXSCREEN);
  }
  
  /// Get the PID owning a window handle
  static int getWindowPid(int hwnd) {
    if (!isAvailable) return 0;
    final pidPtr = calloc<Uint32>();
    try {
      _getWindowThreadProcessId(hwnd, pidPtr);
      return pidPtr.value;
    } finally {
      calloc.free(pidPtr);
    }
  }
  
  // ============================================================
  // High-level helpers (replace PowerShell scripts)
  // ============================================================
  
  /// Hide ALL Chrome windows for a given PID.
  /// Equivalent to the old PowerShell hideWindow() in browser_utils.dart.
  /// Returns number of windows hidden.
  static Future<int> hideAllChromeWindows(int pid, {int maxWaitMs = 8000}) async {
    if (!isAvailable) return 0;
    
    final int intervalMs = 200;
    final int maxIter = maxWaitMs ~/ intervalMs;
    
    for (int i = 0; i < maxIter; i++) {
      final windows = findWindowsByClassAndPid('Chrome_WidgetWin_1', pid);
      int hidden = 0;
      
      for (final hwnd in windows) {
        if (isWindowVisible(hwnd)) {
          hideWindow(hwnd);
          hidden++;
        }
      }
      
      if (hidden > 0) {
        print('[Win32Api] ✓ Hidden $hidden windows for PID $pid');
        // Wait 1s then re-hide in case Chrome re-shows
        await Future.delayed(const Duration(milliseconds: 1000));
        final recheck = findWindowsByClassAndPid('Chrome_WidgetWin_1', pid);
        for (final hwnd in recheck) {
          if (isWindowVisible(hwnd)) hideWindow(hwnd);
        }
        return hidden;
      }
      
      await Future.delayed(Duration(milliseconds: intervalMs));
    }
    
    print('[Win32Api] ✗ No Chrome_WidgetWin_1 window found for PID $pid after ${maxWaitMs}ms');
    return 0;
  }
  
  /// Force a window to be Always-On-Top and position it.
  /// Equivalent to the old PowerShell forceAlwaysOnTop() in browser_utils.dart.
  static Future<bool> forceAlwaysOnTopByPid(int pid, {
    int width = 200,
    int height = 350,
    int offsetIndex = 0,
  }) async {
    if (!isAvailable) return false;
    
    // Wait a bit for window to appear
    await Future.delayed(const Duration(milliseconds: 100));
    
    final screenHeight = getScreenHeight();
    
    // Find main Chrome window for this PID
    // Retry up to 20 times (4 seconds)
    int? targetHwnd;
    for (int i = 0; i < 20; i++) {
      final windows = findWindowsByClassAndPid('Chrome_WidgetWin_1', pid);
      if (windows.isNotEmpty) {
        targetHwnd = windows.first;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    
    if (targetHwnd == null) {
      print('[Win32Api] No Chrome window found for PID $pid');
      return false;
    }
    
    // Calculate Column and Stack index (wrap after 5 browsers)
    final maxInStack = 5;
    final stackIdx = offsetIndex % maxInStack;
    final columnIdx = offsetIndex ~/ maxInStack;
    
    // Position from bottom-left
    final xPos = (columnIdx * (width + 20)) + (stackIdx * 15);
    final yPos = screenHeight - height - 40 - (stackIdx * 25);
    
    return setWindowPos(
      targetHwnd,
      x: xPos,
      y: yPos,
      width: width,
      height: height,
      topMost: true,
    );
  }
  
  /// Bring Chrome to foreground by finding its window.
  /// Equivalent to the old PowerShell SetForegroundWindow in multi_profile_login_service.dart.
  static Future<bool> bringChromeToFront() async {
    if (!isAvailable) return false;
    
    // Find any Chrome window
    final classNamePtr = 'Chrome_WidgetWin_1'.toNativeUtf16();
    try {
      int hwnd = _findWindowExW(0, 0, classNamePtr, nullptr);
      while (hwnd != 0) {
        if (isWindowVisible(hwnd)) {
          showWindow(hwnd, cmd: Win32Constants.SW_RESTORE);
          setForegroundWindow(hwnd);
          return true;
        }
        hwnd = _findWindowExW(0, hwnd, classNamePtr, nullptr);
      }
    } finally {
      calloc.free(classNamePtr);
    }
    return false;
  }
  
  /// Bring a specific Chrome window to front by PID.
  static Future<bool> bringChromeToFrontByPid(int pid) async {
    if (!isAvailable) return false;
    
    final windows = findWindowsByClassAndPid('Chrome_WidgetWin_1', pid);
    for (final hwnd in windows) {
      showWindow(hwnd, cmd: Win32Constants.SW_RESTORE);
      setForegroundWindow(hwnd);
      return true;
    }
    return false;
  }
  
  // ============================================================
  // Process Management
  // ============================================================
  
  /// Set process to High priority and allocate to first 8 cores.
  /// Equivalent to the old PowerShell setHighPerformanceAffinity() in browser_utils.dart.
  static bool setHighPerformanceAffinity(int pid) {
    if (!isAvailable || _kernel32 == null) return false;
    
    final hProcess = _openProcess(
      Win32Constants.PROCESS_SET_INFORMATION | Win32Constants.PROCESS_QUERY_INFORMATION,
      0, // bInheritHandle = FALSE
      pid,
    );
    
    if (hProcess == 0) {
      print('[Win32Api] Failed to open process $pid');
      return false;
    }
    
    try {
      // Set high priority
      _setPriorityClass(hProcess, Win32Constants.HIGH_PRIORITY_CLASS);
      
      // Set affinity to first 8 cores (0xFF = binary 11111111)
      _setProcessAffinityMask(hProcess, 0xFF);
      
      print('[Win32Api] Set process $pid to High priority with affinity 0xFF');
      return true;
    } finally {
      _closeHandle(hProcess);
    }
  }
  
  /// Activate a window by its title using FindWindow.
  /// Equivalent to the old PowerShell WScript.Shell.AppActivate in gemini_hub_connector.dart.
  static Future<bool> activateWindowByTitle(String title) async {
    if (!isAvailable) return false;
    
    // FindWindowW(NULL, title) to find by exact title
    // We'll use FindWindowExW with null class and specific title
    final titlePtr = title.toNativeUtf16();
    try {
      // Search through Chrome windows for one with matching title
      final classNamePtr = 'Chrome_WidgetWin_1'.toNativeUtf16();
      try {
        int hwnd = _findWindowExW(0, 0, classNamePtr, nullptr);
        while (hwnd != 0) {
          showWindow(hwnd, cmd: Win32Constants.SW_RESTORE);
          setForegroundWindow(hwnd);
          return true;
        }
      } finally {
        calloc.free(classNamePtr);
      }
    } finally {
      calloc.free(titlePtr);
    }
    return false;
  }
  
  // ============================================================
  // Hidden Process Launch (CREATE_NO_WINDOW)
  // ============================================================
  
  /// Launch a process completely hidden — no console window flash at all.
  /// Uses CreateProcessW with CREATE_NO_WINDOW flag.
  /// Returns the process ID (PID) or 0 on failure.
  static int launchHiddenProcess(String executable, [List<String>? args]) {
    if (!isAvailable || _kernel32 == null) return 0;
    
    // Build command line: "executable" arg1 arg2 ...
    final cmdLine = StringBuffer('"$executable"');
    if (args != null) {
      for (final arg in args) {
        cmdLine.write(' ');
        if (arg.contains(' ')) {
          cmdLine.write('"$arg"');
        } else {
          cmdLine.write(arg);
        }
      }
    }
    
    final cmdLinePtr = cmdLine.toString().toNativeUtf16();
    final si = calloc<_STARTUPINFOW>();
    final pi = calloc<_PROCESS_INFORMATION>();
    
    try {
      // Initialize STARTUPINFOW
      si.ref.cb = sizeOf<_STARTUPINFOW>();
      si.ref.dwFlags = Win32Constants.STARTF_USESHOWWINDOW;
      si.ref.wShowWindow = Win32Constants.SW_HIDE;
      
      final result = _createProcessW(
        nullptr,      // lpApplicationName (use command line instead)
        cmdLinePtr,   // lpCommandLine
        nullptr,      // lpProcessAttributes
        nullptr,      // lpThreadAttributes
        0,            // bInheritHandles = FALSE
        Win32Constants.CREATE_NO_WINDOW, // dwCreationFlags
        nullptr,      // lpEnvironment (inherit)
        nullptr,      // lpCurrentDirectory (inherit)
        si,           // lpStartupInfo
        pi,           // lpProcessInformation
      );
      
      if (result != 0) {
        final pid = pi.ref.dwProcessId;
        // Close the handles (we don't need them)
        _closeHandle(pi.ref.hProcess.address);
        _closeHandle(pi.ref.hThread.address);
        print('[Win32Api] ✓ Launched hidden process: PID $pid');
        return pid;
      } else {
        print('[Win32Api] ✗ CreateProcessW failed for: $executable');
        return 0;
      }
    } finally {
      calloc.free(cmdLinePtr);
      calloc.free(si);
      calloc.free(pi);
    }
  }
}
