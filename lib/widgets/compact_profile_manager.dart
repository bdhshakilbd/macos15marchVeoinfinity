import 'package:flutter/material.dart';
import '../services/profile_manager_service.dart';
import '../services/settings_service.dart';
import '../services/mobile/mobile_browser_service.dart';
import '../utils/theme_provider.dart';
import '../services/localization_service.dart';

/// Compact multi-profile widget for integration into existing UI
class CompactProfileManagerWidget extends StatefulWidget {
  final Function(int)? onLogin;           // Login SINGLE browser at count position
  final Function(int, String, String)? onLoginAll;  // Login ALL browsers from 1 to count
  final Function(int)? onConnectOpened;
  final Function(int)? onOpenWithoutLogin;
  final ProfileManagerService? profileManager;
  final MobileBrowserService? mobileBrowserService;  // For embedded webview browser status
  final VoidCallback? onStop;

  const CompactProfileManagerWidget({
    Key? key,
    this.onLogin,
    this.onLoginAll,
    this.onConnectOpened,
    this.onOpenWithoutLogin,
    this.profileManager,
    this.mobileBrowserService,
    this.onStop,
  }) : super(key: key);

  @override
  State<CompactProfileManagerWidget> createState() => _CompactProfileManagerWidgetState();
}

class _CompactProfileManagerWidgetState extends State<CompactProfileManagerWidget> {
  int _profileCount = 2;
  bool _isProcessing = false;
  String _processingMessage = 'Processing...';

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: Browser Count + Buttons
        Row(
          children: [
            Text(LocalizationService().tr('home.count_label'), style: TextStyle(fontSize: 10, color: ThemeProvider().textSecondary)),
            const SizedBox(width: 4),
            PopupMenuButton<int>(
              onSelected: _isProcessing ? null : (value) {
                setState(() => _profileCount = value);
              },
              offset: const Offset(0, 28),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              color: ThemeProvider().isDarkMode ? const Color(0xFF1E293B) : Colors.white,
              elevation: 8,
              constraints: const BoxConstraints(minWidth: 60),
              enabled: !_isProcessing,
              itemBuilder: (context) {
                return [1, 2, 3, 4, 5, 6, 8, 10].map((count) {
                  final isSelected = _profileCount == count;
                  return PopupMenuItem<int>(
                    value: count,
                    height: 32,
                    child: Row(
                      children: [
                        Container(
                          width: 6, height: 6,
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFF2563EB) : const Color(0xFF2563EB).withOpacity(0.3),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('$count', style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                            color: isSelected
                              ? (ThemeProvider().isDarkMode ? Colors.white : const Color(0xFF1E40AF))
                              : (ThemeProvider().isDarkMode ? const Color(0xFFCBD5E1) : const Color(0xFF374151)),
                          )),
                        ),
                        if (isSelected)
                          const Icon(Icons.check, size: 14, color: Color(0xFF2563EB)),
                      ],
                    ),
                  );
                }).toList();
              },
              child: Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: ThemeProvider().isDarkMode ? ThemeProvider().borderLight : const Color(0xFFD1D5DB)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.layers, size: 11, color: ThemeProvider().isDarkMode ? ThemeProvider().textSecondary : const Color(0xFF2563EB)),
                    const SizedBox(width: 4),
                    Text('$_profileCount', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: ThemeProvider().textPrimary)),
                    const SizedBox(width: 2),
                    Icon(Icons.arrow_drop_down, size: 14, color: ThemeProvider().textTertiary),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            
            // Login SINGLE browser (at count position)
            Expanded(
              child: SizedBox(
                height: 24,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleLogin,
                  child: Text('🔐 ${LocalizationService().tr('btn.login')}', style: TextStyle(fontSize: 8)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ThemeProvider().isDarkMode ? const Color(0xFF4A7C6A) : const Color(0xFF2E7D5E), // pastel forest-teal
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            
            // Login ALL browsers (from 1 to count)
            Expanded(
              child: SizedBox(
                height: 24,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleLoginAll,
                  child: Text('🚀 ${LocalizationService().tr('btn.connect')}', style: TextStyle(fontSize: 8)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ThemeProvider().isDarkMode ? const Color(0xFF3D6B4A) : const Color(0xFF2E7D32), // pastel rich-green
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 2),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),

            // STOP button
            SizedBox(
              height: 24,
              width: 28,
              child: ElevatedButton(
                onPressed: widget.onStop,
                child: Icon(Icons.stop, size: 12),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ThemeProvider().isDarkMode ? const Color(0xFF7A3E3E) : Colors.red, // pastel dusty-rose
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        
        // Row 3: Connect buttons
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 22,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleConnectOpened,
                  child: Text(LocalizationService().tr('btn.connect_opened'), style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ThemeProvider().isDarkMode ? const Color(0xFF4A6E7A) : const Color(0xFF0277BD), // pastel ocean-teal
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: SizedBox(
                height: 22,
                child: ElevatedButton(
                  onPressed: _isProcessing ? null : _handleOpenWithoutLogin,
                  child: Text(LocalizationService().tr('btn.open_no_login'), style: TextStyle(fontSize: 9)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ThemeProvider().isDarkMode ? const Color(0xFF4A4066) : Colors.grey[700], // pastel indigo-mist
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(horizontal: 6),
                  ),
                ),
              ),
            ),
          ],
        ),

        // Status row - Show embedded browser status if mobileBrowserService exists, otherwise CDP status
        if (widget.mobileBrowserService != null && widget.mobileBrowserService!.profiles.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: ThemeProvider().isDarkMode ? ThemeProvider().inputBg : Colors.blue.shade50,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: ThemeProvider().isDarkMode ? ThemeProvider().borderColor : Colors.blue.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_tree, size: 12, color: ThemeProvider().isDarkMode ? ThemeProvider().textSecondary : Colors.blue),
                const SizedBox(width: 4),
                Text(
                   '${widget.mobileBrowserService!.profiles.where((p) => p.status == MobileProfileStatus.ready).length}/${widget.mobileBrowserService!.profiles.length} ${LocalizationService().tr('home.connected')}',
                  style: TextStyle(fontSize: 9, color: ThemeProvider().isDarkMode ? ThemeProvider().textPrimary : Colors.blue.shade900),
                ),
              ],
            ),
          ),
        ] else if (widget.profileManager != null &&
            widget.profileManager!.profiles.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: ThemeProvider().isDarkMode ? ThemeProvider().inputBg : Colors.blue.shade50,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: ThemeProvider().isDarkMode ? ThemeProvider().borderColor : Colors.blue.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.account_tree, size: 12, color: ThemeProvider().isDarkMode ? ThemeProvider().textSecondary : Colors.blue),
                const SizedBox(width: 4),
                Text(
                   '${widget.profileManager!.countConnectedProfiles()}/${widget.profileManager!.profiles.length} ${LocalizationService().tr('home.connected')}',
                  style: TextStyle(fontSize: 9, color: ThemeProvider().isDarkMode ? ThemeProvider().textPrimary : Colors.blue.shade900),
                ),
              ],
            ),
          ),
        ],
        
        // Loading indicator when browsers are opening
        if (_isProcessing) ...[
          const SizedBox(height: 6),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.amber.shade300),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.amber.shade700),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _processingMessage,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.amber.shade900,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // Login SINGLE browser at count position (e.g., count=4 means login ONLY Browser 4)
  Future<void> _handleLogin() async {
    // Check if accounts are configured in SettingsService
    if (SettingsService.instance.accounts.isEmpty) {
      _showError('⚠️ No accounts configured! Please add accounts in Settings first.');
      return;
    }
    
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Logging in browser $_profileCount...';
    });

    try {
      await widget.onLogin?.call(_profileCount);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Login failed');
      }
    }
  }

  // Login ALL browsers from 1 to count (e.g., count=4 means login 1, 2, 3, 4)
  Future<void> _handleLoginAll() async {
    // Check if accounts are configured in SettingsService
    if (SettingsService.instance.accounts.isEmpty) {
      _showError('⚠️ No accounts configured! Please add accounts in Settings first.');
      return;
    }
    
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Logging in all $_profileCount browsers...';
    });

    try {
      await widget.onLoginAll?.call(_profileCount, '', '');
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Login all failed');
      }
    }
  }

  Future<void> _handleConnectOpened() async {
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Connecting opened browsers...';
    });

    try {
      await widget.onConnectOpened?.call(_profileCount);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Connect failed');
      }
    }
  }

  Future<void> _handleOpenWithoutLogin() async {
    setState(() {
      _isProcessing = true;
      _processingMessage = 'Opening $_profileCount browsers, please wait...';
    });

    try {
      await widget.onOpenWithoutLogin?.call(_profileCount);
      if (mounted) setState(() => _isProcessing = false);
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Open failed');
      }
    }
  }

  Future<void> _handleKillAll() async {
    setState(() => _isProcessing = true);
    try {
      // Kill profiles tracked by service
      if (widget.profileManager != null) {
        await widget.profileManager!.killAllProfiles();
      } else {
        // Fallback: kill by port even if no service attached
        await ProfileManagerService.killAllChromeProcesses();
      }
      if (mounted) {
        setState(() => _isProcessing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Text('✅ All browser processes killed', style: TextStyle(fontSize: 13)),
              ],
            ),
            backgroundColor: Colors.green.shade700,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isProcessing = false);
        _showError('Kill failed: $e');
      }
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message, 
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        backgroundColor: message.contains('No accounts') ? Colors.orange.shade700 : Colors.red.shade700,
        duration: Duration(seconds: message.contains('No accounts') ? 4 : 2),
        behavior: SnackBarBehavior.floating,
        action: message.contains('No accounts') 
          ? SnackBarAction(
              label: 'Open Settings',
              textColor: Colors.white,
              onPressed: () {
                // Navigate to settings tab
                DefaultTabController.of(context).animateTo(6); // Settings is usually tab 6
              },
            )
          : null,
      ),
    );
  }
}
