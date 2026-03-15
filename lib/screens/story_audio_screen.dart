import 'package:file_picker/file_picker.dart'; // Added
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'dart:ui';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import '../models/story/story_audio_part.dart';
import '../models/story/alignment_item.dart';
import '../models/story/story_audio_state.dart';
import '../models/bulk_task.dart'; // Added
import '../models/scene_data.dart'; // Added
import '../services/bulk_task_executor.dart'; // Added
import '../services/video_generation_service.dart'; // Added for 10x Boost support
import '../services/profile_manager_service.dart'; // Added for multi-browser
import '../services/multi_profile_login_service.dart'; // Added for re-login
import '../services/story/gemini_tts_service.dart';
import '../services/story/gemini_alignment_service.dart';
import '../services/gemini_key_service.dart';
import '../services/story/story_export_service.dart';
import '../services/project_service.dart';
import '../services/video_generation_service.dart';
import '../utils/config.dart';
import '../utils/theme_provider.dart';
import '../services/localization_service.dart';

import '../services/mobile/mobile_browser_service.dart'; // Added
import '../widgets/mobile_browser_manager_widget.dart'; // Added for mobile browser on Story Audio
import 'package:open_filex/open_filex.dart'; // For playing videos
import '../widgets/video_player_dialog.dart'; // For internal video player



class StoryAudioScreen extends StatefulWidget {
  final ProjectService projectService;
  final bool isActivated;
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  final String email;
  final String password;
  final String selectedModel;
  final String selectedAccountType;
  final int initialTabIndex;
  final VoidCallback? onBack;  // Callback for back navigation
  final bool reelOnlyMode; // When true, shows only Reel tab without tab bar
  final bool storyAudioOnlyMode; // When true, shows only Story Audio tab without tab bar
  final bool embedded; // When true, hides back button for in-page rendering

  const StoryAudioScreen({
    super.key,
    required this.projectService,
    required this.isActivated,
    this.profileManager,
    this.loginService,
    this.email = '',
    this.password = '',
    this.selectedModel = 'Veo 3.1 - Fast',
    this.selectedAccountType = 'ai_pro',
    this.initialTabIndex = 0,
    this.onBack,
    this.reelOnlyMode = false,
    this.storyAudioOnlyMode = false,
    this.embedded = false,
  });

  @override
  State<StoryAudioScreen> createState() => _StoryAudioScreenState();
}

class _StoryAudioScreenState extends State<StoryAudioScreen> {
  // ========== STATIC STATE (persists across navigation) ==========
  static List<Map<String, dynamic>> _staticReelProjects = [];
  static bool _staticIsGeneratingReel = false;
  static String _staticReelTopic = '';
  static String? _staticSelectedReelTemplateId;
  static StoryAudioState? _staticState;
  
  // State
  StoryAudioState _state = StoryAudioState();
  
  // Services
  final GeminiTtsService _ttsService = GeminiTtsService();
  final GeminiAlignmentService _alignmentService = GeminiAlignmentService();
  final StoryExportService _exportService = StoryExportService();
  ProjectService get _projectService => widget.projectService;
  late final BulkTaskExecutor _bulkExecutor = BulkTaskExecutor(onTaskStatusChanged: _onReelTaskUpdate);
  final _audioPlayer = AudioPlayer();
  
  // Controllers
  final _storyScriptController = TextEditingController();
  final _actionPromptsController = TextEditingController();
  // Export Settings
  double _exportTtsVolume = 2.5; // 250% audio volume
  double _exportVideoVolume = 0.5; // 50% video audio volume
  double _exportPlaybackSpeed = 1.2; // 1.2x playback speed

  TextEditingController _narratorController = TextEditingController();
  final _customDelimiterController = TextEditingController(text: '---');
  final _sentencesPerSegmentController = TextEditingController(text: '1');
  final _alignmentJsonController = TextEditingController();
  final _reelTopicController = TextEditingController(); // Reel
  final TextEditingController _reelCharacterController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController(); // Added persistent controller
  
  // Mapping for bulk updates - STATIC to persist across navigation
  static final Map<int, Map<String, dynamic>> _visualIdMap = {};
  static final Map<int, SceneData> _sceneDataMap = {}; // Added to track SceneData for Reels
  
  // UI State
  bool _isGeneratingTts = false;
  bool _isGeneratingAlignment = false;
  bool _isExporting = false;
  String _statusMessage = '';
  double _progressValue = 0.0;
  String _selectedAlignmentModel = 'gemini-2.5-flash';
  String _selectedExportMethod = 'fast';
  String _reelExportMethod = 'precise'; // For Reel tab exports
  String _reelExportResolution = 'original'; // Resolution: original, 1080p, 2k, 4k
  String _reelExportAspectRatio = 'original'; // Aspect: original, 16:9, 9:16, 1:1, 4:5
  bool _reelForceReEncode = false;
  int _sentencesPerSegment = 1;
  String? _customOutputFolder; // Custom output folder selected by user
  
  // Audio playback state
  int? _currentlyPlayingIndex;
  bool _isPlaying = false;
  
  // Volume state
  double _ttsVolume = 1.0;
  double _videoVolume = 1.0;
  
  // Activity Log
  final List<String> _activityLogs = [];
  final ScrollController _logScrollController = ScrollController();
  static const int _maxLogLines = 500;

  // Reel State - USE GETTERS/SETTERS TO SYNC WITH STATIC
  String _reelCharacter = 'Boy';
  List<Map<String, dynamic>> get _reelProjects => _staticReelProjects;
  set _reelProjects(List<Map<String, dynamic>> value) => _staticReelProjects = value;
  bool get _isGeneratingReel => _staticIsGeneratingReel;
  set _isGeneratingReel(bool value) => _staticIsGeneratingReel = value;
  
  bool _isConnectingBrowsers = false; // Added
  bool _isInitializing = true; // Added to prevent race condition saving
  int _reelCount = 1;
  final TextEditingController _reelCountController = TextEditingController(text: '1');
  int _storiesPerHint = 1; // Number of different stories to generate from one hint
  int _scenesPerStory = 12; // Number of visual scenes/prompts per story (default: 12)
  String _reelTopicMode = 'single'; // 'single' = one topic + count, 'multi' = one per line
  Set<int> _selectedReelsForBulkCreate = {}; // Track selected reels for bulk auto-create
  bool _isBulkAutoCreating = false;
  bool _isRegeneratingMissing = false; // Track if regeneration is in progress
  int _concurrentReelProcessing = 1; // Process 1 reel at a time (default)
  
  StreamSubscription? _vgenSubscription; // For syncing VideoGenerationService status
  
  // Bulk Export Settings
  String _bulkExportMethod = 'precise'; // Export method for bulk processing
  String _bulkExportResolution = 'original'; // Resolution for bulk export
  bool _bulkAutoExport = true; // Auto export after video generation in bulk mode
  bool _use10xBoostMode = false; // Add 10x Boost toggle for Reels
  String _bulkVoiceName = 'Zephyr'; // Default voice for bulk audio generation
  
  // Global Audio Style (overrides AI-generated styles)
  String _globalAudioStyleInstruction = ''; // When set, this style is used for all reels instead of AI-generated
  final TextEditingController _globalAudioStyleController = TextEditingController();
  
  // Persistent controllers for voice style fields (avoid cursor-jump on rebuild)
  final TextEditingController _globalVoiceStyleController = TextEditingController();
  final Map<int, TextEditingController> _partVoiceStyleControllers = {};
  
  Timer? _saveTimer;
  
  // ── Prompt Undo System ──
  // Persistent controllers for visual prompts (keyed by "reelId_partIdx_vIdx")
  final Map<String, TextEditingController> _promptControllers = {};
  // Undo stacks for visual prompts (keyed by same key, max 50 entries each)
  final Map<String, List<String>> _promptUndoStacks = {};
  // Track if we're currently applying an undo (to avoid pushing to undo stack)
  bool _isApplyingUndo = false;
  // Timer for debounced undo snapshot
  final Map<String, Timer?> _promptUndoTimers = {};
  
  // Export Progress State
  bool _isReelExporting = false;
  double _reelExportProgress = 0.0;
  String _reelExportStep = '';
  int _reelExportingIndex = -1;
  
  // Split layout scroll controllers
  final ScrollController _leftScrollController = ScrollController();
  final ScrollController _middleScrollController = ScrollController();
  final ScrollController _rightScrollController = ScrollController();

  void _debouncedSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveState);
  }

  String _reelAccountType = 'ai_pro'; // 'free', 'ai_pro', 'ai_ultra'
  String _reelVideoModel = 'Veo 3.1 - Fast'; // Flow UI model name
  bool _globalNarrationEnabled = false; 
  bool _globalVoiceCueEnabled = true; 
  String _voiceCueLanguage = 'English'; // Language for voice cues in visuals
  String _reelVoiceOverLanguage = 'English'; // Language for narration text
  final TextEditingController _voiceOverLanguageController = TextEditingController(text: 'English');
  
  // Profile State
  String _selectedProfile = 'Default';
  List<String> _profiles = ['Default'];
  
  // Mobile browser overlay
  final GlobalKey _mobileBrowserKey = GlobalKey();
  bool _mobileBrowserVisible = false;
  
  // Periodic refresh timer for background task updates
  Timer? _uiRefreshTimer;

  @override
  void initState() {
    super.initState();
    _ensureProfilesDir();
    _loadProfiles();
    _loadState();
    _ttsService.loadApiKeys(); // Load API keys for TTS
    _alignmentService.loadApiKeys(); // Load API keys for Alignment (and Youtube Analysis)
    _exportService.onLog = _addLog; // Wire export service logs to UI
    
    // Configure bulk executor with multi-browser support
    print('[STORY AUDIO] Configuring BulkTaskExecutor...');
    print('[STORY AUDIO] Profile Manager: ${widget.profileManager != null ? "SET" : "NULL"}');
    print('[STORY AUDIO] Login Service: ${widget.loginService != null ? "SET" : "NULL"}');
    print('[STORY AUDIO] Email: ${widget.email.isNotEmpty ? "SET" : "EMPTY"}');
    
    // Set initial model and account type from widget params
    _reelVideoModel = widget.selectedModel;
    _reelAccountType = widget.selectedAccountType;
    
    _bulkExecutor.setProfileManager(widget.profileManager);
    _bulkExecutor.setLoginService(widget.loginService);
    _bulkExecutor.setCredentials(widget.email, widget.password);
    _bulkExecutor.setAccountType(widget.selectedAccountType);
    
    // Initialize Mobile Service on Android and iOS
    if (Platform.isAndroid || Platform.isIOS) {
       final mobileService = MobileBrowserService();
       mobileService.initialize(4);
       _bulkExecutor.setMobileBrowserService(mobileService);
    }
    
    print('[STORY AUDIO] BulkTaskExecutor configured!');
    
    // Reconnect callback for singleton executor (in case screen was recreated)
    _bulkExecutor.setOnTaskStatusChanged(_onReelTaskUpdate);
    
    // Check if there are running tasks and update UI accordingly
    _reconnectToRunningTasks();
    
    _storyScriptController.addListener(() {
      _state = _state.copyWith(storyScript: _storyScriptController.text);
      _saveState(); // Save on change
    });
    _actionPromptsController.addListener(() {
      _state = _state.copyWith(actionPrompts: _actionPromptsController.text);
      _saveState(); // Save on change
    });
    _reelTopicController.addListener(() {
      _state = _state.copyWith(reelTopic: _reelTopicController.text);
      _staticReelTopic = _reelTopicController.text; // Sync to static
      _saveState(); // Save on change
    });
    
    // Start periodic UI refresh to sync with background task updates
    _uiRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && (_staticIsGeneratingReel || _bulkExecutor.runningTasks.isNotEmpty)) {
        setState(() {}); // Refresh UI to show latest task progress
      }
    });

    // Initialize VideoGenerationService listener for Reels
    _vgenSubscription = VideoGenerationService().statusStream.listen((event) {
      _syncReelVisualsWithVgen();
    });
  }

  @override
  void didUpdateWidget(StoryAudioScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedModel != oldWidget.selectedModel || widget.selectedAccountType != oldWidget.selectedAccountType) {
      print('[STORY AUDIO] Parameters updated: Model=${widget.selectedModel}, Account=${widget.selectedAccountType}');
      setState(() {
        _reelVideoModel = widget.selectedModel;
        _reelAccountType = widget.selectedAccountType;
      });
      _bulkExecutor.setAccountType(widget.selectedAccountType);
    }
  }

  int _getGlobalId(String projectId, int vId) {
     // Create a globally unique-ish int ID for VideoGenerationService by combining
     // a hash of the project ID and the local vId.
     // Project namespace: 1,000,000 potential hashes. Local slot: 10,000 potential scenes.
     return (projectId.hashCode.abs() % 1000000) * 10000 + (vId % 10000);
  }

  void _syncReelVisualsWithVgen() {
    bool anyChanged = false;
    
    final vgen = VideoGenerationService();
    
    // Sync all scenes in progress to their visual object reference
    _visualIdMap.forEach((id, visual) {
       // Look for the LATEST state of this scene from the service
       // Use the global ID for the lookup
       final activeScene = vgen.getScene(id);
       final storedScene = _sceneDataMap[id];
       
       // Priority: active service state > local stored state
       final scene = activeScene ?? storedScene;
       
       if (scene != null) {
          if (visual['gen_status'] != scene.status || visual['video_path'] != scene.videoPath) {
             visual['gen_status'] = scene.status;
             visual['video_path'] = scene.videoPath;
             visual['gen_error'] = scene.error;
             anyChanged = true;
          }
       }
    });
    
    // We also need to check if any projects should transition from 'video_generating' to 'video_done'
    for (var project in _staticReelProjects) {
      if (project['status'] == 'video_generating') {
        final content = project['content'] as List?;
        bool allVisualsTerminal = true;
        if (content != null) {
          for (var part in content) {
            final visuals = part['visuals'] as List?;
            if (visuals != null) {
              for (var v in visuals) {
                if (v['active'] == false) continue; // Skip inactive
                if (v['video_path'] != null && File(v['video_path']).existsSync()) continue; // Skip already done

                final status = v['gen_status'];
                // Only consider it terminal if it's in a terminal state
                if (status != 'completed' && status != 'failed' && status != 'unsafe') {
                  allVisualsTerminal = false;
                  break;
                }
              }
            }
            if (!allVisualsTerminal) break;
          }
        }
        
        if (allVisualsTerminal) {
          print('[REEL VGEN] Project ${project['id']} is fully complete!');
          
          // Only start auto-export sequence if not already doing so
          if (project['status'] == 'video_generating') {
              final int index = _staticReelProjects.indexOf(project);
              final projectId = project['id'];

              if (mounted) {
                  setState(() {
                      project['status'] = 'finalizing';
                      anyChanged = true;
                  });
              }
              
              // Only trigger if bulk auto-creating is NOT active (since it has its own monitor)
              // OR if this specifically was an auto-processed reel
              if (!_isBulkAutoCreating && _bulkAutoExport) {
                  Future(() async {
                      print('[REEL VGEN] Waiting 5s before auto-export for reel: ${index + 1}');
                      await Future.delayed(const Duration(seconds: 5));
                      if (mounted) setState(() { project['status'] = 'exporting'; });
                      await _exportReelWithSettings(index, _bulkExportMethod, _bulkExportResolution);
                      if (mounted) {
                          setState(() {
                              project['status'] = 'video_done';
                              _saveState();
                          });
                      }
                  });
              } else if (!_isBulkAutoCreating) {
                  // Not auto-exporting, just mark as done
                  if (mounted) setState(() { project['status'] = 'video_done'; });
              }
              // If _isBulkAutoCreating is true, the monitor loop in _startBulkAutoCreate handles the status transition
          }
        }
      }
    }

    if (anyChanged) {
       _state = _state.copyWith(reelProjects: _staticReelProjects);
       _debouncedSave();
    }
    
    if (mounted) {
       setState(() {});
    }
  }

  @override
  void dispose() {
    _vgenSubscription?.cancel();
    _uiRefreshTimer?.cancel();
    _reelTopicController.dispose();
    _reelCharacterController.dispose();
    _apiKeyController.dispose(); // Dispose here
    _audioPlayer.dispose();
    // Dispose all prompt controllers
    for (final c in _promptControllers.values) {
      c.dispose();
    }
    _promptControllers.clear();
    _promptUndoStacks.clear();
    for (final t in _promptUndoTimers.values) {
      t?.cancel();
    }
    _promptUndoTimers.clear();
    // Note: NOT disposing _bulkExecutor so tasks continue in background
    // Dispose voice style controllers
    _globalVoiceStyleController.dispose();
    for (final c in _partVoiceStyleControllers.values) {
      c.dispose();
    }
    _partVoiceStyleControllers.clear();
    _logScrollController.dispose();
    super.dispose();
  }
  
  /// Add a log entry to the activity log panel
  void _addLog(String message) {
    if (!mounted) return;
    final timestamp = DateTime.now().toString().substring(11, 19); // HH:MM:SS
    setState(() {
      _activityLogs.add('[$timestamp] $message');
      if (_activityLogs.length > _maxLogLines) {
        _activityLogs.removeRange(0, _activityLogs.length - _maxLogLines);
      }
    });
    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }
  
  /// Get or create a TextEditingController for a visual prompt.
  /// Initializes undo stack with the initial value.
  TextEditingController _getPromptController(String key, String initialValue) {
    if (!_promptControllers.containsKey(key)) {
      _promptControllers[key] = TextEditingController(text: initialValue);
      _promptUndoStacks[key] = [initialValue]; // seed undo with initial value
    } else {
      // If visual data changed externally (e.g., regeneration), sync controller
      final controller = _promptControllers[key]!;
      if (controller.text != initialValue && !_isApplyingUndo) {
        // Only sync if the controller text doesn't match AND we're not mid-edit
        // This handles the case where prompt was changed by code (not user)
        if (!controller.text.contains(initialValue.substring(0, initialValue.length.clamp(0, 20)))) {
          controller.text = initialValue;
          _promptUndoStacks[key] = [initialValue];
        }
      }
    }
    return _promptControllers[key]!;
  }
  
  /// Push a snapshot to the undo stack for a prompt (debounced - groups rapid typing)
  void _pushPromptUndo(String key, String value) {
    if (_isApplyingUndo) return;
    
    // Cancel any pending undo timer for this key
    _promptUndoTimers[key]?.cancel();
    
    // Debounce: Only push undo snapshot after 500ms of no typing
    _promptUndoTimers[key] = Timer(const Duration(milliseconds: 500), () {
      final stack = _promptUndoStacks[key] ??= [];
      // Don't push duplicates
      if (stack.isEmpty || stack.last != value) {
        stack.add(value);
        // Cap at 50 entries
        if (stack.length > 50) {
          stack.removeAt(0);
        }
      }
    });
  }
  
  /// Undo the last change for a prompt. Returns true if undo was applied.
  bool _undoPrompt(String key) {
    final stack = _promptUndoStacks[key];
    if (stack == null || stack.length <= 1) return false; // Nothing to undo (keep initial)
    
    // Pop current value
    stack.removeLast();
    final previousValue = stack.last;
    
    // Apply undo
    _isApplyingUndo = true;
    final controller = _promptControllers[key];
    if (controller != null) {
      controller.text = previousValue;
      // Place cursor at end
      controller.selection = TextSelection.collapsed(offset: previousValue.length);
    }
    _isApplyingUndo = false;
    
    return true;
  }

  /// Reconnect to running tasks when screen is recreated
  void _reconnectToRunningTasks() {
    final runningTasks = _bulkExecutor.runningTasks;
    if (runningTasks.isEmpty) return;
    
    print('[RECONNECT] Found ${runningTasks.length} running tasks');
    
    for (final task in runningTasks) {
      // Handle main reel tasks (reel_task_{projectId})
      if (task.id.startsWith('reel_task_')) {
        final projectIndex = _reelProjects.indexWhere(
          (p) => 'reel_task_${p['id']}' == task.id
        );
        
        if (projectIndex >= 0) {
          final project = _reelProjects[projectIndex];
          print('[RECONNECT] Reconnected to task: ${task.name} (status: ${task.status})');
          
          // Update project status to reflect running task
          if (task.status == TaskStatus.running) {
            setState(() {
              project['status'] = 'video_generating';
              _state = _state.copyWith(reelProjects: _reelProjects);
            });
          }
          
          // Rebuild visualIdMap for scene tracking
          final content = project['content'] as List?;
          if (content != null) {
            for (var scene in task.scenes) {
              if (!_visualIdMap.containsKey(scene.sceneId)) {
                // Find matching visual by prompt
                for (var part in content) {
                  final visuals = part['visuals'] as List?;
                  if (visuals != null) {
                    for (var v in visuals) {
                      if (v['prompt'] == scene.prompt && !_visualIdMap.containsValue(v)) {
                        _visualIdMap[scene.sceneId] = v;
                        break;
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      // Handle regeneration tasks (regen_ or regen_batch_)
      else if (task.id.startsWith('regen_')) {
        print('[RECONNECT] Found running regen task: ${task.id} (status: ${task.status})');
        
        // Set flag if it's a batch regen task still running
        if (task.id.startsWith('regen_batch_') && task.status == TaskStatus.running) {
          _isRegeneratingMissing = true;
        }
        
        // Scene should already be in visualIdMap from when regen was started
        // Just update status for any scenes that might have status updates
        for (var scene in task.scenes) {
          if (_visualIdMap.containsKey(scene.sceneId)) {
            final visual = _visualIdMap[scene.sceneId]!;
            visual['gen_status'] = scene.status;
            if (scene.videoPath != null) {
              visual['video_path'] = scene.videoPath;
            }
          }
        }
        
        if (mounted) setState(() {});
      }
    }
  }

  Future<Directory> _getEffectiveOutputDir() async {
    // On Android, always use public external storage
    if (Platform.isAndroid) {
      final defaultDir = Directory('/storage/emulated/0/veo3');
      if (!await defaultDir.exists()) {
        await defaultDir.create(recursive: true);
      }
      return defaultDir;
    }
    
    // For other platforms, check custom folder first
    if (_customOutputFolder != null) return Directory(_customOutputFolder!);
    if (widget.projectService.currentProject?.projectPath != null) {
      final dir = Directory(widget.projectService.currentProject!.projectPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }
    
    // Default fallback for non-Android
    Directory defaultDir;
    if (Platform.isIOS) {
      // iOS: Use documents directory
      final docsDir = await getApplicationDocumentsDirectory();
      defaultDir = Directory(path.join(docsDir.path, 'veo3_stories'));
    } else {
      // Desktop: Use app directory
      final appDir = File(Platform.resolvedExecutable).parent;
      defaultDir = Directory(path.join(appDir.path, 'stories_history'));
    }
    
    if (!await defaultDir.exists()) {
      await defaultDir.create(recursive: true);
    }
    return defaultDir;
  }

  /// Get organized reel paths for a given reel project
  /// Returns: {baseDir, audiosDir, videoclipsDir, exportDir}
  Future<Map<String, Directory>> _getReelPaths(Map<String, dynamic> project) async {
    final outputDir = await _getEffectiveOutputDir();
    final reelName = (project['name'] as String? ?? 'Untitled_Reel')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(' ', '_');
    
    // Structure: /veo3/reels/{name}/audios, /veo3/reels/{name}/videoclips
    final baseDir = Directory(path.join(outputDir.path, 'reels', reelName));
    final audiosDir = Directory(path.join(baseDir.path, 'audios'));
    final videoclipsDir = Directory(path.join(baseDir.path, 'videoclips'));
    final exportDir = Directory(path.join(outputDir.path, 'reels_output'));
    
    // Create all directories
    await baseDir.create(recursive: true);
    await audiosDir.create(recursive: true);
    await videoclipsDir.create(recursive: true);
    await exportDir.create(recursive: true);
    
    return {
      'base': baseDir,
      'audios': audiosDir,
      'videoclips': videoclipsDir,
      'export': exportDir,
    };
  }


  /// Load state from JSON file
  Future<void> _loadState() async {
    try {
      // If we have static state from a running generation, use it instead of loading from file
      if (_staticReelProjects.isNotEmpty || _staticIsGeneratingReel) {
        print('[STORY AUDIO] Using static state (${_staticReelProjects.length} reels, generating: $_staticIsGeneratingReel)');
        if (mounted) {
          setState(() {
             // Restore topic from static if available
             if (_staticReelTopic.isNotEmpty) {
               _reelTopicController.text = _staticReelTopic;
             }
             // Restore template selection from static if available
             if (_staticSelectedReelTemplateId != null) {
               _state = _state.copyWith(selectedReelTemplateId: _staticSelectedReelTemplateId);
             }
             
             _isInitializing = false;
           });
         }
         return; // Don't overwrite with file state
      }
      
      final projectDir = await _getEffectiveOutputDir();

      final stateFile = File(path.join(projectDir.path, 'story_audio_state.json'));
      if (!await stateFile.exists()) {
        print('[STORY AUDIO] State file does not exist at ${stateFile.path}, using defaults');
        if (mounted) {
          setState(() {
            _ensureDefaultTemplates();
            _isInitializing = false; // CRITICAL: Must set false even when file doesn't exist!
          });
        }
      } else {
        final content = await stateFile.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        
        if (mounted) {
           setState(() {
             _state = StoryAudioState.fromJson(json);
             _ensureDefaultTemplates(); // Call after loading state to ensure they are present
             _storyScriptController.text = _state.storyScript;
             _actionPromptsController.text = _state.actionPrompts;
             _customDelimiterController.text = _state.customDelimiter;
             if (_state.alignmentJson != null && _state.alignmentJson!.isNotEmpty) {
               _alignmentJsonController.text = const JsonEncoder.withIndent('  ').convert(_state.alignmentJson);
             }
           
             // Load Reel State
             _reelTopicController.text = _state.reelTopic;
             _reelCharacter = _state.reelCharacter; // Ensure this matches dropdown items
             if (_state.reelProjects != null && _state.reelProjects!.isNotEmpty) {
                // Deep copy to ensure nested maps/lists are mutable
                _reelProjects = _state.reelProjects!.map((e) {
                  final project = Map<String, dynamic>.from(e);
                  // Deep copy content list (contains visuals with prompts)
                  if (project['content'] is List) {
                    project['content'] = (project['content'] as List).map((part) {
                      final p = Map<String, dynamic>.from(part as Map);
                      if (p['visuals'] is List) {
                        p['visuals'] = (p['visuals'] as List).map((v) => Map<String, dynamic>.from(v as Map)).toList();
                      }
                      return p;
                    }).toList();
                  }
                  return project;
                }).toList();
                print('[STORY AUDIO] Loaded ${_reelProjects.length} reel projects from disk');
             }
             
             // Load Bulk Export Settings
             _bulkExportMethod = _state.bulkExportMethod;
             _bulkExportResolution = _state.bulkExportResolution;
             _bulkAutoExport = _state.bulkAutoExport;
             _use10xBoostMode = _state.use10xBoostMode;
             _bulkVoiceName = _state.bulkVoiceName;
             _exportPlaybackSpeed = _state.exportPlaybackSpeed;
             _exportTtsVolume = _state.exportTtsVolume;
             _exportVideoVolume = _state.exportVideoVolume;
             _globalAudioStyleInstruction = _state.globalAudioStyleInstruction;
             _globalAudioStyleController.text = _state.globalAudioStyleInstruction;
             
              // Load Voice Over Language
              _reelVoiceOverLanguage = _state.reelLanguage ?? 'English';
              _voiceOverLanguageController.text = _reelVoiceOverLanguage;
              
              // Load Voice Cue Language
              _voiceCueLanguage = _state.reelVoiceCueLanguage ?? 'English';
              
              // Load Toggle Flags
              _globalVoiceCueEnabled = _state.globalVoiceCueEnabled;
              _globalNarrationEnabled = _state.globalNarrationEnabled;
              
              // Sync disk-loaded state to static for first-load consistency
              _staticSelectedReelTemplateId = _state.selectedReelTemplateId;
              
              _isInitializing = false;
            });
         }
         
         print('[STORY AUDIO] State loaded from file: ${_reelProjects.length} reels found.');
      }
    } catch (e) {
      print('[STORY AUDIO] Error loading state: $e');
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  /// Save state to JSON file
  Future<void> _saveState() async {
    if (_isInitializing) {
      print('[STORY AUDIO] _saveState skipped: still initializing');
      return; // Prevent saving incomplete state during startup
    }
    try {
      final projectDir = await _getEffectiveOutputDir();
      
      // Deep-copy reelProjects to ensure clean serializable data
      // Strip any non-serializable runtime objects (File, Directory, etc.)
      final serializableReelProjects = _reelProjects.map((project) {
        final p = Map<String, dynamic>.from(project);
        if (p['content'] is List) {
          p['content'] = (p['content'] as List).map((part) {
            final partCopy = Map<String, dynamic>.from(part as Map);
            if (partCopy['visuals'] is List) {
              partCopy['visuals'] = (partCopy['visuals'] as List).map((v) {
                final vCopy = Map<String, dynamic>.from(v as Map);
                // Remove any non-serializable runtime fields
                vCopy.remove('gen_error'); // Transient field
                return vCopy;
              }).toList();
            }
            return partCopy;
          }).toList();
        }
        return p;
      }).toList();
      
      // Ensure state is updated with latest local variables before saving
      _state = _state.copyWith(
         storyScript: _storyScriptController.text,
         actionPrompts: _actionPromptsController.text,
         reelTopic: _reelTopicController.text,
         reelCharacter: _state.reelCharacter, // Use state directly or variable
         reelProjects: serializableReelProjects,
         reelLanguage: _reelVoiceOverLanguage,
         reelVoiceCueLanguage: _voiceCueLanguage,
         // Bulk Export Settings
         bulkExportMethod: _bulkExportMethod,
         bulkExportResolution: _bulkExportResolution,
         bulkAutoExport: _bulkAutoExport,
         use10xBoostMode: _use10xBoostMode,
         bulkVoiceName: _bulkVoiceName,
         exportPlaybackSpeed: _exportPlaybackSpeed,
         exportTtsVolume: _exportTtsVolume,
         exportVideoVolume: _exportVideoVolume,
          globalAudioStyleInstruction: _globalAudioStyleInstruction,
          globalVoiceCueEnabled: _globalVoiceCueEnabled,
          globalNarrationEnabled: _globalNarrationEnabled,
          selectedReelTemplateId: _state.selectedReelTemplateId,
      );

      final stateFile = File(path.join(projectDir.path, 'story_audio_state.json'));
      final jsonStr = jsonEncode(_state.toJson());
      await stateFile.writeAsString(jsonStr);
      print('[STORY AUDIO] Saved state to ${stateFile.path} (${serializableReelProjects.length} reels, ${jsonStr.length} bytes)');
    } catch (e, stackTrace) {
      print('[STORY AUDIO] Error saving state: $e');
      print('[STORY AUDIO] Stack trace: $stackTrace');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save state: $e')));
    }
  }

  /// Split story script into parts
  void _splitStoryScript() {
    final script = _storyScriptController.text.trim();
    if (script.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a story script first')),
      );
      return;
    }

    List<String> textParts = [];

    switch (_state.splitMode) {
      case 'numbered':
        // Split by numbered lines (1., 2., 3., etc.)
        final regex = RegExp(r'^\d+\.\s*', multiLine: true);
        textParts = script.split(regex).where((s) => s.trim().isNotEmpty).toList();
        break;

      case 'line':
        // Split by line breaks
        textParts = script.split('\n').where((s) => s.trim().isNotEmpty).toList();
        break;

      case 'custom':
        // Split by custom delimiter
        final delimiter = _customDelimiterController.text;
        textParts = script.split(delimiter).where((s) => s.trim().isNotEmpty).toList();
        break;

      case 'sentences':
        // Split by sentences - support multiple languages:
        // . ! ? - English, Spanish, German, etc.
        // । - Hindi, Bengali, Sanskrit (Devanagari danda)
        // ۔ - Urdu, Arabic (Arabic full stop)
        // ؟ - Arabic question mark
        // ！ - Chinese/Japanese exclamation
        // ？ - Chinese/Japanese question mark
        // 。 - Chinese/Japanese period
        final allSentences = script
            .split(RegExp(r'[.!?।۔؟！？。]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        
        print('[SPLIT] Found ${allSentences.length} sentences, grouping by $_sentencesPerSegment');
        
        // Group sentences based on _sentencesPerSegment
        for (int i = 0; i < allSentences.length; i += _sentencesPerSegment) {
          final end = (i + _sentencesPerSegment < allSentences.length) 
              ? i + _sentencesPerSegment 
              : allSentences.length;
          final sentencesInGroup = allSentences.sublist(i, end);
          
          // Detect the original terminator from the script to use for joining
          String terminator = '. '; // Default
          if (script.contains('।')) terminator = '। ';
          else if (script.contains('۔')) terminator = '۔ ';
          else if (script.contains('。')) terminator = '。';
          
          final group = sentencesInGroup.join(terminator);
          textParts.add(group);
          print('[SPLIT] Segment ${textParts.length}: ${sentencesInGroup.length} sentences');
        }
        break;
    }

    if (textParts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No parts found. Check your split mode.')),
      );
      return;
    }

    setState(() {
      _state = _state.copyWith(
        parts: textParts.asMap().entries.map((entry) {
          return StoryAudioPart(
            index: entry.key + 1,
            text: entry.value.trim(),
            voiceModel: _state.globalVoiceModel,
            voiceStyle: _state.globalVoiceStyle,
          );
        }).toList(),
      );
    });

    _saveState();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Created ${textParts.length} story parts')),
    );
  }

  bool _stopGenerationFlag = false;

  /// Stop current generation
  void _stopGeneration() {
    setState(() {
      _stopGenerationFlag = true;
    });
  }

  /// Generate TTS for a specific part index (Internal helper for batching)
  Future<void> _generatePartInternal(int index, Directory audioDir, {bool forceOverwrite = false}) async {
    if (_stopGenerationFlag) return;

    final part = _state.parts[index];
    final audioPath = path.join(audioDir.path, 'story_part_${part.index.toString().padLeft(3, '0')}.wav');
    
    // Check if file already exists - skip generation if so (unless forced)
    if (!forceOverwrite && await File(audioPath).exists()) {
       final duration = await _ttsService.getDuration(audioPath);
       if (mounted) {
         setState(() {
           _state.parts[index] = part.copyWith(
             status: 'success',
             audioPath: audioPath,
             duration: duration,
           );
         });
       }
       return;
    }

    // Update part status to generating
    _addLog('[TTS] Generating Part ${part.index} (${part.voiceModel})...');
    if (mounted) {
       setState(() {
        _state.parts[index] = part.copyWith(status: 'generating');
       });
    }
    
    try {
      if (_stopGenerationFlag) return;

      final success = await _ttsService.generateTts(
        text: part.text,
        voiceModel: part.voiceModel,
        voiceStyle: part.voiceStyle,
        speechRate: 1.0,
        outputPath: audioPath,
      );

      if (_stopGenerationFlag) return;

      if (success) {
        final duration = await _ttsService.getDuration(audioPath);
        _addLog('[TTS] ✓ Part ${part.index} done (${duration?.toStringAsFixed(1)}s)');
        if (mounted) {
          setState(() {
            _state.parts[index] = part.copyWith(
              status: 'success',
              audioPath: audioPath,
              duration: duration,
            );
          });
        }
      } else {
        _addLog('[TTS] ✗ Part ${part.index} failed');
         if (mounted) {
          setState(() {
            _state.parts[index] = part.copyWith(status: 'error', error: 'TTS generation failed');
          });
        }
      }
    } catch (e) {
      _addLog('[TTS] ✗ Part ${part.index} error: $e');
      if (mounted) {
        setState(() {
          _state.parts[index] = part.copyWith(status: 'error', error: e.toString());
        });
      }
    }
  }

  /// Generate TTS for all parts causing concurrency
  Future<void> _generateAllTts() async {
    _addLog('[TTS] Starting batch TTS generation for ${_state.parts.length} parts...');
    print('[StoryAudio] Starting generation...');
    if (_state.parts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please split the story script first')),
      );
      return;
    }

    setState(() {
      _isGeneratingTts = true;
      _stopGenerationFlag = false;
      _statusMessage = 'Loading API keys...';
      _progressValue = 0.0;
    });

    try {
      // Load API keys
      print('[StoryAudio] Loading API keys...');
      await _ttsService.loadApiKeys();

      // Get output directory
      String? projectDir = _customOutputFolder ?? widget.projectService.currentProject?.projectPath;
      if (projectDir == null) {
        throw Exception('No project selected');
      }
      
      final audioDir = Directory(path.join(projectDir, 'story_audio'));
      await audioDir.create(recursive: true);
      print('[StoryAudio] Audio dir: ${audioDir.path}');

      // Check for existing files
      int existingFilesCount = 0;
      for (var part in _state.parts) {
         final partPath = path.join(audioDir.path, 'story_part_${part.index.toString().padLeft(3, '0')}.wav');
         if (await File(partPath).exists()) {
            existingFilesCount++;
         }
      }

      bool forceOverwrite = false;
      if (existingFilesCount > 0) {
         if (mounted) {
            final result = await showDialog<String>(
               context: context, 
               barrierDismissible: false,
               builder: (ctx) => AlertDialog(
                 title: const Text('Existing Files Found'),
                 content: Text('$existingFilesCount audio files already exist.\n\nOverwrite all or generate only missing parts?'),
                 actions: [
                   TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Cancel')),
                   TextButton(onPressed: () => Navigator.pop(ctx, 'missing'), child: const Text('Generate Missing')),
                   ElevatedButton(
                     style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.red,
                                              foregroundColor: Colors.white,
                                              
                                            ),
                     onPressed: () => Navigator.pop(ctx, 'overwrite'), 
                     child: const Text('Overwrite All')
                   ),
                 ],
                ),
             );
            
            if (result == 'cancel' || result == null) {
               setState(() => _isGeneratingTts = false);
               return;
            }
            if (result == 'overwrite') {
               forceOverwrite = true;
            }
         }
      }

      // Concurrent Generation Logic (Sliding Window)
      int total = _state.parts.length;
      int completed = 0;
      int concurrentLimit = 10;
      final activeFutures = <Future<void>>{};
      int nextIndex = 0;

      print('[StoryAudio] Starting loop. Total: $total');

      while ((nextIndex < total || activeFutures.isNotEmpty)) {
        if (_stopGenerationFlag) {
           print('[StoryAudio] Stopped by user');
           setState(() => _statusMessage = 'Generation Stopped by User');
           break;
        }

        // Fill pool
        while (activeFutures.length < concurrentLimit && nextIndex < total) {
           if (_stopGenerationFlag) break;
           
           final index = nextIndex;
           nextIndex++;
           
           // Use Completer to ensure stable reference in Set
           final completer = Completer<void>();
           
           // Start task
           _generatePartInternal(index, audioDir, forceOverwrite: forceOverwrite).then((_) {
              completed++;
              if (mounted) {
                 setState(() {
                   _progressValue = completed / total;
                 });
              }
           }).catchError((e) {
              print('[StoryAudio] Task $index failed: $e');
           }).whenComplete(() {
              activeFutures.remove(completer.future);
              completer.complete();
              
              if (mounted && !_stopGenerationFlag) {
                 setState(() {
                   _statusMessage = 'Active: ${activeFutures.length} | Completed: $completed/$total';
                 });
              }
           });
           
           activeFutures.add(completer.future);
        }

        if (activeFutures.isEmpty) break;

        // Wait for at least one future to complete
        await Future.any(activeFutures);
      }
      
      _addLog('[TTS] ${_stopGenerationFlag ? "Stopped by user" : "✓ All TTS generation complete!"}');
      setState(() {
        _statusMessage = _stopGenerationFlag ? 'Stopped.' : 'TTS generation complete!';
      });
      
      if (!_stopGenerationFlag) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('TTS generation complete!')),
        );
      }
    } catch (e) {
      _addLog('[TTS] ✗ Batch error: $e');
      print('[StoryAudio] Error: $e');
      setState(() {
        _statusMessage = 'Error: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      print('[StoryAudio] Finished. Resetting flag.');
      setState(() {
        _isGeneratingTts = false;
      });
    }
  }

  /// Generate TTS for single part
  Future<void> _generateSingleTts(int index) async {
    if (index < 0 || index >= _state.parts.length) return;

    final part = _state.parts[index];

    try {
      await _ttsService.loadApiKeys();

      // Get output directory - use custom folder if selected, otherwise use project
      String? projectDir = _customOutputFolder ?? widget.projectService.currentProject?.projectPath;
      
      if (projectDir == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select an output folder first')),
        );
        return;
      }
      
      final audioDir = Directory(path.join(projectDir, 'story_audio'));
      await audioDir.create(recursive: true);

      _state.parts[index] = part.copyWith(status: 'generating');
      setState(() {});

      final audioPath = path.join(audioDir.path, 'story_part_${part.index.toString().padLeft(3, '0')}.wav');
      
      final success = await _ttsService.generateTts(
        text: part.text,
        voiceModel: part.voiceModel,
        voiceStyle: part.voiceStyle,
        speechRate: 1.0,
        outputPath: audioPath,
      );

      if (success) {
        final duration = await _ttsService.getDuration(audioPath);
        
        _state.parts[index] = part.copyWith(
          status: 'success',
          audioPath: audioPath,
          duration: duration,
        );
      } else {
        _state.parts[index] = part.copyWith(
          status: 'error',
          error: 'TTS generation failed',
        );
      }

      setState(() {});
      await _saveState();
    } catch (e) {
      _state.parts[index] = part.copyWith(
        status: 'error',
        error: e.toString(),
      );
      setState(() {});
    }
  }

  void _saveAlignmentJson() {
    try {
      final jsonContent = _alignmentJsonController.text;
      if (jsonContent.isEmpty) return;
      
      final jsonList = jsonDecode(jsonContent) as List;
      final items = jsonList.map((e) => AlignmentItem.fromJson(e)).toList();
      
      setState(() {
        _state = _state.copyWith(alignmentJson: items);
      });
      _saveState();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alignment JSON updated manually')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid JSON format: $e')),
      );
    }
  }

  void _copyAlignmentJson() {
     if (_alignmentJsonController.text.isNotEmpty) {
       Clipboard.setData(ClipboardData(text: _alignmentJsonController.text));
       ScaffoldMessenger.of(context).showSnackBar(
         const SnackBar(content: Text('Copied to clipboard')),
       );
     }
  }

  /// Generate alignment JSON
  Future<void> _generateAlignment() async {
    if (_state.parts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please create story parts first')),
      );
      return;
    }

    final prompts = _actionPromptsController.text.trim();
    if (prompts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter action prompts first')),
      );
      return;
    }

    setState(() {
      _isGeneratingAlignment = true;
      _statusMessage = 'Generating alignment...';
    });

    try {
      await _alignmentService.loadApiKeys();

      final alignment = await _alignmentService.generateAlignment(
        storyParts: _state.parts,
        videoPromptsRaw: prompts,
        model: _selectedAlignmentModel,
      );

      setState(() {
        _state = _state.copyWith(alignmentJson: alignment);
        _alignmentJsonController.text = const JsonEncoder.withIndent('  ').convert(alignment);
        _statusMessage = 'Alignment generated successfully!';
      });

      await _saveState();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Generated ${alignment.length} alignment items')),
      );
    } catch (e) {
      setState(() {
        _statusMessage = 'Error: $e';
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() {
        _isGeneratingAlignment = false;
      });
    }
  }

  /// Load action prompts from file
  Future<void> _loadActionPrompts() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final content = await file.readAsString();

        // Try to parse as JSON first
        try {
          final json = jsonDecode(content) as List;
          final prompts = json.map((item) => item['prompt'] as String? ?? item.toString()).join('\n');
          _actionPromptsController.text = prompts;
        } catch (_) {
          // If not JSON, use as plain text
          _actionPromptsController.text = content;
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Action prompts loaded')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading prompts: $e')),
      );
    }
  }

  /// Load videos
  /// Import videos directly from the project's videos folder
  Future<void> _loadVideosFromProject() async {
    try {
      final projectPath = widget.projectService.currentProject?.projectPath;
      if (projectPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No project loaded. Please select a project first.')),
        );
        return;
      }

      final videosDir = Directory(path.join(projectPath, 'videos'));
      if (!await videosDir.exists()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No videos folder found at: ${videosDir.path}')),
        );
        return;
      }

      final videoPaths = <String>[];
      await for (final entity in videosDir.list()) {
        if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase();
          if (['.mp4', '.avi', '.mkv', '.mov', '.webm'].contains(ext)) {
            videoPaths.add(entity.path);
          }
        }
      }

      if (videoPaths.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No video files found in project folder')),
        );
        return;
      }

      // Sort by filename (scene_0001, scene_0002, etc.)
      videoPaths.sort((a, b) => path.basename(a).compareTo(path.basename(b)));

      setState(() {
        _state = _state.copyWith(videosPaths: videoPaths);
      });

      await _saveState();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Loaded ${videoPaths.length} videos from project')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading project videos: $e')),
      );
    }
  }

  Future<void> _loadVideos() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp4', 'avi', 'mkv', 'mov', 'webm'],
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        final videoPaths = result.files
            .where((f) => f.path != null)
            .map((f) => f.path!)
            .toList();

        setState(() {
          _state = _state.copyWith(videosPaths: videoPaths);
        });

        await _saveState();

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Loaded ${videoPaths.length} videos')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading videos: $e')),
      );
    }
  }

  /// Export video
  Future<void> _exportVideo() async {
    if (_state.alignmentJson == null || _state.alignmentJson!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please generate alignment JSON first')),
      );
      return;
    }

    if (_state.videosPaths == null || _state.videosPaths!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please load videos first')),
      );
      return;
    }

    // Use the output folder already selected in the UI
    final outputFolder = _customOutputFolder ?? 
        widget.projectService.currentProject?.projectPath;
    
    String finalOutputPath;
    
    if (outputFolder != null) {
      // Auto-generate filename with timestamp
      await Directory(outputFolder).create(recursive: true);
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString().substring(5);
      finalOutputPath = path.join(outputFolder, 'story_video_$timestamp.mp4');
    } else {
      // Fallback: ask user to pick a save location
      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Video As',
        fileName: 'story_video.mp4',
        type: FileType.custom,
        allowedExtensions: ['mp4'],
      );
      if (outputPath == null) return;
      // Ensure .mp4 extension (Windows save dialog may strip it)
      finalOutputPath = outputPath.toLowerCase().endsWith('.mp4') ? outputPath : '$outputPath.mp4';
    }

    _addLog('[EXPORT] Starting ${_selectedExportMethod.toUpperCase()} export...');
    _addLog('[EXPORT] Output: ${path.basename(finalOutputPath)}');
    _addLog('[EXPORT] TTS: ${(_ttsVolume * 100).round()}% | Video: ${(_videoVolume * 100).round()}%');
    setState(() {
      _isExporting = true;
      _statusMessage = 'Exporting video...';
      _progressValue = 0.0;
    });

    try {
      if (_selectedExportMethod == 'fast') {
        await _exportService.exportVideoFast(
          alignment: _state.alignmentJson!,
          parts: _state.parts,
          videoPaths: _state.videosPaths!,
          outputPath: finalOutputPath,
          onProgress: (current, total, message) {
            _addLog('[EXPORT] $message');
            setState(() {
              _progressValue = current / total;
              _statusMessage = message;
            });
          },
          ttsVolume: _ttsVolume,
          videoVolume: _videoVolume,
        );
      } else {
        await _exportService.exportVideoPrecise(
          alignment: _state.alignmentJson!,
          parts: _state.parts,
          videoPaths: _state.videosPaths!,
          outputPath: finalOutputPath,
          onProgress: (current, total, message) {
            _addLog('[EXPORT] $message');
            setState(() {
              _progressValue = current / total;
              _statusMessage = message;
            });
          },
          ttsVolume: _ttsVolume,
          videoVolume: _videoVolume,
        );
      }

      _addLog('[EXPORT] ✓ Export complete: ${path.basename(finalOutputPath)}');
      setState(() {
        _statusMessage = 'Export complete!';
      });

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('✅ Success'),
            content: Text('Video exported successfully!\n\nOutput: ${path.basename(finalOutputPath)}'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  Process.run('explorer', ['/select,', finalOutputPath]);
                },
                child: const Text('Open Folder'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      _addLog('[EXPORT] ✗ Error: $e');
      setState(() {
        _statusMessage = 'Error: $e';
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() {
        _isExporting = false;
      });
    }
  }

  /// Apply global settings to all parts
  void _applyGlobalSettings() {
    if (_state.parts.isEmpty) return;

    setState(() {
      _state = _state.copyWith(
        parts: _state.parts.map((part) {
          return part.copyWith(
            voiceModel: _state.globalVoiceModel,
            voiceStyle: _state.globalVoiceStyle,
          );
        }).toList(),
      );
    });

    _saveState();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Applied global settings to all parts')),
    );
  }

  /// Play audio for a specific part
  Future<void> _playAudio(int index) async {
    if (index < 0 || index >= _state.parts.length) return;
    
    final part = _state.parts[index];
    if (part.audioPath == null || !await File(part.audioPath!).exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio file not found. Please generate audio first.')),
      );
      return;
    }

    try {
      // If already playing this part, stop it
      if (_currentlyPlayingIndex == index && _isPlaying) {
        await _stopAudio();
        return;
      }

      // Stop any currently playing audio
      if (_isPlaying) {
        await _stopAudio();
      }

      // Play the audio
      await _audioPlayer.play(DeviceFileSource(part.audioPath!));
      
      setState(() {
        _currentlyPlayingIndex = index;
        _isPlaying = true;
      });

      // Listen for completion
      _audioPlayer.onPlayerComplete.listen((_) {
        if (mounted) {
          setState(() {
            _currentlyPlayingIndex = null;
            _isPlaying = false;
          });
        }
      });

      print('[AUDIO] Playing: ${path.basename(part.audioPath!)}');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error playing audio: $e')),
      );
      setState(() {
        _currentlyPlayingIndex = null;
        _isPlaying = false;
      });
    }
  }

  /// Stop audio playback
  Future<void> _stopAudio() async {
    try {
      await _audioPlayer.stop();
      setState(() {
        _currentlyPlayingIndex = null;
        _isPlaying = false;
      });
    } catch (e) {
      print('[AUDIO] Error stopping: $e');
    }
  }

  Future<File> _getApiKeyFile() async {
    if (Platform.isAndroid) {
       // User requested explicit path
       final dir = Directory('/storage/emulated/0/veo3');
       if (!await dir.exists()) {
         await dir.create(recursive: true);
       }
       return File(path.join(dir.path, 'gemini_api_keys.txt'));
    } 
    if (Platform.isIOS) {
       final dir = await getApplicationDocumentsDirectory();
       return File(path.join(dir.path, 'gemini_api_keys.txt'));
    }
    final exePath = Platform.resolvedExecutable;
    final appDataDir = AppConfig.getAppDataDir();
    final dir = Directory(appDataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(path.join(appDataDir, 'gemini_api_keys.txt'));
  }

  /// Load API keys from file
  Future<String> _loadApiKeys() async {
    try {
      final file = await _getApiKeyFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) return content;
      }

      // Fallback to global keys
      try {
        final global = await GeminiKeyService.loadKeys();
        if (global.isNotEmpty) return global.join('\n');
      } catch (_) {}

      return '';
    } catch (e) {
      print('[API KEYS] Error loading: $e');
      return '';
    }
  }

  /// Save API keys to file
  Future<void> _saveApiKeys(String keys) async {
    try {
      final file = await _getApiKeyFile();
      
      // Ensure directory exists (mostly for desktop/custom paths)
      if (!await file.parent.exists()) {
         await file.parent.create(recursive: true);
      }
      
      await file.writeAsString(keys);
      // Also save into global GeminiKeyService for fallback across app
      try {
        final parsed = keys
            .split('\n')
            .map((k) => k.trim())
            .where((k) => k.isNotEmpty)
            .toList();
        if (parsed.isNotEmpty) await GeminiKeyService.addKeys(parsed);
      } catch (_) {}
      
      // Reload services (they will need to know the new path too - we'll fix them next)
      try {
        await _ttsService.loadApiKeys();
        await _alignmentService.loadApiKeys();
      } catch (_) {
         // Ignore reload errors here if services aren't updated yet
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('API keys saved to ${file.path}')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error saving API keys: $e')),
      );
    }
  }

  /// Show API keys management dialog
  Future<void> _showApiKeysDialog() async {
    // Load existing keys
    final existingKeys = await _loadApiKeys();
    _apiKeyController.text = existingKeys;

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.key, color: Colors.blue),
            SizedBox(width: 8),
            Text('Gemini API Keys'),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enter your Gemini API keys (one per line):',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '💡 Tip: Multiple keys enable automatic rotation for better rate limiting',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _apiKeyController, // Use persistent controller
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    hintText: 'AIzaSyAbc123...\nAIzaSyDef456...\nAIzaSyGhi789...',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Keys are saved to: gemini_api_keys.txt in app directory',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              final keys = _apiKeyController.text.trim(); // Use persistent controller
              if (keys.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter at least one API key')),
                );
                return;
              }
              
              // Count keys
              final keyCount = keys.split('\n').where((k) => k.trim().isNotEmpty).length;
              
              await _saveApiKeys(keys);
              
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save Keys'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  void _ensureDefaultTemplates() {
    final originalLength = _state.reelTemplates.length;
    final Map<String, ReelTemplate> currentTemplates = {
      for (var t in _state.reelTemplates) t.id: t
    };

    const angryFoodId = 'predefined_angry_food_bengali';
    const courtroomDramaId = 'predefined_courtroom_drama_bengali';

    final angryFoodTemplate = ReelTemplate(
        id: angryFoodId,
        name: 'Angry Food (Bengali Slang)',
        systemPrompt: '''You are an expert Short Video Script Writer and Prompt Engineer.

TASK: Generate a single story variation based on the user's TOPIC which will be a food item, vegetable, fruit, etc.
Create an anthropomorphic funny and angry character out of the user's topic.
The story must consist of scenes of this angry character inside the human body or a relatable biological/health setting, lecturing the viewer using funny Bengali slang about its health benefits and what happens when you eat bad food vs this food.

**CRITICAL INSTRUCTIONS FOR VISUALS & PROMPTS:**
1. Maintain exactly the same character description in EVERY prompt. (e.g., "An anthropomorphic angry [topic] character with... wearing a grey and blue checkered lungi...").
2. Settings should describe the inside of a human body (like a colon, heart cavity, fat tunnels, skin surface) but in a high-end 3D animated style (NutriToony, Octane render, 8k).
3. The exact spoken dialogue MUST be written implicitly inside the video prompt as inline text, and also provided in the 'text' and 'voice_cue' fields.
4. Each prompt must include: "shouting the line: '[Bengali Dialogue]'" at the end of the action description.

NARRATIVE & LANGUAGE RULES:
1. Dialogues MUST be in Bengali slang (funny, angry, somewhat aggressive but comedic, lecturing about health benefits or bad food habits).
2. The `text` field must contain the Bengali dialogue (for TTS narration if enabled).
3. The `prompt` field MUST be in English, EXCEPT for the inline dialogue which should be in Bengali.

OUTPUT JSON FORMAT:
{
  "reels": [
    {
      "title": "Angry [Topic] Health Lecture",
      "content": [
         {
           "text": "আমি হইলাম শসা। আমারে খাইছস? দূর কইরা দিমু তোর কষা।",
           "visuals": [
              {
                "scene_number": 1,
                "art_style": "Vertical video, high-end 3D animation in the style of NutriToony, Octane render, 8k, cinematic lighting.",
                "character_description": "An anthropomorphic angry [topic] character with realistic texture, cartoon arms and legs, large expressive eyes and mouth, wearing a grey and blue checkered lungi wrapped around its waist",
                "visual": "stands inside a dark, wet, textured red colon tunnel representing a human intestine. The character holds a rustic wooden shovel in one hand and gestures aggressively with the other, shouting the line: 'আমি হইলাম শসা। আমারে খাইছস? দূর কইরা দিমু তোর কষা।'",
                "bg_score": "Comedic intense music",
                "voice_cue": "The character shouts: 'আমি হইলাম শসা। আমারে খাইছস? দূর কইরা দিমু তোর কষা।'",
                "previous_prompts_for_context": [],
                "prompt": "[art_style] [character_description], [visual]",
                "active": true
              }
           ]
         }
      ]
    }
  ]
}'''
    );

    final courtroomDramaTemplate = ReelTemplate(
        id: courtroomDramaId,
        name: 'Courtroom Drama (Bengali)',
        systemPrompt: '''You are an expert Short Video Script Writer and Prompt Engineer specializing in 3D Pixar-style courtroom comedy animations.

TASK: Generate exactly FIVE (5) SCENES for a courtroom drama video script based on the user's TOPIC.
Create an anthropomorphic defendant character out of the user's topic.

**VISUAL STYLE & QUALITY BAR:**
You MUST write extremely detailed, cinematic prompts in the exact style of the following structure:
- USE cinematic terms: "Slow dolly-in", "Aggressive snap-zoom", "Smash-cut", "Handheld camera shake", "Low-angle shot", "Over-the-shoulder composition".
- DESCRIBE textures vividly: "crispy bubbly besan-coated texture", "glistening oil droplets", "thin wobbly stick-arms", "porous surface", "silk barrister robe", "curly powdered legal wig".
- ATMOSPHERE: "grand courtroom with mahogany railings, brass fixtures, and golden sunlight through tall stained-glass windows", "deep amber side-lighting with heavy shadows".
- JURY & BACKGROUND: Always include a packed gallery of random anthropomorphic vegetables (weeping onion, stern broccoli, fiery chili, garlic with monocle).

**CHARACTER SELECTION RULES - RANDOMIZE ALL CHARACTERS:**
- **Defendant (accused):** An anthropomorphic version of the user's TOPIC. High-detail Pixar-style. Give this character a FULL physical description (height, texture, eyes, arms, legs, clothing). This EXACT description must be copied into EVERY prompt.
- **Prosecutor (Lawyer):** Pick ANY random anthropomorphic fruit, vegetable, animal, or object (NOT the same as topic). MUST wear black silk barrister robe, white ruffled Elizabethan collar, and white curly powdered legal wig. Give FULL physical description. This EXACT description must be copied into EVERY prompt.
- **Judge:** Pick ANY random anthropomorphic fruit, vegetable, animal, or object (NOT the same as others). MUST wear black suit jacket, white shirt, black tie, silver-rimmed spectacles. Sitting behind an elevated mahogany bench with a 'GEORGE' nameplate. Give FULL physical description. This EXACT description must be copied into EVERY prompt.
- **Police Guards:** Two specific random anthropomorphic fruits/vegetables in navy police uniforms with brass buttons and peaked caps. Give FULL physical description. This EXACT description must be copied into EVERY prompt.

**CRITICAL: CHARACTER CONSISTENCY RULE:**
You MUST define ALL characters once at the start, then copy-paste the EXACT SAME full character descriptions into the `character_description` field AND `prompt` field of EVERY scene. Do NOT abbreviate, shorten, or use references like "the same judge" — always write out the complete physical description in every single prompt. This ensures AI video generation keeps characters visually identical across all scenes.

**STORY BEATS (YOU MUST GENERATE ALL 5 SCENES):**
1. **THE ACCUSATION:** Full-body vertical shot of the grand courtroom, with the [Judge full description] sitting high on the bench looking down sternly. Slow dolly-in toward the [Prosecutor full description] pointing a finger aggressively at the terrified [Defendant full description] who is standing inside the rounded wooden dock. End the scene with a sudden cinematic smash-cut.
2. **THE PROSECUTION EXPLODES:** Aggressive snap-zoom. [Prosecutor full description] slams papers, fully unhinged. [Defendant full description] cowers. Jury erupts.
3. **THE DESPERATE DEFENSE:** Smash-cut to handheld shake medium close-up. [Defendant full description] has an emotional meltdown, stick-arms flailing, tears streaming. Judge watches with narrowed eyes.
4. **THE VERDICT:** Dramatic low-angle push-in on [Judge full description]. Judge roars "অর্ডার অর্ডার", smashes the gavel (wood splinters erupting). Judge announces a funny punishment that is LOGICALLY connected to the defendant's nature (e.g., if defendant is a mango, punishment could be being made into juice; if a fish, being fried in a pan). Keep the Bengali dialogue SHORT (2-3 sentences max) so AI can fit it in 8 seconds.
5. **THE PUNISHMENT:** Wide cinematic shot showing the punishment being carried out or about to be carried out. [Police Guards full description] drag the screaming [Defendant full description] away. Show the reaction of the courtroom — jury cheering, prosecutor smirking smugly.

**PUNISHMENT RULES:**
- The punishment MUST be logically funny — it should relate to what the defendant IS (e.g., an apple gets turned into apple pie, a fish gets fried, a potato gets turned into french fries, a mango gets squeezed into juice).
- Do NOT use random illogical punishments. The humor comes from the ironic connection between the punishment and the defendant's identity.

**CRITICAL RULES:**
1. **COUNT RULE:** YOU MUST OUTPUT EXACTLY FIVE (5) SCENES. No more, no less.
2. **DEFENDANT'S DOCK:** Defendant MUST always be "standing inside a rounded wooden defendant's dock (a waist-high curved wooden enclosure with vertical slats and a small swinging gate), gripping the curved wooden railing tightly."
3. **ABSOLUTELY NO PUNCTUATION AFTER "অর্ডার অর্ডার":** NEVER put exclamation marks (!), periods (.), or ANY punctuation after "অর্ডার অর্ডার". It MUST be written as just "অর্ডার অর্ডার" followed by a space then the next word. Exclamation marks cause the AI voice to slow down. BAD: "অর্ডার অর্ডার!" GOOD: "অর্ডার অর্ডার তোমাকে..."
4. **SCENE 4 TEXT MUST BE UNDER 120 CHARACTERS:** The `text` field for Scene 4 MUST be between 80-120 Bengali characters MAXIMUM. This is critical — longer text makes AI unable to fit it in 8 seconds. The judge says "অর্ডার অর্ডার" then ONE short punishment sentence only. Examples of CORRECT length:
   - "অর্ডার অর্ডার তোমাকে আপেল সস বানানোর হুকুম দেওয়া হলো" (54 chars ✓)
   - "অর্ডার অর্ডার আসামীকে রস করে বাজারে বিক্রি করার আদেশ দেওয়া হচ্ছে" (67 chars ✓)
   - "অর্ডার অর্ডার এই মাছকে ভেজে বাজারে বিক্রি করো" (48 chars ✓)
   Examples of WRONG (too long): "অর্ডার অর্ডার আদালত এই সিদ্ধান্তে উপনীত হয়েছে যে এই আপেলটি সমাজের জন্য ক্ষতিকর তোমাকে আপেল সস বানানোর আদেশ দেওয়া হলো" (TOO LONG ✗)
5. **ALL SCENE TEXT UNDER 150 CHARACTERS:** Every scene's `text` field should be under 150 Bengali characters. Keep dialogues punchy and theatrical, not long speeches.
6. **FULL CHARACTER DESCRIPTION IN EVERY PROMPT:** Every `prompt` field must contain the complete physical description of every character visible in that scene. Never abbreviate or use "the same character" — write the full description every time.
7. **LANGUAGE:** `text` is theatrical Bengali slang. Speech must be fast (5-6s max per scene). `prompt` is English, except for inline dialogue: "shouting the line: '[Bengali Dialogue]'"

OUTPUT JSON FORMAT:
{
  "reels": [
    {
      "title": "[Topic] in Court",
      "content": [
         {
           "text": "[Scene 1 Bengali dialogue]",
           "visuals": [
              {
                "scene_number": 1,
                "art_style": "3D Pixar-style animation, Vertical 9:16 aspect ratio.",
                "character_description": "[FULL detailed description of ALL characters visible — defendant, prosecutor, judge, police, jury. Use complete physical descriptions, textures, outfits].",
                "visual": "[Extremely detailed scene description with specific camera moves and environmental details]. The [character with full description] [action] shouting the line: '[Bengali Dialogue]'",
                "bg_score": "Dramatic intense courtroom music",
                "voice_cue": "The [character] character shouts: '[Bengali Dialogue]'",
                "previous_prompts_for_context": [],
                "prompt": "[art_style] [character_description] [visual]",
                "active": true
              }
           ]
         },
         {
           "text": "[Scene 2 Bengali dialogue]",
           "visuals": [
              {
                "scene_number": 2,
                "art_style": "3D Pixar-style animation, Vertical 9:16 aspect ratio.",
                "character_description": "[SAME full character descriptions repeated exactly]",
                "visual": "[Visual description]. The [character with full description] [action] shouting the line: '[Bengali Dialogue]'",
                "bg_score": "Dramatic intense courtroom music",
                "voice_cue": "The [character] character shouts: '[Bengali Dialogue]'",
                "previous_prompts_for_context": [],
                "prompt": "[art_style] [character_description] [visual]",
                "active": true
              }
           ]
         },
         {
           "text": "[Scene 3 Bengali dialogue]",
           "visuals": [{"scene_number": 3, ...same structure with FULL character descriptions...}]
         },
         {
           "text": "[Scene 4 SHORT Bengali dialogue — ORDER ORDER + punishment announcement (2-3 sentences max)]",
           "visuals": [{"scene_number": 4, ...same structure with FULL character descriptions...}]
         },
         {
           "text": "[Scene 5 Bengali dialogue — punishment execution and courtroom reaction]",
           "visuals": [{"scene_number": 5, ...same structure with FULL character descriptions...}]
         }
      ]
    }
  ]
}'''
    );

    // Force update predefined templates
    currentTemplates[angryFoodId] = angryFoodTemplate;
    currentTemplates[courtroomDramaId] = courtroomDramaTemplate;

    final updatedTemplatesList = currentTemplates.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    // Only update if something actually changed to avoid infinite loops in build()
    bool changed = updatedTemplatesList.length != _state.reelTemplates.length;
    if (!changed) {
      for (int i = 0; i < updatedTemplatesList.length; i++) {
        if (updatedTemplatesList[i].id != _state.reelTemplates[i].id ||
            updatedTemplatesList[i].systemPrompt != _state.reelTemplates[i].systemPrompt) {
          changed = true;
          break;
        }
      }
    }

    if (changed) {
      _state = _state.copyWith(reelTemplates: updatedTemplatesList);
      _saveState(); // Ensure changes persist
    }
  }

  @override
  Widget build(BuildContext context) {
    // Ensure default templates are always up-to-date with our hardcoded logic
    _ensureDefaultTemplates();

    // Reel-only mode: Show only the Reel tab without tab bar
    if (widget.reelOnlyMode) {
      return Stack(
        children: [
          Scaffold(
            backgroundColor: ThemeProvider().scaffoldBg,

            body: _buildReelTab(),
          ),
          // Mobile browser overlay
          if (Platform.isAndroid || Platform.isIOS)
            MobileBrowserManagerWidget(
              key: _mobileBrowserKey,
              browserCount: 4,
              initiallyVisible: _mobileBrowserVisible,
              onVisibilityChanged: (visible) {
                setState(() => _mobileBrowserVisible = visible);
              },
            ),
        ],
      );
    }
    
    // Story Audio only mode: Show only the Story Audio tab without tab bar
    if (widget.storyAudioOnlyMode) {
      if (widget.embedded) {
        // If embedded, we don't need the extra Scaffold/AppBar, just return the content
        return _buildStoryAudioContent();
      }
      
      return Scaffold(
        backgroundColor: ThemeProvider().scaffoldBg,
        appBar: AppBar(
          automaticallyImplyLeading: !widget.embedded,
          leading: widget.embedded ? null : IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: 'Back to Home',
            onPressed: () {
              if (widget.onBack != null) {
                widget.onBack!();
              } else if (Navigator.canPop(context)) {
                Navigator.pop(context);
              }
            },
          ),
          title: const Row(
            children: [
              Icon(Icons.audiotrack, size: 24),
              SizedBox(width: 8),
              Text('Manual Audio with Video'),
            ],
          ),
          backgroundColor: Theme.of(context).colorScheme.inversePrimary,
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'API Settings',
              onPressed: _showApiKeysDialog,
            ),
          ],
        ),
        body: _buildStoryAudioContent(),
      );
    }
    
    // Normal mode: Show tabs
    return Scaffold(
      backgroundColor: ThemeProvider().scaffoldBg,
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        leading: widget.embedded ? null : IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to Home',
          onPressed: () {
            // Use callback if provided, otherwise try Navigator
            if (widget.onBack != null) {
              widget.onBack!();
            } else if (Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          },
        ),
        title: const Row(
          children: [
            Icon(Icons.audiotrack, size: 24),
            SizedBox(width: 8),
            Text('Story Audio'),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'API Settings',
            onPressed: _showApiKeysDialog,
          ),
        ],
      ),
      body: DefaultTabController(
        length: 2,
        initialIndex: widget.initialTabIndex.clamp(0, 1),
        child: Column(
          children: [
            Container(
              color: ThemeProvider().surfaceBg,
              child: const TabBar(
                tabs: [
                  Tab(text: 'Story Audio'),
                  Tab(text: 'Reel Special'),
                ],
                labelColor: Colors.blue,
                unselectedLabelColor: Colors.grey,
                indicatorColor: Colors.blue,
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                   _buildStoryAudioContent(),
                   _buildReelTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reusable compact section wrapper with icon header
  Widget _buildSection({required String title, required IconData icon, required Color accentColor, required List<Widget> children, Widget? trailing}) {
    final tp = ThemeProvider();
    return Container(
      decoration: BoxDecoration(
        color: tp.surfaceBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tp.borderColor.withOpacity(0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: accentColor.withOpacity(tp.isDarkMode ? 0.12 : 0.06),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 14, color: accentColor),
                const SizedBox(width: 6),
                Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: accentColor, letterSpacing: 0.3)),
                if (trailing != null) ...[
                  const Spacer(),
                  trailing!,
                ],
              ],
            ),
          ),
          // Body
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStoryAudioContent() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final padding = isMobile ? 6.0 : 10.0;
        
        if (isMobile) {
          return Padding(
            padding: EdgeInsets.all(padding),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildVideoSection(),
                  const SizedBox(height: 6),
                  _buildOutputAndExportSection(),
                  const SizedBox(height: 6),
                  _buildStoryScriptSection(),
                  const SizedBox(height: 6),
                  _buildActionPromptsSection(),
                  const SizedBox(height: 6),
                  _buildGlobalSettingsSection(),
                  const SizedBox(height: 6),
                  _buildAlignmentSection(),
                  const SizedBox(height: 6),
                  _buildStoryPartsSection(),
                  if (_statusMessage.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _buildStatusSection(),
                  ],
                ],
              ),
            ),
          );
        } else {
          // Desktop: Three column layout
          return Padding(
            padding: EdgeInsets.all(padding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Column - Import & Settings
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildVideoSection(),
                        const SizedBox(height: 6),
                        _buildStoryScriptSection(),
                        const SizedBox(height: 6),
                        _buildActionPromptsSection(),
                        const SizedBox(height: 6),
                        _buildAlignmentSection(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Middle Column - Story Parts
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildGlobalSettingsSection(),
                        const SizedBox(height: 6),
                        _buildStoryPartsSection(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Right Column - Output & Export
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildOutputAndExportSection(),
                        if (_statusMessage.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          _buildStatusSection(),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        }
      },
    );
  }

  // --- Reel Special Tab ---

  // --- Profile Methods ---
  Future<void> _ensureProfilesDir() async {
    await Directory(AppConfig.profilesDir).create(recursive: true);
    final defaultProfile = Directory(path.join(AppConfig.profilesDir, 'Default'));
    if (!await defaultProfile.exists()) {
      await defaultProfile.create(recursive: true);
    }
  }

  Future<void> _loadProfiles() async {
    final profilesDir = Directory(AppConfig.profilesDir);
    if (await profilesDir.exists()) {
      final dirs = await profilesDir.list().where((entity) => entity is Directory).toList();
      setState(() {
        _profiles = dirs.map((d) => path.basename(d.path)).toList()..sort();
        if (_profiles.isEmpty) {
          _profiles = ['Default'];
        }
      });
    }
  }

  Future<void> _connectBrowsers() async {
    if (widget.profileManager == null) return;
    
    setState(() => _isConnectingBrowsers = true);
    
    try {
      // Try to connect to up to 10 browsers (standard max)
      final count = await widget.profileManager!.connectToOpenProfiles(10);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to $count browsers'),
            backgroundColor: count > 0 ? Colors.green : Colors.orange,
          ),
        );
        setState(() {}); // Trigger rebuild to update count display
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error connecting: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isConnectingBrowsers = false);
    }
  }

  Future<void> _launchChrome() async {
     final profilePath = path.join(AppConfig.profilesDir, 'Default'); // Default profile since selector removed
    
    await Process.start(
      AppConfig.chromePath,
      [
        '--remote-debugging-port=${AppConfig.debugPort}',
        '--remote-allow-origins=*',
        '--user-data-dir=$profilePath',
        '--profile-directory=Default',
        'https://labs.google/fx/tools/flow',
      ],
      mode: ProcessStartMode.detached,
    );
     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Launched Chrome with Default profile')));
  }

  Widget _buildReelTab() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 600;
        final isTablet = constraints.maxWidth >= 600 && constraints.maxWidth < 900;
        final isDesktop = constraints.maxWidth >= 900;
        final padding = isMobile ? 8.0 : (isTablet ? 12.0 : 16.0);
        
        // Desktop: Split panel layout (3-column style)
        if (isDesktop) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Column 1: Templates & Prompts (Left)
              Expanded(
                flex: 150,
                child: Container(
                  height: constraints.maxHeight,
                  child: Scrollbar(
                    controller: _leftScrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _leftScrollController,
                      child: Padding(
                        padding: EdgeInsets.only(top: 8, left: padding, right: 0, bottom: padding),
                        child: _buildControlsPanel(padding, false),
                      ),
                    ),
                  ),
                ),
              ),
              // Separator
              const SizedBox(width: 8),
              // Columns 2 & 3: Projects & Settings (Middle & Right)
              Expanded(
                flex: 250,
                child: Container(
                  height: constraints.maxHeight,
                  child: _buildReelsListPanel(padding, isMobile, isDesktop),
                ),
              ),
            ],
          );
        }
        
        // Mobile/Tablet: Stacked layout (original)
        return SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildControlsPanel(padding, isMobile),
                const SizedBox(height: 16),
                _buildReelsListPanel(padding, isMobile, isDesktop),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Build the controls panel (left side on desktop, top on mobile)
  Widget _buildControlsPanel(double padding, bool isMobile) {
    final tp = ThemeProvider();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Input Section
        Container(
          decoration: BoxDecoration(
            color: tp.surfaceBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tp.borderColor),
            boxShadow: [
              BoxShadow(
                color: tp.shadowColor,
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.only(top: 6, left: isMobile ? padding : 12, right: isMobile ? padding : 12, bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isMobile) _buildOutputFolderSection(),
                if (isMobile) const SizedBox(height: 12),
                // Template Selector - Responsive
                isMobile
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          DropdownButtonFormField<String>(
                            value: _state.selectedReelTemplateId,
                            decoration: const InputDecoration(
                              labelText: 'Story Template',
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              isDense: true,
                            ),
                            items: [
                              const DropdownMenuItem(value: null, child: Text("Default (Boy Saves Animals)", style: TextStyle(fontSize: 12))),
                              ..._state.reelTemplates.map((t) => DropdownMenuItem(value: t.id, child: Text(t.name, style: const TextStyle(fontSize: 12)))),
                            ],
                            onChanged: (val) {
                              setState(() {
                                _state = _state.copyWith(selectedReelTemplateId: val);
                              });
                              _saveState();
                            },
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _showTemplateCreatorDialog,
                                  icon: const Icon(Icons.add_circle_outline, size: 16),
                                  label: const Text("New", style: TextStyle(fontSize: 12)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert),
                                onSelected: (String val) {
                                  if (val == 'import') {
                                    _importTemplate();
                                  } else if (val == 'export') {
                                    _exportTemplate();
                                  }
                                },
                                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                                  const PopupMenuItem<String>(
                                    value: 'import',
                                    child: Text('Import Template (JSON)'),
                                  ),
                                   PopupMenuItem<String>(
                                     value: 'export',
                                     child: Text(LocalizationService().tr('reel.export_selected')),
                                   ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Horizontal scrolling template cards
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6, left: 4),
                              child: Text(
                                LocalizationService().tr('reel.templates'),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: tp.textTertiary,
                                  letterSpacing: 0.3,
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                RotatedBox(
                                  quarterTurns: 3,
                                  child: Text(
                                    LocalizationService().tr('reel.templates_label'),
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900,
                                      color: tp.textTertiary,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SizedBox(
                                    height: 165,
                                    child: ListView(
                                      scrollDirection: Axis.horizontal,
                                      children: [
                                        // Default "Boy Saves Animals" card
                                        _buildTemplateCard(
                                          id: null,
                                          name: 'Boy Saves Animals',
                                          imagePath: 'assets/templates/boy_saves_animals.png',
                                          isSelected: _state.selectedReelTemplateId == null,
                                        ),
                                        // User templates
                                        ..._state.reelTemplates.map((t) => _buildTemplateCard(
                                          id: t.id,
                                          name: t.name,
                                          imagePath: t.id == 'predefined_angry_food_bengali' 
                                            ? 'assets/templates/angry_food_template.png' 
                                            : t.id == 'predefined_courtroom_drama_bengali' 
                                              ? 'assets/templates/courtroom_drama_template.png' 
                                              : null,
                                          isSelected: _state.selectedReelTemplateId == t.id,
                                        )),
                                        // New Template Card
                                        Container(
                                          width: 90,
                                          margin: const EdgeInsets.only(right: 12),
                                          decoration: BoxDecoration(
                                            color: tp.isDarkMode ? tp.inputBg : Colors.grey.shade50,
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(color: tp.borderColor, style: BorderStyle.solid),
                                          ),
                                          child: Stack(
                                            children: [
                                              Center(
                                                child: Column(
                                                  mainAxisAlignment: MainAxisAlignment.center,
                                                  children: [
                                                    IconButton(
                                                      icon: const Icon(Icons.add_circle, color: Colors.deepPurple, size: 32),
                                                      onPressed: _showTemplateCreatorDialog,
                                                      tooltip: 'Create New Template',
                                                    ),
                                                    const SizedBox(height: 4),
                                                    const Text("New", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
                                                  ],
                                                ),
                                              ),
                                              Positioned(
                                                top: 0,
                                                right: 0,
                                                child: PopupMenuButton<String>(
                                                  icon: Icon(Icons.more_horiz, size: 20, color: Colors.grey.shade600),
                                                  tooltip: 'More Options',
                                                  padding: EdgeInsets.zero,
                                                  onSelected: (val) {
                                                    if (val == 'import') _importTemplate();
                                                    if (val == 'export') _exportTemplate();
                                                  },
                                                  itemBuilder: (context) => [
                                                    const PopupMenuItem(value: 'import', child: Text('Import Template')),
                                                    const PopupMenuItem(value: 'export', child: Text('Export Template')),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                     const SizedBox(height: 16),
                    TextField(
                      controller: _reelTopicController,
                      decoration: InputDecoration(
                        hintText: LocalizationService().tr('reel.enter_topic'),
                        hintStyle: TextStyle(color: tp.textTertiary, fontSize: 13),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.deepPurple, width: 1.5)),
                        filled: true,
                        fillColor: tp.inputBg,
                        isDense: true,
                        contentPadding: const EdgeInsets.all(12),
                      ),
                      maxLines: isMobile ? 3 : 2,
                      style: TextStyle(fontSize: 13, color: tp.textPrimary),
                    ),

                    const SizedBox(height: 8),
                    // Character & Language Row (compact)
                    Row(
                      children: [
                        Text(LocalizationService().tr('reel.character'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: tp.textSecondary)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            initialValue: _state.reelCharacter,
                            decoration: InputDecoration(
                              hintText: 'e.g. Boy',
                              hintStyle: TextStyle(color: tp.textTertiary, fontSize: 12),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                              filled: true,
                              fillColor: tp.inputBg,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            ),
                            style: TextStyle(fontSize: 12, color: tp.textPrimary),
                            onChanged: (value) {
                              _state = _state.copyWith(reelCharacter: value);
                              _saveState();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Topic Mode Toggle
                    Row(
                      children: [
                        Text(LocalizationService().tr('reel.topic_mode'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        const SizedBox(width: 8),
                        SegmentedButton<String>(
                          segments: [
                            ButtonSegment(value: 'single', label: Text(LocalizationService().tr('reel.single_topic'), style: const TextStyle(fontSize: 11))),
                            ButtonSegment(value: 'multi', label: Text(LocalizationService().tr('reel.one_per_line'), style: const TextStyle(fontSize: 11))),
                          ],
                          selected: {_reelTopicMode},
                          onSelectionChanged: (v) => setState(() => _reelTopicMode = v.first),
                          style: ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                        const SizedBox(height: 12),
                        // Reels count and story variations - Responsive
                        if (_reelTopicMode == 'single')
                          isMobile
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(child: Text(LocalizationService().tr('reel.reels'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                                        SizedBox(
                                          width: 80,
                                          child: TextField(
                                            controller: _reelCountController,
                                            keyboardType: TextInputType.number,
                                            style: const TextStyle(fontSize: 12),
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                              isDense: true,
                                            ),
                                            onChanged: (v) {
                                              final count = int.tryParse(v) ?? 1;
                                              setState(() => _reelCount = count.clamp(1, 1000));
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Expanded(child: Text(LocalizationService().tr('reel.stories_hint'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                                        SizedBox(
                                          width: 60,
                                          child: DropdownButton<int>(
                                            value: _storiesPerHint,
                                            isDense: true,
                                            isExpanded: true,
                                            items: [1, 2, 3, 4, 5].map((n) => DropdownMenuItem(
                                              value: n,
                                              child: Text('$n', style: const TextStyle(fontSize: 12)),
                                            )).toList(),
                                            onChanged: (v) => setState(() => _storiesPerHint = v ?? 1),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    // Scenes per Story (Video Prompts)
                                    Row(
                                      children: [
                                        Expanded(child: Text(LocalizationService().tr('reel.scenes'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                                        SizedBox(
                                          width: 60,
                                          child: DropdownButton<int>(
                                            value: _scenesPerStory,
                                            isDense: true,
                                            isExpanded: true,
                                            items: [8, 10, 12, 15, 18, 20].map((n) => DropdownMenuItem(
                                              value: n,
                                              child: Text('$n', style: const TextStyle(fontSize: 12)),
                                            )).toList(),
                                            onChanged: (v) => setState(() => _scenesPerStory = v ?? 12),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                )
                              : Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(LocalizationService().tr('reel.reels'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                        const SizedBox(width: 4),
                                        SizedBox(
                                          width: 50,
                                          child: TextField(
                                            controller: _reelCountController,
                                            keyboardType: TextInputType.number,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                                              isDense: true,
                                            ),
                                            style: const TextStyle(fontSize: 12),
                                            onChanged: (v) {
                                              final count = int.tryParse(v) ?? 1;
                                              setState(() => _reelCount = count.clamp(1, 1000));
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(LocalizationService().tr('reel.stories_hint'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                        const SizedBox(width: 4),
                                        DropdownButton<int>(
                                          value: _storiesPerHint,
                                          isDense: true,
                                          style: TextStyle(fontSize: 12, color: tp.textPrimary),
                                          items: [1, 2, 3, 4, 5].map((n) => DropdownMenuItem(
                                            value: n,
                                            child: Text('$n'),
                                          )).toList(),
                                          onChanged: (v) => setState(() => _storiesPerHint = v ?? 1),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(LocalizationService().tr('reel.scenes'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                        const SizedBox(width: 4),
                                        DropdownButton<int>(
                                          value: _scenesPerStory,
                                          isDense: true,
                                          style: TextStyle(fontSize: 12, color: tp.textPrimary),
                                          items: [8, 10, 12, 15, 18, 20].map((n) => DropdownMenuItem(
                                            value: n,
                                            child: Text('$n'),
                                          )).toList(),
                                          onChanged: (v) => setState(() => _scenesPerStory = v ?? 12),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                        
                        const SizedBox(height: 20),
                        
                        // Section 1: Video Voice (Veo3)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          height: 52,
                          decoration: BoxDecoration(
                            color: tp.isDarkMode ? Colors.blue.withOpacity(0.1) : Colors.blue.shade50.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: tp.isDarkMode ? tp.borderColor : Colors.blue.shade100),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Icon(Icons.video_camera_front, size: 16, color: Colors.blue.shade700),
                              const SizedBox(width: 8),
                              Text(LocalizationService().tr('reel.video_voice'), 
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: tp.textPrimary)),
                              Text('(Veo3)', style: TextStyle(fontSize: 10, color: tp.textTertiary)),
                              
                              if (_globalVoiceCueEnabled) ...[
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Container(
                                    alignment: Alignment.center,
                                    height: 32, // Controlled height for the input box
                                    child: Autocomplete<String>(
                                      initialValue: TextEditingValue(text: _voiceCueLanguage),
                                      optionsBuilder: (textEditingValue) {
                                        final options = ['English', 'Bengali', 'Hindi', 'Spanish', 'French', 'Arabic', 'Japanese', 'Korean', 'Portuguese', 'German'];
                                        if (textEditingValue.text.isEmpty) return options;
                                        return options.where((o) => o.toLowerCase().contains(textEditingValue.text.toLowerCase()));
                                      },
                                      onSelected: (value) {
                                        setState(() => _voiceCueLanguage = value);
                                        _saveState();
                                      },
                                      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                                        return TextFormField(
                                          controller: controller,
                                          focusNode: focusNode,
                                          textAlignVertical: TextAlignVertical.center,
                                          style: const TextStyle(fontSize: 12),
                                          decoration: InputDecoration(
                                            isDense: true,
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
                                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade200)),
                                            hintText: 'Lang',
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                                            filled: true,
                                            fillColor: tp.inputBg,
                                          ),
                                          onChanged: (v) {
                                            _voiceCueLanguage = v;
                                            _debouncedSave();
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ] else ...[
                                const Spacer(),
                              ],
                              
                              const SizedBox(width: 12),
                              SizedBox(
                                height: 24,
                                child: Transform.scale(
                                  scale: 0.8,
                                  child: Switch(
                                    value: _globalVoiceCueEnabled,
                                    activeColor: Colors.blue,
                                    onChanged: (v) {
                                      setState(() => _globalVoiceCueEnabled = v);
                                      _saveState();
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 8),
                        
                        // Section 2: External Dubbing Voice
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          height: 52,
                          decoration: BoxDecoration(
                            color: tp.isDarkMode ? Colors.deepPurple.withOpacity(0.1) : Colors.deepPurple.shade50.withOpacity(0.3),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: tp.isDarkMode ? tp.borderColor : Colors.deepPurple.shade100),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Icon(Icons.mic, size: 16, color: Colors.deepPurple.shade700),
                              const SizedBox(width: 8),
                              Text(LocalizationService().tr('reel.external_dubbing'), 
                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: tp.textPrimary)),
                              
                              if (_globalNarrationEnabled) ...[
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Container(
                                    alignment: Alignment.center,
                                    height: 32, // Controlled height for the input box
                                    child: Autocomplete<String>(
                                      optionsBuilder: (textEditingValue) {
                                        final options = ['Bengali', 'Hindi', 'English', 'Urdu', 'Spanish', 'Arabic', 'French', 'Japanese', 'Korean', 'Portuguese', 'German', 'Chinese', 'Russian'];
                                        if (textEditingValue.text.isEmpty) return options;
                                        return options.where((o) => o.toLowerCase().contains(textEditingValue.text.toLowerCase()));
                                      },
                                      onSelected: (value) {
                                        setState(() {
                                          _reelVoiceOverLanguage = value;
                                          _state = _state.copyWith(reelLanguage: value);
                                        });
                                        _saveState();
                                      },
                                      fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                                        if (controller.text.isEmpty && _reelVoiceOverLanguage.isNotEmpty) {
                                          controller.text = _reelVoiceOverLanguage;
                                        }
                                        return TextFormField(
                                          controller: controller,
                                          focusNode: focusNode,
                                          textAlignVertical: TextAlignVertical.center,
                                          style: const TextStyle(fontSize: 12),
                                          decoration: InputDecoration(
                                            isDense: true,
                                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade300)),
                                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.grey.shade200)),
                                            hintText: 'Lang',
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                                            filled: true,
                                            fillColor: tp.inputBg,
                                          ),
                                          onChanged: (v) {
                                            setState(() {
                                              _reelVoiceOverLanguage = v;
                                              _state = _state.copyWith(reelLanguage: v);
                                            });
                                            _debouncedSave();
                                          },
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ] else ...[
                                const Spacer(),
                              ],
                              
                              const SizedBox(width: 12),
                              SizedBox(
                                height: 24,
                                child: Transform.scale(
                                  scale: 0.8,
                                  child: Switch(
                                    value: _globalNarrationEnabled,
                                    activeColor: Colors.deepPurple,
                                    onChanged: (v) {
                                      setState(() => _globalNarrationEnabled = v);
                                      _saveState();
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        
                        const SizedBox(height: 24),
                        
                        // Generate Button Section
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: _isGeneratingReel ? null : _generateReel,
                                icon: _isGeneratingReel
                                   ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                   : const Icon(Icons.movie_creation, size: 20),
                                label: Text(_isGeneratingReel ? 'Generating...' : LocalizationService().tr('reel.generate_content'), 
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF673AB7),
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  padding: const EdgeInsets.symmetric(vertical: 18),
                                ),
                              ),
                            ),
                            if (_isGeneratingReel) ...[
                               const SizedBox(width: 10),
                               ElevatedButton.icon(
                                  onPressed: () {
                                     setState(() {
                                        _shouldStopReelGeneration = true;
                                        _isGeneratingReel = false;
                                     });
                                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stopping...')));
                                  },
                                  icon: const Icon(Icons.stop, size: 18),
                                  label: const Text('Stop', style: TextStyle(fontSize: 13)),
                                  style: ElevatedButton.styleFrom(
                                     backgroundColor: Colors.red,
                                     foregroundColor: Colors.white,
                                     padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                                  ),
                               ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
  }

  /// Build the reels list panel (right side on desktop, bottom on mobile)
  Widget _buildReelsListPanel(double padding, bool isMobile, bool isDesktop) {
    // Controls Panel
    final controlsPanel = _reelProjects.isEmpty
        ? const SizedBox.shrink()
        : Container(
            // width: 300, // Handled by parent in desktop layout
              decoration: BoxDecoration(
                color: ThemeProvider().surfaceBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ThemeProvider().borderColor),
                boxShadow: [
                  BoxShadow(
                    color: ThemeProvider().shadowColor,
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(16.0),
              child: DefaultTextStyle(
                style: GoogleFonts.outfit(color: ThemeProvider().textPrimary),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                     // Header
                     Column(
                       crossAxisAlignment: CrossAxisAlignment.start,
                       children: [
                         Row(
                           children: [
                             Icon(Icons.tune, size: 18, color: ThemeProvider().textPrimary),
                             const SizedBox(width: 8),
                             Text(LocalizationService().tr('reel.bulk_settings'),
                               style: GoogleFonts.outfit(
                                 fontSize: 16,
                                 fontWeight: FontWeight.w400,
                                 color: ThemeProvider().textPrimary,
                                 letterSpacing: -0.3,
                               ),
                             ),
                           ],
                         ),
                       ],
                     ),
                     const SizedBox(height: 8),
                     Row(
                       children: [
                        // Compact Browser status
                        if (widget.profileManager != null)
                          Tooltip(
                             message: widget.profileManager!.countConnectedProfiles() > 0
                               ? '${widget.profileManager!.countConnectedProfiles()} ${LocalizationService().tr('reel.browsers_connected')}'
                               : LocalizationService().tr('reel.no_browsers'),
                             child: InkWell(
                               onTap: _connectBrowsers,
                               borderRadius: BorderRadius.circular(4),
                               child: Padding(
                                 padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                 child: Row(
                                   mainAxisSize: MainAxisSize.min,
                                   children: [
                                     Icon(
                                       widget.profileManager!.countConnectedProfiles() > 0
                                           ? Icons.sensors
                                           : Icons.sensors_off,
                                       size: 13,
                                       color: widget.profileManager!.countConnectedProfiles() > 0
                                           ? Colors.green
                                           : Colors.orange,
                                     ),
                                     const SizedBox(width: 3),
                                     if (_isConnectingBrowsers)
                                       const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5))
                                     else
                                       Text(
                                         widget.profileManager!.countConnectedProfiles() > 0
                                              ? '${LocalizationService().tr('reel.connect_browser')} (${widget.profileManager!.countConnectedProfiles()})'
                                              : LocalizationService().tr('reel.connect_browser'),
                                         style: TextStyle(
                                           fontSize: 10,
                                           fontWeight: FontWeight.w500,
                                           color: widget.profileManager!.countConnectedProfiles() > 0
                                               ? Colors.green.shade700
                                               : Colors.orange.shade800,
                                         ),
                                       ),
                                   ],
                                 ),
                               ),
                             ),
                          ),
                        const Spacer(),
                         Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: ThemeProvider().isDarkMode ? ThemeProvider().inputBg : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('${_selectedReelsForBulkCreate.length}',
                            style: TextStyle(
                              color: Colors.grey.shade700,
                              fontSize: 11,
                              fontWeight: FontWeight.w500
                            )
                          ),
                        ),
                      ],
                    ),
                   const SizedBox(height: 16),
                   // Actions (Moved to Top)
                   Row(
                     children: [
                       Expanded(
                         child: InkWell(
                            onTap: () {
                             setState(() {
                               if (_selectedReelsForBulkCreate.length == _reelProjects.length) {
                                 _selectedReelsForBulkCreate.clear();
                               } else {
                                 _selectedReelsForBulkCreate = Set.from(
                                   List.generate(_reelProjects.length, (i) => i)
                                 );
                               }
                             });
                           },
                           borderRadius: BorderRadius.circular(4),
                           child: Padding(
                             padding: const EdgeInsets.symmetric(vertical: 8.0),
                             child: Row(
                               children: [
                                 Icon(_selectedReelsForBulkCreate.length == _reelProjects.length
                                     ? Icons.check_circle_outline
                                     : Icons.radio_button_unchecked,
                                     size: 16, color: Colors.grey.shade600
                                 ),
                                 const SizedBox(width: 8),
                                 Text(
                                   _selectedReelsForBulkCreate.length == _reelProjects.length
                                       ? LocalizationService().tr('reel.deselect_all')
                                       : LocalizationService().tr('reel.select_all'),
                                   style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                                 ),
                               ],
                             ),
                           ),
                         ),
                       ),
                       // High-visibility 10x Boost Toggle (Moved Here)
                       MouseRegion(
                         cursor: SystemMouseCursors.click,
                         child: GestureDetector(
                           onTap: () {
                             setState(() { _use10xBoostMode = !_use10xBoostMode; _saveState(); });
                           },
                           child: Row(
                             mainAxisSize: MainAxisSize.min,
                             children: [
                               Text(
                                 LocalizationService().tr('reel.boost_10x'),
                                 style: GoogleFonts.inter(
                                   fontSize: 11,
                                   fontWeight: FontWeight.w600,
                                   color: _use10xBoostMode ? Colors.deepOrange.shade600 : Colors.grey.shade600,
                                 ),
                               ),
                               const SizedBox(width: 6),
                               AnimatedContainer(
                                 duration: const Duration(milliseconds: 300),
                                 width: 34,
                                 height: 18,
                                 padding: const EdgeInsets.all(2),
                                 decoration: BoxDecoration(
                                   borderRadius: BorderRadius.circular(20),
                                   gradient: _use10xBoostMode
                                       ? LinearGradient(colors: [Colors.orange.shade400, Colors.deepOrange.shade600])
                                       : null,
                                   color: _use10xBoostMode ? null : Colors.grey.shade300,
                                 ),
                                 child: AnimatedAlign(
                                   duration: const Duration(milliseconds: 300),
                                   alignment: _use10xBoostMode ? Alignment.centerRight : Alignment.centerLeft,
                                   child: Container(
                                     width: 14,
                                     height: 14,
                                     decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                                     child: Center(
                                       child: Icon(
                                         _use10xBoostMode ? Icons.rocket_launch_rounded : Icons.circle_outlined,
                                         size: 8,
                                         color: _use10xBoostMode ? Colors.deepOrange.shade500 : Colors.grey.shade500,
                                       ),
                                     ),
                                   ),
                                 ),
                               ),
                             ],
                           ),
                         ),
                       ),
                     ],
                   ),
                   const SizedBox(height: 8),
                   Row(
                     children: [
                       Text(LocalizationService().tr('reel.video_model'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                       const SizedBox(width: 8),
                       Expanded(
                         child: Builder(
                           builder: (context) {
                             Map<String, String> itemsMap = AppConfig.flowModelOptions;
                             if (_reelAccountType == 'ai_pro') {
                               itemsMap = AppConfig.flowModelOptionsPro;
                             } else if (_reelAccountType == 'free') {
                               itemsMap = AppConfig.flowModelOptionsFree;
                             } else if (_reelAccountType == 'ai_ultra') {
                               itemsMap = AppConfig.flowModelOptionsUltra;
                             }
                             
                             if (!itemsMap.containsKey(_reelVideoModel)) {
                               _reelVideoModel = itemsMap.keys.first;
                             }
                   
                             return _buildMinimalDropdown<String>(
                               value: _reelVideoModel,
                               items: itemsMap.keys.map((name) => DropdownMenuItem(
                                 value: name, 
                                 child: Text(name, style: const TextStyle(fontSize: 11))
                               )).toList(),
                               onChanged: (v) {
                                 if (v != null) {
                                   setState(() {
                                     _reelVideoModel = v;
                                   });
                                   _saveState();
                                 }
                               },
                             );
                           }
                         ),
                       ),
                     ],
                   ),
                   const SizedBox(height: 8),
                   Row(
                     children: [
                       Text(LocalizationService().tr('reel.concurrent_label'), style: const TextStyle(fontSize: 11, color: Colors.grey)),
                       const SizedBox(width: 8),
                       Expanded(
                         child: _buildMinimalDropdown<int>(
                            value: _concurrentReelProcessing,
                            items: [1, 2, 3, 4].map((n) => DropdownMenuItem(value: n, child: Text('$n'))).toList(),
                            onChanged: (v) => setState(() => _concurrentReelProcessing = v ?? 2),
                         ),
                       ),
                     ],
                   ),
                   const SizedBox(height: 16),
                    SizedBox(
                       height: 42,
                       width: double.infinity,
                       child: ElevatedButton.icon(
                          onPressed: _selectedReelsForBulkCreate.isEmpty || _isBulkAutoCreating
                              ? null
                              : () => _startBulkAutoCreate(),
                          icon: _isBulkAutoCreating
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                              : const Icon(Icons.play_arrow_rounded, size: 20),
                          label: Text(_isBulkAutoCreating ? LocalizationService().tr('reel.running') : LocalizationService().tr('reel.run'),
                            style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1A73E8),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey.shade200,
                            disabledForegroundColor: Colors.grey.shade400,
                            elevation: 0,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                    ),
                    if (_isBulkAutoCreating) ...[
                       const SizedBox(height: 8),
                       TextButton.icon(
                         onPressed: _stopBulkAutoCreate,
                         icon: const Icon(Icons.stop_circle_outlined, color: Colors.red, size: 16),
                          label: Text(LocalizationService().tr('reel.stop_all'), style: GoogleFonts.inter(color: Colors.red, fontSize: 12)),
                        ),
                     ],
                     const SizedBox(height: 16),
                    const Divider(),
                    const SizedBox(height: 12),

                    // Group 1: Output
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(LocalizationService().tr('reel.output'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blueGrey, letterSpacing: 1.0)),
                       const SizedBox(height: 12),
                       Row(
                         children: [
                           Expanded(
                             child: _buildMinimalDropdown<String>(
                               value: _bulkExportMethod,
                               items: [
                                 DropdownMenuItem(value: 'precise', child: Text(LocalizationService().tr('reel.precise'))),
                                 DropdownMenuItem(value: 'fast', child: Text(LocalizationService().tr('reel.fast'))),
                               ],
                               onChanged: (v) => setState(() => _bulkExportMethod = v ?? 'precise'),
                             ),
                           ),
                           const SizedBox(width: 8),
                           Expanded(
                             child: _buildMinimalDropdown<String>(
                               value: _bulkExportResolution,
                               items: [
                                 DropdownMenuItem(value: 'original', child: Text(LocalizationService().tr('reel.original'))),
                                 DropdownMenuItem(value: '1080p', child: Text('1080p')),
                                 DropdownMenuItem(value: '2k', child: Text('2K')),
                                 DropdownMenuItem(value: '4k', child: Text('4K')),
                               ],
                               onChanged: (v) => setState(() => _bulkExportResolution = v ?? 'original'),
                             ),
                           ),
                         ],
                       ),
                       const SizedBox(height: 12),
                        Row(
                         children: [
                           SizedBox(
                             height: 24,
                             child: Transform.scale(
                               scale: 0.8,
                               child: Switch(
                                 value: _bulkAutoExport,
                                 onChanged: (v) { setState(() => _bulkAutoExport = v); _saveState(); },
                                 materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                               ),
                             ),
                           ),
                           const SizedBox(width: 8),
                           Text(LocalizationService().tr('reel.auto_export'), style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),

                         ],
                       ),
                     ],
                   ),
                   const SizedBox(height: 20),
                   
                    // Group 2: Audio
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(LocalizationService().tr('reel.audio_label'), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blueGrey, letterSpacing: 1.0)),
                       const SizedBox(height: 12),
                       Row(
                         children: [
                           Expanded(
                             flex: 2,
                             child: _buildMinimalDropdown<String>(
                               value: _bulkVoiceName,
                               items: const [
                                 DropdownMenuItem(value: 'Zephyr', child: Text('Zephyr')),
                                 DropdownMenuItem(value: 'Puck', child: Text('Puck')),
                                 DropdownMenuItem(value: 'Charon', child: Text('Charon')),
                                 DropdownMenuItem(value: 'Kore', child: Text('Kore')),
                                 DropdownMenuItem(value: 'Fenrir', child: Text('Fenrir')),
                                 DropdownMenuItem(value: 'Aoede', child: Text('Aoede')),
                                 DropdownMenuItem(value: 'Leda', child: Text('Leda')),
                                 DropdownMenuItem(value: 'Orus', child: Text('Orus')),
                                 DropdownMenuItem(value: 'Elara', child: Text('Elara')),
                                 DropdownMenuItem(value: 'Callirrhoe', child: Text('Callirrhoe')),
                                 DropdownMenuItem(value: 'Autonoe', child: Text('Autonoe')),
                                 DropdownMenuItem(value: 'Enceladus', child: Text('Enceladus')),
                                 DropdownMenuItem(value: 'Iapetus', child: Text('Iapetus')),
                                 DropdownMenuItem(value: 'Umbriel', child: Text('Umbriel')),
                                 DropdownMenuItem(value: 'Aletheia', child: Text('Aletheia')),
                                 DropdownMenuItem(value: 'Narvi', child: Text('Narvi')),
                                 DropdownMenuItem(value: 'Perseus', child: Text('Perseus')),
                                 DropdownMenuItem(value: 'Helios', child: Text('Helios')),
                                 DropdownMenuItem(value: 'Hermes', child: Text('Hermes')),
                                 DropdownMenuItem(value: 'Apollo', child: Text('Apollo')),
                                 DropdownMenuItem(value: 'Athena', child: Text('Athena')),
                                 DropdownMenuItem(value: 'Artemis', child: Text('Artemis')),
                                 DropdownMenuItem(value: 'Clio', child: Text('Clio')),
                                 DropdownMenuItem(value: 'Demeter', child: Text('Demeter')),
                                 DropdownMenuItem(value: 'Echo', child: Text('Echo')),
                                 DropdownMenuItem(value: 'Iris', child: Text('Iris')),
                                 DropdownMenuItem(value: 'Morpheus', child: Text('Morpheus')),
                                 DropdownMenuItem(value: 'Nyx', child: Text('Nyx')),
                                 DropdownMenuItem(value: 'Selene', child: Text('Selene')),
                                 DropdownMenuItem(value: 'Thalia', child: Text('Thalia')),
                               ],
                               onChanged: (v) => setState(() => _bulkVoiceName = v ?? 'Zephyr'),
                             ),
                           ),
                           const SizedBox(width: 8),
                            Expanded(
                             child: _buildMinimalDropdown<double>(
                               value: _exportPlaybackSpeed,
                               items: const [
                                 DropdownMenuItem(value: 1.0, child: Text('1.0x')),
                                 DropdownMenuItem(value: 1.1, child: Text('1.1x')),
                                 DropdownMenuItem(value: 1.2, child: Text('1.2x')),
                                 DropdownMenuItem(value: 1.3, child: Text('1.3x')),
                                 DropdownMenuItem(value: 1.5, child: Text('1.5x')),
                               ],
                               onChanged: (v) => setState(() => _exportPlaybackSpeed = v ?? 1.2),
                             ),
                           ),
                         ],
                       ),
                       const SizedBox(height: 12),
                       // Volume Sliders Stacked
                       Row(
                         children: [
                           Text(LocalizationService().tr('reel.voice_vol'), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                           const SizedBox(width: 8),
                           Expanded(
                             child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                                  activeTrackColor: Colors.black54,
                                  inactiveTrackColor: Colors.grey.shade200,
                                  thumbColor: Colors.black,
                                ),
                                child: Slider(
                                  value: _exportTtsVolume,
                                  min: 0.0, max: 5.0, divisions: 50,
                                  onChanged: (v) => setState(() => _exportTtsVolume = v),
                                ),
                              ),
                           ),
                           Text('${(_exportTtsVolume * 100).toInt()}%', style: const TextStyle(fontSize: 10)),
                         ],
                       ),
                        Row(
                         children: [
                           Text(LocalizationService().tr('reel.video_vol'), style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                           const SizedBox(width: 8),
                           Expanded(
                             child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 2,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                                  activeTrackColor: Colors.black54,
                                  inactiveTrackColor: Colors.grey.shade200,
                                  thumbColor: Colors.black,
                                ),
                                child: Slider(
                                  value: _exportVideoVolume,
                                  min: 0.0, max: 5.0, divisions: 50,
                                  onChanged: (v) => setState(() => _exportVideoVolume = v),
                                ),
                              ),
                           ),
                           Text('${(_exportVideoVolume * 100).toInt()}%', style: const TextStyle(fontSize: 10)),
                         ],
                       ),
                     ],
                   ),
                   const SizedBox(height: 20),
                   
                    // Group 3: Tone & Style
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(LocalizationService().tr('reel.tone_style'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.blueGrey, letterSpacing: 1.0)),
                       const SizedBox(height: 8),
                       TextField(
                         controller: _globalAudioStyleController,
                         maxLines: 2,
                         decoration: InputDecoration(
                           hintText: LocalizationService().tr('reel.optional_instructions'),
                           hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                           border: OutlineInputBorder(
                             borderRadius: BorderRadius.circular(8),
                             borderSide: BorderSide(color: Colors.grey.shade300),
                           ),
                           enabledBorder: OutlineInputBorder(
                             borderRadius: BorderRadius.circular(8),
                             borderSide: BorderSide(color: Colors.grey.shade300),
                           ),
                           focusedBorder: OutlineInputBorder(
                             borderRadius: BorderRadius.circular(8),
                             borderSide: const BorderSide(color: Colors.blue, width: 1.5),
                           ),
                           isDense: true,
                           contentPadding: const EdgeInsets.all(12),
                           suffixIcon: _globalAudioStyleInstruction.isNotEmpty
                               ? IconButton(
                                   icon: const Icon(Icons.clear, size: 14),
                                   onPressed: () {
                                     _globalAudioStyleController.clear();
                                      setState(() => _globalAudioStyleInstruction = '');
                                    },
                                  )
                                : null,
                          ),
                          onChanged: (v) => setState(() => _globalAudioStyleInstruction = v),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          );

    // Projects List Panel
    final listPanel = _reelProjects.isNotEmpty 
             ? Container(
                 decoration: BoxDecoration(
                   color: ThemeProvider().surfaceBg,
                   borderRadius: BorderRadius.circular(12),
                   border: Border.all(color: ThemeProvider().borderColor),
                   boxShadow: [
                     BoxShadow(
                       color: ThemeProvider().shadowColor,
                       blurRadius: 10,
                       offset: const Offset(0, 4),
                     ),
                   ],
                 ),
                 child: Column(
                  children: _reelProjects.asMap().entries.map((entry) {
                     final index = entry.key;
                     final project = entry.value;
                     final projectId = project['id'];
                     return Column(
                       children: [
                        const SizedBox(height: 0),
                        ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          initiallyExpanded: false, // Don't auto-expand
                          title: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                margin: const EdgeInsets.only(right: 12),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [Colors.blue.shade400, Colors.blue.shade700],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.blue.withOpacity(0.3),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    fontSize: 16, 
                                    fontWeight: FontWeight.w900, 
                                    color: Colors.white,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  project['name'] ?? 'Untitled Reel',
                                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: ThemeProvider().textPrimary),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 2,
                                ),
                              ),
                              // Play button - shows when exported
                              if (project['exportedVideoPath'] != null && 
                                  File(project['exportedVideoPath']).existsSync())
                                Container(
                                  margin: const EdgeInsets.only(right: 4),
                                  decoration: const BoxDecoration(
                                    shape: BoxShape.circle,
                                  ),
                                  child: Material(
                                    color: Colors.blue,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      onTap: () {
                                        VideoPlayerDialog.show(
                                          context,
                                          project['exportedVideoPath'],
                                          title: project['name'] ?? 'Reel Video',
                                        );
                                      },
                                      customBorder: const CircleBorder(),
                                      child: const Padding(
                                        padding: EdgeInsets.all(6),
                                        child: Icon(
                                          Icons.play_arrow,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              // Show in folder button - shows when exported
                              if (project['exportedVideoPath'] != null && 
                                  File(project['exportedVideoPath']).existsSync())
                                IconButton(
                                  icon: const Icon(Icons.folder_open, color: Colors.green, size: 20),
                                  tooltip: 'Show in Folder',
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () async {
                                    final path = project['exportedVideoPath'] as String;
                                    if (Platform.isWindows) {
                                      await Process.run('explorer', ['/select,', path]);
                                    } else if (Platform.isMacOS) {
                                      await Process.run('open', ['-R', path]);
                                    } else if (Platform.isLinux) {
                                      await Process.run('xdg-open', [File(path).parent.path]);
                                    }
                                  },
                                ),
                              const SizedBox(width: 4),
                              // Video count indicator (right side, bold and big)
                              Builder(
                                builder: (context) {
                                  final content = project['content'] as List?;
                                  if (content == null) return const SizedBox.shrink();
                                  
                                  int totalVideos = 0;
                                  int completedVideos = 0;
                                  
                                  for (var part in content) {
                                    final visuals = part['visuals'] as List?;
                                    if (visuals != null) {
                                      for (var visual in visuals) {
                                        if (visual['active'] != false) {
                                          totalVideos++;
                                          if (visual['video_path'] != null) {
                                            completedVideos++;
                                          }
                                        }
                                      }
                                    }
                                  }
                                  
                                  final isDark = ThemeProvider().isDarkMode;
                                  final color = completedVideos == totalVideos 
                                      ? Colors.green 
                                      : completedVideos == 0 
                                          ? Colors.red 
                                          : Colors.orange;
                                   
                                   return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [color.withOpacity(isDark ? 0.08 : 0.15), color.withOpacity(isDark ? 0.03 : 0.05)],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: color.withOpacity(isDark ? 0.4 : 1.0), width: 2),
                                      boxShadow: [
                                        BoxShadow(
                                          color: color.withOpacity(isDark ? 0.1 : 0.2),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      '$completedVideos/$totalVideos',
                                      style: TextStyle(
                                        fontSize: 15, 
                                        color: isDark ? color.shade200 : color.shade900, 
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: Icon(Icons.delete, color: ThemeProvider().isDarkMode ? Colors.red.shade300 : Colors.red, size: 20),
                                onPressed: () => _deleteReel(index),
                                tooltip: 'Delete Reel',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(width: 4),
                              Checkbox(
                                 value: _selectedReelsForBulkCreate.contains(index),
                                 materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                 visualDensity: VisualDensity.compact,
                                 activeColor: Colors.blue.shade700,
                                 onChanged: (checked) {
                                   setState(() {
                                     if (checked == true) {
                                       _selectedReelsForBulkCreate.add(index);
                                     } else {
                                       _selectedReelsForBulkCreate.remove(index);
                                     }
                                   });
                                 },
                              ),
                            ],
                          ),
                         subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                                 Row(
                                   children: [
                                     Text(
                                       'Status: ${project['status']}', 
                                       style: TextStyle(
                                         fontSize: isMobile ? 11 : 13, 
                                         fontWeight: (project['status'] == 'finalizing' || project['status'] == 'exporting') ? FontWeight.bold : FontWeight.normal, 
                                         color: (project['status'] == 'finalizing' || project['status'] == 'exporting') ? Colors.blue : ThemeProvider().textSecondary
                                       ),
                                     ),
                                     if (project['status'] == 'finalizing' || project['status'] == 'exporting')
                                       const Padding(
                                         padding: EdgeInsets.only(left: 6),
                                         child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue)),
                                       ),
                                     const SizedBox(width: 8),
                                     // Compact Model Indicator
                                     Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                           color: _reelAccountType == 'ai_ultra' 
                                               ? (ThemeProvider().isDarkMode ? Colors.purple.withOpacity(0.12) : Colors.purple.shade50) 
                                               : _reelAccountType == 'ai_pro'
                                                   ? (ThemeProvider().isDarkMode ? Colors.blue.withOpacity(0.12) : Colors.blue.shade50)
                                                   : (ThemeProvider().isDarkMode ? Colors.green.withOpacity(0.12) : Colors.green.shade50),
                                           borderRadius: BorderRadius.circular(4),
                                           border: Border.all(color: ThemeProvider().isDarkMode ? Colors.grey.shade700 : Colors.grey.shade300),
                                        ),
                                        child: Row(
                                           mainAxisSize: MainAxisSize.min,
                                           children: [
                                              Icon(
                                                 _reelAccountType == 'ai_ultra' ? Icons.star : _reelAccountType == 'ai_pro' ? Icons.workspace_premium : Icons.auto_awesome,
                                                 size: 10,
                                                 color: _reelAccountType == 'ai_ultra' ? Colors.purple : _reelAccountType == 'ai_pro' ? Colors.blue : Colors.green,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                 _reelVideoModel ?? 'Veo',
                                                 style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: ThemeProvider().isDarkMode ? Colors.grey.shade300 : Colors.grey.shade800),
                                              ),
                                           ],
                                        ),
                                     ),
                                     const Spacer(),
                                     ElevatedButton.icon(
                                       onPressed: _isRegeneratingMissing ? null : () => _regenerateFailedVideos(index),
                                       icon: _isRegeneratingMissing 
                                           ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                           : Icon(Icons.refresh, size: isMobile ? 14 : 16),
                                       label: Text(_isRegeneratingMissing ? 'Regen...' : 'Regen Missing', style: TextStyle(fontSize: isMobile ? 10 : 11)),
                                       style: ElevatedButton.styleFrom(
                                         backgroundColor: _isRegeneratingMissing ? (ThemeProvider().isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200) : (ThemeProvider().isDarkMode ? Colors.orange.withOpacity(0.15) : Colors.orange.shade100),
                                         foregroundColor: _isRegeneratingMissing ? Colors.grey : (ThemeProvider().isDarkMode ? Colors.orange.shade200 : Colors.orange.shade900),
                                         padding: EdgeInsets.symmetric(horizontal: isMobile ? 6 : 8, vertical: isMobile ? 4 : 6),
                                         minimumSize: const Size(0, 28),
                                         visualDensity: VisualDensity.compact,
                                       ),
                                     ),
                                   ],
                                 ),
                               // Export Progress Bar (when exporting)
                               if (_isReelExporting && _reelExportingIndex == index) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                     decoration: BoxDecoration(
                                        color: Colors.green.shade50,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.green.shade200),
                                     ),
                                     child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                           Row(
                                              children: [
                                                 const SizedBox(
                                                    width: 16, height: 16,
                                                    child: CircularProgressIndicator(strokeWidth: 2),
                                                 ),
                                                 const SizedBox(width: 8),
                                                 Text(LocalizationService().tr('reel.exporting'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                 const Spacer(),
                                                 Text('${(_reelExportProgress * 100).toInt()}%', 
                                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                              ],
                                           ),
                                           const SizedBox(height: 6),
                                           ClipRRect(
                                              borderRadius: BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                 value: _reelExportProgress,
                                                 backgroundColor: Colors.grey.shade200,
                                                 valueColor: AlwaysStoppedAnimation<Color>(Colors.green.shade600),
                                                 minHeight: 8,
                                              ),
                                           ),
                                           const SizedBox(height: 4),
                                           Text(
                                              _reelExportStep,
                                              style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                           ),
                                        ],
                                     ),
                                  ),
                               ],
                               const SizedBox(height: 8),
                               // Live Progress Indicator (when generating)
                               if (project['status'] == 'video_generating') Builder(
                                 builder: (context) {
                                   final content = project['content'] as List?;
                                   if (content == null) return const SizedBox.shrink();
                                   
                                   int queued = 0, generating = 0, polling = 0, downloading = 0, completed = 0, failed = 0;
                                   for (var part in content) {
                                     final visuals = part['visuals'] as List?;
                                     if (visuals != null) {
                                       for (var v in visuals) {
                                         if (v['active'] != false) {
                                           final status = v['gen_status'] ?? (v['video_path'] != null ? 'completed' : 'queued');
                                           if (status == 'completed' || v['video_path'] != null) completed++;
                                           else if (status == 'generating') generating++;
                                           else if (status == 'polling') polling++;
                                           else if (status == 'downloading') downloading++;
                                           else if (status == 'failed') failed++;
                                           else queued++;
                                         }
                                       }
                                     }
                                   }
                                   final total = queued + generating + polling + downloading + completed + failed;
                                   final progress = total > 0 ? completed / total : 0.0;
                                   
                                   return Column(
                                     crossAxisAlignment: CrossAxisAlignment.start,
                                     children: [
                                       Row(
                                         children: [
                                           Expanded(
                                             child: ClipRRect(
                                               borderRadius: BorderRadius.circular(4),
                                               child: LinearProgressIndicator(
                                                 value: progress,
                                                 backgroundColor: Colors.grey.shade200,
                                                 valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
                                                 minHeight: 8,
                                               ),
                                             ),
                                           ),
                                           const SizedBox(width: 8),
                                           Text('${(progress * 100).toInt()}%', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                         ],
                                       ),
                                       const SizedBox(height: 4),
                                       Wrap(
                                         spacing: 8,
                                         children: [
                                           if (generating > 0) _buildStatusChip('Gen: $generating', Colors.blue),
                                           if (polling > 0) _buildStatusChip('Poll: $polling', Colors.cyan),
                                           if (downloading > 0) _buildStatusChip('DL: $downloading', Colors.teal),
                                           if (completed > 0) _buildStatusChip('Done: $completed', Colors.green),
                                           if (failed > 0) _buildStatusChip('Fail: $failed', Colors.red),
                                           if (queued > 0) _buildStatusChip('Queue: $queued', Colors.grey),
                                         ],
                                       ),
                                       const SizedBox(height: 8),
                                     ],
                                   );
                                 },
                               ),
                                // Compact Controls Row (Aspect Ratio + Voice)
                                Row(
                                  children: [
                                    // Aspect Ratio
                                    Expanded(
                                      flex: 4,
                                      child: DropdownButtonFormField<String>(
                                          value: project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT',
                                          decoration: const InputDecoration(
                                             labelText: 'Aspect Ratio',
                                             isDense: true,
                                             border: OutlineInputBorder(),
                                             contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                          ),
                                          items: [
                                              DropdownMenuItem(value: 'VIDEO_ASPECT_RATIO_PORTRAIT', child: Text('9:16', style: TextStyle(fontSize: isMobile ? 11 : 12))),
                                             DropdownMenuItem(value: 'VIDEO_ASPECT_RATIO_LANDSCAPE', child: Text('16:9', style: TextStyle(fontSize: isMobile ? 11 : 12))),
                                          ],
                                          onChanged: (val) {
                                             if (val != null) {
                                                setState(() {
                                                   project['aspect_ratio'] = val;
                                                   _state = _state.copyWith(reelProjects: _reelProjects);
                                                });
                                                _saveState();
                                             }
                                          },
                                       ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Voice Model
                                    Expanded(
                                       flex: 3,
                                       child: Builder(
                                         builder: (context) {
                                           final allVoices = ['Zephyr', 'Puck', 'Kore', 'Fenrir', 'Lambo', 'Aoede', 'Charon', 'Maia', 'Orpheus', 'Leda', 'Orus', 'Elara', 'Callirrhoe', 'Autonoe', 'Enceladus', 'Iapetus', 'Umbriel', 'Aletheia', 'Narvi', 'Perseus', 'Helios', 'Hermes', 'Apollo', 'Athena', 'Artemis', 'Clio', 'Demeter', 'Echo', 'Iris', 'Morpheus', 'Nyx', 'Selene', 'Thalia'];
                                           final currentVoice = project['voice_model'] ?? 'Zephyr';
                                           // Ensure the current value exists in the list
                                           final effectiveVoice = allVoices.contains(currentVoice) ? currentVoice : 'Zephyr';
                                           if (effectiveVoice != currentVoice) {
                                             project['voice_model'] = effectiveVoice;
                                           }
                                           return DropdownButtonFormField<String>(
                                           value: effectiveVoice,
                                           decoration: const InputDecoration(
                                              labelText: 'Voice',
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                           ),
                                           items: allVoices
                                              .map((v) => DropdownMenuItem(value: v, child: Text(v, style: const TextStyle(fontSize: 12))))
                                              .toList(),
                                          onChanged: (val) {
                                             if (val != null) {
                                                setState(() {
                                                   project['voice_model'] = val;
                                                   _state = _state.copyWith(reelProjects: _reelProjects);
                                                });
                                                _debouncedSave();
                                             }
                                          },
                                       );
                                         },
                                       ),
                                    ),
                                  ],
                                ),
                               const SizedBox(height: 8),
                               // Voice Style
                               TextFormField(
                                  initialValue: project['voice_style'] ?? 'friendly and engaging',
                                  decoration: InputDecoration(
                                     labelText: project['voice_style_auto'] == true ? 'Voice Style (AI Generated)' : 'Voice Style',
                                     isDense: true,
                                     border: const OutlineInputBorder(),
                                     contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                     suffixIcon: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                           // Regenerate with AI
                                           IconButton(
                                              icon: const Icon(Icons.auto_awesome, size: 18),
                                              tooltip: 'Regenerate with AI',
                                              onPressed: () async {
                                                 final content = project['content'] as List;
                                                 final storyTexts = content.map((c) => c['text']?.toString() ?? '').toList();
                                                 final newStyle = await _alignmentService.generateVoiceStyle(
                                                    storyTitle: project['name'] ?? 'Story',
                                                    storyTexts: storyTexts,
                                                    language: _reelVoiceOverLanguage.isNotEmpty ? _reelVoiceOverLanguage : 'English',
                                                 );
                                                 setState(() {
                                                    project['voice_style'] = newStyle;
                                                    project['voice_style_auto'] = true;
                                                 });
                                                 _saveState();
                                              },
                                           ),
                                           // Preset dropdown
                                           PopupMenuButton<String>(
                                              icon: const Icon(Icons.list, size: 18),
                                              tooltip: 'Use Preset',
                                              itemBuilder: (ctx) => [
                                                 const PopupMenuItem(value: 'Friendly and engaging storytelling', child: Text('Friendly')),
                                                 const PopupMenuItem(value: 'Dramatic, movie-trailer style with powerful pauses', child: Text('Dramatic')),
                                                 const PopupMenuItem(value: 'Warm, gentle narration like a bedtime story', child: Text('Bedtime')),
                                                 const PopupMenuItem(value: 'Excited, fast-paced with childlike enthusiasm', child: Text('Excited')),
                                                 const PopupMenuItem(value: 'Calm and soothing with clear articulation', child: Text('Calm')),
                                              ],
                                              onSelected: (val) {
                                                 setState(() {
                                                    project['voice_style'] = val;
                                                    project['voice_style_auto'] = false;
                                                 });
                                                 _saveState();
                                              },
                                           ),
                                        ],
                                      ),
                                   ),
                                  style: const TextStyle(fontSize: 12),
                                  onChanged: (val) {
                                     project['voice_style'] = val;
                                     project['voice_style_auto'] = false;
                                     _debouncedSave();
                                  },
                               ),
                               const SizedBox(height: 8),
                               // Controls
                               Wrap(
                                 spacing: 8,
                                 children: [
                                     if (project['status'] != 'video_generating')
                                        ElevatedButton.icon(
                                           icon: Icon(Icons.play_arrow, size: isMobile ? 14 : 16),
                                            label: Text(LocalizationService().tr('reels.resume'), style: TextStyle(fontSize: isMobile ? 10 : 12)),
                                           onPressed: () => _generateReelVideo(index), 
                                           style: ElevatedButton.styleFrom(
                                              backgroundColor: ThemeProvider().isDarkMode ? Colors.green.withOpacity(0.15) : Colors.green.shade100,
                                              foregroundColor: ThemeProvider().isDarkMode ? Colors.green.shade200 : Colors.green.shade900,
                                              
                                            ),
                                        ),
                                     
                                     if (project['status'] == 'video_generating')
                                        ElevatedButton.icon(
                                           icon: Icon(Icons.pause, size: isMobile ? 14 : 16),
                                            label: Text('Pause', style: TextStyle(fontSize: isMobile ? 10 : 12)),
                                           onPressed: () => _cancelReelTask(index), 
                                           style: ElevatedButton.styleFrom(
                                              backgroundColor: ThemeProvider().isDarkMode ? Colors.orange.withOpacity(0.15) : Colors.orange.shade100,
                                              foregroundColor: ThemeProvider().isDarkMode ? Colors.orange.shade200 : Colors.orange.shade900,
                                              
                                            ),
                                        ),
                                        
                                     ElevatedButton.icon(
                                           icon: Icon(Icons.refresh, size: isMobile ? 14 : 16),
                                            label: Text(LocalizationService().tr('reels.restart'), style: TextStyle(fontSize: isMobile ? 10 : 12)),
                                           onPressed: () {
                                              // Confirm restart
                                              showDialog(context: context, builder: (c) => AlertDialog(
                                                 title: const Text('Restart Video Generation?'),
                                                 content: const Text('This will clear all existing videos for this reel and start over. Are you sure?'),
                                                 actions: [
                                                    TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
                                                    TextButton(onPressed: () {
                                                       Navigator.pop(c);
                                                       _restartReelVideo(index);
                                                    }, child: const Text('Restart', style: TextStyle(color: Colors.red))),
                                                 ],
                                              ));
                                           }, 
                                           style: ElevatedButton.styleFrom(
                                              backgroundColor: ThemeProvider().isDarkMode ? Colors.red.withOpacity(0.15) : Colors.red.shade100,
                                              foregroundColor: ThemeProvider().isDarkMode ? Colors.red.shade200 : Colors.red.shade900,
                                              
                                            ),
                                     ),
                                     
                                     // Auto Create (Magic) Button
                                     if (_autoProcessMap[projectId] != true)
                                         ElevatedButton.icon(
                                           icon: Icon(Icons.auto_awesome, size: isMobile ? 14 : 16),
                                            label: Text(LocalizationService().tr('reels.auto_create'), style: TextStyle(fontSize: isMobile ? 10 : 12)),
                                           onPressed: () => _processReelFull(index),
                                           style: ElevatedButton.styleFrom(
                                              backgroundColor: ThemeProvider().isDarkMode ? Colors.purple.withOpacity(0.15) : Colors.purple.shade100,
                                              foregroundColor: ThemeProvider().isDarkMode ? Colors.purple.shade200 : Colors.purple.shade900,
                                              
                                            ),
                                         )
                                     else
                                         ElevatedButton.icon(
                                           icon: Icon(Icons.stop_circle, size: isMobile ? 14 : 16),
                                            label: Text(LocalizationService().tr('reels.stop_auto'), style: TextStyle(fontSize: isMobile ? 10 : 12)),
                                           onPressed: () => _stopReelProcess(index),
                                           style: ElevatedButton.styleFrom(
                                              backgroundColor: ThemeProvider().isDarkMode ? Colors.red.shade800 : Colors.red,
                                              foregroundColor: ThemeProvider().isDarkMode ? Colors.red.shade100 : Colors.white,
                                              
                                            ),
                                         ),
                                 ],
                               )
                            ],
                         ),
                         children: [
                            Padding( // Content - Split Layout
                                      padding: const EdgeInsets.all(12),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final isWide = constraints.maxWidth > 500;
                                          
                                          // Left side: Controls
                                          final controlsWidget = Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: ThemeProvider().surfaceBg,
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: ThemeProvider().borderColor),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.stretch,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(LocalizationService().tr('reel.quick_actions'), 
                                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                                                const SizedBox(height: 12),
                                                _buildMinimalActionButton(
                                                  onPressed: () => _generateReelAudio(index),
                                                  icon: Icons.record_voice_over,
                                                  label: LocalizationService().tr('reel.gen_audio'),
                                                ),
                                                const SizedBox(height: 8),
                                                _buildMinimalActionButton(
                                                  onPressed: () => _generateReelVideo(index), 
                                                  icon: Icons.video_library,
                                                  label: LocalizationService().tr('reel.gen_video'),
                                                ),
                                                const SizedBox(height: 12),
                                                ElevatedButton.icon(
                                                  onPressed: () => _showExportDialog(index),
                                                  icon: const Icon(Icons.download, size: 16),
                                                  label: Text(LocalizationService().tr('btn.export'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: Colors.green.shade600,
                                                    foregroundColor: Colors.white,
                                                    elevation: 0,
                                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          );
                                          
                                          // Right side: Prompts list
                                          final promptsWidget = Container(
                                            height: 450,
                                            decoration: BoxDecoration(
                                              color: ThemeProvider().surfaceBg,
                                              borderRadius: BorderRadius.circular(12),
                                              border: Border.all(color: ThemeProvider().borderColor),
                                            ),
                                            child: Column(
                                              children: [
                                                // Header
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                                  child: Row(
                                                    children: [
                                                      const Icon(Icons.list_alt, size: 16),
                                                      const SizedBox(width: 6),
                                                      Expanded(child: Text(LocalizationService().tr('reel.scene_prompts'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
                                                      TextButton.icon(
                                                        onPressed: () => _toggleMuteAll(index, true),
                                                        icon: const Icon(Icons.volume_off, size: 12),
                                                        label: Text(LocalizationService().tr('reel.mute_all'), style: const TextStyle(fontSize: 9)),
                                                        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(50, 24)),
                                                      ),
                                                      TextButton.icon(
                                                        onPressed: () => _toggleMuteAll(index, false),
                                                        icon: const Icon(Icons.volume_up, size: 12),
                                                        label: Text(LocalizationService().tr('reel.unmute'), style: const TextStyle(fontSize: 9)),
                                                        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(50, 24)),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const Divider(height: 1),
                                                Expanded(
                                                  child: ListView.builder(
                                                    physics: const ClampingScrollPhysics(),
                                                    itemCount: (project['content'] as List).length,
                                                    itemBuilder: (ctx, partIdx) {
                                                       final part = (project['content'] as List)[partIdx];
                                                       final hasAudio = part['audio_path'] != null;
                                                       final visuals = part['visuals'] as List?;
                                                       
                                                       return Column(
                                                          children: [
                                                             // Audio Part Header
                                                             Container(
                                                                color: ThemeProvider().isDarkMode ? ThemeProvider().headerBg : Colors.grey.shade200,
                                                                padding: const EdgeInsets.all(8),
                                                                child: Column(
                                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                                  children: [
                                                                     Row(children: [
                                                                        Text('${LocalizationService().tr('reel.audio_part')} ${partIdx + 1}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                                                        const Spacer(),
                                                                        // TTS Mute Toggle
                                                                        IconButton(
                                                                           icon: Icon(
                                                                              (part['tts_muted'] == true) ? Icons.mic_off : Icons.mic,
                                                                              color: (part['tts_muted'] == true) ? Colors.red : Colors.green,
                                                                              size: 18,
                                                                           ),
                                                                           tooltip: (part['tts_muted'] == true) ? LocalizationService().tr('reel.unmute_tts') : LocalizationService().tr('reel.mute_tts'),
                                                                           onPressed: () {
                                                                              setState(() {
                                                                                 part['tts_muted'] = !(part['tts_muted'] == true);
                                                                                 _state = _state.copyWith(reelProjects: _reelProjects);
                                                                              });
                                                                              _saveState();
                                                                           },
                                                                           constraints: const BoxConstraints(),
                                                                           padding: const EdgeInsets.only(right: 8),
                                                                        ),
                                                                        if (hasAudio) IconButton(
                                                                           icon: const Icon(Icons.play_circle, color: Colors.blue),
                                                                           onPressed: () => _playReelAudio(part['audio_path']),
                                                                           constraints: const BoxConstraints(),
                                                                           padding: EdgeInsets.zero,
                                                                        ),
                                                                     ]),
                                                                     TextFormField(
                                                                        initialValue: part['text'] ?? '',
                                                                        maxLines: null,
                                                                        style: const TextStyle(fontSize: 13),
                                                                        decoration: InputDecoration(
                                                                           isDense: true,
                                                                           border: InputBorder.none,
                                                                           contentPadding: const EdgeInsets.symmetric(vertical: 4),
                                                                           hintText: LocalizationService().tr('reel.enter_script'),
                                                                        ),
                                                                        onChanged: (val) {
                                                                           part['text'] = val;
                                                                           _debouncedSave();
                                                                        },
                                                                     ),
                                                                  ],
                                                                ),
                                                             ),
                                                             // Visuals List
                                                             if (visuals != null)
                                                                ...visuals.asMap().entries.map((entry) {
                                                                   final vIdx = entry.key;
                                                                   final visual = entry.value;
                                                                   final hasVideo = visual['video_path'] != null;
                                                                   final isMuted = visual['is_muted'] ?? false;
                                                                   
                                                                   return Container(
                                                                      padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4, right: 8),
                                                                      decoration: BoxDecoration(
                                                                          border: Border(bottom: BorderSide(color: Colors.grey.shade100))
                                                                      ),
                                                                      child: Row(
                                                                         crossAxisAlignment: CrossAxisAlignment.start,
                                                                         children: [
                                                                           Checkbox(
                                                                             value: visual['active'] ?? true, 
                                                                             onChanged: (val) {
                                                                                setState(() {
                                                                                   visual['active'] = val;
                                                                                });
                                                                                _saveState();
                                                                             },
                                                                             materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                                           ),
                                                                           Expanded(
                                                                             child: Column(
                                                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                                                children: [
                                                                                   Row(children: [
                                                                                      Text('Visual ${partIdx + 1}.${vIdx + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey)),
                                                                                      if (hasVideo) ...[
                                                                                         const SizedBox(width: 4),
                                                                                         const Icon(Icons.videocam, size: 12, color: Colors.green),
                                                                                      ],
                                                                                       // Live generation status badge
                                                                                       if (visual['gen_status'] != null && visual['gen_status'] != 'completed' && !hasVideo) ...[
                                                                                          const SizedBox(width: 4),
                                                                                          Container(
                                                                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                                                            decoration: BoxDecoration(
                                                                                              color: visual['gen_status'] == 'generating' 
                                                                                                ? Colors.blue.shade100 
                                                                                                : visual['gen_status'] == 'polling' 
                                                                                                  ? Colors.cyan.shade100 
                                                                                                  : visual['gen_status'] == 'downloading'
                                                                                                    ? Colors.green.shade100
                                                                                                    : visual['gen_status'] == 'failed'
                                                                                                      ? Colors.red.shade100
                                                                                                      : Colors.grey.shade100,
                                                                                              borderRadius: BorderRadius.circular(3),
                                                                                            ),
                                                                                            child: Row(
                                                                                              mainAxisSize: MainAxisSize.min,
                                                                                              children: [
                                                                                                if (visual['gen_status'] == 'generating' || visual['gen_status'] == 'polling' || visual['gen_status'] == 'downloading')
                                                                                                  const SizedBox(
                                                                                                    width: 8, height: 8,
                                                                                                    child: CircularProgressIndicator(strokeWidth: 1.5),
                                                                                                  ),
                                                                                                if (visual['gen_status'] == 'generating' || visual['gen_status'] == 'polling' || visual['gen_status'] == 'downloading')
                                                                                                  const SizedBox(width: 3),
                                                                                                Text(
                                                                                                  visual['gen_status'] == 'generating' ? 'Gen...' 
                                                                                                    : visual['gen_status'] == 'polling' ? 'Poll...'
                                                                                                    : visual['gen_status'] == 'downloading' ? 'DL...'
                                                                                                    : visual['gen_status'] == 'failed' ? 'Failed'
                                                                                                    : visual['gen_status'].toString().substring(0, min(5, visual['gen_status'].toString().length)),
                                                                                                  style: TextStyle(
                                                                                                    fontSize: 9, 
                                                                                                    color: visual['gen_status'] == 'failed' ? Colors.red : Colors.black54,
                                                                                                  ),
                                                                                                ),
                                                                                              ],
                                                                                            ),
                                                                                          ),
                                                                                       ],
                                                                                       const Spacer(),
                                                                                      // Mute Toggle
                                                                                      IconButton(
                                                                                         icon: Icon(isMuted ? Icons.volume_off : Icons.volume_up, size: 16, color: isMuted ? Colors.red : Colors.grey),
                                                                                         tooltip: isMuted ? LocalizationService().tr('reel.unmute') : LocalizationService().tr('reel.mute'),
                                                                                         constraints: const BoxConstraints(),
                                                                                         padding: const EdgeInsets.symmetric(horizontal: 4),
                                                                                         onPressed: () {
                                                                                            setState(() {
                                                                                               visual['is_muted'] = !isMuted;
                                                                                            });
                                                                                             _saveState();
                                                                                         },
                                                                                      ),
                                                                                       if (hasVideo) Tooltip(
                                                                                          message: 'Open Video',
                                                                                          child: InkWell(
                                                                                             onTap: () {
                                                                                                if (visual['video_path'] != null) {
                                                                                                   Process.run('explorer', ['/select,', visual['video_path']]);
                                                                                                }
                                                                                             }, 
                                                                                             child: const Icon(Icons.folder_open, size: 16, color: Colors.blue),
                                                                                          ),
                                                                                       ),
                                                                                       const SizedBox(width: 8),
                                                                                       // Play Video (External)
                                                                                       if (hasVideo) Tooltip(
                                                                                          message: 'Play Video',
                                                                                          child: InkWell(
                                                                                             onTap: () async {
                                                                                                final videoPath = visual['video_path'];
                                                                                                if (videoPath != null) {
                                                                                                   try {
                                                                                                      await OpenFilex.open(videoPath);
                                                                                                   } catch (e) {
                                                                                                      print('[PLAY] Error opening video: $e');
                                                                                                      ScaffoldMessenger.of(context).showSnackBar(
                                                                                                        SnackBar(content: Text('Cannot play: $videoPath'))
                                                                                                      );
                                                                                                   }
                                                                                                }
                                                                                             }, 
                                                                                             child: const Icon(Icons.play_circle_filled, size: 16, color: Colors.green),
                                                                                          ),
                                                                                       ),
                                                                                       const SizedBox(width: 8),
                                                                                       // Regenerate Video Button
                                                                                       Tooltip(
                                                                                          message: 'Regenerate Video',
                                                                                          child: InkWell(
                                                                                             onTap: () {
                                                                                                // Regenerate this specific visual
                                                                                                _regenerateSingleVisual(index, partIdx, vIdx);
                                                                                             }, 
                                                                                             child: Icon(
                                                                                                Icons.refresh, 
                                                                                                size: 16, 
                                                                                                color: hasVideo ? Colors.orange : Colors.red,
                                                                                             ),
                                                                                          ),
                                                                                       ),
                                                                                    ]),
                                                                                   Builder(
                                                                                      builder: (context) {
                                                                                        final promptKey = '${project['id']}_${partIdx}_$vIdx';
                                                                                        final promptCtrl = _getPromptController(promptKey, visual['prompt'] ?? '');
                                                                                        return CallbackShortcuts(
                                                                                          bindings: <ShortcutActivator, VoidCallback>{
                                                                                            const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
                                                                                              final didUndo = _undoPrompt(promptKey);
                                                                                              if (didUndo) {
                                                                                                visual['prompt'] = promptCtrl.text;
                                                                                                _debouncedSave();
                                                                                              }
                                                                                            },
                                                                                          },
                                                                                          child: TextField(
                                                                                            controller: promptCtrl,
                                                                                            maxLines: null,
                                                                                            style: const TextStyle(fontSize: 12),
                                                                                            decoration: const InputDecoration(
                                                                                               isDense: true,
                                                                                               border: InputBorder.none,
                                                                                               contentPadding: EdgeInsets.zero,
                                                                                               hintText: 'Enter visual prompt...',
                                                                                            ),
                                                                                            onChanged: (val) {
                                                                                               visual['prompt'] = val;
                                                                                               _pushPromptUndo(promptKey, val);
                                                                                               _debouncedSave();
                                                                                            },
                                                                                          ),
                                                                                        );
                                                                                      },
                                                                                   ),
                                                                                   // Voice Cue field (for video speech)
                                                                                   if (visual['voice_cue'] != null) ...[
                                                                                      const SizedBox(height: 4),
                                                                                      Container(
                                                                                         padding: const EdgeInsets.all(4),
                                                                                          decoration: BoxDecoration(
                                                                                             color: ThemeProvider().isDarkMode ? Colors.blue.withOpacity(0.12) : Colors.blue.shade50,
                                                                                             borderRadius: BorderRadius.circular(4),
                                                                                          ),
                                                                                         child: Row(
                                                                                            children: [
                                                                                               const Icon(Icons.record_voice_over, size: 14, color: Colors.blue),
                                                                                               const SizedBox(width: 4),
                                                                                               Expanded(
                                                                                                  child: Builder(
                                                                                                    builder: (context) {
                                                                                                      final vcKey = 'vc_${project['id']}_${partIdx}_$vIdx';
                                                                                                      final vcCtrl = _getPromptController(vcKey, visual['voice_cue'] ?? '');
                                                                                                      return CallbackShortcuts(
                                                                                                        bindings: <ShortcutActivator, VoidCallback>{
                                                                                                          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
                                                                                                            final didUndo = _undoPrompt(vcKey);
                                                                                                            if (didUndo) {
                                                                                                              visual['voice_cue'] = vcCtrl.text;
                                                                                                              _debouncedSave();
                                                                                                            }
                                                                                                          },
                                                                                                        },
                                                                                                        child: TextField(
                                                                                                          controller: vcCtrl,
                                                                                                          maxLines: null,
                                                                                                           style: TextStyle(fontSize: 11, color: ThemeProvider().isDarkMode ? Colors.blue.shade300 : Colors.blue),
                                                                                                           decoration: InputDecoration(
                                                                                                             isDense: true,
                                                                                                             border: InputBorder.none,
                                                                                                             contentPadding: EdgeInsets.zero,
                                                                                                             hintText: LocalizationService().tr('reel.voice_cue_hint'),
                                                                                                          ),
                                                                                                          onChanged: (val) {
                                                                                                             visual['voice_cue'] = val;
                                                                                                             _pushPromptUndo(vcKey, val);
                                                                                                             _debouncedSave();
                                                                                                          },
                                                                                                        ),
                                                                                                      );
                                                                                                    },
                                                                                                  ),
                                                                                               ),
                                                                                            ],
                                                                                         ),
                                                                                      ),
                                                                                   ],
                                                                                ],
                                                                             ),
                                                                           ),
                                                                         ],
                                                                      ),
                                                                   );
                                                                }).toList(),
                                                          ],
                                                       );
                                                    },
                                                  ),
                                                ),
                                               ],
                                            ),
                                          );
                                          
                                          // Return split layout for wide, stacked for narrow
                                          if (isWide) {
                                            return Row(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                SizedBox(width: 140, child: controlsWidget),
                                                const SizedBox(width: 12),
                                                Expanded(child: promptsWidget),
                                              ],
                                            );
                                          } else {
                                            return Column(
                                              children: [
                                                controlsWidget,
                                                const SizedBox(height: 12),
                                                promptsWidget,
                                              ],
                                            );
                                          }
                                        },
                                      ),
                                    ), // Padding
                                  ], // ExpansionTile children
                                ), // ExpansionTile
                                  if (index < _reelProjects.length - 1)
                                    Divider(height: 1, color: Colors.grey.shade100, indent: 16, endIndent: 16),
                                ],
                              );
                            },).toList(),
                            ),
                          )
            : const Center(
                child: Text('Add a reel project to get started', style: TextStyle(color: Colors.grey)),
              );

    if (!isDesktop) {
      if (!isMobile) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: listPanel),
            if (_reelProjects.isNotEmpty) ...[
               const SizedBox(width: 24),
               SizedBox(width: 260, child: controlsPanel),
            ],
          ],
        );
      }

      // Mobile Layout
      return Column(
        children: [
          if (_reelProjects.isNotEmpty) ...[
             controlsPanel,
             const SizedBox(height: 16),
          ],
          listPanel,
        ],
      );
    }

    // DESKTOP: Triple Column Scrolling (Middle and Right are handled here)
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Middle Div: Projects List with Scrollbar
        Expanded(
          child: Scrollbar(
            controller: _middleScrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _middleScrollController,
              padding: const EdgeInsets.only(top: 8, right: 0),
              child: listPanel,
            ),
          ),
        ),
        if (_reelProjects.isNotEmpty) ...[
          const SizedBox(width: 8),
          // Right Div: Run Settings with its own scroll
          SizedBox(
            width: 260,
            child: SingleChildScrollView(
              controller: _rightScrollController,
              padding: const EdgeInsets.only(top: 8),
              child: controlsPanel,
            ),
          ),
        ],
      ],
    );
  }
  
  // --- Generators ---
  
  // Template Card Builder
  Widget _buildTemplateCard({
    required String? id,
    required String name,
    required String? imagePath,
    required bool isSelected,
  }) {
    return GestureDetector(
      onTap: () {
         setState(() {
           _state = _state.copyWith(selectedReelTemplateId: id);
           _staticSelectedReelTemplateId = id; // Sync to static for tab persistence
         });
         _saveState();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 90,
        height: 160,
        margin: const EdgeInsets.only(right: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.deepPurple : Colors.grey.shade300,
            width: isSelected ? 3 : 1,
          ),
          boxShadow: isSelected ? [
            BoxShadow(
              color: Colors.deepPurple.withOpacity(0.4),
              blurRadius: 10,
              spreadRadius: 2,
            ),
          ] : [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 4,
              offset: const Offset(0, 2),
            )
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(isSelected ? 9 : 10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background Image with Blur if selected
              ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: isSelected ? 0.8 : 0,
                  sigmaY: isSelected ? 0.8 : 0,
                ),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  foregroundDecoration: BoxDecoration(
                    color: isSelected ? Colors.black.withOpacity(0.2) : Colors.transparent,
                  ),
                  child: imagePath != null
                      ? Image.asset(
                          imagePath,
                          width: double.infinity,
                          height: double.infinity,
                          fit: BoxFit.cover,
                          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                            if (wasSynchronouslyLoaded) return child;
                            return AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              child: frame != null
                                  ? child
                                  : Container(
                                      color: Colors.grey.shade200,
                                      child: Center(
                                        child: SizedBox(
                                          width: 16, height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.grey.shade400,
                                          ),
                                        ),
                                      ),
                                    ),
                            );
                          },
                          errorBuilder: (ctx, err, st) => Container(
                            color: Colors.grey.shade200,
                            child: const Icon(Icons.movie_creation, size: 24, color: Colors.grey),
                          ),
                        )
                      : Container(
                          color: Colors.grey.shade100,
                          child: const Icon(Icons.description, size: 24, color: Colors.grey),
                        ),
                ),
              ),
              
              // Modern, sleek Animated Checkmark Overlay
              AnimatedScale(
                scale: isSelected ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                child: Center(
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5), // Sleek thin white ring
                      boxShadow: [
                        BoxShadow(
                          color: Colors.deepPurple.withOpacity(0.35),
                          blurRadius: 6,
                          spreadRadius: 0.5,
                        )
                      ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: const [
                        Icon(Icons.circle, color: Colors.deepPurple, size: 32),
                        Icon(Icons.check, color: Colors.white, size: 20),
                      ],
                    ),
                  ),
                ),
              ),
              
              // Bottom Label Overlay for better readability
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                    ),
                  ),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _shouldStopReelGeneration = false;
  final Map<int, bool> _autoProcessMap = {};

  Future<void> _processReelFull(int index) async {
     final project = _reelProjects[index];
     final projectId = project['id'];
     
     setState(() {
        _autoProcessMap[projectId] = true;
     });
     
     // 1. Audio
     if (project['status'] != 'audio_done') {
         await _generateReelAudio(index);
         
         // Check if stopped or failed
         if (_autoProcessMap[projectId] != true) return;
         if (project['status'] != 'audio_done') {
             ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Auto Process: Audio generation incomplete.')));
             setState(() { _autoProcessMap[projectId] = false; });
             return;
         }
     }
     
     // 2. Video
     if (project['status'] != 'video_done') {
         // Start generation
         await _generateReelVideo(index);
         // Return immediately - polling and completion are handled by _onReelTaskUpdate and VideoGenerationService background loop
         return;
     }
     
     // 3. Export - Fire and forget
     if (_autoProcessMap[projectId] == true && _bulkAutoExport) {
         final eIdx = index;
         final eMethod = _bulkExportMethod;
         final eRes = _bulkExportResolution;
         Future(() async {
             try {
                 final proj = _reelProjects[eIdx];
                 final ct = proj['content'] as List?;
                 bool ready = true;
                 int miss = 0;
                 if (ct != null) {
                   for (var part in ct) {
                     final vis = part['visuals'] as List?;
                     if (vis != null) {
                       for (var v in vis) {
                         if (v['gen_status'] != 'completed' || v['video_path'] == null || !File(v['video_path']).existsSync()) {
                           ready = false;
                           miss++;
                         }
                       }
                     }
                   }
                 }
                  if (ready) {
                    print('[AUTO EXPORT] Videos ready for $projectId - exporting in background...');
                    if (mounted) setState(() { proj['status'] = 'finalizing'; });
                    await Future.delayed(const Duration(seconds: 5));
                    if (mounted) setState(() { proj['status'] = 'exporting'; });
                    await _exportReelWithSettings(eIdx, eMethod, eRes);
                    if (mounted) {
                        setState(() {
                            proj['status'] = 'video_done';
                            _autoProcessMap[projectId] = false;
                        });
                        _saveState();
                    }
                    print('[AUTO EXPORT] Done for $projectId');
                  } else {
                   print('[AUTO EXPORT] Skipped $projectId - $miss missing');
                 }
             } catch (e) {
                 print('[AUTO EXPORT] Error: $e');
             }
         });
     }
     
     if (mounted) {
        setState(() {
           _autoProcessMap[projectId] = false;
        });
     }
  }

  void _stopReelProcess(int index) {
      final projectId = _reelProjects[index]['id'];
      final status = _reelProjects[index]['status'];
      
      print('[REEL] Stopping process for reel $index (status: $status)');
      
      setState(() {
         _autoProcessMap[projectId] = false;
      });
      
      // Cancel video task if running
      if (status == 'video_generating') {
          _cancelReelTask(index);
      }
      
      print('[REEL] Process stopped for reel $index');
  }
  
  /// Stop bulk auto-create process
  void _stopBulkAutoCreate() {
    print('[REEL] Stopping bulk auto-create...');
    
    // Cancel all running reel tasks
    for (int i = 0; i < _reelProjects.length; i++) {
      final status = _reelProjects[i]['status'];
      if (status == 'video_generating') {
        _cancelReelTask(i);
      }
    }
    
    setState(() {
      _isBulkAutoCreating = false;
    });
    
    print('[REEL] Bulk auto-create stopped');
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bulk processing stopped'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  /// Bulk auto-create: FIRE-AND-FORGET approach.
  /// Rapidly loops through ALL reels, generates audio, collects scenes,
  /// and fires generation requests with small intervals — does NOT wait
  /// for polling/downloading/exporting before moving to the next reel.
  ///
  /// Phase 1: Sequentially loop through all reels with small delays (~3s each).
  ///          For each reel: generate audio if needed, collect scenes, and
  ///          submit them to VideoGenerationService (fire-and-forget).
  /// Phase 2: Background monitors (one per reel) watch scene statuses.
  ///          When all scenes for a reel complete, auto-export is triggered.
  ///
  /// 429 handling: VideoGenerationService already handles per-profile 429
  /// cooldowns (40s). The producer skips profiles in cooldown and continues
  /// with available ones.
  Future<void> _startBulkAutoCreate() async {
    if (_selectedReelsForBulkCreate.isEmpty) return;
    
    setState(() => _isBulkAutoCreating = true);
    
    int totalReels = 0;
    int skippedReels = 0;
    final List<Future<void>> backgroundMonitors = [];

    try {
      final selectedIndices = _selectedReelsForBulkCreate.toList()..sort();
      int tempIdCounter = DateTime.now().microsecondsSinceEpoch;
      
      // Collect ALL scenes from ALL reels first, then submit them all at once
      List<SceneData> allScenesToGenerate = [];

      print('[BULK-FIRE] 🚀 Starting Fire-and-Forget Bulk Processing for ${selectedIndices.length} reels');
      print('[BULK-FIRE] Mode: 10x Boost = $_use10xBoostMode');

      // ─────────────────────────────────────────────────────────────────
      // PHASE 1: Rapidly generate audio + collect scenes for ALL reels
      // ─────────────────────────────────────────────────────────────────
      for (int index in selectedIndices) {
        if (!_isBulkAutoCreating) break;
        
        final project = _reelProjects[index];
        final projectId = project['id'];
        
        if (mounted) setState(() { _autoProcessMap[projectId] = true; });

        print('[BULK-FIRE] ──────────────────────────────────────────');
        print('[BULK-FIRE] 📦 Preparing Reel ${index + 1}: ${project['name'] ?? project['title']}');
        
        // Skip already completed reels
        if (project['status'] == 'video_done') {
          print('[BULK-FIRE] Skip Reel ${index + 1}: Already video_done');
          skippedReels++;
          continue;
        }
        
        // 1. Audio Generation (must be sequential per reel - quick)
        if (project['status'] != 'audio_done' && project['status'] != 'video_generating' && project['status'] != 'video_done') {
           print('[BULK-FIRE] 🎙️ Generating audio for Reel ${index + 1}');
           await _generateReelAudio(index);
           if (!_isBulkAutoCreating) break;
           
           // Check if audio failed
           if (project['status'] != 'audio_done') {
              print('[BULK-FIRE] ⚠️ Audio generation incomplete for Reel ${index + 1}, skipping...');
              skippedReels++;
              continue;
           }
        }

        // 2. Collect scenes for this reel
        final content = project['content'] as List;
        final reelPaths = await _getReelPaths(project);
        final videoDir = reelPaths['videoclips']!;
        
        List<SceneData> scenesForThisReel = [];
        for(var part in content) {
           if(part['visuals'] != null) {
              for(var v in part['visuals']) {
                 if (v['active'] != false && (v['video_path'] == null || !File(v['video_path']).existsSync())) {
                     final prompt = v['prompt'];
                     if (prompt != null) {
                        int vId = v['vId'] ?? tempIdCounter++;
                        v['vId'] = vId;
                        final String pid = project['id'].toString();
                        final globalId = _getGlobalId(pid, vId);
                        _visualIdMap[globalId] = v;
                        v['gen_status'] = 'queued';
                        
                         var scene = _sceneDataMap[globalId];
                         if (scene == null) {
                            scene = SceneData(
                               sceneId: globalId,
                               prompt: prompt,
                               status: 'queued',
                               aspectRatio: project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT',
                               targetFolder: videoDir.path,
                            );
                            _sceneDataMap[globalId] = scene;
                         } else {
                            scene.prompt = prompt;
                            scene.aspectRatio = project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT';
                            scene.targetFolder = videoDir.path;
                            if (scene.status == 'failed') scene.status = 'queued';
                         }
                         scenesForThisReel.add(scene);
                     }
                 }
              }
           }
        }

        if (scenesForThisReel.isNotEmpty) {
            totalReels++;
            
            // Mark project as generating
            if (mounted) setState(() { project['status'] = 'video_generating'; });
            
            // Set project folder for this reel
            VideoGenerationService().setProjectFolder(videoDir.path);
            
            print('[BULK-FIRE] 🎬 Queuing ${scenesForThisReel.length} scenes from Reel ${index + 1}');
            
            // Add to master list
            allScenesToGenerate.addAll(scenesForThisReel);
            
            // 3. Launch background monitor for this reel (fire-and-forget)
            final monitorFuture = _monitorReelCompletion(
              reelIndex: index,
              scenes: scenesForThisReel,
              onCompleted: () {
                print('[BULK-FIRE] ✅ Reel ${index + 1} completed!');
              },
              onFailed: () {
                print('[BULK-FIRE] ❌ Reel ${index + 1} failed!');
              },
            );
            backgroundMonitors.add(monitorFuture);
            
            // Small delay between reel preparation (not waiting for completion!)
            await Future.delayed(const Duration(seconds: 1));
        } else {
            print('[BULK-FIRE] Skip Reel ${index + 1}: All videos already exist');
            skippedReels++;
            if (mounted) setState(() { project['status'] = 'video_done'; });
        }
      }

      if (!_isBulkAutoCreating || allScenesToGenerate.isEmpty) {
        print('[BULK-FIRE] No scenes to generate or bulk cancelled');
        if (mounted) setState(() => _isBulkAutoCreating = false);
        return;
      }

      // ─────────────────────────────────────────────────────────────────
      // PHASE 2: Submit ALL scenes at once to VideoGenerationService
      // The service handles concurrent generation, per-profile 429 cooldowns,
      // polling, downloading — all in the background.
      // ─────────────────────────────────────────────────────────────────
      print('[BULK-FIRE] ═══════════════════════════════════════════');
      print('[BULK-FIRE] 🚀 Firing ALL ${allScenesToGenerate.length} scenes from $totalReels reels');
      print('[BULK-FIRE] 🔥 Background monitors: ${backgroundMonitors.length} active');
      print('[BULK-FIRE] ═══════════════════════════════════════════');
      
      // Fire the single batch with ALL scenes — VideoGenerationService
      // handles everything: generation, polling, downloading, 429 cooldowns.
      // This call returns when all generation requests are SUBMITTED (not completed).
      // Polling + downloading continue in the background.
      VideoGenerationService().startBatch(
        allScenesToGenerate,
        model: _reelVideoModel,
        aspectRatio: _reelProjects.isNotEmpty 
            ? (_reelProjects.first['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT')
            : 'VIDEO_ASPECT_RATIO_PORTRAIT',
        use10xBoostMode: _use10xBoostMode,
        autoRetry: true,
      );
      
      // Don't await startBatch — let the generation fire in the background.
      // The background monitors will detect when each reel's scenes are done
      // and trigger auto-export.
      
      print('[BULK-FIRE] 🔥 All generation requests fired! Waiting for background monitors...');
      
      // Wait for ALL background monitors to finish (they handle export too)
      await Future.wait(backgroundMonitors);
      
      // Count results
      int completed = 0;
      int failed = 0;
      for (int index in selectedIndices) {
        final project = _reelProjects[index];
        if (project['status'] == 'video_done') {
          completed++;
        } else if (project['status'] == 'video_error') {
          failed++;
        }
      }

      if (mounted) {
         setState(() => _isBulkAutoCreating = false);
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('Bulk automation finished! Completed: $completed, Failed: $failed, Skipped: $skippedReels'),
           backgroundColor: failed > 0 ? Colors.orange : Colors.green)
         );
      }
      
      print('[BULK-FIRE] ════════════════════════════════════════════');
      print('[BULK-FIRE] ✅ BULK COMPLETE: $completed done, $failed failed, $skippedReels skipped');
      print('[BULK-FIRE] ════════════════════════════════════════════');
    } catch (e) {
      print('[BULK-FIRE] Error in fire-and-forget bulk automation: $e');
      if (mounted) setState(() => _isBulkAutoCreating = false);
    }
  }

  /// Background monitor for a single reel's scene completion.
  /// Polls scene statuses every 5s. When all scenes are completed/failed,
  /// triggers file verification and auto-export if enabled.
  Future<void> _monitorReelCompletion({
    required int reelIndex,
    required List<SceneData> scenes,
    required VoidCallback onCompleted,
    required VoidCallback onFailed,
  }) async {
    final project = _reelProjects[reelIndex];
    final projectId = project['id'];
    
    print('[BULK-MONITOR] Started monitoring Reel ${reelIndex + 1} (${scenes.length} scenes)');
    
    // Poll until all scenes are done (completed or failed) or bulk is cancelled
    while (_isBulkAutoCreating) {
      await Future.delayed(const Duration(seconds: 5));
      
      if (!_isBulkAutoCreating) break;
      
      // Check scene statuses
      int doneCount = 0;
      int failCount = 0;
      int activeCount = 0;
      
      for (final scene in scenes) {
        switch (scene.status) {
          case 'completed':
            doneCount++;
            break;
          case 'failed':
            failCount++;
            break;
          default:
            activeCount++;
            break;
        }
      }
      
      print('[BULK-MONITOR] Reel ${reelIndex + 1}: $doneCount done, $failCount failed, $activeCount active');
      
      // All scenes resolved (completed or failed)
      if (activeCount == 0) {
        break;
      }
    }
    
    if (!_isBulkAutoCreating) {
      print('[BULK-MONITOR] Reel ${reelIndex + 1} monitoring cancelled');
      return;
    }
    
    // Verify files on disk
    final content = project['content'] as List;
    bool allScenesDone = true;
    for (var part in content) {
      final visuals = part['visuals'] as List?;
      if (visuals != null) {
        for (var v in visuals) {
          if (v['active'] != false && (v['video_path'] == null || !File(v['video_path']).existsSync())) {
            allScenesDone = false;
            break;
          }
        }
      }
      if (!allScenesDone) break;
    }
    
    if (allScenesDone && _isBulkAutoCreating) {
      print('[BULK-MONITOR] ✓ Reel ${reelIndex + 1} all videos complete. Finalizing...');
      if (mounted) {
        setState(() {
          project['status'] = 'finalizing';
          _autoProcessMap[projectId] = false;
        });
      }
      
      // Auto Export (runs on this reel's background thread)
      if (_bulkAutoExport) {
        print('[BULK-MONITOR] Auto-exporting Reel ${reelIndex + 1}');
        await Future.delayed(const Duration(seconds: 5));
        if (!_isBulkAutoCreating) return;
        
        if (mounted) setState(() { project['status'] = 'exporting'; });
        await _exportReelWithSettings(reelIndex, _bulkExportMethod, _bulkExportResolution);
      }
      
      if (mounted) {
        setState(() { project['status'] = 'video_done'; });
      }
      _saveState();
      onCompleted();
      print('[BULK-MONITOR] ✓ Reel ${reelIndex + 1} DONE');
    } else if (_isBulkAutoCreating) {
      print('[BULK-MONITOR] ✗ Reel ${reelIndex + 1} finished with missing videos');
      if (mounted) setState(() { project['status'] = 'video_error'; });
      onFailed();
    }
  }

  Future<void> _generateReel() async {
    final topic = _reelTopicController.text.trim();
    if (topic.isEmpty) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter a topic')));
       return;
    }

     setState(() { 
        _isGeneratingReel = true; 
        _shouldStopReelGeneration = false;
     });
     
     // Debug: Log the language being used
     print('[REEL] Voice Over Language selected: $_reelVoiceOverLanguage');
     
      try {
           await _alignmentService.loadApiKeys();

           final isRandomChar = _reelCharacter == 'Random';
           final baseCharacter = isRandomChar ? 'Boy or Girl' : _reelCharacter;
           int successCount = 0;
           
           // Determine topics to process based on mode
           List<String> topicsToProcess;
           if (_reelTopicMode == 'multi') {
              // Multi-line: each line is a separate topic (process one by one)
              topicsToProcess = topic.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
           } else {
              // Single mode: Generate multiple stories from one hint
              if (_storiesPerHint > 1) {
                 // Generate N different stories from the same hint
                 topicsToProcess = List.generate(_reelCount, (i) {
                    final storyVariation = (i % _storiesPerHint) + 1;
                    if (storyVariation == 1) {
                       return topic;
                    } else {
                       // Request completely different story variations
                       return """Generate story variation #$storyVariation based on this theme: $topic
                       
Requirements:
- Create a COMPLETELY DIFFERENT story with unique characters, setting, and plot
- Use different animals/creatures if applicable
- Change the environment/location
- Alter the conflict/challenge
- Make it feel like a fresh, original story while keeping the core theme""";
                    }
                 });
              } else {
                 // Original behavior: variations of the same story
                 topicsToProcess = List.generate(_reelCount, (i) {
                    if (i == 0) return topic;
                    return "Create a unique variation of this story: $topic. Use completely different animals/settings/characters.";
                 });
              }
           }
           
           // Determine concurrency based on API key count (max 5 concurrent)
           final apiKeyCount = _alignmentService.apiKeyCount;
           final concurrency = apiKeyCount.clamp(1, 5);
           print('[REEL] Using $concurrency concurrent API requests (${apiKeyCount} keys available)');
           
           // Process topics in batches of [concurrency] size
           for (int batchStart = 0; batchStart < topicsToProcess.length; batchStart += concurrency) {
              if (_shouldStopReelGeneration) {
                 if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Generation Stopped by User')));
                 break;
              }
              
              final batchEnd = (batchStart + concurrency).clamp(0, topicsToProcess.length);
              final batch = topicsToProcess.sublist(batchStart, batchEnd);
              
              // Create concurrent futures for this batch
              final futures = <Future<void>>[];
              
              for (int j = 0; j < batch.length; j++) {
                 final i = batchStart + j;
                 final currentTopic = batch[j];
                 
                 futures.add(() async {
                    if (_shouldStopReelGeneration) return;
                    
                    String characterType = baseCharacter;
                    
                    // In multi-line mode, detect character from the topic line
                    if (_reelTopicMode == 'multi') {
                       final lowerTopic = currentTopic.toLowerCase();
                       if (lowerTopic.contains('girl') || lowerTopic.contains('she ') || lowerTopic.contains('her ')) {
                          characterType = 'Girl';
                       } else if (lowerTopic.contains('boy') || lowerTopic.contains('he ') || lowerTopic.contains('his ')) {
                          characterType = 'Boy';
                       } else {
                          characterType = 'Character from the topic (Boy or Girl based on context)';
                       }
                    } else if (isRandomChar && i > 0) {
                       characterType = 'Random Character (Not the same as before if possible)';
                    }

                    List<Map<String, dynamic>> batchResults = [];
                    int retries = 0;
                    bool stepSuccess = false;

                    while (!stepSuccess && retries < 3) {
                       if (_shouldStopReelGeneration) break;
                       try {
                          ReelTemplate? templateToUse;
                          if (_state.selectedReelTemplateId != null) {
                             try {
                               templateToUse = _state.reelTemplates.firstWhere((t) => t.id == _state.selectedReelTemplateId);
                             } catch (_) {}
                          }

                          batchResults = await _alignmentService.generateBatchReelContent(
                             topic: currentTopic,
                             characterType: characterType,
                             model: 'gemini-2.5-flash',
                             language: _reelVoiceOverLanguage.isNotEmpty ? _reelVoiceOverLanguage : 'English',
                             count: 1,
                             scenesPerStory: _scenesPerStory,
                             template: templateToUse,
                             voiceCueEnabled: _globalVoiceCueEnabled,
                             voiceCueLanguage: _voiceCueLanguage,
                             narrationEnabled: _globalNarrationEnabled,
                          );
                          stepSuccess = true;
                       } catch (e) {
                          retries++;
                          print('Gen Reel ${i+1} failed (Attempt $retries): $e');
                          await Future.delayed(const Duration(seconds: 2));
                       }
                    }
                    
                    if (stepSuccess && batchResults.isNotEmpty) {
                         final reelData = batchResults.first;
                         final title = reelData['title'] ?? '$topic (Var ${i + 1})';
                         final content = reelData['content'] as List;

                         // Force defaults
                         for (var item in content) {
                           if (item is Map) {
                               item['active'] = true;
                               if (item['visuals'] != null && item['visuals'] is List) {
                                  for (var v in (item['visuals'] as List)) {
                                     if (v is Map) v['active'] = true;
                                  }
                               }
                           }
                         }

                         // Generate AI voice style based on story content
                         String generatedVoiceStyle = _state.globalVoiceStyle;
                         try {
                            final storyTexts = content.map((c) => c['text']?.toString() ?? '').toList();
                            generatedVoiceStyle = await _alignmentService.generateVoiceStyle(
                               storyTitle: title,
                               storyTexts: storyTexts,
                               language: _reelVoiceOverLanguage.isNotEmpty ? _reelVoiceOverLanguage : 'English',
                            );
                         } catch (e) {
                            print('[REEL] Voice style generation failed: $e');
                         }

                         final newProject = {
                            'id': DateTime.now().millisecondsSinceEpoch + i,
                            'name': title,
                            'status': 'draft',
                            'content': content,
                            'voice_model': _state.globalVoiceModel,
                            'voice_style': generatedVoiceStyle,
                            'voice_style_auto': true,
                            'video_model': _reelVideoModel,
                            'aspect_ratio': 'VIDEO_ASPECT_RATIO_PORTRAIT',
                            'created_at': DateTime.now().toIso8601String(),
                         };
                         
                         // Add to static list (thread-safe since Dart is single-threaded)
                         _staticReelProjects.add(newProject);
                         _state = _state.copyWith(reelProjects: _staticReelProjects);
                         
                         if (mounted) setState(() {});
                         _saveState();
                         successCount++;
                    }
                 }());
              }
              
              // Wait for all concurrent requests in this batch to complete
              await Future.wait(futures);
           }
        
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Generated $successCount / $_reelCount reels.')));
      } catch (e) {
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      } finally {
         // Always update static flag even if widget is disposed
         _staticIsGeneratingReel = false;
         if (mounted) setState(() {});
      }
  }

  void _deleteReel(int index) {
      setState(() {
         _reelProjects.removeAt(index);
         _state = _state.copyWith(reelProjects: _reelProjects);
      });
      _saveState();
  }
  
  String _getReelVoiceScript(Map<String, dynamic> project) {
    final content = project['content'] as List?;
    if (content == null) return '';
    return content
        .where((s) => (s['active'] ?? true) && s['text'] != null && s['text'].toString().isNotEmpty)
        .map((s) => s['text'].toString().trim())
        .join('\n\n');
  }

  void _toggleMuteAll(int projectIndex, bool mute) {
      final project = _reelProjects[projectIndex];
      final content = project['content'] as List;
      
      for(var part in content) {
          if (part['visuals'] != null) {
              for(var v in part['visuals']) {
                  v['is_muted'] = mute;
              }
          }
      }
      
      setState(() {
          _state = _state.copyWith(reelProjects: _reelProjects);
      });
      _saveState();
  }

  // --- Reel Pipeline Methods ---
  
  Future<void> _generateReelAudio(int projectIndex) async {
    final project = _staticReelProjects[projectIndex];
    final content = project['content'] as List;
    final projectId = project['id'];

     // Update static state directly
     project['status'] = 'audio_generating';
     _state = _state.copyWith(reelProjects: _staticReelProjects);
     if (mounted) setState(() {});
     
     int successCount = 0;
     
     // Get organized reel paths - audios will go to reels/{name}/audios/
     final reelPaths = await _getReelPaths(project);
     final audioDir = reelPaths['audios']!;
     
     // Load keys before loop
     await _ttsService.loadApiKeys();

     // Process in batches of 5
     const int batchSize = 5;
     for (int i = 0; i < content.length; i += batchSize) {
       final end = (i + batchSize < content.length) ? i + batchSize : content.length;
       final batch = content.sublist(i, end);
       final futures = <Future<void>>[];

       for (int j = 0; j < batch.length; j++) {
         final partIdx = i + j;
         final part = batch[j];
         
         if (part['text'] == null || part['text'].toString().trim().isEmpty) {
            part['tts_muted'] = true;
            continue;
         }
         
         // Skip if already generated
         // Note: We check this inside the future to keep the loop synchronous structure clean, 
         // but strictly speaking checking existence is fast.
         
         futures.add(() async {
            if (part['audio_path'] != null && await File(part['audio_path']).exists()) {
               successCount++;
               return; 
            }
            
            try {
               final outputAudioPath = path.join(audioDir.path, 'reel_part_${partIdx}.wav');
               // Use global audio style if set, otherwise use per-project or default
               final effectiveVoiceStyle = _globalAudioStyleInstruction.isNotEmpty
                   ? _globalAudioStyleInstruction
                   : (project['voice_style'] ?? _state.globalVoiceStyle ?? 'friendly and engaging');
               // Use bulk voice name setting, or per-project, or global default
               final effectiveVoiceModel = _bulkVoiceName.isNotEmpty 
                   ? _bulkVoiceName
                   : (project['voice_model'] ?? _state.globalVoiceModel ?? 'Zephyr');
               final success = await _ttsService.generateTts(
                  text: part['text'],
                  voiceModel: effectiveVoiceModel,
                  voiceStyle: effectiveVoiceStyle,
                  outputPath: outputAudioPath,
                  speechRate: 1.0, 
               );
               
               if (success) {
                   // Update static state directly
                   part['audio_path'] = outputAudioPath;
                   if (mounted) setState(() {});
                   successCount++;
               }
            } catch (e) {
               print('Error generating audio for part $partIdx: $e');
            }
         }());
       }

       await Future.wait(futures);
       
       // Update global state and save after each batch
       _state = _state.copyWith(reelProjects: _staticReelProjects);
       if (mounted) setState(() {});
       _saveState();
     }
     
     // Final status update
     project['status'] = 'audio_done';
     _state = _state.copyWith(reelProjects: _staticReelProjects);
     if (mounted) setState(() {});
     _saveState();
  }

  Future<void> _generateReelVideo(int projectIndex) async {
     print('\n${'=' * 60}');
     print('[REEL VIDEO] Starting video generation for project $projectIndex');
     print('[REEL VIDEO] Platform: ${Platform.operatingSystem}');
     print('[REEL VIDEO] Is Mobile: ${Platform.isAndroid || Platform.isIOS}');
     print('${'=' * 60}');
     
     final project = _staticReelProjects[projectIndex];
     final content = project['content'] as List;
     final projectId = project['id'];
     
     print('[REEL VIDEO] Project ID: $projectId');
     print('[REEL VIDEO] Project Name: ${project['name']}');
     print('[REEL VIDEO] Content Parts: ${content.length}');
     
     // Pre-initialize status for all visuals to ensure progress counts correctly
     for(var part in content) {
       if(part['visuals'] != null) {
         for(var v in part['visuals']) {
           if (v['active'] == false) continue;
           if (v['video_path'] != null && File(v['video_path']).existsSync()) {
             v['gen_status'] = 'completed';
           } else {
             v['gen_status'] = 'queued';
           }
         }
       }
     }

     // Update static state directly
     project['status'] = 'video_generating';
     _state = _state.copyWith(reelProjects: _staticReelProjects);
     if (mounted) setState(() {});

     // Get organized reel paths - videos will go to reels/{name}/videoclips/
     final reelPaths = await _getReelPaths(project);
     final videoDir = reelPaths['videoclips']!;
     print('[REEL VIDEO] Videos will be saved to: ${videoDir.path}');

     // Flatten visual list and create SceneData
     List<SceneData> scenesToGen = [];
     // Use microsecond precision to prevent collisions across multiple rapid starts
     int tempIdCounter = DateTime.now().microsecondsSinceEpoch; 

     
     for(var part in content) {
        if(part['visuals'] != null) {
           for(var v in part['visuals']) {
              if (v['active'] != false && (v['video_path'] == null || !File(v['video_path']).existsSync())) {
                  final prompt = v['prompt'];
                  if (prompt != null) {
                     int vId = v['vId'] ?? tempIdCounter++;
                     v['vId'] = vId; // Store back to visual for persistence
                     final String pid = project['id'].toString();
                     final globalId = _getGlobalId(pid, vId);
                     _visualIdMap[globalId] = v;
                     
                     v['gen_status'] = 'queued';
                     v['gen_error'] = null;
                     
                      var scene = _sceneDataMap[globalId];
                      if (scene == null) {
                         scene = SceneData(
                            sceneId: globalId,
                            prompt: prompt,
                            status: 'queued',
                            aspectRatio: project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT',
                            targetFolder: videoDir.path,
                         );
                         _sceneDataMap[globalId] = scene;
                       } else {
                          // Reuse existing instance but update if needed
                          scene.prompt = prompt;
                          scene.aspectRatio = project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT';
                          scene.targetFolder = videoDir.path;
                          if (scene.status == 'failed') scene.status = 'queued';
                       }
                      
                      scenesToGen.add(scene);
                   }
               }
            }
         }
      }
     
     print('[REEL VIDEO] Scenes to generate: ${scenesToGen.length}');
     
     if (scenesToGen.isEmpty) {
        print('[REEL VIDEO] No scenes to generate - marking as done');
        project['status'] = 'video_done'; // Nothing to do
        _state = _state.copyWith(reelProjects: _staticReelProjects);
        if (mounted) setState(() {});
        _saveState();
        return;
     }

     // Debug: Check BulkExecutor configuration
     print('\n[REEL VIDEO] === BULK EXECUTOR CONFIG ===');
     print('[REEL VIDEO] Model: $_reelVideoModel');
     print('[REEL VIDEO] Account Type: $_reelAccountType');
     print('[REEL VIDEO] Aspect Ratio: ${project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT'}');
     
     // Check mobile service
     if (Platform.isAndroid || Platform.isIOS) {
        final mobileService = MobileBrowserService();
        print('[REEL VIDEO] Mobile Service Profile Count: ${mobileService.profiles.length}');
        print('[REEL VIDEO] Mobile Connected: ${mobileService.countConnected()}');
        print('[REEL VIDEO] Mobile Healthy: ${mobileService.countHealthy()}');
        
        for (int i = 0; i < mobileService.profiles.length; i++) {
           final p = mobileService.profiles[i];
           print('[REEL VIDEO]   Profile $i: ${p.name}');
           print('[REEL VIDEO]     Status: ${p.status}');
           print('[REEL VIDEO]     Generator: ${p.generator != null ? "SET" : "NULL"}');
           print('[REEL VIDEO]     Token: ${p.accessToken != null ? "HAS TOKEN" : "NO TOKEN"}');
           print('[REEL VIDEO]     403 Count: ${p.consecutive403Count}');
        }
        
        // Check if any profile has a generator
        final hasGenerator = mobileService.profiles.any((p) => p.generator != null);
        if (!hasGenerator) {
           print('[REEL VIDEO] ⚠️ WARNING: No mobile profiles have a generator!');
           print('[REEL VIDEO] ⚠️ User needs to open Browser tab first to initialize WebViews!');
        }
     }
     
     // Create Bulk Task (using global Flow UI model)
     final vgen = VideoGenerationService();
     vgen.setProjectFolder(videoDir.path);
     vgen.initialize(
        profileManager: widget.profileManager,
        mobileService: (Platform.isAndroid || Platform.isIOS) ? MobileBrowserService() : null,
        loginService: widget.loginService,
        email: widget.email,
        password: widget.password,
        accountType: widget.selectedAccountType,
     );
     project['status'] = 'video_generating';
     if (mounted) setState(() {});
     
     // Start Predefined Batch
     final isAutoCreate = _autoProcessMap[project['id']] == true;
     try {
       await VideoGenerationService().startBatch(
         scenesToGen,
         model: _reelVideoModel,
         aspectRatio: project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT',
         use10xBoostMode: _use10xBoostMode,
         autoRetry: true,
       );
       print('[REEL VIDEO] ✓ VideoGenerationService batch started successfully');
     } catch (e, stackTrace) {
       print('[REEL VIDEO] ✗ VideoGenerationService Start Error: $e');
       print('[REEL VIDEO] Stack trace: $stackTrace');
        project['status'] = 'video_error';
        _state = _state.copyWith(reelProjects: _staticReelProjects);
        if (mounted) setState(() {});
     }
  }

  void _onReelTaskUpdate(BulkTask task) {
     // Trigger UI update - sync scene statuses to visual objects
     bool anyChanged = false;
     
     print('[REEL UPDATE] Task ${task.id}: ${task.scenes.length} scenes, status: ${task.status}');
     
     for(var scene in task.scenes) {
        if (_visualIdMap.containsKey(scene.sceneId)) {
           final visual = _visualIdMap[scene.sceneId]!;
           
           // Update status for live display
           final oldStatus = visual['gen_status'];
           if (oldStatus != scene.status) {
              print('[REEL UPDATE] Scene ${scene.sceneId}: $oldStatus -> ${scene.status}');
              visual['gen_status'] = scene.status;
              visual['gen_error'] = scene.error;
              anyChanged = true;
           }
           
           // Update video path when completed
           if (scene.status == 'completed' && scene.videoPath != null) {
              if (visual['video_path'] != scene.videoPath) {
                 print('[REEL UPDATE] Scene ${scene.sceneId}: Video downloaded to ${scene.videoPath}');
                 visual['video_path'] = scene.videoPath;
                 anyChanged = true;
              }
           }
        } else {
           print('[REEL UPDATE] Scene ${scene.sceneId} NOT in visualIdMap (status: ${scene.status})');
        }
     }
     
     // Update static state directly (works even if widget disposed)
     if (anyChanged) {
        _state = _state.copyWith(reelProjects: _staticReelProjects);
     }
     
     // Update project status if task done
     if (task.status == TaskStatus.completed) {
        // Handle main reel tasks
        final proj = _staticReelProjects.firstWhere((p) => 'reel_task_${p['id']}' == task.id, orElse: ()=> {});
        if (proj.isNotEmpty) {
          proj['status'] = 'video_done';
          _saveState();
        }
        
        // Handle regen_batch_ tasks - clear the regenerating flag
        if (task.id.startsWith('regen_batch_')) {
          _isRegeneratingMissing = false;
        }
     } else if (task.status == TaskStatus.running) {
        final proj = _staticReelProjects.firstWhere((p) => 'reel_task_${p['id']}' == task.id, orElse: ()=> {});
        if (proj.isNotEmpty && proj['status'] != 'video_generating') {
          proj['status'] = 'video_generating';
        }
     } else if (task.status == TaskStatus.cancelled || task.status == TaskStatus.failed) {
        // Handle cancelled/failed regen_batch_ tasks
        if (task.id.startsWith('regen_batch_')) {
          _isRegeneratingMissing = false;
        }
     }
     
     // Only call setState if mounted
     if (mounted) setState(() {});
     
     // Save completed videos periodically
     if (anyChanged && task.completedScenes > 0) {
        _saveState();
     }
  }
    

  void _showExportDialog(int index) {
     showDialog(
        context: context,
        builder: (ctx) => LayoutBuilder(
          builder: (context, constraints) {
            final isMobile = constraints.maxWidth < 600;
            final fontSize = isMobile ? 12.0 : 14.0;
            final titleFontSize = isMobile ? 14.0 : 16.0;
            
            return StatefulBuilder(
              builder: (context, setDialogState) {
                return AlertDialog(
                  title: Text('Export Reel Settings', style: TextStyle(fontSize: titleFontSize)),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [
                          Expanded(child: Text('Voice Script Volume:', style: TextStyle(fontSize: fontSize))),
                          Text(_exportTtsVolume.toStringAsFixed(1), style: TextStyle(fontSize: fontSize)),
                        ]),
                        Slider(
                          value: _exportTtsVolume.clamp(0.0, 5.0),
                          min: 0.0, max: 5.0,
                          divisions: 50,
                          onChanged: (v) => setDialogState(() => _exportTtsVolume = v),
                        ),
                        Row(children: [
                          Expanded(child: Text('Video Sound Volume:', style: TextStyle(fontSize: fontSize))),
                          Text(_exportVideoVolume.toStringAsFixed(1), style: TextStyle(fontSize: fontSize)),
                        ]),
                        Slider(
                          value: _exportVideoVolume.clamp(0.0, 5.0),
                          min: 0.0, max: 5.0,
                          divisions: 50,
                          onChanged: (v) => setDialogState(() => _exportVideoVolume = v),
                        ),
                        Row(children: [
                          Expanded(child: Text('Video Speed (Final):', style: TextStyle(fontSize: fontSize))),
                          Text('${_exportPlaybackSpeed.toStringAsFixed(1)}x', style: TextStyle(fontSize: fontSize)),
                        ]),
                        Slider(
                          value: _exportPlaybackSpeed.clamp(0.5, 2.0),
                          min: 0.5, max: 2.0,
                          divisions: 15,
                          onChanged: (v) => setDialogState(() => _exportPlaybackSpeed = v),
                        ),
                        const Divider(),
                        Text('Export Method:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: titleFontSize)),
                        const SizedBox(height: 8),
                        SegmentedButton<String>(
                          segments: [
                            ButtonSegment(
                              value: 'fast',
                              label: Text('Fast', style: TextStyle(fontSize: fontSize)),
                              icon: Icon(Icons.speed, size: isMobile ? 14 : 16),
                            ),
                            ButtonSegment(
                              value: 'precise',
                              label: Text('Precise', style: TextStyle(fontSize: fontSize)),
                              icon: Icon(Icons.precision_manufacturing, size: isMobile ? 14 : 16),
                            ),
                          ],
                          selected: {_reelExportMethod},
                          onSelectionChanged: (v) => setDialogState(() => _reelExportMethod = v.first),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _reelExportMethod == 'fast' 
                            ? 'Adjusts audio speed to match video' 
                            : 'Adjusts video speed to match audio',
                          style: TextStyle(fontSize: isMobile ? 10 : 11, color: Colors.grey.shade600),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  actions: [
                     TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                     ElevatedButton(
                        onPressed: () {
                           Navigator.pop(ctx);
                           _exportReel(index);
                        },
                        child: const Text('Export'),
                     )
                  ],
                );
              },
            );
          },
        ),
      );
  }

  Future<void> _exportReel(int projectIndex) async {
    final project = _reelProjects[projectIndex];
    final content = project['content'] as List;
    final projectId = project['id'];
    
    // Get organized reel paths - export goes to reels_output/
    final reelPaths = await _getReelPaths(project);
    final exportDir = reelPaths['export']!;
    
    // Sanitize filename: remove special chars AND non-ASCII chars for FFmpeg compatibility
    final rawName = (project['name'] ?? 'reel_$projectId').toString();
    // Replace non-ASCII chars with underscore, then remove invalid filename chars
    final safeName = rawName
        .replaceAll(RegExp(r'[^\x00-\x7F]'), '_')  // Replace non-ASCII with underscore
        .replaceAll(RegExp(r'[<>:"/\\|?*\s]'), '_')  // Replace invalid chars and spaces
        .replaceAll(RegExp(r'_+'), '_')  // Collapse multiple underscores
        .replaceAll(RegExp(r'^_|_$'), ''); // Remove leading/trailing underscores
    final finalName = safeName.isEmpty ? 'reel_$projectId' : safeName;
    final outputFile = path.join(exportDir.path, '$finalName.mp4');
    
    // Start export progress tracking
    setState(() {
      project['status'] = 'exporting';
      _isReelExporting = true;
      _reelExportingIndex = projectIndex;
      _reelExportProgress = 0.0;
      _reelExportStep = 'Preparing...';
      _state = _state.copyWith(reelProjects: _reelProjects);
    });
    
    try {
       // 1. Auto-create Alignment JSON
       setState(() => _reelExportStep = 'Creating alignment...');
       
       final alignmentItems = <AlignmentItem>[];
       for(int i=0; i<content.length; i++) {
          final part = content[i];
          final visuals = part['visuals'] as List?;
          
          List<VideoReference> vRefs = [];
          if (visuals != null) {
             for (int j=0; j<visuals.length; j++) {
                if (visuals[j]['active'] != false) {
                   // ID is implied by order or path? Use unique string
                   vRefs.add(VideoReference(id: 'part_${i}_visual_${j}'));
                }
             }
          }
          
          alignmentItems.add(AlignmentItem(
             audioPartIndex: i,
             text: part['text'] ?? '',
             matchingVideos: vRefs,
          ));
       }
       // Save to reel folder or output folder? User said "how it create on story default tab". 
       // Main tab saves to project root usually. I'll save alongside the video for convenience.
       final alignmentJsonPath = path.join(exportDir.path, '${finalName}_alignment.json');
       await File(alignmentJsonPath).writeAsString(jsonEncode(alignmentItems.map((e) => e.toJson()).toList()));
       print('Saved alignment JSON to $alignmentJsonPath');

       // 2. Export with live progress updates
       await _exportService.exportReel(
          scenes: content,
          outputPath: outputFile,
          onProgress: (current, total, msg) {
             if (mounted) {
                setState(() {
                   _reelExportProgress = total > 0 ? current / total : 0.0;
                   _reelExportStep = msg;
                });
             }
             print('[EXPORT] $msg ($current/$total)');
          },
          ttsVolume: _exportTtsVolume,
          videoVolume: _exportVideoVolume,
          method: _reelExportMethod,
          playbackSpeed: _exportPlaybackSpeed,
       );
       
       setState(() {
        project['status'] = 'complete';
        project['exportedVideoPath'] = outputFile; // Store for playback
        _state = _state.copyWith(reelProjects: _reelProjects);
      });
      _saveState();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('✓ Reel Exported: $finalName.mp4'),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(label: 'Open', onPressed: () async {
             await OpenFilex.open(outputFile);
          }),
        ));
      }
    } catch (e) {
       if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export Error: $e')));
       setState(() {
        project['status'] = 'export_failed';
       });
    } finally {
       // Reset export progress state
       setState(() {
          _isReelExporting = false;
          _reelExportingIndex = -1;
          _reelExportProgress = 0.0;
          _reelExportStep = '';
       });
    }
  }
  
  /// Export reel with custom settings (used by bulk auto-create)
  Future<void> _exportReelWithSettings(int projectIndex, String exportMethod, String resolution) async {
    // Temporarily store and override settings
    final oldMethod = _reelExportMethod;
    final oldResolution = _reelExportResolution;
    
    _reelExportMethod = exportMethod;
    _reelExportResolution = resolution;
    
    try {
      await _exportReel(projectIndex);
    } finally {
      // Restore original settings
      _reelExportMethod = oldMethod;
      _reelExportResolution = oldResolution;
    }
  }
  
  Future<void> _playReelAudio(String? path) async {
     if (path == null) return;
     if (await File(path).exists()) {
        await _audioPlayer.play(DeviceFileSource(path));
     }
  }


  
  String _getReelPrompts(Map<String, dynamic> project) {
    final content = project['content'] as List?;
    if (content == null) return '';
    StringBuffer sb = StringBuffer();
    for (var part in content) {
       final visuals = part['visuals'] as List?;
       if (visuals != null) {
          for (var v in visuals) {
             sb.writeln('- ${v['prompt']}');
          }
       }
    }
    return sb.toString();
  }
  
  void _copyToClipboard(String text) {
     Clipboard.setData(ClipboardData(text: text));
     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied!')));
  }

  Widget _buildOutputFolderSection() {
    final currentFolder = _customOutputFolder ?? 
        widget.projectService.currentProject?.projectPath ?? 
        'No folder selected';
    
    final tp = ThemeProvider();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tp.isDarkMode ? Colors.blue.withOpacity(0.1) : Colors.blue.shade50.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tp.isDarkMode ? tp.borderColor : Colors.blue.shade100),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_open, size: 16, color: Colors.blue),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Output Folder', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue)),
                Text(
                  currentFolder,
                  style: TextStyle(fontSize: 11, color: tp.isDarkMode ? Colors.blue.shade200 : Colors.blue.shade900, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: Colors.blue,
            borderRadius: BorderRadius.circular(4),
            child: InkWell(
              onTap: _selectOutputFolder,
              borderRadius: BorderRadius.circular(4),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Text('SELECT', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Select output folder
  Future<void> _selectOutputFolder() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Select Output Folder for Story Audio',
      );

      if (result != null) {
        setState(() {
          _customOutputFolder = result;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Output folder: ${path.basename(result)}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error selecting folder: $e')),
      );
    }
  }

  Widget _buildStoryScriptSection() {
    final tp = ThemeProvider();
    return _buildSection(
      title: LocalizationService().tr('dub.story_script'),
      icon: Icons.text_snippet,
      accentColor: Colors.blue,
      children: [
        TextField(
          controller: _storyScriptController,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Enter your story script here...',
            hintStyle: TextStyle(fontSize: 12, color: tp.textTertiary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.blue, width: 1.5)),
            filled: true,
            fillColor: tp.inputBg,
            contentPadding: const EdgeInsets.all(8),
            isDense: true,
          ),
          style: TextStyle(fontSize: 12, color: tp.textPrimary),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<String>(
                value: _state.splitMode,
                decoration: InputDecoration(
                  labelText: 'Split Mode',
                  labelStyle: TextStyle(fontSize: 11, color: tp.textSecondary),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  isDense: true,
                  filled: true,
                  fillColor: tp.inputBg,
                ),
                style: TextStyle(fontSize: 12, color: tp.textPrimary),
                items: [
                  DropdownMenuItem(value: 'numbered', child: Text('Numbered', style: TextStyle(fontSize: 12, color: tp.textPrimary))),
                  DropdownMenuItem(value: 'line', child: Text('Line Breaks', style: TextStyle(fontSize: 12, color: tp.textPrimary))),
                  DropdownMenuItem(value: 'custom', child: Text('Custom', style: TextStyle(fontSize: 12, color: tp.textPrimary))),
                  DropdownMenuItem(value: 'sentences', child: Text('Sentences', style: TextStyle(fontSize: 12, color: tp.textPrimary))),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _state = _state.copyWith(splitMode: value);
                    });
                    _saveState();
                  }
                },
              ),
            ),
            if (_state.splitMode == 'custom') ...[
              const SizedBox(width: 6),
              Expanded(
                flex: 1,
                child: TextField(
                  controller: _customDelimiterController,
                  decoration: InputDecoration(
                    labelText: 'Delimiter',
                    labelStyle: TextStyle(fontSize: 11, color: tp.textSecondary),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    isDense: true,
                    filled: true,
                    fillColor: tp.inputBg,
                  ),
                  style: TextStyle(fontSize: 12, color: tp.textPrimary),
                  onChanged: (value) {
                    _state = _state.copyWith(customDelimiter: value);
                    _saveState();
                  },
                ),
              ),
            ],
            if (_state.splitMode == 'sentences') ...[
              const SizedBox(width: 6),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _sentencesPerSegmentController,
                  decoration: InputDecoration(
                    labelText: 'Per Seg',
                    labelStyle: TextStyle(fontSize: 11, color: tp.textSecondary),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    isDense: true,
                    filled: true,
                    fillColor: tp.inputBg,
                  ),
                  style: TextStyle(fontSize: 12, color: tp.textPrimary),
                  keyboardType: TextInputType.number,
                  onChanged: (value) {
                    final num = int.tryParse(value);
                    if (num != null && num > 0) {
                      setState(() {
                        _sentencesPerSegment = num;
                      });
                      print('[SPLIT] Sentences per segment set to: $num');
                    }
                  },
                ),
              ),
            ],
            const SizedBox(width: 6),
            Material(
              color: Colors.blue,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: _splitStoryScript,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.splitscreen, size: 14, color: Colors.white),
                      SizedBox(width: 4),
                      Text(LocalizationService().tr('dub.split'), style: TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildActionPromptsSection() {
    final tp = ThemeProvider();
    return _buildSection(
      title: LocalizationService().tr('dub.video_prompts'),
      icon: Icons.movie_filter,
      accentColor: Colors.orange,
      trailing: Material(
        color: Colors.orange,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: _loadActionPrompts,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.file_open, size: 12, color: Colors.white),
                SizedBox(width: 4),
                Text(LocalizationService().tr('dub.load'), style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
      children: [
        TextField(
          controller: _actionPromptsController,
          maxLines: 8,
          decoration: InputDecoration(
            hintText: 'Enter video action prompts (one per line)...',
            hintStyle: TextStyle(fontSize: 12, color: tp.textTertiary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Colors.orange, width: 1.5)),
            filled: true,
            fillColor: tp.inputBg,
            contentPadding: const EdgeInsets.all(8),
            isDense: true,
          ),
          style: TextStyle(fontSize: 12, color: tp.textPrimary),
        ),
      ],
    );
  }

  Widget _buildStoryPartsSection() {
    if (_state.parts.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildSection(
      title: '${LocalizationService().tr('dub.story_parts')} (${_state.parts.length})',
      icon: Icons.format_list_numbered,
      accentColor: Colors.deepPurple,
      trailing: Material(
        color: _isGeneratingTts ? Colors.red : Colors.green,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: _isGeneratingTts ? _stopGeneration : _generateAllTts,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_isGeneratingTts ? Icons.stop : Icons.play_arrow, size: 12, color: Colors.white),
                const SizedBox(width: 4),
                Text(_isGeneratingTts ? 'Stop' : LocalizationService().tr('dub.generate_all'), style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
      children: [
        if (_isGeneratingTts) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: _progressValue, minHeight: 3, backgroundColor: ThemeProvider().borderColor),
          ),
          const SizedBox(height: 6),
        ],
        // Total audio duration + clip estimates
        Builder(builder: (context) {
          final tp = ThemeProvider();
          final partsWithDuration = _state.parts.where((p) => p.duration != null && p.duration! > 0).toList();
          if (partsWithDuration.isEmpty) return const SizedBox.shrink();
          
          final totalDuration = partsWithDuration.fold<double>(0.0, (sum, p) => sum + p.duration!);
          final allComplete = partsWithDuration.length == _state.parts.length;
          final mins = (totalDuration / 60).floor();
          final secs = (totalDuration % 60).floor();
          final clips8s = (totalDuration / 8).ceil();
          final clips5s = (totalDuration / 5).ceil();
          
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: tp.isDarkMode ? Colors.teal.withOpacity(0.15) : Colors.teal.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tp.isDarkMode ? Colors.teal.withOpacity(0.3) : Colors.teal.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.timer, size: 18, color: Colors.teal),
                const SizedBox(width: 6),
                Text(
                  '${allComplete ? "Total" : "${partsWithDuration.length}/${_state.parts.length}"}: ${mins}m ${secs}s',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: tp.textPrimary),
                ),
                const SizedBox(width: 16),
                Icon(Icons.videocam, size: 16, color: Colors.orange),
                const SizedBox(width: 4),
                Text(
                  'VEO3 8s clips: $clips8s',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.orange.shade700),
                ),
                const SizedBox(width: 14),
                Text(
                  '5s clips: $clips5s',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.blue.shade700),
                ),
              ],
            ),
          );
        }),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _state.parts.length,
          itemBuilder: (context, index) => _buildPartCard(_state.parts[index], index),
        ),
      ],
    );
  }

  /// Show dialog to edit part text
  Future<void> _showEditPartDialog(int index) async {
    final part = _state.parts[index];
    final controller = TextEditingController(text: part.text);

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit Part ${part.index}'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Enter text...',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                _state.parts[index] = part.copyWith(
                  text: controller.text,
                  status: 'idle', // Reset status
                );
              });
              _saveState();
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Get or create a persistent controller for part voice style (prevents cursor-jump)
  TextEditingController _getPartVoiceStyleController(int index, String? currentValue) {
    if (!_partVoiceStyleControllers.containsKey(index)) {
      _partVoiceStyleControllers[index] = TextEditingController(text: currentValue ?? '');
    }
    final controller = _partVoiceStyleControllers[index]!;
    // Only update if value changed externally (e.g. Apply to All)
    if (controller.text != (currentValue ?? '')) {
      controller.text = currentValue ?? '';
    }
    return controller;
  }

  /// Get the persistent controller for global voice style
  TextEditingController _getGlobalVoiceStyleController() {
    final currentValue = _state.globalVoiceStyle ?? '';
    if (_globalVoiceStyleController.text != currentValue) {
      _globalVoiceStyleController.text = currentValue;
    }
    return _globalVoiceStyleController;
  }

  Widget _buildPartCard(StoryAudioPart part, int index) {
    final tp = ThemeProvider();
    IconData statusIcon;
    Color statusColor;

    switch (part.status) {
      case 'success':
        statusIcon = Icons.check_circle;
        statusColor = Colors.green;
        break;
      case 'generating':
        statusIcon = Icons.sync;
        statusColor = Colors.blue;
        break;
      case 'error':
        statusIcon = Icons.error;
        statusColor = Colors.red;
        break;
      default:
        statusIcon = Icons.pending;
        statusColor = tp.textTertiary;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: tp.inputBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tp.borderColor.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: statusColor, size: 16),
              const SizedBox(width: 6),
              Text('Part ${part.index}', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: tp.textPrimary)),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _showEditPartDialog(index),
                child: Icon(Icons.edit, size: 13, color: Colors.blue.shade300),
              ),
              const Spacer(),
              if (part.duration != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: statusColor.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                  child: Text('${part.duration!.toStringAsFixed(1)}s', style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: tp.scaffoldBg, borderRadius: BorderRadius.circular(6)),
            child: Text(part.text, style: TextStyle(fontSize: 11, color: tp.textPrimary, height: 1.4), maxLines: 4, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: part.voiceModel,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Voice', labelStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.borderColor)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), isDense: true, filled: true, fillColor: tp.surfaceBg,
                  ),
                  style: TextStyle(fontSize: 11, color: tp.textPrimary),
                  items: VoiceModels.all.map((voice) => DropdownMenuItem(value: voice, child: Text(voice, style: TextStyle(fontSize: 11, color: tp.textPrimary)))).toList(),
                  onChanged: (value) { if (value != null) { setState(() { _state.parts[index] = part.copyWith(voiceModel: value); }); _saveState(); } },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                flex: 2,
                child: TextField(
                  decoration: InputDecoration(
                    labelText: 'Style', labelStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.borderColor)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.borderColor)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4), isDense: true, filled: true, fillColor: tp.surfaceBg,
                  ),
                  style: TextStyle(fontSize: 11, color: tp.textPrimary),
                  controller: _getPartVoiceStyleController(index, part.voiceStyle),
                  onChanged: (value) { _state.parts[index] = part.copyWith(voiceStyle: value); _saveState(); },
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _generateSingleTts(index),
                borderRadius: BorderRadius.circular(6),
                child: Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.refresh, size: 16, color: Colors.blue)),
              ),
              if (part.audioPath != null && File(part.audioPath!).existsSync()) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: () => _playAudio(index),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: (_currentlyPlayingIndex == index && _isPlaying) ? Colors.red.withOpacity(0.1) : Colors.green.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                    child: Icon((_currentlyPlayingIndex == index && _isPlaying) ? Icons.stop : Icons.play_arrow, size: 16,
                      color: (_currentlyPlayingIndex == index && _isPlaying) ? Colors.red : Colors.green)),
                ),
              ],
            ],
          ),
          if (part.error != null) ...[
            const SizedBox(height: 4),
            Text('Error: ${part.error}', style: const TextStyle(color: Colors.red, fontSize: 10)),
          ],
        ],
      ),
    );
  }

  Widget _buildGlobalSettingsSection() {
    final tp = ThemeProvider();
    return _buildSection(
      title: LocalizationService().tr('dub.global_voice'),
      icon: Icons.record_voice_over,
      accentColor: Colors.indigo,
      trailing: Material(
        color: Colors.indigo,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: _applyGlobalSettings,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.done_all, size: 12, color: Colors.white),
                SizedBox(width: 4),
                Text(LocalizationService().tr('dub.apply_to_all'), style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _state.globalVoiceModel,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Voice', labelStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), isDense: true, filled: true, fillColor: tp.inputBg,
                ),
                style: TextStyle(fontSize: 12, color: tp.textPrimary),
                items: VoiceModels.all.map((voice) => DropdownMenuItem(value: voice, child: Text(voice, style: TextStyle(fontSize: 12, color: tp.textPrimary)))).toList(),
                onChanged: (value) { if (value != null) { setState(() { _state = _state.copyWith(globalVoiceModel: value); }); _saveState(); } },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                decoration: InputDecoration(
                  labelText: 'Style', labelStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), isDense: true, filled: true, fillColor: tp.inputBg,
                ),
                style: TextStyle(fontSize: 12, color: tp.textPrimary),
                controller: _getGlobalVoiceStyleController(),
                onChanged: (value) { _state = _state.copyWith(globalVoiceStyle: value); _saveState(); },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAlignmentSection() {
    final tp = ThemeProvider();
    return _buildSection(
      title: LocalizationService().tr('dub.alignment'),
      icon: Icons.auto_awesome,
      accentColor: Colors.purple,
      trailing: Material(
        color: _isGeneratingAlignment ? Colors.grey : Colors.purple,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: _isGeneratingAlignment ? null : _generateAlignment,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isGeneratingAlignment)
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                else
                  const Icon(Icons.auto_awesome, size: 12, color: Colors.white),
                const SizedBox(width: 4),
                Text(_isGeneratingAlignment ? 'Working...' : LocalizationService().tr('dub.match_media'), style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
      children: [
        DropdownButtonFormField<String>(
          value: _selectedAlignmentModel,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Model', labelStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: tp.borderColor)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), isDense: true, filled: true, fillColor: tp.inputBg,
          ),
          style: TextStyle(fontSize: 12, color: tp.textPrimary),
          items: [
            DropdownMenuItem(value: 'gemini-2.5-flash', child: Text('Gemini 2.5 Flash', style: TextStyle(fontSize: 12, color: tp.textPrimary))),
          ],
          onChanged: (value) { if (value != null) { setState(() { _selectedAlignmentModel = value; }); } },
        ),
        if (_state.alignmentJson != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text('Alignment JSON:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: tp.textSecondary)),
              const Spacer(),
              InkWell(
                onTap: _copyAlignmentJson,
                borderRadius: BorderRadius.circular(4),
                child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.copy, size: 14, color: tp.textSecondary)),
              ),
              const SizedBox(width: 4),
              Material(
                color: Colors.purple.withOpacity(0.15),
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: _saveAlignmentJson,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.save, size: 12, color: Colors.purple.shade300),
                        const SizedBox(width: 4),
                        Text(LocalizationService().tr('dub.save'), style: TextStyle(fontSize: 10, color: Colors.purple.shade300, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            height: 200,
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: tp.inputBg,
              border: Border.all(color: tp.borderColor),
              borderRadius: BorderRadius.circular(6),
            ),
            child: TextField(
              controller: _alignmentJsonController,
              maxLines: null,
              style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: tp.textPrimary),
              decoration: InputDecoration.collapsed(border: InputBorder.none, hintText: 'JSON...', hintStyle: TextStyle(color: tp.textTertiary)),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildVideoSection() {
    return _buildSection(
      title: LocalizationService().tr('dub.import_clips'),
      icon: Icons.video_library,
      accentColor: Colors.teal,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.deepPurple,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              onTap: _loadVideosFromProject,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.home, size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text(LocalizationService().tr('dub.from_project'), style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Material(
            color: Colors.teal,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              onTap: _loadVideos,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open, size: 12, color: Colors.white),
                    SizedBox(width: 4),
                    Text(LocalizationService().tr('dub.load_videos'), style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      children: [
        if (_state.videosPaths != null && _state.videosPaths!.isNotEmpty)
          Text(
            '✓ ${_state.videosPaths!.length} ${LocalizationService().tr('dub.videos_loaded')}',
            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600, fontSize: 12),
          )
        else
          Text('No videos loaded', style: TextStyle(color: ThemeProvider().textTertiary, fontSize: 12)),
      ],
    );
  }

  Widget _buildOutputAndExportSection() {
    final tp = ThemeProvider();
    final currentFolder = _customOutputFolder ?? 
        widget.projectService.currentProject?.projectPath ?? 
        'No folder selected';

    return _buildSection(
      title: LocalizationService().tr('dub.output_export'),
      icon: Icons.video_file,
      accentColor: Colors.green,
      children: [
        // Output folder row
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: tp.isDarkMode ? Colors.blue.withOpacity(0.08) : Colors.blue.shade50.withOpacity(0.4),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: tp.isDarkMode ? Colors.blue.withOpacity(0.15) : Colors.blue.shade100),
          ),
          child: Row(
            children: [
              const Icon(Icons.folder_open, size: 14, color: Colors.blue),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(LocalizationService().tr('dub.output_folder'), style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Colors.blue)),
                    Text(currentFolder, style: TextStyle(fontSize: 10, color: tp.isDarkMode ? Colors.blue.shade200 : Colors.blue.shade900, overflow: TextOverflow.ellipsis)),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Material(
                color: Colors.blue,
                borderRadius: BorderRadius.circular(4),
                child: InkWell(
                  onTap: _selectOutputFolder,
                  borderRadius: BorderRadius.circular(4),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text('SELECT', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Export method
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'fast', label: Text(LocalizationService().tr('dub.fast'), style: const TextStyle(fontSize: 11)), icon: const Icon(Icons.speed, size: 14)),
            ButtonSegment(value: 'precise', label: Text(LocalizationService().tr('dub.precise'), style: const TextStyle(fontSize: 11)), icon: const Icon(Icons.precision_manufacturing, size: 14)),
          ],
          selected: {_selectedExportMethod},
          onSelectionChanged: (value) { setState(() { _selectedExportMethod = value.first; }); },
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 4),
        Text(
          _selectedExportMethod == 'fast' ? 'Adjusts audio speed to match video' : 'Adjusts video speed to match audio',
          style: TextStyle(fontSize: 10, color: tp.textTertiary),
        ),
        const SizedBox(height: 8),
        // Volume Controls
        Text(LocalizationService().tr('dub.audio_mixing'), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: tp.textSecondary)),
        Row(
          children: [
            SizedBox(width: 36, child: Text('TTS:', style: TextStyle(fontSize: 11, color: tp.textSecondary))),
            Expanded(child: Slider(value: _ttsVolume, min: 0.0, max: 5.0, divisions: 50, label: '${(_ttsVolume * 100).round()}%', onChanged: (v) => setState(() => _ttsVolume = v))),
            Text('${(_ttsVolume * 100).round()}%', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: tp.textPrimary)),
          ],
        ),
        Row(
          children: [
            SizedBox(width: 36, child: Text('Video:', style: TextStyle(fontSize: 11, color: tp.textSecondary))),
            Expanded(child: Slider(value: _videoVolume, min: 0.0, max: 5.0, divisions: 50, label: '${(_videoVolume * 100).round()}%', onChanged: (v) => setState(() => _videoVolume = v))),
            Text('${(_videoVolume * 100).round()}%', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: tp.textPrimary)),
          ],
        ),
        if (_isExporting) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: _progressValue, minHeight: 3, backgroundColor: tp.borderColor),
          ),
        ],
        const SizedBox(height: 8),
        Center(
          child: Material(
            color: _isExporting ? Colors.grey : Colors.green,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: _isExporting ? null : _exportVideo,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isExporting)
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    else
                      const Icon(Icons.video_file, size: 16, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(_isExporting ? 'Exporting...' : LocalizationService().tr('dub.export_video'), style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Activity Log Panel
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0D0D0D),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade800),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header with Copy & Clear
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.terminal, size: 13, color: Colors.grey.shade400),
                    const SizedBox(width: 4),
                    Text(LocalizationService().tr('dub.activity_log'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey.shade400)),
                    const Spacer(),
                    InkWell(
                      onTap: () {
                        if (_activityLogs.isNotEmpty) {
                          final text = _activityLogs.join('\n');
                          Clipboard.setData(ClipboardData(text: text));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Copied ${_activityLogs.length} log lines'), duration: const Duration(seconds: 1)),
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy, size: 12, color: Colors.blue.shade300),
                            const SizedBox(width: 2),
                            Text(LocalizationService().tr('dub.copy_all'), style: TextStyle(fontSize: 9, color: Colors.blue.shade300, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => setState(() => _activityLogs.clear()),
                      child: Padding(
                        padding: const EdgeInsets.all(2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.delete_sweep, size: 12, color: Colors.red.shade300),
                            const SizedBox(width: 2),
                            Text(LocalizationService().tr('dub.clear'), style: TextStyle(fontSize: 9, color: Colors.red.shade300, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Log content
              SizedBox(
                height: 200,
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent || event is KeyRepeatEvent) {
                      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                        _logScrollController.animateTo(
                          (_logScrollController.offset + 40).clamp(0, _logScrollController.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 50), curve: Curves.linear,
                        );
                        return KeyEventResult.handled;
                      } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                        _logScrollController.animateTo(
                          (_logScrollController.offset - 40).clamp(0, _logScrollController.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 50), curve: Curves.linear,
                        );
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: _activityLogs.isEmpty
                    ? Center(child: Text(LocalizationService().tr('dub.logs_hint'), style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontStyle: FontStyle.italic)))
                    : ListView.builder(
                        controller: _logScrollController,
                        padding: const EdgeInsets.all(6),
                        itemCount: _activityLogs.length,
                        itemBuilder: (context, index) {
                          final log = _activityLogs[index];
                          Color logColor = Colors.grey.shade500;
                          if (log.contains('Error') || log.contains('failed') || log.contains('✗')) {
                            logColor = Colors.red.shade400;
                          } else if (log.contains('✓') || log.contains('Success') || log.contains('Complete')) {
                            logColor = Colors.green.shade400;
                          } else if (log.contains('[TTS]')) {
                            logColor = Colors.cyan.shade400;
                          } else if (log.contains('[EXPORT]') || log.contains('[FFmpeg]')) {
                            logColor = Colors.orange.shade400;
                          }
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 1),
                            child: Text(
                              log,
                              style: TextStyle(
                                fontSize: 10,
                                fontFamily: 'Consolas',
                                color: logColor,
                                height: 1.3,
                              ),
                            ),
                          );
                        },
                      ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStatusSection() {
    final tp = ThemeProvider();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(tp.isDarkMode ? 0.1 : 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info, color: Colors.blue, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(_statusMessage, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 11, color: tp.textPrimary))),
        ],
      ),
    );
  }
  Future<void> _cancelReelTask(int projectIndex) async {
     final project = _reelProjects[projectIndex];
     final projectId = project['id'];
     final taskId = 'reel_task_$projectId';
     
     print('[REEL] Cancelling task: $taskId');
     
     // Cancel the task in the bulk executor
     _bulkExecutor.cancelTask(taskId);
     
     // Update UI status
     setState(() {
        project['status'] = 'cancelled';
        _state = _state.copyWith(reelProjects: _reelProjects);
     });
     _saveState();
     
     print('[REEL] Task cancelled and state updated');
  }

  Future<void> _restartReelVideo(int projectIndex) async {
     final project = _reelProjects[projectIndex];
     final content = project['content'] as List;
     
     // Clear existing videos
     for (var part in content) {
        if (part['visuals'] != null) {
           for (var v in part['visuals']) {
              v['video_path'] = null;
              v['download_url'] = null;
              v['file_size'] = null;
           }
        }
     }
     
     setState(() {
         _state = _state.copyWith(reelProjects: _reelProjects);
     });
     _saveState();
     await _generateReelVideo(projectIndex);
  }
  // --- Template Creator ---
  
  void _showTemplateCreatorDialog() {
     final nameCtrl = TextEditingController();
     final storyCtrl = TextEditingController();
     final instructionCtrl = TextEditingController();
     final youtubeUrlCtrl = TextEditingController(); // New
     final systemPromptCtrl = TextEditingController(); // Filled by analysis
     
     bool isAnalyzing = false;
     
     showDialog(
        context: context,
        builder: (context) {
           return StatefulBuilder(
              builder: (ctx, setDialogState) {
                 return AlertDialog(
                    title: const Text("Create New Reel Template"),
                    content: SizedBox(
                       width: 700,
                       height: 650,
                       child: Column(
                          children: [
                             TextField(
                                controller: nameCtrl,
                                decoration: const InputDecoration(labelText: "Template Name", border: OutlineInputBorder()),
                             ),
                             const SizedBox(height: 16),
                             Expanded(
                                child: DefaultTabController(
                                   length: 3, 
                                   child: Builder(
                                      builder: (tabCtx) {
                                         return Column(
                                            children: [
                                               const TabBar(
                                                  labelColor: Colors.blue,
                                                  unselectedLabelColor: Colors.grey,
                                                  tabs: [
                                                     Tab(text: "Auto-Analyze Style"), 
                                                     Tab(text: "YouTube Analyze"),
                                                     Tab(text: "Manual Prompt")
                                                  ],
                                               ),
                                               Expanded(
                                                  child: TabBarView(
                                                     children: [
                                                        // Tab 1: Auto Analyze (Text)
                                                        Padding(
                                                           padding: const EdgeInsets.all(8.0),
                                                           child: Column(
                                                              children: [
                                                                 const Text("Paste an example story/script and specific constraints. Gemini will generate the System Prompt for you.", style: TextStyle(fontSize: 12, color: Colors.grey)),
                                                                 const SizedBox(height: 8),
                                                                 Expanded(
                                                                    child: TextField(
                                                                       controller: storyCtrl,
                                                                       decoration: const InputDecoration(labelText: "Example Story / Script", border: OutlineInputBorder(), alignLabelWithHint: true),
                                                                       maxLines: 8,
                                                                    ),
                                                                 ),
                                                                 const SizedBox(height: 8),
                                                                 TextField(
                                                                    controller: instructionCtrl,
                                                                    decoration: const InputDecoration(labelText: "Visual/Duration Instructions", border: OutlineInputBorder()),
                                                                 ),
                                                                 const SizedBox(height: 16),
                                                                 ElevatedButton.icon(
                                                                    onPressed: isAnalyzing ? null : () async {
                                                                       if (storyCtrl.text.isEmpty && instructionCtrl.text.isEmpty) return;
                                                                       
                                                                       setDialogState(() => isAnalyzing = true);
                                                                       try {
                                                                          final result = await _alignmentService.generateTemplateFromExample(
                                                                             model: 'gemini-2.5-flash',
                                                                             exampleStory: storyCtrl.text,
                                                                             additionalInstructions: instructionCtrl.text,
                                                                          );
                                                                          setDialogState(() {
                                                                             systemPromptCtrl.text = result;
                                                                             isAnalyzing = false;
                                                                          });
                                                                          // Use tabCtx to find DefaultTabController
                                                                          DefaultTabController.of(tabCtx).animateTo(2); 
                                                                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Template Analyzed!")));
                                                                       } catch (e) {
                                                                          setDialogState(() => isAnalyzing = false);
                                                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                                                                       }
                                                                    },
                                                                    icon: isAnalyzing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_fix_high),
                                                                    label: const Text("Analyze & Generate Prompt"),
                                                                 ),
                                                              ],
                                                           ),
                                                        ),
                                                        
                                                        // Tab 2: YouTube Analyze
                                                        Padding(
                                                           padding: const EdgeInsets.all(8.0),
                                                           child: Column(
                                                              children: [
                                                                 const Text("Paste a YouTube link. We'll extract the title, description, and transcript (if available) to analyze the style.", style: TextStyle(fontSize: 12, color: Colors.grey)),
                                                                 const SizedBox(height: 16),
                                                                 TextField(
                                                                    controller: youtubeUrlCtrl,
                                                                    decoration: const InputDecoration(labelText: "YouTube Video URL", border: OutlineInputBorder(), prefixIcon: Icon(Icons.link)),
                                                                 ),
                                                                 const SizedBox(height: 8),
                                                                 TextField(
                                                                    controller: instructionCtrl,
                                                                    decoration: const InputDecoration(labelText: "Additional Instructions (optional)", border: OutlineInputBorder()),
                                                                 ),
                                                                 const SizedBox(height: 16),
                                                                 ElevatedButton.icon(
                                                                    onPressed: isAnalyzing ? null : () async {
                                                                       if (youtubeUrlCtrl.text.isEmpty) return;
                                                                       
                                                                       setDialogState(() => isAnalyzing = true);
                                                                       try {
                                                                          final result = await _alignmentService.generateTemplateFromYoutube(
                                                                             model: 'gemini-2.5-flash',
                                                                             youtubeUrl: youtubeUrlCtrl.text,
                                                                             additionalInstructions: instructionCtrl.text,
                                                                          );
                                                                          setDialogState(() {
                                                                             systemPromptCtrl.text = result;
                                                                             isAnalyzing = false;
                                                                          });
                                                                          // Use tabCtx to find DefaultTabController
                                                                          DefaultTabController.of(tabCtx).animateTo(2); 
                                                                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("YouTube Video Analyzed!")));
                                                                       } catch (e) {
                                                                          setDialogState(() => isAnalyzing = false);
                                                                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e")));
                                                                       }
                                                                    },
                                                                    icon: isAnalyzing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.video_library),
                                                                    label: const Text("Analyze YouTube Video"),
                                                                 ),
                                                              ],
                                                           ),
                                                        ),
                                                        
                                                        // Tab 3: Manual / Result
                                                        Padding(
                                                           padding: const EdgeInsets.all(8.0),
                                                           child: Column(
                                                              children: [
                                                                 const Text("This is the actual System Prompt. Edit carefully.", style: TextStyle(fontSize: 12, color: Colors.grey)),
                                                                 const SizedBox(height: 8),
                                                                 Expanded(
                                                                    child: TextField(
                                                                       controller: systemPromptCtrl,
                                                                       decoration: const InputDecoration(border: OutlineInputBorder(), hintText: "System Prompt..."),
                                                                       maxLines: null,
                                                                       expands: true,
                                                                       style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
                                                                    ),
                                                                 ),
                                                              ],
                                                           ),
                                                        ),
                                                     ],
                                                  ),
                                               ),
                                            ],
                                         );
                                      }
                                   ),
                                ),
                             ),
                          ],
                       ),
                    ),
                    actions: [
                       TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
                       ElevatedButton(
                          onPressed: () {
                             if (nameCtrl.text.isEmpty || systemPromptCtrl.text.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Name and Prompt are required")));
                                return;
                             }
                             
                             final newTemplate = ReelTemplate(
                                id: DateTime.now().millisecondsSinceEpoch.toString(),
                                name: nameCtrl.text,
                                systemPrompt: systemPromptCtrl.text,
                             );
                             
                             setState(() {
                                final updatedTemplates = List<ReelTemplate>.from(_state.reelTemplates)..add(newTemplate);
                                _state = _state.copyWith(
                                    reelTemplates: updatedTemplates,
                                    selectedReelTemplateId: newTemplate.id
                                );
                             });
                             _saveState();
                             Navigator.pop(context);
                          },
                          child: const Text("Save Template"),
                       ),
                    ],
                 );
              },
           );
        },
     );
  }

  Future<void> _exportTemplate() async {
     final templateId = _state.selectedReelTemplateId;
     if (templateId == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No custom template selected")));
        return;
     }

     final template = _state.reelTemplates.firstWhere((t) => t.id == templateId, orElse: () => ReelTemplate(id: '', name: '', systemPrompt: ''));
     if (template.id.isEmpty) return;

     try {
       // Just save to Downloads or App Dir for simplicity if file_picker too complex for now,
       // but file_picker is better. I'll assume I can't easily add it via multi_replace if imports missing.
       // ACTUALLY, I can't guarantee `file_picker` import is present at top.
       // I'll use `_projectService` path or `_customOutputFolder` if available, else standard Location.
       
       final dir = _customOutputFolder ?? widget.projectService.currentProject?.projectPath ?? Directory.current.path;
       final path = '$dir/${template.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')}_template.json';
       final file = File(path);
       await file.writeAsString(jsonEncode(template.toJson()));
       
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Exported to: $path")));
       // Open folder
       Process.run('explorer', ['/select,', path]); // Windows specific selection
       
     } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Export failed: $e")));
     }
  }

  Future<void> _importTemplate() async {
     try {
        final result = await FilePicker.platform.pickFiles(
           type: FileType.custom,
           allowedExtensions: ['json'],
        );
        
        if (result != null && result.files.single.path != null) {
           final file = File(result.files.single.path!);
           final jsonStr = await file.readAsString();
           final json = jsonDecode(jsonStr);
           
           final newTemplate = ReelTemplate.fromJson(json);
           // Generate new ID to avoid conflict? Or keep?
           // Better generate new ID to be safe
           final importedTemplate = ReelTemplate(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: '${newTemplate.name} (Imported)',
              systemPrompt: newTemplate.systemPrompt
           );
           
           setState(() {
              final updatedTemplates = List<ReelTemplate>.from(_state.reelTemplates)..add(importedTemplate);
              _state = _state.copyWith(
                 reelTemplates: updatedTemplates,
                 selectedReelTemplateId: importedTemplate.id
              );
           });
           _saveState();
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Template Imported!")));
        }
     } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Import failed: $e")));
     }
  }

  void _deleteAllData() {
    _showDeleteConfirmationDialog();
  }

  void _showDeleteConfirmationDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete All Data'),
          content: const Text(
            'Are you sure you want to delete all generated data and reset the project? This action cannot be undone.',
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Delete'),
              onPressed: () {
                Navigator.of(context).pop();
                // Add your delete logic here
                setState(() {
                   // _state.reelProjects.clear();
                   // _state.reelTemplates.clear();
                   // _saveState();
                });
              },
            ),
          ],
        );
      },
    );
  }

  /// Regenerate a single visual scene within a reel
  Future<void> _regenerateSingleVisual(int reelIndex, int partIndex, int visualIndex) async {
    if (reelIndex >= _reelProjects.length) return;
    
    final project = _reelProjects[reelIndex];
    final content = project['content'] as List?;
    if (content == null || partIndex >= content.length) return;
    
    final part = content[partIndex];
    final visuals = part['visuals'] as List?;
    if (visuals == null || visualIndex >= visuals.length) return;
    
    final visual = visuals[visualIndex];
    final prompt = visual['prompt'] as String?;
    if (prompt == null || prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No prompt found for this visual'))
      );
      return;
    }
    
    // Clear the video for this visual and set generating status
    setState(() {
      visual['video_path'] = null;
      visual['gen_status'] = 'generating';
      _state = _state.copyWith(reelProjects: _reelProjects);
    });
    _saveState();
    
    // Create scene ID and register in visualIdMap for live updates
    final sceneId = DateTime.now().millisecondsSinceEpoch;
    _visualIdMap[sceneId] = visual;
    
    print('[REGENERATE] Starting Visual ${partIndex + 1}.${visualIndex + 1}...');
    
    // Get the same output folder as main generation: reels/reelName/videoclips/
    final reelPaths = await _getReelPaths(project);
    final videoDir = reelPaths['videoclips']!.path;
    
    // Create a single-scene task for just this visual
    final scene = SceneData(
      sceneId: sceneId,
      prompt: prompt,
      status: 'queued',
    );
    
    // Use same task ID format as main generation so callback can find it
    final taskId = 'reel_task_${project['id']}';
    
    final task = BulkTask(
      id: 'regen_${sceneId}', // Unique ID for this regen
      name: (project['name'] as String? ?? 'Untitled_Reel'), // Use reel name
      scenes: [scene],
      profile: 'Default',
      model: _reelVideoModel,
      aspectRatio: project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT',
      outputFolder: videoDir, // Use videoclips folder
      scheduleType: TaskScheduleType.immediate,
    );
    
    print('[REGENERATE] Video will be saved to: $videoDir');
    
    // Execute the task - the _onReelTaskUpdate callback will handle updates
    try {
      await _bulkExecutor.startTask(task);
      
      // The callback should have updated visual['video_path'] already
      // But let's verify and update UI
      if (scene.videoPath != null && await File(scene.videoPath!).exists()) {
        setState(() {
          visual['video_path'] = scene.videoPath;
          visual['gen_status'] = 'completed';
          _state = _state.copyWith(reelProjects: _reelProjects);
        });
        _saveState();
        
        // No snackbar here - parent function shows completion message
        print('[REGENERATE] ✓ Visual ${partIndex + 1}.${visualIndex + 1} completed');
      } else if (visual['video_path'] != null) {
        // Callback already set the path
        setState(() {
          visual['gen_status'] = 'completed';
          _state = _state.copyWith(reelProjects: _reelProjects);
        });
        _saveState();
        
        // No snackbar here - parent function shows completion message
        print('[REGENERATE] ✓ Visual ${partIndex + 1}.${visualIndex + 1} completed (via callback)');
      } else {
        print('[REGENERATE] Video not found. Scene videoPath: ${scene.videoPath}');
        
        setState(() {
          visual['gen_status'] = 'failed';
          visual['gen_error'] = scene.error ?? 'Video file not found after generation';
          _state = _state.copyWith(reelProjects: _reelProjects);
        });
        _saveState();
        
        // Only show error snackbar
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✗ Visual ${partIndex + 1}.${visualIndex + 1} failed'),
            backgroundColor: Colors.red,
          )
        );
      }
    } catch (e) {
      print('[REGENERATE] Error: $e');
      setState(() {
        visual['gen_status'] = 'failed';
        visual['gen_error'] = e.toString();
        _state = _state.copyWith(reelProjects: _reelProjects);
      });
      _saveState();
      
      // Show error snackbar
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✗ Regeneration error: ${e.toString().substring(0, min(50, e.toString().length))}...'),
          backgroundColor: Colors.red,
        )
      );
    }
  }

  /// Regenerate all failed or missing videos in a reel using bulk task executor
  Future<void> _regenerateFailedVideos(int reelIndex) async {
    if (reelIndex >= _reelProjects.length) return;
    if (_isRegeneratingMissing) return; // Already running
    
    final project = _reelProjects[reelIndex];
    final content = project['content'] as List?;
    if (content == null) return;
    
    // Find all visuals that need regeneration (missing or failed)
    final scenesToGen = <SceneData>[];
    
    for (int partIdx = 0; partIdx < content.length; partIdx++) {
      final part = content[partIdx];
      final visuals = part['visuals'] as List?;
      if (visuals == null) continue;
      
      for (int visualIdx = 0; visualIdx < visuals.length; visualIdx++) {
        final visual = visuals[visualIdx];
        final hasVideo = visual['video_path'] != null;
        final isFailed = visual['gen_status'] == 'failed';
        
        if (visual['active'] != false && (!hasVideo || isFailed)) {
          final prompt = visual['prompt'] as String?;
          if (prompt == null || prompt.isEmpty) continue;
          
          // Create unique scene ID and register in visualIdMap
          final sceneId = DateTime.now().millisecondsSinceEpoch + partIdx * 1000 + visualIdx;
          _visualIdMap[sceneId] = visual;
          
          // Clear old video path and set generating status
          visual['video_path'] = null;
          visual['gen_status'] = 'queued';
          
          scenesToGen.add(SceneData(
            sceneId: sceneId,
            prompt: prompt,
            status: 'queued',
          ));
        }
      }
    }
    
    if (scenesToGen.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No failed or missing videos to regenerate'))
      );
      return;
    }
    
    // Confirm with user
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Regenerate Failed Videos'),
        content: Text('Regenerate ${scenesToGen.length} failed/missing videos concurrently?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Regenerate'),
          ),
        ],
      ),
    );
    
    if (confirm != true) return;
    
    // Set flag to disable button
    setState(() {
      _isRegeneratingMissing = true;
      _state = _state.copyWith(reelProjects: _reelProjects);
    });
    _saveState();
    
    // Get output folder
    final reelPaths = await _getReelPaths(project);
    final videoDir = reelPaths['videoclips']!.path;
    
    // Create bulk task with all missing scenes
    final projectId = project['id'];
    final task = BulkTask(
      id: 'regen_batch_$projectId', // Unique ID for this regen batch
      name: '${project['name'] ?? 'Reel'} - Regen ${scenesToGen.length}',
      scenes: scenesToGen,
      profile: 'Default',
      model: _reelVideoModel,
      aspectRatio: project['aspect_ratio'] ?? 'VIDEO_ASPECT_RATIO_PORTRAIT',
      outputFolder: videoDir,
      scheduleType: TaskScheduleType.immediate,
    );
    
    print('[REGEN] Starting bulk regeneration of ${scenesToGen.length} scenes');
    print('[REGEN] Model: $_reelVideoModel, Output: $videoDir');
    
    // Show starting message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Starting regeneration of ${scenesToGen.length} videos...'),
        duration: const Duration(seconds: 2),
      )
    );
    
    try {
      // Execute using bulk executor - will use proper concurrency (4 for relaxed, 20 for others)
      await _bulkExecutor.startTask(task);
      
      // Update final status
      if (mounted) {
        setState(() {
          _isRegeneratingMissing = false;
          _state = _state.copyWith(reelProjects: _reelProjects);
        });
        _saveState();
        
        final completed = scenesToGen.where((s) => s.status == 'completed').length;
        final failed = scenesToGen.where((s) => s.status == 'failed').length;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Regen complete: $completed succeeded, $failed failed'),
            backgroundColor: failed > 0 ? Colors.orange : Colors.green,
            duration: const Duration(seconds: 3),
          )
        );
      }
    } catch (e) {
      print('[REGEN] Error: $e');
      if (mounted) {
        setState(() => _isRegeneratingMissing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Regeneration error: $e'),
            backgroundColor: Colors.red,
          )
        );
      }
    }
  }

  /// Helper to build compact status chips for progress display
  Widget _buildStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5), width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildMinimalDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    final tp = ThemeProvider();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tp.borderColor),
        color: tp.inputBg,
      ),
      height: 28,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          isDense: true,
          style: TextStyle(fontSize: 12, color: tp.textPrimary),
          icon: Icon(Icons.keyboard_arrow_down, size: 16, color: tp.textTertiary),
          focusColor: Colors.transparent,
          dropdownColor: tp.surfaceBg,
        ),
      ),
    );
  }

  Widget _buildMinimalActionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
  }) {
    final tp = ThemeProvider();
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        foregroundColor: tp.isDarkMode ? tp.textSecondary : Colors.blueGrey.shade700,
        side: BorderSide(color: tp.borderColor),
        padding: const EdgeInsets.symmetric(vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
