import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../services/settings_service.dart';
import '../utils/theme_provider.dart';
import '../services/localization_service.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onBack;
  
  const SettingsScreen({super.key, this.onBack});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class GoogleAccount {
  String id;
  String username;
  String password;
  List<String> assignedProfiles; // profile ids

  GoogleAccount({required this.id, required this.username, required this.password, List<String>? assignedProfiles})
      : assignedProfiles = assignedProfiles ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'password': password,
        'assignedProfiles': assignedProfiles,
      };

  factory GoogleAccount.fromJson(Map<String, dynamic> j) => GoogleAccount(
        id: j['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
        username: j['username'] ?? '',
        password: j['password'] ?? '',
        assignedProfiles: (j['assignedProfiles'] as List?)?.map((e) => e.toString()).toList() ?? [],
      );
}

class BrowserProfile {
  String id;
  String name;

  BrowserProfile({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory BrowserProfile.fromJson(Map<String, dynamic> j) => BrowserProfile(id: j['id'], name: j['name']);
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _geminiController = TextEditingController();
  int _geminiKeyCount = 0;

  List<BrowserProfile> _profiles = [];
  List<GoogleAccount> _accounts = [];
  
  int _selectedTab = 0; // 0 = Gemini API, 1 = Browsers, 2 = Google Accounts
  bool _isLoading = true; // Show shimmer on first load
  bool _showApiKeys = false; // Toggle to show/hide API keys

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final g = prefs.getString('settings_gemini_api') ?? '';
    _geminiController.text = g;
    _updateGeminiCount();

    final profilesJson = prefs.getString('settings_browser_profiles');
    if (profilesJson != null && profilesJson.isNotEmpty) {
      try {
        final list = jsonDecode(profilesJson) as List;
        _profiles = list.map((e) => BrowserProfile.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (_) {}
    } else {
      // Seed with some example profiles if none
      _profiles = [
        BrowserProfile(id: 'profile_default', name: 'Default'),
        BrowserProfile(id: 'profile_1', name: 'Profile 1'),
        BrowserProfile(id: 'profile_2', name: 'Profile 2'),
      ];
    }

    final accountsJson = prefs.getString('settings_google_accounts');
    if (accountsJson != null && accountsJson.isNotEmpty) {
      try {
        final list = jsonDecode(accountsJson) as List;
        _accounts = list.map((e) => GoogleAccount.fromJson(Map<String, dynamic>.from(e))).toList();
      } catch (_) {}
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings_gemini_api', _geminiController.text);
    await prefs.setString('settings_browser_profiles', jsonEncode(_profiles.map((p) => p.toJson()).toList()));
    await prefs.setString('settings_google_accounts', jsonEncode(_accounts.map((a) => a.toJson()).toList()));
    await SettingsService.instance.reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✓ ${LocalizationService().tr('common.success')}'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _addProfile() async {
    final nameCtrl = TextEditingController();
    final res = await showDialog<String?>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(LocalizationService().tr('set.add_browser_profile')),
          content: TextField(
            controller: nameCtrl,
            decoration: InputDecoration(
              labelText: LocalizationService().tr('set.profile_name'),
              hintText: LocalizationService().tr('set.profile_name_hint'),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text(LocalizationService().tr('btn.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
              child: Text(LocalizationService().tr('btn.add')),
            ),
          ],
        );
      },
    );
    if (res != null && res.isNotEmpty) {
      setState(() {
        _profiles.add(BrowserProfile(id: 'profile_${DateTime.now().millisecondsSinceEpoch}', name: res));
      });
      await _saveSettings();
    }
  }

  void _removeProfile(BrowserProfile profile) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(LocalizationService().tr('set.remove_browser_profile')),
          content: Text('${LocalizationService().tr('set.remove_profile_confirm')} "${profile.name}"?\n\n${LocalizationService().tr('set.remove_profile_note')}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(LocalizationService().tr('btn.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: Text(LocalizationService().tr('set.remove')),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      setState(() {
        // Remove from profiles list
        _profiles.remove(profile);
        // Remove from all accounts' assignedProfiles
        for (var account in _accounts) {
          account.assignedProfiles.remove(profile.id);
        }
      });
      await _saveSettings();
    }
  }

  void _addAccount() async {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final res = await showDialog<bool?>(
      context: context,
      builder: (ctx) {
        var obscure = true;
        return StatefulBuilder(
          builder: (ctx2, setSt) {
            return AlertDialog(
              title: Text(LocalizationService().tr('set.add_google_account')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: userCtrl,
                    decoration: InputDecoration(
                      labelText: LocalizationService().tr('set.email_username'),
                      prefixIcon: const Icon(Icons.email),
                    ),
                    autofocus: true,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passCtrl,
                    decoration: InputDecoration(
                      labelText: LocalizationService().tr('settings.password'),
                      prefixIcon: const Icon(Icons.lock),
                      suffixIcon: IconButton(
                        icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setSt(() => obscure = !obscure),
                      ),
                    ),
                    obscureText: obscure,
                    enableInteractiveSelection: true,
                    autofillHints: const [AutofillHints.password],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    LocalizationService().tr('set.password_tip'),
                    style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(LocalizationService().tr('btn.cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(LocalizationService().tr('btn.add')),
                ),
              ],
            );
          },
        );
      },
    );

    if (res == true) {
      setState(() {
        _accounts.add(GoogleAccount(
          id: 'acct_${DateTime.now().millisecondsSinceEpoch}',
          username: userCtrl.text.trim(),
          password: passCtrl.text.trim(),
        ));
      });
      await _saveSettings();
    }
  }

  void _updateGeminiCount() {
    final lines = _geminiController.text.split(RegExp(r"\r?\n")).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    setState(() => _geminiKeyCount = lines.length);
  }

  void _editAccountAssignments(GoogleAccount account) async {
    final assigned = Set<String>.from(account.assignedProfiles);
    final res = await showDialog<bool?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setSt) {
            return AlertDialog(
              title: Text(LocalizationService().tr('set.assign_browser')),
              content: SizedBox(
                width: 400,
                child: _profiles.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(LocalizationService().tr('set.no_profiles_available')),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: _profiles
                            .map(
                              (p) => CheckboxListTile(
                                value: assigned.contains(p.id),
                                title: Text(p.name),
                                onChanged: (v) => setSt(() => v == true ? assigned.add(p.id) : assigned.remove(p.id)),
                              ),
                            )
                            .toList(),
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(LocalizationService().tr('btn.cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(LocalizationService().tr('btn.save')),
                ),
              ],
            );
          },
        );
      },
    );

    if (res == true) {
      setState(() {
        account.assignedProfiles = assigned.toList();
      });
      await _saveSettings();
    }
  }

  @override
  void dispose() {
    _geminiController.dispose();
    super.dispose();
  }

  /// Returns masked API keys for display (shows first 8 and last 4 chars)
  String _getMaskedKeys() {
    final keys = _geminiController.text.split('\n').where((k) => k.trim().isNotEmpty).toList();
    if (keys.isEmpty) return LocalizationService().tr('set.no_keys');
    
    return keys.map((key) {
      final trimmed = key.trim();
      if (trimmed.length <= 12) return '****';
      final start = trimmed.substring(0, 8);
      final end = trimmed.substring(trimmed.length - 4);
      return '$start••••••••••$end';
    }).join('\n');
  }

  @override
  Widget build(BuildContext context) {
    // If used inline (with onBack callback), render as content without Scaffold
    final isInlineMode = widget.onBack != null;
    
    final contentWidget = Row(
      children: [
        // Left sidebar navigation
        Container(
          width: 240,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.3),
            border: Border(right: BorderSide(color: ThemeProvider().borderColor)),
          ),
          child: Column(
            children: [
              // Header with back button if inline
              Container(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (isInlineMode)
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: widget.onBack,
                        tooltip: LocalizationService().tr('set.back'),
                      ),
                    if (isInlineMode) const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        LocalizationService().tr('settings.title'),
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  children: [
                    _buildNavItem(
                      icon: Icons.api,
                      title: LocalizationService().tr('set.gemini_api'),
                      index: 0,
                    ),
                    _buildNavItem(
                      icon: Icons.web,
                      title: LocalizationService().tr('set.browser_profiles'),
                      index: 1,
                    ),
                    _buildNavItem(
                      icon: Icons.account_circle,
                      title: LocalizationService().tr('set.google_accounts'),
                      index: 2,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Main content area with loading shimmer
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 400),
            child: _isLoading
                ? _buildShimmerPlaceholder()
                : _buildContentForTab(_selectedTab),
          ),
        ),
      ],
    );
    
    // If inline mode, wrap in Scaffold without AppBar (for Material ancestor)
    if (isInlineMode) {
      return Scaffold(
        body: contentWidget,
      );
    }
    
    // If standalone mode (Navigator), wrap in Scaffold with AppBar
    return Scaffold(
      appBar: AppBar(
        title: Text(LocalizationService().tr('settings.title')),
        centerTitle: false,
      ),
      body: contentWidget,
    );
  }

  Widget _buildNavItem({required IconData icon, required String title, required int index}) {
    final isSelected = _selectedTab == index;
    return ListTile(
      leading: Icon(icon, color: isSelected ? Theme.of(context).colorScheme.primary : null),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          color: isSelected ? Theme.of(context).colorScheme.primary : null,
        ),
      ),
      selected: isSelected,
      selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
      onTap: () => setState(() => _selectedTab = index),
    );
  }

  // Shimmer placeholder for loading state
  Widget _buildShimmerPlaceholder() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title shimmer
          Container(
            height: 32,
            width: 200,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 24),
          // Card placeholders
          for (int i = 0; i < 3; i++) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 20,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      height: 60,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  Widget _buildContentForTab(int tab) {
    switch (tab) {
      case 0:
        return _buildGeminiAPITab();
      case 1:
        return _buildBrowserProfilesTab();
      case 2:
        return _buildGoogleAccountsTab();
      default:
        return const Center(child: Text('Unknown tab'));
    }
  }

  // Gemini API Tab
  Widget _buildGeminiAPITab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.api, size: 28, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Text(
                LocalizationService().tr('set.gemini_config'),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            LocalizationService().tr('set.gemini_desc'),
            style: TextStyle(color: ThemeProvider().textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Toggle between masked view and edit mode
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        LocalizationService().tr('set.gemini_keys_label'),
                        style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
                      ),
                      IconButton(
                        icon: Icon(_showApiKeys ? Icons.visibility_off : Icons.visibility),
                        tooltip: _showApiKeys ? LocalizationService().tr('set.hide_keys') : LocalizationService().tr('set.show_keys'),
                        onPressed: () => setState(() => _showApiKeys = !_showApiKeys),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_showApiKeys)
                    // Editable TextField when visible
                    TextField(
                      controller: _geminiController,
                      decoration: const InputDecoration(
                        hintText: 'AIzaSy...\\nAIzaSy...',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      onChanged: (_) => _updateGeminiCount(),
                    )
                  else
                    // Masked display when hidden
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(color: ThemeProvider().borderColor),
                        borderRadius: BorderRadius.circular(4),
                        color: ThemeProvider().inputBg,
                      ),
                      constraints: const BoxConstraints(minHeight: 150),
                      child: Text(
                        _getMaskedKeys(),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: ThemeProvider().textSecondary,
                          height: 1.5,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.check_circle, color: Colors.green, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            '${LocalizationService().tr('set.parsed_keys')}: $_geminiKeyCount',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                      FilledButton.icon(
                        onPressed: () => _saveSettings(),
                        icon: const Icon(Icons.save),
                        label: Text(LocalizationService().tr('btn.save')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Browser Profiles Tab
  Widget _buildBrowserProfilesTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.web, size: 28, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Text(
                LocalizationService().tr('set.browser_profiles'),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            LocalizationService().tr('set.browser_desc'),
            style: TextStyle(color: ThemeProvider().textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_profiles.length} ${LocalizationService().tr('set.profiles_count')}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              FilledButton.icon(
                onPressed: _addProfile,
                icon: const Icon(Icons.add),
                label: Text(LocalizationService().tr('btn.add')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_profiles.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.web, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text(LocalizationService().tr('set.no_profiles')),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _addProfile,
                        icon: const Icon(Icons.add),
                        label: Text(LocalizationService().tr('set.create_first_profile')),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            ..._profiles.map((p) {
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: const Icon(Icons.person),
                  ),
                  title: Text(
                    p.name,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text('${LocalizationService().tr('set.profile_id')}: ${p.id}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    color: Colors.red,
                    tooltip: LocalizationService().tr('set.remove_profile'),
                    onPressed: () => _removeProfile(p),
                  ),
                ),
              );
            }).toList(),
        ],
      ),
    );
  }

  // Google Accounts Tab
  Widget _buildGoogleAccountsTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.account_circle, size: 28, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Text(
                LocalizationService().tr('set.google_accounts'),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            LocalizationService().tr('set.accounts_desc'),
            style: TextStyle(color: ThemeProvider().textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${_accounts.length} ${LocalizationService().tr('set.accounts_count')}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              FilledButton.icon(
                onPressed: _addAccount,
                icon: const Icon(Icons.add),
                label: Text(LocalizationService().tr('settings.add_account')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_accounts.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.account_circle, size: 64, color: Colors.grey.shade400),
                      const SizedBox(height: 16),
                      Text(LocalizationService().tr('set.no_accounts')),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _addAccount,
                        icon: const Icon(Icons.add),
                        label: Text(LocalizationService().tr('set.add_first_account')),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            ..._accounts.map((a) {
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                    child: Text(
                      a.username.isNotEmpty ? a.username[0].toUpperCase() : '?',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  title: Text(
                    a.username,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    a.assignedProfiles.isEmpty
                        ? LocalizationService().tr('set.not_assigned')
                        : '${LocalizationService().tr('set.assigned_to')} ${a.assignedProfiles.length} ${LocalizationService().tr('set.profiles_count')}',
                  ),
                  trailing: Wrap(
                    spacing: 8,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.people_outline),
                        tooltip: LocalizationService().tr('set.assign_profiles'),
                        onPressed: () => _editAccountAssignments(a),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        color: Colors.red,
                        tooltip: LocalizationService().tr('set.remove_account'),
                        onPressed: () {
                          setState(() => _accounts.remove(a));
                          _saveSettings();
                        },
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
        ],
      ),
    );
  }
}
