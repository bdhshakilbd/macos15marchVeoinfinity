import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'profile_manager_service.dart';
import 'video_generation_service.dart';
import 'settings_service.dart';
import 'playwright_browser_service.dart';
import 'mobile/mobile_browser_service.dart';
import '../utils/browser_utils.dart';
import '../utils/win32_api.dart';

/// Service for automated multi-profile Google OAuth login
class MultiProfileLoginService {
  final ProfileManagerService profileManager;
  final Random _random = Random();
  
  // Cancellation support
  bool _isCancelled = false;
  
  MultiProfileLoginService({required this.profileManager});
  
  /// Stop the current login process immediately
  void stopLogin() {
    _isCancelled = true;
    print('[AutoLogin] ⛔ STOP requested - cancelling all login operations...');
  }
  
  /// Reset cancellation flag (call before starting new login)
  void resetCancellation() {
    _isCancelled = false;
  }
  
  /// Check if login was cancelled
  bool get isCancelled => _isCancelled;
  
  /// Check cancellation and throw if cancelled
  void _checkCancelled(String profileName) {
    if (_isCancelled) {
      print('[AutoLogin] $profileName - ⛔ CANCELLED');
      throw _CancelledException();
    }
  }
  
  /// Delay with cancellation support - checks every 500ms
  Future<void> _delayWithCancellation(Duration duration, String profileName) async {
    final startTime = DateTime.now();
    while (DateTime.now().difference(startTime) < duration) {
      if (_isCancelled) {
        print('[AutoLogin] $profileName - ⛔ CANCELLED during delay');
        throw _CancelledException();
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
  }

  /// Perform automated Google OAuth login for a single profile
  /// Delegates the entire login flow to the Playwright Python server.
  /// Returns true if login successful and token verified.
  Future<bool> autoLogin({
    required ChromeProfile profile,
    required String email,
    required String password,
    int maxAttempts = 3,
    bool headless = false,
  }) async {
    // Auto-lookup credentials from settings if not provided
    String usedEmail = email;
    String usedPassword = password;
    if (usedEmail.isEmpty || usedPassword.isEmpty) {
      try {
        final acct = SettingsService.instance.getAssignedAccountForProfileName(profile.name);
        if (acct != null) {
          usedEmail = (acct['username'] ?? '').toString();
          usedPassword = (acct['password'] ?? '').toString();
          print('[AutoLogin] ${profile.name} - Found assigned account: $usedEmail');
        } else {
          print('[AutoLogin] ${profile.name} - No account assigned to this profile in Settings!');
        }
      } catch (e) {
        print('[AutoLogin] ${profile.name} - Error looking up account: $e');
      }
    }
    
    // Check if we have valid credentials
    if (usedEmail.isEmpty || usedPassword.isEmpty) {
      print('[AutoLogin] ${profile.name} - SKIPPING: No email/password assigned!');
      profile.status = ProfileStatus.error;
      return false;
    }
    
    print('\n${'=' * 60}');
    print('[AutoLogin] ${profile.name} - Starting Playwright login for $usedEmail');
    print('=' * 60);

    final pw = PlaywrightBrowserService();

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_isCancelled) {
        print('[AutoLogin] ${profile.name} - ⛔ CANCELLED');
        profile.status = ProfileStatus.disconnected;
        return false;
      }
      
      if (attempt > 1) {
        print('[AutoLogin] ${profile.name} - Retry attempt $attempt/$maxAttempts');
      }

      try {
        // Step 1: Ensure browser is launched via Playwright
        _checkCancelled(profile.name);
        if (profile.generator == null || !profile.generator!.isConnected) {
          print('[AutoLogin] ${profile.name} - Launching browser via Playwright...');
          final launched = await profileManager.launchProfile(profile, headless: headless);
          if (!launched) throw Exception('Failed to launch browser');
          final connected = await profileManager.connectToProfileWithoutToken(profile);
          if (!connected) throw Exception('Failed to connect to browser');
        }

        // Step 2: Delegate entire login to Playwright server
        // The server handles: navigate -> CSRF -> OAuth -> email -> password -> redirect -> token
        _checkCancelled(profile.name);
        print('[AutoLogin] ${profile.name} - Sending login to Playwright server...');
        
        final result = await pw.login(
          port: profile.debugPort,
          email: usedEmail,
          password: usedPassword,
        );
        
        if (_isCancelled) {
          profile.status = ProfileStatus.disconnected;
          return false;
        }

        if (result['success'] == true) {
          final token = result['token'] as String?;
          if (token != null && token.isNotEmpty) {
            profile.accessToken = token;
            profile.status = ProfileStatus.connected;
            profile.consecutive403Count = 0;
            print('[AutoLogin] ${profile.name} - ✓ Login successful! Token obtained');
            return true;
          }
          
          // Login succeeded but no token yet — try to get token
          print('[AutoLogin] ${profile.name} - Login succeeded, verifying token...');
          final verifiedToken = await _verifyLoginWithRetry(profile);
          if (verifiedToken != null) {
            profile.accessToken = verifiedToken;
            profile.status = ProfileStatus.connected;
            profile.consecutive403Count = 0;
            print('[AutoLogin] ${profile.name} - ✓ Token verified!');
            return true;
          }
        }
        
        print('[AutoLogin] ${profile.name} - ✗ Login failed: ${result['error'] ?? 'Unknown'}');
        if (attempt < maxAttempts) {
          await _delayWithCancellation(Duration(seconds: 5), profile.name);
          continue;
        }
      } on _CancelledException {
        print('[AutoLogin] ${profile.name} - ⛔ Login cancelled by user');
        profile.status = ProfileStatus.disconnected;
        return false;
      } catch (e) {
        if (_isCancelled) {
          profile.status = ProfileStatus.disconnected;
          return false;
        }
        print('[AutoLogin] ${profile.name} - Error on attempt $attempt: $e');
        if (attempt < maxAttempts) {
          try {
            await _delayWithCancellation(Duration(seconds: 5), profile.name);
          } on _CancelledException {
            profile.status = ProfileStatus.disconnected;
            return false;
          }
          continue;
        }
      }
    }

    print('[AutoLogin] ${profile.name} - ✗ Login failed after $maxAttempts attempts');
    profile.status = ProfileStatus.error;
    return false;
  }



  /// Relogin a single profile after 403 errors
  Future<void> reloginProfile(
    ChromeProfile profile,
    String email,
    String password,
  ) async {
    print('\n[Relogin] ${profile.name} - Too many 403 errors, relogging...');
    profile.status = ProfileStatus.relogging;
    profile.consecutive403Count = 0;
    // Ensure any previous cancellation state is cleared before relogin
    if (_isCancelled) {
      print('[Relogin] ${profile.name} - Clearing previous cancellation flag before relogin');
      resetCancellation();
    }
    
    // CRITICAL: Bring browser window to front
    // Login UI (reCAPTCHA, input fields) may not work if window is in background
    try {
      print('[Relogin] ${profile.name} - Bringing browser window to front...');
      
      // Step 1: Playwright handles page focus automatically
      // No CDP command needed
      
      // Step 2: Windows API (brings Chrome window to very top of all windows)
      if (Platform.isWindows) {
        try {
          // Use native Win32 FFI instead of PowerShell (avoids Defender issues)
          final activated = await Win32Api.bringChromeToFront();
          if (activated) {
            print('[Relogin] ${profile.name} - ✓ Window brought to VERY TOP (native FFI)');
          } else {
            print('[Relogin] ${profile.name} - ✓ CDP activation done (no Chrome window found)');
          }
        } catch (e) {
          print('[Relogin] ${profile.name} - ✓ CDP activation done (Win32 API failed: $e)');
        }
      } else {
        print('[Relogin] ${profile.name} - ✓ Window activated (CDP only)');
      }
    } catch (e) {
      print('[Relogin] ${profile.name} - Warning: Could not bring window to front: $e');
    }
    
    // CRITICAL: Clear old reCAPTCHA tokens
    // Tokens generated before relogin are tied to the old session and will get 403
    if (profile.generator != null) {
      print('[Relogin] ${profile.name} - Clearing old session tokens...');
      profile.generator!.clearPrefetchedTokens();
    }


    try {
      // Simplified relogin: just refresh & re-navigate (no data clearing)
      // Clearing cookies/cache causes instability and triggers bot detection
      print('[Relogin] ${profile.name} - Refreshing browser session...');
      
      // Step 1: Navigate to Flow with event-based wait
      _checkCancelled(profile.name);
      if (profile.generator != null && profile.generator!.isConnected) {
        await profile.generator!.navigateAndWait('https://labs.google/fx/tools/flow');
        await profile.generator!.waitForNetworkIdle(timeoutSeconds: 8);
      } else {
        // Reconnect if disconnected
        final gen = DesktopGenerator(debugPort: profile.debugPort);
        await gen.connect();
        profile.generator = gen;
        await gen.navigateAndWait('https://labs.google/fx/tools/flow');
        await gen.waitForNetworkIdle(timeoutSeconds: 8);
      }
      
      // Step 2: Brief stabilization
      _checkCancelled(profile.name);
      await Future.delayed(const Duration(seconds: 2));
    } on _CancelledException {
      print('[Relogin] ${profile.name} - ⛔ Relogin cancelled during cleanup');
      profile.status = ProfileStatus.disconnected;
      return;
    } catch (e) {
      print('[Relogin] ${profile.name} - Error during cleanup: $e');
    }

    // Step 5: Perform the actual login (autoLogin will navigate to Flow)
    _checkCancelled(profile.name);
    print('[Relogin] ${profile.name} - Step 5: Starting login process...');
    // Only use specifically assigned account from Settings - NO FALLBACK
    var usedEmail = email;
    var usedPassword = password;
    if ((usedEmail.isEmpty || usedPassword.isEmpty)) {
      try {
        // Only use specifically assigned account - NO FALLBACK
        final acct = SettingsService.instance.getAssignedAccountForProfileName(profile.name);
        if (acct != null) {
          usedEmail = (acct['username'] ?? '').toString();
          usedPassword = (acct['password'] ?? '').toString();
          print('[Relogin] ${profile.name} - Found assigned account: $usedEmail');
        } else {
          print('[Relogin] ${profile.name} - No account assigned to this profile in Settings!');
        }
      } catch (e) {
        print('[Relogin] ${profile.name} - Error looking up account: $e');
      }
    }

    final success = await autoLogin(
      profile: profile,
      email: usedEmail,
      password: usedPassword,
      maxAttempts: 3,
      headless: profile.headless,
    );

    if (success) {
      print('[Relogin] ${profile.name} - ✓ Relogin successful');
      try {
        // Notify the unified generator service to update any pending polls
        VideoGenerationService().onProfileRelogin(profile, profile.accessToken ?? '');
      } catch (e) {
        print('[Relogin] ${profile.name} - Warning: Failed to notify generator of relogin: $e');
      }
      
      // CRITICAL: Wait for browser to be fully ready before resuming
      print('[Relogin] ${profile.name} - Waiting for browser to be fully ready...');
      
      try {
        // Step 1: Wait for page to fully load
        await _delayWithCancellation(const Duration(seconds: 3), profile.name);
        
        // Step 2: Wait for textarea to be ready (skip project creation)
        _checkCancelled(profile.name);
        print('[Relogin] ${profile.name} - Waiting for textarea to be ready...');
        bool textareaReady = false;
        for (int i = 0; i < 10; i++) {
          _checkCancelled(profile.name);
          final result = await profile.generator!.executeJs('''
            (() => {
              const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
              return textarea !== null && textarea.offsetParent !== null;
            })()
          ''');
          if (result == true) {
            textareaReady = true;
            break;
          }
          await _delayWithCancellation(const Duration(seconds: 1), profile.name);
        }
        
        if (textareaReady) {
          print('[Relogin] ${profile.name} - ✓ Textarea is ready');
        } else {
          print('[Relogin] ${profile.name} - ⚠️ Textarea not found, but continuing...');
        }
        
        // Step 3: Settings will be applied via API parameters (not UI automation)
        _checkCancelled(profile.name);
        final settings = SettingsService.instance;
        if (settings.currentModel != null && settings.currentAspectRatio != null) {
          print('[Relogin] ${profile.name} - Settings will be applied via API parameters');
        }
        
        // Step 4: Final wait to ensure everything is stable
        await _delayWithCancellation(const Duration(seconds: 2), profile.name);
        print('[Relogin] ${profile.name} - ✓ Browser fully ready for generation');
        
        // CRITICAL: Mark profile as ready so producer can use it
        VideoGenerationService().markProfileReady(profile.name);
        
      } on _CancelledException {
        print('[Relogin] ${profile.name} - ⛔ Relogin cancelled during post-login setup');
        profile.status = ProfileStatus.disconnected;
        VideoGenerationService().markProfileReady(profile.name); // Remove from waiting list
        return;
      } catch (e) {
        print('[Relogin] ${profile.name} - ⚠️ Post-login setup error: $e');
        // Mark as ready anyway so it can be used (may get 403 and retry)
        VideoGenerationService().markProfileReady(profile.name);
      }
    } else {
      print('[Relogin] ${profile.name} - ✗ Relogin failed, will retry in 60s...');
      // Don't mark as error - keep as disconnected so it can be retried
      profile.status = ProfileStatus.disconnected;
      
      // Remove from waiting list since login failed
      VideoGenerationService().markProfileReady(profile.name);
      
      // Schedule another relogin attempt after delay
      // NOTE: We don't use _delayWithCancellation here because this is a separate background task
      // and we want it to be cancelable via the global flag if it starts.
      Future.delayed(Duration(seconds: 60), () {
        if (_isCancelled) return;
        if (profile.status == ProfileStatus.disconnected) {
          print('[Relogin] ${profile.name} - Retrying relogin...');
          reloginProfile(profile, email, password);
        }
      });
    }
  }

  /// Ensure browser is fully ready for generation (project open, textarea ready, settings applied)
  Future<void> _ensureBrowserReady(ChromeProfile profile) async {
    try {
      // Step 1: Wait for page to fully load
      await _delayWithCancellation(const Duration(seconds: 3), profile.name);
      
      // Step 2: Wait for textarea to be ready (skip project creation)
      _checkCancelled(profile.name);
      print('[Relogin] ${profile.name} - Waiting for textarea to be ready...');
      bool textareaReady = false;
      for (int i = 0; i < 10; i++) {
        _checkCancelled(profile.name);
        final result = await profile.generator!.executeJs('''
          (() => {
            const textarea = document.getElementById('PINHOLE_TEXT_AREA_ELEMENT_ID');
            return textarea !== null && textarea.offsetParent !== null;
          })()
        ''');
        if (result == true) {
          textareaReady = true;
          break;
        }
        await _delayWithCancellation(const Duration(seconds: 1), profile.name);
      }
      
      if (textareaReady) {
        print('[Relogin] ${profile.name} - ✓ Textarea is ready');
      } else {
        print('[Relogin] ${profile.name} - ⚠️ Textarea not found, but continuing...');
      }
      
      // Step 3: Settings will be applied via API parameters (not UI automation)
      final settings = SettingsService.instance;
      if (settings.currentModel != null && settings.currentAspectRatio != null) {
        print('[Relogin] ${profile.name} - Settings will be applied via API parameters');
      }
      
      // Step 4: Final wait to ensure everything is stable
      await Future.delayed(const Duration(seconds: 2));
      print('[Relogin] ${profile.name} - ✓ Browser fully ready for generation');
    } catch (e) {
      print('[Relogin] ${profile.name} - ⚠️ Browser readiness check error: $e');
    }
  }

  /// Login ALL browsers (Super Fast Strategy)
  Future<void> loginAllProfiles(
    int count,
    String email,
    String password, {
    bool headless = false,
  }) async {
    // Reset cancellation flag at start of new login session
    resetCancellation();
    
    print('\n${'=' * 60}');
    print('MULTI-PROFILE LOGIN (FAST STRATEGY) - Launching $count profiles');
    print('=' * 60);

    // Initialize profiles
    await profileManager.initializeProfiles(count);

    if (profileManager.profiles.isEmpty) return;

    // Step 1: Perform FULL login on the FIRST browser only
    final firstProfile = profileManager.profiles[0];
    print('[FastLogin] Performing full login on first profile: ${firstProfile.name}');
    
    await profileManager.launchProfile(firstProfile, headless: headless);
    await profileManager.connectToProfileWithoutToken(firstProfile);
    
    final firstSuccess = await autoLogin(
      profile: firstProfile,
      email: email,
      password: password,
    );

    if (!firstSuccess) {
      print('[FastLogin] ✗ First profile login failed. Aborting fast strategy.');
      return;
    }

    // Step 2: Simply navigate all OTHER browsers to Flow
    // If they share data dirs or if the session is cookie-preserved, they will log in instantly
    print('[FastLogin] First profile success! Launching remaining ${profileManager.profiles.length - 1} profiles...');
    
    int successCount = 1;

    for (var i = 1; i < profileManager.profiles.length; i++) {
      if (_isCancelled) break;
      
      final profile = profileManager.profiles[i];
      print('\n[FastLogin] ${profile.name} (${i + 1}/$count) - Setting up...');

      // Launch and connect the browser first
      final launched = await profileManager.launchProfile(profile, headless: headless);
      if (!launched) continue;
      
      final connected = await profileManager.connectToProfileWithoutToken(profile);
      if (!connected) continue;

      // Perform full login with assigned account
      if (await autoLogin(profile: profile, email: email, password: password, headless: headless)) {
        successCount++;
      }
    }

    print('\n${'=' * 60}');
    print('FAST MULTI-PROFILE LOGIN COMPLETE - $successCount/$count connected');
    print('=' * 60);
  }

  // ========== HELPER METHODS ==========

  // _clearBrowserData removed — Playwright handles browser state, no direct CDP needed


  Future<void> _navigateToFlow(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Navigating to Flow...');
    await profile.generator!.executeJs("window.location.href = 'https://labs.google/fx/tools/flow'");
    await Future.delayed(const Duration(seconds: 8));
    

  }

  Future<bool> _initiateLoginWithCSRF(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Initiating login via Fast CSRF strategy...');
    
    try {
      final result = await profile.generator!.executeJs('''
        (async function() {
          try {
            // 1. Get CSRF Token programmatically
            const csrfRes = await fetch('https://labs.google/fx/api/auth/csrf');
            const csrfData = await csrfRes.json();
            const token = csrfData.csrfToken;
            
            if (!token) return 'NO_CSRF';
            
            // 2. Post to the Signin endpoint directly with the CSRF token
            const formData = new URLSearchParams();
            formData.append('csrfToken', token);
            formData.append('callbackUrl', 'https://labs.google/fx/tools/flow');
            formData.append('json', 'true');
            
            const signinRes = await fetch('https://labs.google/fx/api/auth/signin/google', {
              method: 'POST',
              headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
              body: formData.toString()
            });
            
            const signinData = await signinRes.json();
            
            // 3. Redirect instantly to the Google Account selection page
            if (signinData.url) {
               window.location.href = signinData.url;
               return 'REDIRECTING';
            }
            return 'NO_URL';
          } catch(e) {
            return 'ERROR: ' + e.toString();
          }
        })()
      ''');

      if (result == 'REDIRECTING') {
        print('[AutoLogin] ${profile.name} - ✓ CSRF Sign-in initiated, redirecting to Google...');
        return true;
      } else {
        print('[AutoLogin] ${profile.name} - ✗ CSRF Login failed: $result');
        return false;
      }
    } catch (e) {
      print('[AutoLogin] ${profile.name} - ✗ Error in CSRF initiation: $e');
      return false;
    }
  }

  Future<bool> _clickCreateWithFlow(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Looking for "Create with Flow" button...');

    for (var i = 0; i < 15; i++) {
      try {
        final clicked = await profile.generator!.executeJs('''
          (async function() {
            const buttons = Array.from(document.querySelectorAll('button, div[role="button"], a'));
            const createBtn = buttons.find(b => 
              b.innerText && b.innerText.includes('Create with Flow')
            );
            if (createBtn) {
              createBtn.scrollIntoView({block: "center"});
              await new Promise(r => setTimeout(r, 1000));
              createBtn.click();
              return true;
            }
            return false;
          })()
        ''');

        if (clicked == true) {
          print('[AutoLogin] ${profile.name} - ✓ Clicked "Create with Flow"');
          return true;
        }

        await Future.delayed(Duration(seconds: 2));
      } catch (e) {
        print('[AutoLogin] ${profile.name} - Error clicking button: $e');
      }
    }

    return false;
  }

  Future<bool> _waitForGoogleOAuth(ChromeProfile profile, {int maxSeconds = 15}) async {
    for (var i = 0; i < maxSeconds; i++) {
      if (_isCancelled) {
        throw _CancelledException();
      }
      try {
        final url = await profile.generator!.getCurrentUrl();
        if (url.contains('accounts.google.com')) {
          print('[AutoLogin] ${profile.name} - ✓ On Google OAuth page');
          return true;
        }
      } catch (e) {}
      try {
        await _delayWithCancellation(Duration(seconds: 1), profile.name);
      } on _CancelledException {
        rethrow;
      }
    }
    return false;
  }

  Future<bool> _waitForPageLoad(ChromeProfile profile, {int maxSeconds = 10}) async {
    for (var i = 0; i < maxSeconds; i++) {
      if (_isCancelled) {
        throw _CancelledException();
      }
      try {
        final ready = await profile.generator!.executeJs('''
          (function() {
            return document.readyState === 'complete';
          })()
        ''');
        if (ready == true) {
          print('[AutoLogin] ${profile.name} - ✓ Page loaded');
          return true;
        }
      } catch (e) {}
      try {
        await _delayWithCancellation(Duration(seconds: 2), profile.name);
      } on _CancelledException {
        rethrow;
      }
    }
    return false;
  }

  Future<bool> _waitForEmailField(ChromeProfile profile, {int maxSeconds = 15}) async {
    print('[AutoLogin] ${profile.name} - Waiting for email input field...');
    for (var i = 0; i < maxSeconds; i++) {
      if (_isCancelled) {
        throw _CancelledException();
      }
      try {
        final found = await profile.generator!.executeJs('''
          (function() {
            const input = document.getElementById('identifierId');
            return input !== null && input.offsetParent !== null;
          })()
        ''');
        if (found == true) {
          print('[AutoLogin] ${profile.name} - ✓ Email field ready');
          return true;
        }
      } catch (e) {}
      try {
        await _delayWithCancellation(Duration(seconds: 1), profile.name);
      } on _CancelledException {
        rethrow;
      }
    }
    return false;
  }

  Future<bool> _waitForPasswordField(ChromeProfile profile, {int maxSeconds = 15}) async {
    print('[AutoLogin] ${profile.name} - Waiting for password input field...');
    for (var i = 0; i < maxSeconds; i++) {
      if (_isCancelled) {
        throw _CancelledException();
      }
      try {
        final found = await profile.generator!.executeJs('''
          (function() {
            const input = document.querySelector('input[name="Passwd"]');
            return input !== null && input.offsetParent !== null;
          })()
        ''');
        if (found == true) {
          print('[AutoLogin] ${profile.name} - ✓ Password field ready');
          return true;
        }
      } catch (e) {}
      try {
        await _delayWithCancellation(Duration(seconds: 1), profile.name);
      } on _CancelledException {
        rethrow;
      }
    }
    return false;
  }

  Future<void> _enterEmail(ChromeProfile profile, String email) async {
    print('[AutoLogin] ${profile.name} - Entering email...');
    await profile.generator!.executeJs('''
      (async function() {
        const input = document.getElementById('identifierId');
        if (input) {
          input.focus();
          await new Promise(r => setTimeout(r, 500));
          input.value = '$email';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          await new Promise(r => setTimeout(r, 500));
        }
      })()
    ''');
  }

  Future<void> _clickNextEmail(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Clicking Next (email)...');
    await profile.generator!.executeJs('''
      (async function() {
        const btn = document.getElementById('identifierNext');
        if (btn) {
          btn.scrollIntoView({block: "center"});
          await new Promise(r => setTimeout(r, 500));
          btn.click();
        }
      })()
    ''');
  }

  Future<void> _enterPassword(ChromeProfile profile, String password) async {
    print('[AutoLogin] ${profile.name} - Entering password...');
    await profile.generator!.executeJs('''
      (async function() {
        const input = document.querySelector('input[name="Passwd"]');
        if (input) {
          input.focus();
          await new Promise(r => setTimeout(r, 500));
          input.value = '$password';
          input.dispatchEvent(new Event('input', { bubbles: true }));
          await new Promise(r => setTimeout(r, 500));
        }
      })()
    ''');
  }

  Future<void> _clickNextPassword(ChromeProfile profile) async {
    print('[AutoLogin] ${profile.name} - Clicking Next (password)...');
    await profile.generator!.executeJs('''
      (async function() {
        const btn = document.querySelector('#passwordNext');
        if (btn) {
          btn.scrollIntoView({block: "center"});
          await new Promise(r => setTimeout(r, 500));
          btn.click();
        }
      })()
    ''');
  }

  Future<bool> _waitForFlowRedirect(ChromeProfile profile, {int maxSeconds = 20}) async {
    for (var i = 0; i < maxSeconds; i++) {
      // Check for cancellation
      if (_isCancelled) {
        print('[AutoLogin] ${profile.name} - ⛔ CANCELLED during redirect wait');
        throw _CancelledException();
      }
      
      try {
        final url = await profile.generator!.getCurrentUrl();
        if (url.contains('labs.google')) {
          print('[AutoLogin] ${profile.name} - ✓ Redirected to Flow');
          return true;
        }
      } catch (e) {}
      
      try {
        await _delayWithCancellation(Duration(seconds: 1), profile.name);
      } on _CancelledException {
        rethrow;
      }
    }
    return false;
  }

  Future<String?> _verifyLoginWithRetry(ChromeProfile profile, {int maxAttempts = 10}) async {
    // Check every 5 seconds for up to 50 seconds (10 attempts)
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      // Check for cancellation before waiting
      if (_isCancelled) {
        print('[AutoLogin] ${profile.name} - ⛔ CANCELLED during token verification');
        throw _CancelledException();
      }
      
      // Use cancellation-aware delay (5s intervals)
      try {
        await _delayWithCancellation(Duration(seconds: 5), profile.name);
      } on _CancelledException {
        print('[AutoLogin] ${profile.name} - ⛔ CANCELLED during token verification wait');
        rethrow;
      }
      
      print('[AutoLogin] ${profile.name} - Token verification attempt $attempt/$maxAttempts (${attempt * 5}s)...');

      // Check again after delay
      if (_isCancelled) {
        print('[AutoLogin] ${profile.name} - ⛔ CANCELLED during token verification');
        throw _CancelledException();
      }

      try {
        // Reconnect if needed
        if (profile.generator == null) {
        final gen = DesktopGenerator(debugPort: profile.debugPort);
          await gen.connect();
          profile.generator = gen;
        }

        final token = await profile.generator!.getAccessToken();
        if (token != null) {
          return token;
        }
      } catch (e) {
        if (_isCancelled) {
          throw _CancelledException();
        }
        print('[AutoLogin] ${profile.name} - Token check error: $e');
      }
    }

    return null;
  }
}

/// Exception thrown when login is cancelled
class _CancelledException implements Exception {
  @override
  String toString() => 'Login was cancelled by user';
}
