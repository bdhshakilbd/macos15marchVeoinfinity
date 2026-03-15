import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/theme_provider.dart';
import '../services/localization_service.dart';

/// Clone YouTube Screen - YouTube video cloning tool with story history sidebar
class CloneYouTubeScreen extends StatefulWidget {
  const CloneYouTubeScreen({super.key});

  @override
  State<CloneYouTubeScreen> createState() => _CloneYouTubeScreenState();
}

class _CloneYouTubeScreenState extends State<CloneYouTubeScreen> 
    with AutomaticKeepAliveClientMixin {
  
  @override
  bool get wantKeepAlive => true;
  
  InAppWebViewController? _webViewController;
  final GlobalKey _webViewKey = GlobalKey();
  bool _isWebViewLoading = true;
  bool _webViewInitialized = false;
  
  // Story history
  List<Map<String, dynamic>> _storyHistory = [];
  bool _historyPanelOpen = true;
  bool _isLoadingHistory = false;
  String? _selectedStoryId;
  DateTime? _lastHistoryLoad;
  
  // Paste prompt
  final TextEditingController _pasteController = TextEditingController();
  bool _isSavingPaste = false;
  String _pasteStatus = ''; // '', 'saving', 'saved', 'error'
  DateTime? _lastPasteTime;

  @override
  void initState() {
    super.initState();
    _loadStoryHistory();
    _pasteController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  Future<Directory> _getHistoryDir() async {
    final appDir = await getApplicationSupportDirectory();
    final historyDir = Directory('${appDir.path}${Platform.pathSeparator}story_history');
    if (!await historyDir.exists()) {
      await historyDir.create(recursive: true);
    }
    return historyDir;
  }

  Future<void> _loadStoryHistory({bool force = false}) async {
    if (_isLoadingHistory && !force) return;
    if (mounted) setState(() => _isLoadingHistory = true);
    
    try {
      final historyDir = await _getHistoryDir();
      print('[StoryHistory] Loading from: ${historyDir.path}');
      
      final allFiles = await historyDir.list().toList();
      final jsonFiles = allFiles.where((f) => f is File && f.path.endsWith('.json')).toList();
      print('[StoryHistory] Found ${jsonFiles.length} JSON files');
      
      final stories = <Map<String, dynamic>>[];
      for (final file in jsonFiles) {
        try {
          final content = await File(file.path).readAsString();
          final data = jsonDecode(content) as Map<String, dynamic>;
          data['_filePath'] = file.path;
          stories.add(data);
        } catch (e) {
          print('[StoryHistory] Skipping corrupt file: ${file.path} — $e');
        }
      }
      
      stories.sort((a, b) {
        final ta = a['timestamp'] as String? ?? '';
        final tb = b['timestamp'] as String? ?? '';
        return tb.compareTo(ta);
      });
      
      print('[StoryHistory] Loaded ${stories.length} stories');
      
      if (mounted) {
        setState(() {
          _storyHistory = stories;
          _isLoadingHistory = false;
        });
      }
    } catch (e) {
      print('[StoryHistory] Error loading: $e');
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _deleteStory(Map<String, dynamic> story) async {
    final filePath = story['_filePath'] as String?;
    if (filePath != null) {
      try {
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
        setState(() {
          _storyHistory.remove(story);
          if (_selectedStoryId == story['id']) _selectedStoryId = null;
        });
      } catch (_) {}
    }
  }

  void _copyStoryToClipboard(Map<String, dynamic> story) {
    final content = story['response'] as String? ?? story['prompt'] as String? ?? '';
    Clipboard.setData(ClipboardData(text: content));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Story copied to clipboard!'),
        backgroundColor: Color(0xFF16A34A),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _openStoryInExplorer(Map<String, dynamic> story) {
    final filePath = story['_filePath'] as String?;
    if (filePath != null) {
      // Open Windows Explorer with the file selected
      Process.run('explorer', ['/select,', filePath]);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    // Auto-refresh history when tab becomes visible (throttled to once per 3 seconds)
    final now = DateTime.now();
    if (_lastHistoryLoad == null || now.difference(_lastHistoryLoad!).inSeconds > 3) {
      _lastHistoryLoad = now;
      Future.microtask(() => _loadStoryHistory());
    }
    return Row(
      children: [
        // Left sidebar: Story History
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: _historyPanelOpen ? 280 : 0,
          curve: Curves.easeOut,
          child: _historyPanelOpen ? _buildHistoryPanel() : const SizedBox.shrink(),
        ),
        
        // Toggle button — white themed
        _buildToggleButton(),
        
        // Main content: WebView
        Expanded(
          child: Stack(
            children: [
              if (!_webViewInitialized || _webViewController != null)
                InAppWebView(
                  key: _webViewKey,
                  initialUrlRequest: URLRequest(
                    url: WebUri('https://ai.studio/apps/drive/1GWn1yu8l66TjZk5_GeqPvc5WNlnkNhRt?fullscreenApplet=true'),
                  ),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    javaScriptCanOpenWindowsAutomatically: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    useHybridComposition: Platform.isAndroid,
                    disableContextMenu: false,
                    supportZoom: true,
                    cacheEnabled: true,
                  ),
                  onWebViewCreated: (controller) {
                    _webViewController = controller;
                    _webViewInitialized = true;
                  },
                  onLoadStart: (controller, url) {
                    if (mounted) setState(() => _isWebViewLoading = true);
                  },
                  onLoadStop: (controller, url) async {
                    if (mounted) setState(() => _isWebViewLoading = false);
                  },
                  onReceivedError: (controller, request, error) {
                    if (mounted) setState(() => _isWebViewLoading = false);
                  },
                  shouldOverrideUrlLoading: (controller, navigationAction) async {
                    return NavigationActionPolicy.ALLOW;
                  },
                ),
              
              // Loading Overlay
              if (_isWebViewLoading)
                Container(
                  color: ThemeProvider().scaffoldBg,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Loading Clone YouTube App...',
                          style: TextStyle(fontSize: 16, color: ThemeProvider().textPrimary, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'This page stays open when you switch tabs',
                          style: TextStyle(fontSize: 13, color: ThemeProvider().textSecondary),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
  
  Widget _buildToggleButton() {
    return GestureDetector(
      onTap: () => setState(() => _historyPanelOpen = !_historyPanelOpen),
      child: Container(
        width: 20,
        color: ThemeProvider().surfaceBg,
        child: Center(
          child: Icon(
            _historyPanelOpen ? Icons.chevron_left : Icons.chevron_right,
            color: ThemeProvider().textTertiary,
            size: 16,
          ),
        ),
      ),
    );
  }
  
  Widget _buildHistoryPanel() {
    final tp = ThemeProvider();
    return Container(
      color: tp.surfaceBg,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tp.surfaceBg,
              border: Border(bottom: BorderSide(color: tp.borderColor, width: 1)),
            ),
            child: Row(
              children: [
                const Icon(Icons.history, color: Color(0xFF6366F1), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    LocalizationService().tr('clone.story_history'),
                    style: TextStyle(
                      color: tp.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                // Open folder
                InkWell(
                  onTap: () async {
                    final dir = await _getHistoryDir();
                    Process.run('explorer', [dir.path]);
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.folder_open, color: tp.textTertiary, size: 16),
                  ),
                ),
                const SizedBox(width: 4),
                // Refresh button
                InkWell(
                  onTap: _loadStoryHistory,
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      _isLoadingHistory ? Icons.hourglass_top : Icons.refresh,
                      color: tp.textTertiary,
                      size: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Paste prompt textarea
          _buildPasteArea(),
          
          // Story count
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: tp.borderColor, width: 0.5)),
            ),
            child: Row(
              children: [
                Text(
                  '${_storyHistory.length} ${LocalizationService().tr('clone.stories_count')}',
                  style: TextStyle(color: tp.textTertiary, fontSize: 11),
                ),
              ],
            ),
          ),
          
          // Story list
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6366F1)))
                : _storyHistory.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_stories, size: 40, color: tp.textTertiary),
                            const SizedBox(height: 12),
                            Text(
                              LocalizationService().tr('clone.no_stories'),
                              style: TextStyle(color: tp.textSecondary, fontSize: 13),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              LocalizationService().tr('clone.no_stories_hint'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: tp.textTertiary, fontSize: 11),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _storyHistory.length,
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemBuilder: (context, index) {
                          final story = _storyHistory[index];
                          return _buildStoryItem(story, index);
                        },
                      ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildStoryItem(Map<String, dynamic> story, int index) {
    final id = story['id'] as String? ?? '';
    final isSelected = _selectedStoryId == id;
    final title = story['title'] as String? ?? 'Story ${index + 1}';
    final template = story['template'] as String? ?? 'No template';
    final timestamp = story['timestamp'] as String? ?? '';
    final model = story['model'] as String? ?? '';
    final promptCount = story['promptCount'] as int? ?? 0;
    
    // Parse timestamp for display  
    String timeDisplay = '';
    try {
      final dt = DateTime.parse(timestamp);
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1) {
        timeDisplay = LocalizationService().tr('clone.just_now');
      } else if (diff.inHours < 1) {
        timeDisplay = '${diff.inMinutes}m ago';
      } else if (diff.inDays < 1) {
        timeDisplay = '${diff.inHours}h ago';
      } else if (diff.inDays < 7) {
        timeDisplay = '${diff.inDays}d ago';
      } else {
        timeDisplay = '${dt.month}/${dt.day}';
      }
    } catch (_) {}
    
    return InkWell(
      onTap: () {
        setState(() => _selectedStoryId = isSelected ? null : id);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected 
              ? (ThemeProvider().isDarkMode ? const Color(0xFF2E3140) : const Color(0xFFF0F0FF))
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected 
              ? Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.2))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title row + action icons
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isSelected ? ThemeProvider().textPrimary : ThemeProvider().textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                // Copy icon (always visible)
                InkWell(
                  onTap: () => _copyStoryToClipboard(story),
                  borderRadius: BorderRadius.circular(3),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.copy, size: 13, color: ThemeProvider().textTertiary),
                  ),
                ),
                const SizedBox(width: 4),
                // Open in Explorer icon (always visible)
                InkWell(
                  onTap: () => _openStoryInExplorer(story),
                  borderRadius: BorderRadius.circular(3),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.folder_open, size: 13, color: ThemeProvider().textTertiary),
                  ),
                ),
                const SizedBox(width: 4),
                // Delete icon (always visible)
                InkWell(
                  onTap: () => _deleteStory(story),
                  borderRadius: BorderRadius.circular(3),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 13, color: Colors.red.shade300),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Template + count + time
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    template,
                    style: const TextStyle(color: Color(0xFF6366F1), fontSize: 9),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$promptCount ${LocalizationService().tr('clone.prompts_count')}',
                  style: TextStyle(color: ThemeProvider().textTertiary, fontSize: 9),
                ),
                const Spacer(),
                Text(
                  timeDisplay,
                  style: TextStyle(color: ThemeProvider().textTertiary, fontSize: 9),
                ),
              ],
            ),
            
            // Expanded details when selected
            if (isSelected) ...[
              const SizedBox(height: 8),
              // Model info
              if (model.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(Icons.smart_toy, size: 11, color: ThemeProvider().textTertiary),
                      const SizedBox(width: 4),
                      Text(model, style: TextStyle(color: ThemeProvider().textSecondary, fontSize: 10)),
                    ],
                  ),
                ),
              // Preview snippet
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: ThemeProvider().inputBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: ThemeProvider().borderColor),
                ),
                child: Text(
                  (story['response'] as String? ?? story['prompt'] as String? ?? 'No content')
                      .replaceAll('\n', ' ')
                      .substring(0, ((story['response'] as String? ?? story['prompt'] as String? ?? '').length).clamp(0, 200)),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: ThemeProvider().textSecondary, fontSize: 10, height: 1.4),
                ),
              ),
              const SizedBox(height: 6),
              // Delete button
              Align(
                alignment: Alignment.centerRight,
                child: InkWell(
                  onTap: () => _deleteStory(story),
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: ThemeProvider().isDarkMode ? Colors.red.withOpacity(0.1) : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline, size: 12, color: Colors.red.shade300),
                        const SizedBox(width: 3),
                        Text(LocalizationService().tr('btn.delete'), style: TextStyle(fontSize: 10, color: Colors.red.shade300)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  /// Build the paste prompt textarea area
  Widget _buildPasteArea() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: ThemeProvider().borderColor, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.paste, size: 14, color: ThemeProvider().textSecondary),
              const SizedBox(width: 6),
              Text(LocalizationService().tr('clone.paste_prompt'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ThemeProvider().textSecondary)),
              const Spacer(),
              if (_pasteStatus == 'saving')
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.blue.shade400)),
                    const SizedBox(width: 4),
                    Text('Saving...', style: TextStyle(fontSize: 9, color: Colors.blue.shade400)),
                  ],
                )
              else if (_pasteStatus == 'saved')
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, size: 12, color: Colors.green.shade400),
                    const SizedBox(width: 3),
                    Text('Saved!', style: TextStyle(fontSize: 9, color: Colors.green.shade500)),
                  ],
                )
              else if (_pasteStatus == 'error')
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error, size: 12, color: Colors.red.shade400),
                    const SizedBox(width: 3),
                    Text('Error', style: TextStyle(fontSize: 9, color: Colors.red.shade400)),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 80,
            decoration: BoxDecoration(
              border: Border.all(color: ThemeProvider().borderColor),
              borderRadius: BorderRadius.circular(6),
              color: ThemeProvider().inputBg,
            ),
            child: TextField(
              controller: _pasteController,
              maxLines: null,
              expands: true,
              style: TextStyle(fontSize: 10, color: ThemeProvider().textPrimary, height: 1.4),
              decoration: InputDecoration(
              hintText: LocalizationService().tr('clone.paste_json_hint'),
                hintStyle: TextStyle(fontSize: 10, color: ThemeProvider().textTertiary),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.all(8),
              ),
            ),
          ),
          const SizedBox(height: 4),
          // Save button row
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: _pasteController.text.trim().isNotEmpty ? () => _saveFromPaste(_pasteController.text) : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.save, size: 12, color: Color(0xFF6366F1)),
                        SizedBox(width: 4),
                        Text(LocalizationService().tr('clone.save_to_history'), style: TextStyle(fontSize: 10, color: Color(0xFF6366F1), fontWeight: FontWeight.w500)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: () {
                  _pasteController.clear();
                  setState(() => _pasteStatus = '');
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.clear, size: 14, color: ThemeProvider().textTertiary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
  
  void _debounceSavePaste(String text) {
    _lastPasteTime = DateTime.now();
    final capturedTime = _lastPasteTime;
    
    // Wait 1.5 seconds after last change before auto-saving
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (_lastPasteTime == capturedTime && text.trim().isNotEmpty) {
        _saveFromPaste(text);
      }
    });
  }
  
  Future<void> _saveFromPaste(String text) async {
    if (_isSavingPaste || text.trim().isEmpty) return;
    
    setState(() {
      _isSavingPaste = true;
      _pasteStatus = 'saving';
    });
    
    try {
      final historyDir = await _getHistoryDir();
      final now = DateTime.now();
      final id = '${now.millisecondsSinceEpoch}';
      
      // Create a title from first meaningful line
      String title = text.split('\n').first.trim();
      title = title.replaceAll(RegExp(r'^[\[\{\s]+'), '').replaceAll(RegExp(r'[\]\}\s]+$'), '');
      if (title.length > 60) title = '${title.substring(0, 57)}...';
      if (title.isEmpty) title = 'Pasted Story $id';
      
      final data = <String, dynamic>{
        'id': id,
        'title': title,
        'prompt': '',
        'response': text,
        'template': 'Pasted',
        'model': 'Manual',
        'promptCount': 0,
        'timestamp': now.toIso8601String(),
      };
      
      // Try to detect prompt count from JSON
      try {
        final parsed = jsonDecode(text);
        if (parsed is List) {
          data['promptCount'] = parsed.length;
        } else if (parsed is Map && parsed.containsKey('scenes')) {
          final scenes = parsed['scenes'];
          if (scenes is List) data['promptCount'] = scenes.length;
        }
      } catch (_) {}
      
      final file = File('${historyDir.path}${Platform.pathSeparator}story_$id.json');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      print('[StoryHistory] Saved paste: ${file.path}');
      
      // Reload history
      await _loadStoryHistory(force: true);
      
      if (mounted) {
        setState(() {
          _pasteStatus = 'saved';
          _isSavingPaste = false;
        });
        
        // Clear the paste area after successful save
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            _pasteController.clear();
            setState(() => _pasteStatus = '');
          }
        });
      }
    } catch (e) {
      print('[StoryHistory] Error saving paste: $e');
      if (mounted) {
        setState(() {
          _pasteStatus = 'error';
          _isSavingPaste = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _pasteController.dispose();
    super.dispose();
  }
}

/// Static utility to save a story to history (called from Character Studio)
class StoryHistoryService {
  static Future<void> saveStory({
    required String prompt,
    required String response,
    required String template,
    required String model,
    required int promptCount,
  }) async {
    try {
      final appDir = await getApplicationSupportDirectory();
      print('[StoryHistory] AppSupport dir: ${appDir.path}');
      final historyDir = Directory('${appDir.path}${Platform.pathSeparator}story_history');
      if (!await historyDir.exists()) {
        await historyDir.create(recursive: true);
      }
      
      final now = DateTime.now();
      final id = '${now.millisecondsSinceEpoch}';
      
      // Create a title from the prompt (first line or first 60 chars)
      String title = prompt.split('\n').first.trim();
      if (title.length > 60) title = '${title.substring(0, 57)}...';
      if (title.isEmpty) title = 'Story $id';
      
      final data = {
        'id': id,
        'title': title,
        'prompt': prompt,
        'response': response,
        'template': template,
        'model': model,
        'promptCount': promptCount,
        'timestamp': now.toIso8601String(),
      };
      
      final file = File('${historyDir.path}${Platform.pathSeparator}story_$id.json');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
      print('[StoryHistory] ✅ Saved: ${file.path}');
    } catch (e) {
      print('[StoryHistory] ❌ Error saving: $e');
    }
  }
}
