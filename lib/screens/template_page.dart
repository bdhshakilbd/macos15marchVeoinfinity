/// Story Prompt Processor - Internal Version for Main App
/// Two tabs: 1) Create Story 2) Generate Videos

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/theme_provider.dart';
import '../services/localization_service.dart';
import '../services/flow_image_generation_service.dart';
import '../models/character_studio/image_model_config.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:url_launcher/url_launcher.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/browser_utils.dart';
import '../services/veo3_for_template_page.dart';
import '../services/gemini_api_service.dart';
import '../services/video_generation_service.dart';
import '../services/profile_manager_service.dart';
import '../utils/config.dart';
import '../services/multi_profile_login_service.dart';
import '../models/scene_data.dart';
import 'package:file_picker/file_picker.dart';
import '../utils/ffmpeg_utils.dart';

// Removed main() and MaterialApp - this is now embeddable

// ============================================================================
// MODELS
// ============================================================================

class _PromptInputField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;

  const _PromptInputField({
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<_PromptInputField> createState() => _PromptInputFieldState();
}

class _PromptInputFieldState extends State<_PromptInputField> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void didUpdateWidget(covariant _PromptInputField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the value changed externally (not by typing in this controller), update it.
    // But since the parent rebuilds with the same value we just typed, we shouldn't reset it 
    // to avoid losing cursor. We check if text is different.
    if (widget.initialValue != _controller.text) {
      // Logic: Only update if strictly necessary. 
      // In this specific app flow, frame.prompt is updated via onChanged.
      // So widget.initialValue will be equal to _controller.text.
      // Thus, this block won't execute, and cursor is preserved.
      // If we *did* want to support external updates (e.g. cloud sync), we'd need more logic.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      maxLines: 3,
      style: const TextStyle(fontSize: 10, height: 1.3),
      decoration: InputDecoration(
        hintText: 'Enter prompt...',
        hintStyle: TextStyle(fontSize: 10, color: Colors.grey.shade400),
        contentPadding: const EdgeInsets.all(8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
        isDense: true,
      ),
      controller: _controller,
      onChanged: widget.onChanged,
    );
  }
}
class StoryProject {
  final String title;
  final VisualStyle visualStyle;
  final List<Character> characters;
  final Map<String, String> sizeIndexMap;
  final List<Location> locations;
  final List<StoryFrame> frames;
  final List<VideoClip> videoClips;

  StoryProject({required this.title, required this.visualStyle, required this.characters,
    required this.sizeIndexMap, required this.locations, required this.frames, required this.videoClips});

  factory StoryProject.fromJson(Map<String, dynamic> json) {
    final story = json['story'] as Map<String, dynamic>? ?? json;
    
    // Parse characters - handle both object array and string array formats
    List<Character> parseCharacters(dynamic charData) {
      if (charData == null) return [];
      if (charData is! List) return [];
      
      return charData.map((c) {
        if (c is Map<String, dynamic>) {
          // Detailed object format: {id, name, description, ...}
          return Character.fromJson(c);
        } else if (c is String) {
          // Simple string format: "Name: Description"
          final colonIdx = c.indexOf(':');
          if (colonIdx > 0) {
            final name = c.substring(0, colonIdx).trim();
            final desc = c.substring(colonIdx + 1).trim();
            final id = 'char_${name.toLowerCase().replaceAll(' ', '_').replaceAll(RegExp(r'[^a-z0-9_]'), '')}';
            return Character(id: id, name: name, description: desc, sizeIndex: 5, sizeReference: '');
          } else {
            return Character(id: 'char_${c.toLowerCase().replaceAll(' ', '_')}', name: c, description: c, sizeIndex: 5, sizeReference: '');
          }
        }
        return Character(id: '', name: '', description: '', sizeIndex: 5, sizeReference: '');
      }).toList();
    }
    
    // Parse locations - handle both object array and string array formats
    List<Location> parseLocations(dynamic locData) {
      if (locData == null) return [];
      if (locData is! List) return [];
      
      return locData.map((l) {
        if (l is Map<String, dynamic>) {
          // Detailed object format: {id, name, description}
          return Location.fromJson(l);
        } else if (l is String) {
          // Simple string format: "Name: Description"
          final colonIdx = l.indexOf(':');
          if (colonIdx > 0) {
            final name = l.substring(0, colonIdx).trim();
            final desc = l.substring(colonIdx + 1).trim();
            final id = 'loc_${name.toLowerCase().replaceAll(' ', '_').replaceAll(RegExp(r'[^a-z0-9_]'), '')}';
            return Location(id: id, name: name, description: desc);
          } else {
            return Location(id: 'loc_${l.toLowerCase().replaceAll(' ', '_')}', name: l, description: l);
          }
        }
        return Location(id: '', name: '', description: '');
      }).toList();
    }
    
    return StoryProject(
      title: story['title'] ?? 'Untitled',
      visualStyle: VisualStyle.fromJson(story['visual_style'] ?? {}),
      characters: parseCharacters(story['characters']),
      sizeIndexMap: (story['size_index_map'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
      locations: parseLocations(story['locations']),
      frames: (json['frames'] as List?)?.map((f) => StoryFrame.fromJson(f)).toList() ?? [],
      videoClips: (json['video_clips'] as List?)?.map((v) => VideoClip.fromJson(v)).toList() ?? [],
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'story': {
        'title': title,
        'visual_style': visualStyle.toJson(),
        'characters': characters.map((c) => c.toJson()).toList(),
        'size_index_map': sizeIndexMap,
        'locations': locations.map((l) => l.toJson()).toList(),
      },
      'frames': frames.map((f) => f.toJson()).toList(),
      'video_clips': videoClips.map((v) => v.toJson()).toList(),
    };
  }

  /// Factory to convert ANY array of JSON objects to StoryProject
  /// Each prompt = 1 frame. Auto-reuse pattern: 1,2 generate, then odd skip/even generate
  /// @param autoReuse - when true, applies the alternating reuse pattern
  factory StoryProject.fromSimplePromptArray(List<dynamic> prompts, {bool autoReuse = true}) {
    final frames = <StoryFrame>[];
    final clips = <VideoClip>[];
    
    for (int i = 0; i < prompts.length; i++) {
      final p = prompts[i] as Map<String, dynamic>;
      final promptIndex = i + 1; // 1-based index
      final frameId = 'frame_${promptIndex.toString().padLeft(3, '0')}';
      
      // Build prompt by concatenating ALL string values from the object
      final promptParts = <String>[];
      int durationSec = 8; // default
      
      for (final entry in p.entries) {
        final key = entry.key.toLowerCase();
        final value = entry.value;
        
        // Skip certain keys
        if (key.contains('duration') && value is String) {
          final match = RegExp(r'(\d+)').firstMatch(value);
          if (match != null) durationSec = int.tryParse(match.group(1)!) ?? 8;
          continue;
        }
        // Skip these attributes (already in prompt or not needed)
        if (key.contains('aspect') || 
            key.contains('negative') || 
            key == 'id' || 
            key.contains('char_in_this_scene') ||
            key.contains('characters_in_scene')) continue;
        
        // Add strings to prompt
        if (value is String && value.isNotEmpty) {
          promptParts.add(value);
        } else if (value is List) {
          for (final item in value) {
            if (item is String && item.isNotEmpty) promptParts.add(item);
          }
        }
      }
      
      final fullPrompt = promptParts.join('\n\n');
      
      // Determine if this frame should be generated or reused
      // Pattern when autoReuse is ON:
      //   ID 1: Generate (first frame)
      //   ID 2: Generate (second frame)
      //   ID 3: Skip/Reuse from ID 2
      //   ID 4: Generate
      //   ID 5: Skip/Reuse from ID 4
      //   ID 6: Generate
      //   ... (odd >= 3 skip, even >= 4 generate)
      
      bool shouldGenerate;
      String? reuseFrom;
      
      if (autoReuse) {
        if (promptIndex == 1 || promptIndex == 2) {
          shouldGenerate = true;
        } else if (promptIndex % 2 == 1) {
          // Odd index >= 3: Skip, reuse from previous (which is even)
          shouldGenerate = false;
          reuseFrom = 'frame_${(promptIndex - 1).toString().padLeft(3, '0')}';
        } else {
          // Even index >= 4: Generate
          shouldGenerate = true;
        }
      } else {
        // No auto-reuse: generate all frames
        shouldGenerate = true;
      }
      
      frames.add(StoryFrame(
        frameId: frameId,
        videoClipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        framePosition: 'single',
        locationId: '',
        charactersInScene: [],
        prompt: fullPrompt,
        camera: '',
        generateImage: shouldGenerate,
        reuseFrame: reuseFrom,
        notes: shouldGenerate ? null : 'AUTO-REUSE: Uses image from $reuseFrom',
      ));
      
      // Create video clip (each prompt is one clip)
      // Clip uses current frame as both first and last
      // When generating video, the auto-reuse toggle handles using previous frame
      clips.add(VideoClip(
        clipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        firstFrame: frameId,
        lastFrame: frameId,
        durationSeconds: durationSec,
        veo3Prompt: fullPrompt,
        audioDescription: '',
      ));
    }
    
    // Count stats
    final generateCount = frames.where((f) => f.generateImage).length;
    final reuseCount = frames.where((f) => !f.generateImage).length;
    
    return StoryProject(
      title: 'Prompt Array (${frames.length} prompts, $generateCount generate, $reuseCount reuse)',
      visualStyle: VisualStyle(
        artStyle: 'Cinematic',
        colorPalette: 'Cinematic',
        lighting: 'Volumetric lighting',
        aspectRatio: '16:9',
        quality: '8K, ultra-detailed',
      ),
      characters: [],
      sizeIndexMap: {},
      locations: [],
      frames: frames,
      videoClips: clips,
    );
  }

  /// Factory to convert plain text prompts (one prompt per line) to StoryProject
  /// Supports format: [MM:SS - MM:SS] Prompt text here...
  /// Each non-empty line becomes one frame/video clip
  factory StoryProject.fromPlainTextPrompts(String text, {bool autoReuse = true}) {
    final frames = <StoryFrame>[];
    final clips = <VideoClip>[];
    
    // Split by newlines, filter empty lines
    final lines = text.split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    
    // Regex to extract timestamp: [00:00 - 00:08] or [00:00-00:08]
    final timestampRegex = RegExp(r'^\[(\d+):(\d+)\s*-\s*(\d+):(\d+)\]\s*');
    
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final promptIndex = i + 1; // 1-based index
      final frameId = 'frame_${promptIndex.toString().padLeft(3, '0')}';
      
      String promptText = line;
      int durationSec = 8; // default
      
      // Try to extract timestamp and calculate duration
      final match = timestampRegex.firstMatch(line);
      if (match != null) {
        final startMin = int.parse(match.group(1)!);
        final startSec = int.parse(match.group(2)!);
        final endMin = int.parse(match.group(3)!);
        final endSec = int.parse(match.group(4)!);
        
        final startTotal = startMin * 60 + startSec;
        final endTotal = endMin * 60 + endSec;
        durationSec = (endTotal - startTotal).clamp(5, 60);
        
        // Remove timestamp from prompt
        promptText = line.substring(match.end).trim();
      }
      
      // Determine if this frame should be generated or reused
      // Same pattern as JSON parser
      bool shouldGenerate;
      String? reuseFrom;
      
      if (autoReuse) {
        if (promptIndex == 1 || promptIndex == 2) {
          shouldGenerate = true;
        } else if (promptIndex % 2 == 1) {
          shouldGenerate = false;
          reuseFrom = 'frame_${(promptIndex - 1).toString().padLeft(3, '0')}';
        } else {
          shouldGenerate = true;
        }
      } else {
        shouldGenerate = true;
      }
      
      frames.add(StoryFrame(
        frameId: frameId,
        videoClipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        framePosition: 'single',
        locationId: '',
        charactersInScene: [],
        prompt: promptText,
        camera: '',
        generateImage: shouldGenerate,
        reuseFrame: reuseFrom,
        notes: shouldGenerate ? null : 'AUTO-REUSE: Uses image from $reuseFrom',
      ));
      
      // Create video clip
      clips.add(VideoClip(
        clipId: 'video_${promptIndex.toString().padLeft(3, '0')}',
        firstFrame: frameId,
        lastFrame: frameId,
        durationSeconds: durationSec,
        veo3Prompt: promptText,
        audioDescription: '',
      ));
    }
    
    final generateCount = frames.where((f) => f.generateImage).length;
    final reuseCount = frames.where((f) => !f.generateImage).length;
    
    return StoryProject(
      title: 'Text Prompts (${frames.length} prompts, $generateCount generate, $reuseCount reuse)',
      visualStyle: VisualStyle(
        artStyle: 'Hyper-realistic 3D cinematic',
        colorPalette: 'Cinematic',
        lighting: 'Volumetric lighting',
        aspectRatio: '16:9',
        quality: '8K, ultra-detailed',
      ),
      characters: [],
      sizeIndexMap: {},
      locations: [],
      frames: frames,
      videoClips: clips,
    );
  }

  Character? getCharacterById(String id) => characters.where((c) => c.id == id).firstOrNull;
  Location? getLocationById(String id) => locations.where((l) => l.id == id || l.name == id).firstOrNull;
  StoryFrame? getFrameById(String id) => frames.where((f) => f.frameId == id).firstOrNull;
  String getSizeDescription(int idx) => sizeIndexMap[idx.toString()] ?? 'unknown';
}

class VisualStyle {
  final String artStyle, colorPalette, lighting, aspectRatio, quality;
  VisualStyle({required this.artStyle, required this.colorPalette, required this.lighting, 
    required this.aspectRatio, required this.quality});
  factory VisualStyle.fromJson(Map<String, dynamic> json) => VisualStyle(
    artStyle: json['art_style'] ?? '', colorPalette: json['color_palette'] ?? '',
    lighting: json['lighting'] ?? '', aspectRatio: json['aspect_ratio'] ?? '16:9', quality: json['quality'] ?? '');
  String toPromptString() => [artStyle, colorPalette, lighting, quality].where((s) => s.isNotEmpty).join('. ');
  Map<String, dynamic> toJson() => {
    'art_style': artStyle,
    'color_palette': colorPalette,
    'lighting': lighting,
    'aspect_ratio': aspectRatio,
    'quality': quality,
  };
}

class Character {
  final String id, name, description, sizeReference;
  final int sizeIndex;
  Character({required this.id, required this.name, required this.description, required this.sizeIndex, required this.sizeReference});
  factory Character.fromJson(Map<String, dynamic> json) => Character(
    id: json['id'] ?? '', name: json['name'] ?? '', description: json['description'] ?? '',
    sizeIndex: json['size_index'] ?? 5, sizeReference: json['size_reference'] ?? '');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'size_index': sizeIndex,
    'size_reference': sizeReference,
  };
}

class Location {
  final String id, name, description;
  Location({required this.id, required this.name, required this.description});
  factory Location.fromJson(Map<String, dynamic> json) => Location(
    id: json['id'] ?? '', name: json['name'] ?? '', description: json['description'] ?? '');
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
  };
}

class StoryFrame {
  final String frameId, videoClipId, framePosition, locationId;
  final List<String> charactersInScene;
  String? prompt; // Made non-final for editing
  final String? camera, refImage, reuseFrame, notes;
  final bool generateImage;
  final int? timestampStart, timestampEnd;
  String? generatedImagePath, processedPrompt, error;
  bool isGenerating = false;
  String? timelapseRefId; // Transient: set during timelapse generation

  StoryFrame({required this.frameId, required this.videoClipId, required this.framePosition,
    required this.locationId, required this.charactersInScene, this.prompt, this.camera,
    this.refImage, required this.generateImage, this.reuseFrame, this.notes,
    this.timestampStart, this.timestampEnd});

  factory StoryFrame.fromJson(Map<String, dynamic> json) => StoryFrame(
    frameId: json['frame_id'] ?? '', 
    videoClipId: json['video_clip_id'] ?? '',
    framePosition: json['frame_position'] ?? 'first', 
    locationId: json['location_id']?.toString() ?? '',  // Can be ID or name
    charactersInScene: (json['characters_in_scene'] as List?)?.map((c) => c.toString()).toList() ?? [],
    prompt: json['prompt'], 
    camera: json['camera'], 
    refImage: json['ref_image'],
    generateImage: json['generate_image'] ?? true, 
    reuseFrame: json['reuse_frame'], 
    notes: json['notes'],
    timestampStart: json['timestamp_start'] as int?,
    timestampEnd: json['timestamp_end'] as int?);
  Map<String, dynamic> toJson() => {
    'frame_id': frameId,
    'video_clip_id': videoClipId,
    'frame_position': framePosition,
    'location_id': locationId,
    'characters_in_scene': charactersInScene,
    'prompt': prompt,
    'camera': camera,
    'ref_image': refImage,
    'generate_image': generateImage,
    'reuse_frame': reuseFrame,
    'notes': notes,
    'timestamp_start': timestampStart,
    'timestamp_end': timestampEnd,
  };
}

class VideoClip {
  final String clipId, firstFrame, lastFrame, veo3Prompt, audioDescription;
  final int durationSeconds;
  VideoClip({required this.clipId, required this.firstFrame, required this.lastFrame,
    required this.durationSeconds, required this.veo3Prompt, required this.audioDescription});
  factory VideoClip.fromJson(Map<String, dynamic> json) {
    // Handle audio_description as either String or detailed object
    String audioDesc = '';
    final audioData = json['audio_description'];
    if (audioData is String) {
      audioDesc = audioData;
    } else if (audioData is Map) {
      // Convert detailed audio object to formatted string
      final parts = <String>[];
      if (audioData['sfx'] != null) {
        final sfx = audioData['sfx'];
        if (sfx is List) {
          parts.add('SFX: ${sfx.join(", ")}');
        } else {
          parts.add('SFX: $sfx');
        }
      }
      if (audioData['bgm'] != null) parts.add('BGM: ${audioData['bgm']}');
      if (audioData['speech'] != null && audioData['speech'] != 'None') {
        parts.add('Speech: ${audioData['speech']}');
      }
      if (audioData['ambient'] != null) parts.add('Ambient: ${audioData['ambient']}');
      audioDesc = parts.join(' | ');
    }
    
    return VideoClip(
      clipId: json['clip_id'] ?? '', 
      firstFrame: json['first_frame'] ?? '', 
      lastFrame: json['last_frame'] ?? '',
      durationSeconds: json['duration_seconds'] ?? 5, 
      veo3Prompt: json['veo3_prompt'] ?? '',
      audioDescription: audioDesc);
  }
  Map<String, dynamic> toJson() => {
    'clip_id': clipId,
    'first_frame': firstFrame,
    'last_frame': lastFrame,
    'duration_seconds': durationSeconds,
    'veo3_prompt': veo3Prompt,
    'audio_description': audioDescription,
  };
}

// DetectedCharacter model for character analysis
class DetectedCharacter {
  final String id;              // e.g., "char_john_suit_001"
  final String name;             // e.g., "John"
  final String outfit;           // e.g., "blue suit"
  final String fullDescription;  // Full AI-generated description
  String? referenceImagePath;    // Path to generated character image
  String? referenceMediaId;      // Whisk media ID for reference
  List<int> appearsInScenes;     // Scene indices where this character appears
  bool isGeneratingImage;        // Track if image is being generated
  
  DetectedCharacter({
    required this.id,
    required this.name,
    required this.outfit,
    required this.fullDescription,
    this.referenceImagePath,
    this.referenceMediaId,
    List<int>? appearsInScenes,
    this.isGeneratingImage = false,
  }) : appearsInScenes = appearsInScenes ?? [];
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'outfit': outfit,
    'fullDescription': fullDescription,
    'referenceImagePath': referenceImagePath,
    'referenceMediaId': referenceMediaId,
    'appearsInScenes': appearsInScenes,
  };
  
  factory DetectedCharacter.fromJson(Map<String, dynamic> json) => DetectedCharacter(
    id: json['id'] ?? '',
    name: json['name'] ?? '',
    outfit: json['outfit'] ?? '',
    fullDescription: json['fullDescription'] ?? json['description'] ?? '',
    referenceImagePath: json['referenceImagePath'],
    referenceMediaId: json['referenceMediaId'],
    appearsInScenes: (json['appearsInScenes'] as List?)?.map((e) => e as int).toList() ?? 
                     (json['scenes'] as List?)?.map((e) => e as int).toList() ?? [],
  );
}

// ============================================================================
// WHISK API SERVICE
// ============================================================================
class WhiskApiService {
  String? _authToken, _cookie;
  DateTime? _sessionExpiry;
  bool get isAuthenticated => _authToken != null;
  DateTime? get sessionExpiry => _sessionExpiry;

  Future<bool> loadCredentials() async {
    try {
      final credFile = File('${Directory.current.path}/whisk_credentials.json');
      if (!await credFile.exists()) return false;
      final json = jsonDecode(await credFile.readAsString());
      final expiry = DateTime.parse(json['expiry']);
      if (expiry.isBefore(DateTime.now().add(const Duration(minutes: 5)))) return false;
      _cookie = json['cookie']; _authToken = json['authToken']; _sessionExpiry = expiry;
      return true;
    } catch (_) { return false; }
  }

  Future<bool> checkSession(String cookie) async {
    try {
      final response = await http.get(Uri.parse('https://labs.google/fx/api/auth/session'),
        headers: {'host': 'labs.google', 'cookie': cookie, 'content-type': 'application/json'});
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        _authToken = json['access_token']; _cookie = cookie; _sessionExpiry = DateTime.parse(json['expires']);
        await File('${Directory.current.path}/whisk_credentials.json').writeAsString(jsonEncode({
          'cookie': _cookie, 'expiry': _sessionExpiry!.toIso8601String(), 'authToken': _authToken}));
        return true;
      }
      return false;
    } catch (_) { return false; }
  }

  // Wrapper for backward compatibility returning just bytes
  Future<Uint8List?> generateImage({required String prompt, String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE', 
    String imageModel = 'IMAGEN_3_5', int maxRetries = 2, String? refImageId, List<String>? refImageIds, List<String>? refCaptions, String? mediaCategory}) async {
      final result = await generateImageWithDetails(
        prompt: prompt, aspectRatio: aspectRatio, imageModel: imageModel, 
        maxRetries: maxRetries, refImageId: refImageId, refImageIds: refImageIds, refCaptions: refCaptions, mediaCategory: mediaCategory
      );
      return result?['bytes'] as Uint8List?;
  }

  // Extended (Main) Implementation that returns details (bytes + ID)
  Future<Map<String, dynamic>?> generateImageWithDetails({required String prompt, String aspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE', 
    String imageModel = 'IMAGEN_3_5', int maxRetries = 2, String? refImageId, List<String>? refImageIds, List<String>? refCaptions, String? mediaCategory}) async {
    if (_authToken == null) throw Exception('Not authenticated');
    
    // Combine single and list refs
    final allRefIds = <String>[];
    if (refImageId != null) allRefIds.add(refImageId);
    if (refImageIds != null) allRefIds.addAll(refImageIds);
    final hasRefs = allRefIds.isNotEmpty;

    print('\n🎨 ========================================');
    print('🎨 IMAGE GENERATION REQUEST ${hasRefs ? "(WITH REF)" : ""}');
    print('🎨 ========================================');
    print('📝 Prompt: ${prompt.length > 100 ? prompt.substring(0, 100) + '...' : prompt}');
    if (hasRefs) print('🖼️ Reference Image IDs: ${allRefIds.join(", ")}');
    print('📐 Aspect Ratio: $aspectRatio');
    print('🤖 Primary Model: $imageModel');
    print('🔄 Max Retries: $maxRetries');
    
    String currentModel = imageModel;
    if (hasRefs) {
      currentModel = 'GEM_PIX';
      print('ℹ️  Ref images active: Using GEM_PIX preference strategy.');
    }
    
    final alternativeModel = imageModel == 'IMAGEN_3_5' ? 'GEM_PIX' : 'IMAGEN_3_5';
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final waitSeconds = attempt * 2; // Exponential backoff: 2s, 4s
          print('\n⏳ Retry attempt $attempt/$maxRetries - Waiting ${waitSeconds}s...');
          await Future.delayed(Duration(seconds: waitSeconds));
          
          if (hasRefs) {
             // Ref Strategy: GemPix (0) -> GemPix (1) -> Imagen (2+)
             if (attempt >= 2) {
                currentModel = 'IMAGEN_3_5';
                print('🔀 Ref Strategy: Falling back to IMAGEN_3_5...');
             } else {
                currentModel = 'GEM_PIX';
                print('🔄 Ref Strategy: Retrying with GEM_PIX...');
             }
          } else {
             // Standard Switching Logic
             if (attempt == 1) {
               currentModel = alternativeModel;
               print('🔀 Switching to alternative model: $currentModel');
             } else if (attempt == 2) {
               currentModel = imageModel;
               print('🔙 Reverting to original model: $currentModel');
             }
          }
        }
        
        print('\n📤 Sending request to Whisk API...');
        print('🤖 Using Model: $currentModel');
        final startTime = DateTime.now();
        
        final endpoint = hasRefs 
          ? 'https://aisandbox-pa.googleapis.com/v1/whisk:runImageRecipe'
          : 'https://aisandbox-pa.googleapis.com/v1/whisk:generateImage';

        final Map<String, dynamic> body = {
          "clientContext": {
            "workflowId": DateTime.now().millisecondsSinceEpoch.toString(), 
            "tool": "BACKBONE",
            "sessionId": ";${DateTime.now().millisecondsSinceEpoch}"
          },
          "imageModelSettings": {"imageModel": currentModel, "aspectRatio": aspectRatio},
          "seed": DateTime.now().millisecondsSinceEpoch % 1000000,
        };

        if (hasRefs) {
          body["userInstruction"] = prompt;
          // Build recipe media inputs with captions
          body["recipeMediaInputs"] = [];
          for (int i = 0; i < allRefIds.length; i++) {
            final caption = (refCaptions != null && i < refCaptions.length) 
              ? refCaptions[i] 
              : "reference subject";
            body["recipeMediaInputs"].add({
              "caption": caption,
              "mediaInput": {
                "mediaCategory": "MEDIA_CATEGORY_SUBJECT",
                "mediaGenerationId": allRefIds[i]
              }
            });
          }
        } else {
          body["prompt"] = prompt;
          if (mediaCategory != null) {
            body["mediaCategory"] = mediaCategory;
          }
        }
        
        final response = await http.post(Uri.parse(endpoint),
          headers: {'authorization': 'Bearer $_authToken', 'content-type': 'text/plain;charset=UTF-8', 
            'origin': 'https://labs.google'},
          body: jsonEncode(body));
        
        final duration = DateTime.now().difference(startTime);
        print('📥 Response received in ${duration.inSeconds}s');
        print('📊 Status Code: ${response.statusCode}');
        
        if (response.statusCode == 200) {
          print('✅ Request successful!');
          final responseJson = jsonDecode(response.body);
          final panels = responseJson['imagePanels'] as List?;
          
          if (panels?.isNotEmpty == true) {
            final imgList = panels![0]['generatedImages'] as List?;
            final imgObj = imgList?.firstOrNull as Map<String, dynamic>?;
            final imgEncoded = imgObj?['encodedImage'];
            
            if (imgEncoded != null) {
              final imageBytes = base64Decode(imgEncoded);
              
              // Extract ID if available to skip upload step later
              String? mediaId;
              if (imgObj != null) {
                 if (imgObj['mediaGenerationId'] != null) mediaId = imgObj['mediaGenerationId'].toString();
                 else if (imgObj['mediaId'] != null) mediaId = imgObj['mediaId'].toString();
              }
              if (mediaId != null) print('🆔 Extracted Media ID from generation: $mediaId');

              print('🖼️  Image decoded: ${(imageBytes.length / 1024).toStringAsFixed(2)} KB');
              if (currentModel != imageModel) {
                print('ℹ️  Generated with fallback model: $currentModel');
              }
              print('🎨 ========================================\n');
              return {'bytes': imageBytes, 'id': mediaId};
            } else {
              print('⚠️  No image data in response');
            }
          } else {
            print('⚠️  No image panels in response');
          }
        } else {
          print('❌ Request failed with status ${response.statusCode}');
          print('📄 Error body: ${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}');
          
          if (attempt < maxRetries) {
            print('🔄 Will retry with ${attempt == 0 ? alternativeModel : (attempt == 1 ? imageModel : currentModel)}...');
          } else {
            print('❌ Max retries reached. Giving up.');
          }
        }
      } catch (e, stackTrace) {
        print('❌ Exception during image generation: $e');
        print('📚 Stack trace: ${stackTrace.toString().split('\n').take(3).join('\n')}');
        
        if (attempt < maxRetries) {
          print('🔄 Will retry with ${attempt == 0 ? alternativeModel : currentModel}...');
        } else {
          print('❌ Max retries reached. Giving up.');
          print('🎨 ========================================\n');
          rethrow;
        }
      }
    }
    
    print('🎨 ========================================\n');
    return null;
  }

  /// Upload an image to Whisk for use as reference
  Future<String?> uploadUserImage(Uint8List bytes, String fileName) async {
    if (_authToken == null) throw Exception('Not authenticated');
    
    print('📤 Uploading image for reference: $fileName');
    
    try {
      final imageB64 = base64Encode(bytes);
      String mimeType = 'image/png';
      if (fileName.toLowerCase().endsWith('.jpg') || fileName.toLowerCase().endsWith('.jpeg')) mimeType = 'image/jpeg';
      if (fileName.toLowerCase().endsWith('.webp')) mimeType = 'image/webp';
      
      final Map<String, dynamic> body = {
        "imageInput": {
          "rawImageBytes": imageB64,
          "mimeType": mimeType,
          "isUserUploaded": true,
          "aspectRatio": "IMAGE_ASPECT_RATIO_LANDSCAPE"
        },
        "clientContext": {
          "sessionId": ";${DateTime.now().millisecondsSinceEpoch}",
          "tool": "ASSET_MANAGER"
        }
      };

      final response = await http.post(
        Uri.parse('https://aisandbox-pa.googleapis.com/v1:uploadUserImage'),
        headers: {
          'authorization': 'Bearer $_authToken', 
          'content-type': 'text/plain;charset=UTF-8', 
          'origin': 'https://labs.google'
        },
        body: jsonEncode(body)
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String? mediaId;
        
        if (data is Map) {
          if (data.containsKey('mediaGenerationId')) {
            final mediaGen = data['mediaGenerationId'];
            mediaId = mediaGen is Map ? mediaGen['mediaGenerationId']?.toString() : mediaGen?.toString();
          } else if (data.containsKey('mediaId')) {
            mediaId = data['mediaId']?.toString();
          }
        }
        
        if (mediaId != null) {
          print('✅ Upload success: $mediaId');
          return mediaId;
        }
      }
      print('❌ Upload failed: ${response.statusCode} - ${response.body}');
      return null;
    } catch (e) {
      print('❌ Upload exception: $e');
      return null;
    }
  }
  
  static String convertAspectRatio(String r) => r == '9:16' ? 'IMAGE_ASPECT_RATIO_PORTRAIT' : 
    r == '1:1' ? 'IMAGE_ASPECT_RATIO_SQUARE' : 'IMAGE_ASPECT_RATIO_LANDSCAPE';
}

// ============================================================================
// GEMINI API SERVICE - Uses file_data for YouTube video analysis
// ============================================================================
class GeminiService {
  String? apiKey;
  String model = 'gemini-3-flash-preview';
  bool _isCancelled = false;

  void cancelAnalysis() {
    _isCancelled = true;
    print('\n🛑 Analysis cancellation requested by user');
  }

  void resetCancellation() {
    _isCancelled = false;
  }

  /// Analyze YouTube video using file_data format (proper Gemini API format)
  Future<String?> analyzeYouTubeVideo(String videoUrl, String masterPrompt, int sceneCount) async {
    if (apiKey == null || apiKey!.isEmpty) throw Exception('Gemini API key not set');
    
    // Build request with file_data for YouTube URL
    final requestBody = {
      "contents": [{
        "parts": [
          {
            "file_data": {
              "file_uri": videoUrl
            }
          },
          {
            "text": '''$masterPrompt

Generate exactly $sceneCount scene prompts (frames will be 2x this number). 
Output ONLY valid JSON, no markdown, no explanations.'''
          }
        ]
      }],
      "generationConfig": {
        "temperature": 0.7,
        "maxOutputTokens": 8192
      }
    };

    final response = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      return json['candidates']?[0]?['content']?['parts']?[0]?['text'];
    }
    throw Exception('Gemini API error: ${response.statusCode} - ${response.body}');
  }

  /// Analyze YouTube video in batches - SMART VERSION
  /// - Analyzes video only in first batch
  /// - Saves progress after each batch
  /// - Resumes from last completed batch
  /// - Shows results progressively
  Future<String?> analyzeInBatches(
    String videoUrl, 
    String masterPrompt, 
    int totalScenes,
    Function(int, int) onProgress,
    Function(String) onBatchComplete, // NEW: Callback for progressive results
  ) async {
    if (apiKey == null) throw Exception('API key not set');
    
    const batchSize = 10;
    final batches = (totalScenes / batchSize).ceil();
    
    // Create organized cache folder structure
    final videoId = Uri.parse(videoUrl).queryParameters['v'] ?? 'unknown';
    final cacheDir = Directory('${Directory.current.path}/yt_stories/$videoId');
    await cacheDir.create(recursive: true);
    
    final progressFile = File('${cacheDir.path}/progress_${totalScenes}scenes.json');
    final storyFile = File('${cacheDir.path}/story.json');
    
    List<Map<String, dynamic>> allFrames = [];
    List<Map<String, dynamic>> allClips = [];
    Map<String, dynamic>? storyData;
    String extractedStory = '';
    int startBatch = 0;

    // Try to load cached progress
    if (await progressFile.exists()) {
      try {
        final cached = jsonDecode(await progressFile.readAsString());
        allFrames = List<Map<String, dynamic>>.from(cached['frames'] ?? []);
        allClips = List<Map<String, dynamic>>.from(cached['video_clips'] ?? []);
        startBatch = cached['last_completed_batch'] ?? 0;
        
        // Load complete story structure (includes frames and clips)
        if (await storyFile.exists()) {
          final storyContent = await storyFile.readAsString();
          print('📖 Story file found: ${storyFile.path}');
          print('📄 Story content length: ${storyContent.length} chars');
          
          final completeStory = jsonDecode(storyContent);
          storyData = completeStory['story'];
          extractedStory = jsonEncode(storyData); // Just the metadata for subsequent batches
          
          print('✅ Complete story loaded: ${storyData?.keys.toList()}');
        } else {
          print('⚠️  Story file not found: ${storyFile.path}');
        }
        
        print('\n📂 Found cached progress!');
        print('✅ Story extracted: ${storyData != null ? 'Yes' : 'No'}');
        print('🎞️  Cached frames: ${allFrames.length}');
        print('🎬 Cached clips: ${allClips.length}');
        print('▶️  Resuming from batch ${startBatch + 1}/$batches\n');
        
        // Send cached results immediately
        if (allFrames.isNotEmpty || allClips.isNotEmpty) {
          final partialResult = jsonEncode({
            "story": storyData ?? {},
            "frames": allFrames,
            "video_clips": allClips
          });
          onBatchComplete(partialResult);
        }
      } catch (e) {
        print('⚠️  Could not load cache: $e');
        startBatch = 0;
      }
    }

    print('\n========================================');
    print('🎬 Starting YouTube Video Analysis');
    print('========================================');
    print('📹 Video URL: $videoUrl');
    print('🎯 Total Scenes: $totalScenes');
    print('📦 Batch Size: $batchSize');
    print('🔢 Total Batches: $batches');
    print('🤖 Model: $model');
    if (startBatch > 0) print('⏭️  Skipping batches 1-$startBatch (already done)');
    print('========================================\n');

    for (int i = startBatch; i < batches; i++) {
      // Check for cancellation
      if (_isCancelled) {
        print('\n🛑 Analysis cancelled by user at batch ${i + 1}/$batches');
        print('📊 Partial results: ${allFrames.length} frames, ${allClips.length} clips');
        break;
      }
      
      onProgress(i + 1, batches);
      final start = i * batchSize + 1;
      final end = ((i + 1) * batchSize).clamp(1, totalScenes);
      
      print('\n--- Batch ${i + 1}/$batches ---');
      print('📊 Scenes: $start to $end');

      String batchPrompt;
      Map<String, dynamic> requestBody;

      if (i == 0) {
        // FIRST BATCH: Analyze video + extract story
        print('🎥 Analyzing video (first batch only)...');
        
        batchPrompt = '''$masterPrompt

**FIRST BATCH - Extract Story & Generate Scenes $start to $end**

1. Watch the video and extract:
   - Visual style (art_style, color_palette, lighting, aspect_ratio, quality)
   - All characters with descriptions and size_index
   - All locations with descriptions
   
2. Generate scenes $start to $end with frames and video_clips

Output valid JSON with "story", "frames", and "video_clips".''';

        requestBody = {
          "contents": [{
            "parts": [
              {"file_data": {"file_uri": videoUrl}},
              {"text": batchPrompt}
            ]
          }],
          "generationConfig": {"temperature": 0.7, "maxOutputTokens": 8192}
        };
      } else {
        // SUBSEQUENT BATCHES: Use extracted story (text-only, no video analysis)
        print('📝 Using extracted story (no video re-analysis)...');
        
        final lastClipPrompt = allClips.lastOrNull?['veo3_prompt'] ?? 'Story beginning';
        
        batchPrompt = '''Continue the story from where we left off.

**EXTRACTED STORY CONTEXT:**
$extractedStory

**Last scene:** $lastClipPrompt

**Generate scenes $start to $end of $totalScenes total**

Create frames and video_clips for scenes $start to $end.
Frame IDs: frame_${start.toString().padLeft(3, '0')} to frame_${(end * 2).toString().padLeft(3, '0')}

Output ONLY "frames" and "video_clips" arrays in valid JSON.''';

        // TEXT-ONLY REQUEST (no video file_data)
        requestBody = {
          "contents": [{
            "parts": [{"text": batchPrompt}]
          }],
          "generationConfig": {"temperature": 0.7, "maxOutputTokens": 8192}
        };
      }

      print('📤 Sending request to Gemini API...');
      
      try {
        final response = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(requestBody),
        );

        print('📥 Response Status: ${response.statusCode}');

        if (response.statusCode == 200) {
          print('✅ API call successful');
          
          final responseJson = jsonDecode(response.body);
          final text = responseJson['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
          
          if (text.isEmpty) {
            print('⚠️  WARNING: Empty response text');
            continue;
          }
          
          print('📝 Response length: ${text.length} characters');
          
          try {
            final cleaned = text.replaceAll('```json', '').replaceAll('```', '').trim();
            final batchJson = jsonDecode(cleaned);
            
            print('✅ JSON parsed successfully');
            
            // Extract story data from first batch
            if (i == 0 && batchJson['story'] != null) {
              storyData = batchJson['story'];
              extractedStory = jsonEncode(storyData);
              print('📖 Story extracted: ${storyData!.keys.toList()}');
            }
            
            // Collect frames and clips
            if (batchJson['frames'] != null) {
              final newFrames = List<Map<String, dynamic>>.from(batchJson['frames']);
              allFrames.addAll(newFrames);
              print('🎞️  Added ${newFrames.length} frames (Total: ${allFrames.length})');
            }
            if (batchJson['video_clips'] != null) {
              final newClips = List<Map<String, dynamic>>.from(batchJson['video_clips']);
              allClips.addAll(newClips);
              print('🎬 Added ${newClips.length} clips (Total: ${allClips.length})');
            }
            
            // SAVE PROGRESS IMMEDIATELY
            // Save COMPLETE story file (metadata + all frames + all clips so far)
            if (storyData != null) {
              await storyFile.writeAsString(jsonEncode({
                "story": storyData,
                "frames": allFrames,
                "video_clips": allClips,
              }));
              print('📖 Complete story saved (${allFrames.length} frames, ${allClips.length} clips)');
            }
            
            // Save individual batch file
            final batchFile = File('${cacheDir.path}/batch_${(i + 1).toString().padLeft(2, '0')}.json');
            await batchFile.writeAsString(jsonEncode({
              "batch_number": i + 1,
              "scenes": "$start-$end",
              "frames": batchJson['frames'] ?? [],
              "video_clips": batchJson['video_clips'] ?? [],
            }));
            print('💾 Batch ${i + 1} saved to batch file');
            
            // SAVE PROGRESS IMMEDIATELY
            await progressFile.writeAsString(jsonEncode({
              "story": storyData ?? {},
              "frames": allFrames,
              "video_clips": allClips,
              "extracted_story": extractedStory,
              "last_completed_batch": i + 1,
              "total_batches": batches,
            }));
            print('� Progress saved to cache');
            
            // SEND PROGRESSIVE RESULTS TO UI
            final progressiveResult = jsonEncode({
              "story": storyData ?? {},
              "frames": allFrames,
              "video_clips": allClips
            });
            onBatchComplete(progressiveResult);
            print('📤 Results sent to UI');
            
          } catch (e) {
            print('❌ JSON Parse Error in batch ${i + 1}: $e');
            print('🔍 Raw text (first 500 chars): ${text.substring(0, text.length > 500 ? 500 : text.length)}');
          }
        } else {
          print('❌ API Error: ${response.statusCode}');
          print('🔍 Error body: ${response.body}');
          
          try {
            final errorJson = jsonDecode(response.body);
            print('🔍 Error details: ${errorJson['error']?['message'] ?? 'No error message'}');
          } catch (_) {}
        }
      } catch (e, stackTrace) {
        print('❌ Exception in batch ${i + 1}: $e');
        print('📚 Stack trace: $stackTrace');
      }
      
      // Delay between batches
      if (i < batches - 1) {
        print('⏳ Waiting 2 seconds before next batch...\n');
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    print('\n========================================');
    print('✅ Analysis Complete!');
    print('========================================');
    print('📖 Story data: ${storyData != null ? 'Yes' : 'No'}');
    print('🎞️  Total frames: ${allFrames.length}');
    print('🎬 Total clips: ${allClips.length}');
    print('💾 Cache folder: ${cacheDir.path}');
    print('========================================\n');

    return jsonEncode({
      "story": storyData ?? {},
      "frames": allFrames,
      "video_clips": allClips
    });
  }
}

// ============================================================================
// MAIN SCREEN WITH TABS
// ============================================================================
class MainScreen extends StatefulWidget {
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  
  const MainScreen({
    super.key,
    this.profileManager,
    this.loginService,
  });
  
  @override State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final WhiskApiService _whiskApi = WhiskApiService();
  final GeminiService _geminiApi = GeminiService();
  final Veo3VideoService _veo3Api = Veo3VideoService();
  
  // Shared state
  StoryProject? _project;
  final Map<String, Uint8List> _imageBytes = {};
  String _outputDir = '';
  
  // Auto-reuse toggle (shared across tabs)
  bool _autoReusePreviousFrame = false;
  bool _useOddAsRefForEven = false;
  
  // Video generation settings (shared across tabs)
  // MUST use display names matching AppConfig — these are passed to startBatch(model:)
  // which calls AppConfig.getApiModelKey(model, accountType) internally
  String _selectedVideoModel = 'Veo 3.1 - Fast [Lower Priority]';
  String _selectedVideoAspectRatio = 'VIDEO_ASPECT_RATIO_LANDSCAPE';
  bool _useFirstAndLastFrame = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _initOutputDir();
    _whiskApi.loadCredentials().then((_) => setState(() {}));
    _loadSavedProject(); // Load saved project on init
    _loadSceneBuilderSettings(); // Load toggle states
  }

  /// Save SceneBuilder toggle states to SharedPreferences
  Future<void> _saveSceneBuilderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sb_autoReuse', _autoReusePreviousFrame);
    await prefs.setBool('sb_pairedRef', _useOddAsRefForEven);
    await prefs.setString('sb_videoModel', _selectedVideoModel);
    await prefs.setString('sb_videoAspectRatio', _selectedVideoAspectRatio);
  }

  /// Load SceneBuilder toggle states from SharedPreferences
  Future<void> _loadSceneBuilderSettings() async {
    final prefs = await SharedPreferences.getInstance();
    const validModels = ['Veo 3.1 - Fast', 'Veo 3.1 - Fast [Lower Priority]', 'Veo 3.1 - Quality', 'Veo 2 - Fast', 'Veo 2 - Quality'];
    const validAspectRatios = ['VIDEO_ASPECT_RATIO_LANDSCAPE', 'VIDEO_ASPECT_RATIO_PORTRAIT'];
    final savedModel = prefs.getString('sb_videoModel') ?? 'Veo 3.1 - Fast [Lower Priority]';
    final savedRatio = prefs.getString('sb_videoAspectRatio') ?? 'VIDEO_ASPECT_RATIO_LANDSCAPE';
    setState(() {
      _autoReusePreviousFrame = prefs.getBool('sb_autoReuse') ?? false;
      _useOddAsRefForEven = prefs.getBool('sb_pairedRef') ?? false;
      _selectedVideoModel = validModels.contains(savedModel) ? savedModel : 'Veo 3.1 - Fast [Lower Priority]';
      _selectedVideoAspectRatio = validAspectRatios.contains(savedRatio) ? savedRatio : 'VIDEO_ASPECT_RATIO_LANDSCAPE';
    });
  }

  Future<void> _initOutputDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    _outputDir = path.join(appDir.path, 'story_frames');
    await Directory(_outputDir).create(recursive: true);
  }
  
  /// Save project data to SharedPreferences
  Future<void> _saveProject() async {
    if (_project == null) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Save project JSON
      final projectJson = _project!.toJson();
      await prefs.setString('scenebuilder_project', jsonEncode(projectJson));
      
      // Save image paths (images are already saved to _outputDir)
      final imagePaths = <String, String>{};
      for (var entry in _imageBytes.entries) {
        final frameId = entry.key;
        final imagePath = path.join(_outputDir, '$frameId.png');
        imagePaths[frameId] = imagePath;
      }
      await prefs.setString('scenebuilder_image_paths', jsonEncode(imagePaths));
      
      print('[SAVE] ✅ Project saved: ${_project!.title}');
    } catch (e) {
      print('[SAVE] ❌ Error saving project: $e');
    }
  }
  
  /// Load saved project from SharedPreferences
  Future<void> _loadSavedProject() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final projectJson = prefs.getString('scenebuilder_project');
      
      if (projectJson != null) {
        final decoded = jsonDecode(projectJson) as Map<String, dynamic>;
        _project = StoryProject.fromJson(decoded);
        
        // Load image bytes from saved files
        final imagePathsJson = prefs.getString('scenebuilder_image_paths');
        if (imagePathsJson != null) {
          final imagePaths = Map<String, String>.from(jsonDecode(imagePathsJson));
          
          for (var entry in imagePaths.entries) {
            final frameId = entry.key;
            final imagePath = entry.value;
            final file = File(imagePath);
            
            if (await file.exists()) {
              _imageBytes[frameId] = await file.readAsBytes();
            }
          }
        }
        
        if (mounted) {
          setState(() {});
          print('[LOAD] ✅ Project loaded: ${_project!.title} (${_project!.videoClips.length} clips, ${_imageBytes.length} images)');
        }
      }
    } catch (e) {
      print('[LOAD] ❌ Error loading project: $e');
    }
  }
  
  /// Clear saved project data
  Future<void> _clearSavedProject() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('scenebuilder_project');
      await prefs.remove('scenebuilder_image_paths');
      print('[CLEAR] ✅ Saved project cleared');
    } catch (e) {
      print('[CLEAR] ❌ Error clearing project: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TabBarView(controller: _tabController, children: [
        CreateStoryTab(whiskApi: _whiskApi, project: _project, imageBytes: _imageBytes, outputDir: _outputDir,
          autoReuse: _autoReusePreviousFrame,
          useOddAsRefForEven: _useOddAsRefForEven,
          tabController: _tabController,
          selectedVideoModel: _selectedVideoModel,
          selectedVideoAspectRatio: _selectedVideoAspectRatio,
          useFirstAndLastFrame: _useFirstAndLastFrame,
          onAutoReuseChanged: (v) { setState(() => _autoReusePreviousFrame = v); _saveSceneBuilderSettings(); },
          onPairedRefChanged: (v) { setState(() => _useOddAsRefForEven = v); _saveSceneBuilderSettings(); },
          onVideoModelChanged: (v) { setState(() => _selectedVideoModel = v); _saveSceneBuilderSettings(); },
          onVideoAspectRatioChanged: (v) { setState(() => _selectedVideoAspectRatio = v); _saveSceneBuilderSettings(); },
          onUseFirstAndLastFrameChanged: (v) => setState(() => _useFirstAndLastFrame = v),
          onOpenFolder: () async {
            if (_outputDir.isNotEmpty) {
              try {
                if (Platform.isWindows) {
                  await Process.run('explorer', [_outputDir]);
                } else if (Platform.isMacOS) {
                  await Process.run('open', [_outputDir]);
                } else if (Platform.isLinux) {
                  await Process.run('xdg-open', [_outputDir]);
                }
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open folder: $e'), backgroundColor: Colors.red),
                );
              }
            }
          },
          onClearAllImages: () {
            if (_imageBytes.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('No images to clear'), backgroundColor: Colors.orange),
              );
              return;
            }
            
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Clear All Images?'),
                content: Text('This will clear ${_imageBytes.length} loaded images from the screen.\n\nFiles in the folder will NOT be deleted.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _imageBytes.clear();
                        if (_project != null) {
                          for (final frame in _project!.frames) {
                            frame.generatedImagePath = null;
                          }
                        }
                      });
                      _clearSavedProject();
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ All images cleared from screen'), backgroundColor: Colors.green),
                      );
                    },
                    child: const Text('Clear', style: TextStyle(color: Colors.red)),
                  ),
                ],
              ),
            );
          },
          onProjectChanged: (p) {
            setState(() => _project = p);
            _saveProject(); // Save when project changes
          },
          onImageGenerated: (id, bytes) {
            setState(() => _imageBytes[id] = bytes);
            _saveProject(); // Save when images are generated
          }),
        GenerateVideosTab(
          project: _project,
          outputDir: _outputDir,
          profileManager: widget.profileManager,
          loginService: widget.loginService,
          tabController: _tabController,
          selectedModel: _selectedVideoModel,
          selectedAspectRatio: _selectedVideoAspectRatio,
          useFirstAndLastFrame: _useFirstAndLastFrame,
          onModelChanged: (v) => setState(() => _selectedVideoModel = v),
          onAspectRatioChanged: (v) => setState(() => _selectedVideoAspectRatio = v),
          onUseFirstAndLastFrameChanged: (v) => setState(() => _useFirstAndLastFrame = v),
        ),
      ]),
    );
  }

  @override
  void dispose() { _tabController.dispose(); super.dispose(); }
}

// ============================================================================
// CREATE STORY TAB
// ============================================================================
class CreateStoryTab extends StatefulWidget {
  final WhiskApiService whiskApi;
  final StoryProject? project;
  final Map<String, Uint8List> imageBytes;
  final String outputDir;
  final bool autoReuse;
  final bool useOddAsRefForEven;
  final Function(bool) onAutoReuseChanged;
  final Function(bool) onPairedRefChanged;
  final Function() onOpenFolder;
  final Function() onClearAllImages;
  final Function(StoryProject?) onProjectChanged;
  final Function(String, Uint8List) onImageGenerated;
  final TabController tabController;
  final String selectedVideoModel;
  final String selectedVideoAspectRatio;
  final bool useFirstAndLastFrame;
  final Function(String) onVideoModelChanged;
  final Function(String) onVideoAspectRatioChanged;
  final Function(bool) onUseFirstAndLastFrameChanged;

  const CreateStoryTab({super.key, required this.whiskApi, this.project, required this.imageBytes,
    required this.outputDir, this.autoReuse = true, this.useOddAsRefForEven = false, 
    required this.onAutoReuseChanged, required this.onPairedRefChanged,
    required this.onOpenFolder, required this.onClearAllImages,
    required this.onProjectChanged, required this.onImageGenerated,
    required this.tabController,
    required this.selectedVideoModel,
    required this.selectedVideoAspectRatio,
    required this.useFirstAndLastFrame,
    required this.onVideoModelChanged,
    required this.onVideoAspectRatioChanged,
    required this.onUseFirstAndLastFrameChanged});

  @override State<CreateStoryTab> createState() => _CreateStoryTabState();
}

class _CreateStoryTabState extends State<CreateStoryTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  
  final _jsonController = TextEditingController();
  final _cookieController = TextEditingController();
  String? _parseError;
  bool _isGeneratingAll = false;
  int _currentIdx = 0, _totalFrames = 0;
  String _selectedModel = 'IMAGEN_3_5';
  
  // Ultrafast Scene Generator settings
  int _batchSize = 5;
  int _generatedCount = 0;
  int _failedCount = 0;
  final List<String> _models = ['IMAGEN_3_5', 'GEM_PIX'];
  int _currentModelIndex = 0;
  String _generationMode = 'ultrafast'; // 'ultrafast' or 'sequential'
  String _generationStatus = '';
  
  // Model picker & aspect ratio for image generation
  FlowImageGenerationService? _flowService;
  final List<ImageModelConfig> _sceneImageModels = [
    ImageModelConfig(name: 'Whisk Ai', url: 'IMAGEN_3_5', modelType: 'api', apiModelId: 'IMAGEN_3_5'),
    ImageModelConfig(name: 'Whisk Ai Precise', url: 'GEM_PIX', modelType: 'api', apiModelId: 'GEM_PIX'),
    ImageModelConfig(name: 'Nano Banana Pro (Flow)', url: 'GEM_PIX_2', modelType: 'flow', apiModelId: 'GEM_PIX_2'),
    ImageModelConfig(name: 'Nano Banana 2 (Flow)', url: 'NARWHAL', modelType: 'flow', apiModelId: 'NARWHAL'),
    ImageModelConfig(name: 'Imagen 4 (Flow)', url: 'IMAGEN_3_5_FLOW', modelType: 'flow', apiModelId: 'IMAGEN_3_5'),
  ];
  ImageModelConfig? _selectedSceneModel;
  String _selectedAspectRatio = 'IMAGE_ASPECT_RATIO_LANDSCAPE';
  bool _useTimelapse = false; // Use prev image as reference for next image
  bool _isJoiningClips = false; // Joining video clips in progress

  Future<void> _loadTimelapseState() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _useTimelapse = prefs.getBool('sb_useTimelapse') ?? false;
      });
    }
  }

  Future<void> _saveTimelapseState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sb_useTimelapse', _useTimelapse);
  }
  
  // Video action prompts for timelapse mode
  final TextEditingController _videoActionPromptController = TextEditingController();
  List<String> _videoActionPrompts = [];
  bool _skipVideoActionPrompts = false;
  final Map<String, TextEditingController> _clipPromptControllers = {};
  Timer? _clipPromptSaveTimer;
  
  // Video status tracking for clips
  StreamSubscription<String>? _videoStatusSub;
  final Map<int, String> _clipGenerationStatus = {}; // clipIdx -> status string
  final Set<int> _clipGenerating = {}; // track actively generating clips
  String _connectorVideosDir = '';
  
  // Cookie expiry tracking
  DateTime? _cookieExpiry;
  String _cookieStatus = '';
  bool _isLoadingCookie = false;
  
  // Character detection and management
  List<DetectedCharacter> _detectedCharacters = [];
  bool _showCharacterPanel = false;
  bool _isAnalyzingCharacters = false;
  bool _cancelCharacterAnalysis = false; // Flag to cancel analysis
  String _characterAnalysisStatus = '';
  Map<int, List<String>> _sceneCharacterMap = {}; // sceneIndex -> [charIds]
  final ScrollController _characterScrollController = ScrollController();
  bool _isGeneratingScenes = false; // Track scene generation
  int _leftPanelTabIndex = 0; // 0 = Controls, 1 = Characters

  // Persistent controllers for character description text fields
  final Map<String, TextEditingController> _charDescControllers = {};

  /// Get or create a persistent TextEditingController for a character
  TextEditingController _getCharDescController(String charId, String currentText) {
    if (!_charDescControllers.containsKey(charId)) {
      _charDescControllers[charId] = TextEditingController(text: currentText);
    } else if (_charDescControllers[charId]!.text != currentText) {
      // Only update text if it changed externally (not from user typing)
      // This preserves cursor position during typing
      final controller = _charDescControllers[charId]!;
      if (!controller.text.contains(currentText) && !currentText.contains(controller.text)) {
        controller.text = currentText;
      }
    }
    return _charDescControllers[charId]!;
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCookie();
    _loadPersistedCharacterData();
    _initVideoTracking();
    _loadTimelapseState();
  }

  void _initVideoTracking() {
    // Use absolute path — widget.outputDir is empty during initState (set async)
    _connectorVideosDir = path.join(Directory.current.path, 'v_output', 'videos');
    Directory(_connectorVideosDir).create(recursive: true);
    _videoStatusSub = VideoGenerationService().statusStream.listen((msg) {
      if (mounted) {
        setState(() {}); // Re-scan files on any status update
      }
    });
  }

  @override
  void dispose() {
    _charDescControllers.values.forEach((c) => c.dispose());
    _charDescControllers.clear();
    _characterScrollController.dispose();
    _jsonController.dispose();
    _cookieController.dispose();
    _videoActionPromptController.dispose();
    _clipPromptControllers.values.forEach((c) => c.dispose());
    _clipPromptControllers.clear();
    _clipPromptSaveTimer?.cancel();
    _clipPollTimer?.cancel();
    _videoStatusSub?.cancel();
    super.dispose();
  }

  /// Load persisted character data from SharedPreferences
  Future<void> _loadPersistedCharacterData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load characters
      final charactersJson = prefs.getString('detected_characters');
      if (charactersJson != null) {
        final List<dynamic> charList = jsonDecode(charactersJson);
        final characters = charList
            .map((json) => DetectedCharacter.fromJson(json as Map<String, dynamic>))
            .toList();
        
        setState(() {
          _detectedCharacters = characters;
          _showCharacterPanel = characters.isNotEmpty;
        });
        
        print('[PERSISTENCE] Loaded ${characters.length} characters');
      }
      
      // Load scene-character mapping
      final mappingJson = prefs.getString('scene_character_map');
      if (mappingJson != null) {
        final Map<String, dynamic> rawMap = jsonDecode(mappingJson);
        final Map<int, List<String>> sceneMap = {};
        
        rawMap.forEach((key, value) {
          sceneMap[int.parse(key)] = List<String>.from(value as List);
        });
        
        setState(() => _sceneCharacterMap = sceneMap);
        print('[PERSISTENCE] Loaded scene mappings for ${sceneMap.length} scenes');
      }
    } catch (e) {
      print('[PERSISTENCE] Error loading character data: $e');
    }
  }

  /// Save character data to SharedPreferences
  Future<void> _saveCharacterData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Save characters
      final charactersJson = jsonEncode(
        _detectedCharacters.map((c) => c.toJson()).toList(),
      );
      await prefs.setString('detected_characters', charactersJson);
      
      // Save scene-character mapping
      final Map<String, dynamic> stringKeyMap = {};
      _sceneCharacterMap.forEach((key, value) {
        stringKeyMap[key.toString()] = value;
      });
      final mappingJson = jsonEncode(stringKeyMap);
      await prefs.setString('scene_character_map', mappingJson);
      
      print('[PERSISTENCE] Saved ${_detectedCharacters.length} characters and ${_sceneCharacterMap.length} scene mappings');
    } catch (e) {
      print('[PERSISTENCE] Error saving character data: $e');
    }
  }

  /// Clear all persisted character data
  Future<void> _resetCharacterData() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Character Data?'),
        content: const Text('This will delete all detected characters, their images, and scene mappings. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Reset All'),
          ),
        ],
      ),
    );
    
    if (confirm != true) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('detected_characters');
      await prefs.remove('scene_character_map');
      
      // Delete character image files
      for (var char in _detectedCharacters) {
        if (char.referenceImagePath != null) {
          try {
            await File(char.referenceImagePath!).delete();
          } catch (e) {
            print('[RESET] Error deleting ${char.referenceImagePath}: $e');
          }
        }
      }
      
      setState(() {
        _detectedCharacters = [];
        _sceneCharacterMap = {};
        _showCharacterPanel = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Character data reset successfully'),
          backgroundColor: Colors.green,
        ),
      );
      
      print('[RESET] All character data cleared');
    } catch (e) {
      print('[RESET] Error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Reset failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  /// Load saved cookie from SharedPreferences
  Future<void> _loadSavedCookie() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCookie = prefs.getString('whisk_cookie');
      final savedExpiryMs = prefs.getInt('whisk_cookie_expiry');
      
      if (savedCookie != null && savedCookie.isNotEmpty) {
        // Auto-verify the saved cookie to get REAL session expiry
        try {
          await widget.whiskApi.checkSession(savedCookie);
          
          setState(() {
            _cookieController.text = savedCookie;
            // Use API session expiry from whiskApi!
            _cookieExpiry = widget.whiskApi.sessionExpiry;
            _updateCookieStatus();
          });
          
          print('✅ Saved cookie verified - expires: ${widget.whiskApi.sessionExpiry}');
        } catch (e) {
          print('Saved cookie verification failed: $e');
          // Clear expired cookie on startup
          if (mounted) {
            setState(() {
              _cookieController.text = '';
              _cookieExpiry = null;
              _cookieStatus = '';
            });
          }
        }
      }
    } catch (e) {
      print('Error loading saved cookie: $e');
    }
  }

  /// Save cookie to SharedPreferences
  Future<void> _saveCookie(String cookie, DateTime? expiry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('whisk_cookie', cookie);
      if (expiry != null) {
        await prefs.setInt('whisk_cookie_expiry', expiry.millisecondsSinceEpoch);
      }
    } catch (e) {
      print('Error saving cookie: $e');
    }
  }

  void _parseJson() {
    final inputText = _jsonController.text.trim();
    if (inputText.isEmpty) {
      setState(() => _parseError = 'Please enter text or JSON');
      return;
    }
    
    StoryProject? project;
    String formatDetected = '';
    
    // First, try to parse as JSON
    try {
      final decoded = jsonDecode(inputText);
      
      if (decoded is List) {
        // Any array of objects - each object becomes a video clip prompt
        if (decoded.isNotEmpty && decoded[0] is Map) {
          project = StoryProject.fromSimplePromptArray(decoded, autoReuse: widget.autoReuse);
          final genCount = project.frames.where((f) => f.generateImage).length;
          final reuseCount = project.frames.where((f) => !f.generateImage).length;
          formatDetected = 'JSON array (${decoded.length} prompts, $genCount generate, $reuseCount reuse)';
        } else {
          throw Exception('Array must contain objects');
        }
      } else if (decoded is Map<String, dynamic>) {
        // Standard StoryProject format
        project = StoryProject.fromJson(decoded);
        formatDetected = 'StoryProject JSON';
      }
    } catch (jsonError) {
      // JSON parsing failed - try as plain text (line-by-line prompts)
      try {
        project = StoryProject.fromPlainTextPrompts(inputText, autoReuse: widget.autoReuse);
        final genCount = project.frames.where((f) => f.generateImage).length;
        final reuseCount = project.frames.where((f) => !f.generateImage).length;
        formatDetected = 'Plain text (${project.videoClips.length} lines, $genCount generate, $reuseCount reuse)';
        print('📋 JSON parse failed, using plain text format');
      } catch (textError) {
        setState(() => _parseError = 'Could not parse as JSON or plain text.\nJSON error: $jsonError');
        return;
      }
    }
    
    if (project == null) {
      setState(() => _parseError = 'Could not create project from input');
      return;
    }
    
    print('📋 Detected format: $formatDetected');
    
    for (final frame in project.frames) {
      frame.processedPrompt = _buildPrompt(project, frame);
    }
    widget.onProjectChanged(project);
    setState(() => _parseError = null);
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ $formatDetected → ${project.frames.length} frames, ${project.videoClips.length} clips'),
      backgroundColor: Colors.green));
  }
  
  /// Analyze story prompts and detect characters using Gemini AI
  Future<void> _analyzeAndDetectCharacters() async {
    if (widget.project == null || widget.project!.frames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('⚠️ Please parse prompts first'), backgroundColor: Colors.orange),
      );
      return;
    }
    
    setState(() {
      _isAnalyzingCharacters = true;
      _cancelCharacterAnalysis = false; // Reset cancel flag
      _characterAnalysisStatus = 'Analyzing story prompts...';
      _showCharacterPanel = true;
    });
    
    try {
      // Prepare prompts for analysis
      print('\n🎭 ====================================');
      print('🎭 CHARACTER ANALYSIS STARTED');
      print('🎭 ====================================');
      
      final promptsText = widget.project!.frames
          .asMap()
          .entries
          .map((e) => 'Scene ${e.key + 1}: ${e.value.prompt ?? ""}')
          .join('\n\n');
      
      print('📊 Analyzing ${widget.project!.frames.length} scenes for characters...');
      print('📝 Total prompt text: ${promptsText.length} characters');
      
      final systemPrompt = '''
Analyze the following story prompts and extract ALL characters that appear across the scenes.

For each unique character:
1. Create a unique ID in format: char_[name]_[outfit]_001 (e.g., "char_john_suit_001", "char_mary_dress_001")
2. Provide name (first name or identifier)
3. Describe outfit/appearance variation
4. Write a FULL detailed character description including: physical appearance, clothing, accessories, distinctive features, age, build, etc.
5. List ALL scene numbers where this character appears (1-indexed)

IMPORTANT:
- Each character with different outfit/appearance = separate ID
- Same person in different outfits = different character IDs
- Be very descriptive in fullDescription (minimum 50 words per character)
- Extract character details from the prompts themselves

Return ONLY valid JSON (no markdown, no explanations):
{
  "characters": [
    {
      "id": "char_john_suit_001",
      "name": "John",
      "outfit": "blue suit",
      "description": "A tall man in his 30s with short brown hair, wearing a professional tailored blue suit with white shirt and red tie, black leather shoes, clean-shaven face, athletic build, confident posture",
      "scenes": [1, 3, 5]
    }
  ]
}

Story Prompts:
$promptsText
''';
      
      // Call Gemini API using GeminiApiService
      final geminiService = await GeminiApiService.loadFromFile();
      final apiKey = geminiService.currentKey;
      
      if (apiKey == null || apiKey.isEmpty) {
        throw Exception('Gemini API key not configured. Please set it in Settings.');
      }
      
      setState(() => _characterAnalysisStatus = 'Calling Gemini AI...');
      print('🤖 Calling Gemini AI for character extraction...');
      
      final model = 'gemini-3-flash-preview'; // Use same model as rest of app
      
      final requestBody = {
        "contents": [{
          "parts": [{"text": systemPrompt}]
        }],
        "generationConfig": {
          "temperature": 0.4,
          "maxOutputTokens": 16384, // Increased to handle more characters
          "responseMimeType": "application/json"
        }
      };
      
      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );
      
      if (response.statusCode != 200) {
        print('❌ Gemini API error: ${response.statusCode}');
        throw Exception('Gemini API error: ${response.statusCode} - ${response.body}');
      }
      
      print('✅ Gemini API response received (${response.statusCode})');
      print('📦 Response size: ${response.body.length} bytes');
      
      final jsonResponse = jsonDecode(response.body);
      final responseText = jsonResponse['candidates']?[0]?['content']?['parts']?[0]?['text'];
      
      if (responseText == null) {
        throw Exception('No response from Gemini');
      }
      
      // Check if user cancelled during API call
      if (_cancelCharacterAnalysis) {
        setState(() {
          _isAnalyzingCharacters = false;
          _characterAnalysisStatus = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('❌ Character analysis cancelled'), backgroundColor: Colors.orange),
        );
        return;
      }
      
      setState(() => _characterAnalysisStatus = 'Parsing character data...');
      print('🔍 Parsing character data from response...');
      
      // Debug: Print the response to see what we got
      print('[CHARACTER ANALYSIS] Response length: ${responseText.length}');
      print('[CHARACTER ANALYSIS] Response preview: ${responseText.substring(0, responseText.length > 500 ? 500 : responseText.length)}');
      
      // Parse response with error handling
      Map<String, dynamic> characterData;
      try {
        characterData = jsonDecode(responseText);
      } catch (e) {
        print('[CHARACTER ANALYSIS] JSON Parse Error: $e');
        print('[CHARACTER ANALYSIS] Full response: $responseText');
        throw Exception('Failed to parse character data. Response may be incomplete. Try with fewer scenes.');
      }
      
      final characters = (characterData['characters'] as List?)?.map((c) => 
        DetectedCharacter.fromJson(c as Map<String, dynamic>)
      ).toList() ?? [];
      
      print('✅ Found ${characters.length} unique characters');
      for (var char in characters) {
        print('   - ${char.name} (${char.outfit}) appears in scenes: ${char.appearsInScenes.join(", ")}');
      }
      
      // Build scene-character map
      final sceneMap = <int, List<String>>{};
      for (var char in characters) {
        for (var sceneIdx in char.appearsInScenes) {
          sceneMap.putIfAbsent(sceneIdx, () => []).add(char.id);
        }
      }
      
      setState(() {
        _detectedCharacters = characters;
        _sceneCharacterMap = sceneMap;
        _isAnalyzingCharacters = false;
        _characterAnalysisStatus = '';
      });
      
      print('💾 Saving character data...');
      // Save to persistence
      await _saveCharacterData();
      
      print('🎭 ====================================');
      print('✅ CHARACTER ANALYSIS COMPLETE');
      print('🎭 Total: ${characters.length} characters detected');
      print('🎭 ====================================\n');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Detected ${characters.length} character(s)'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      setState(() {
        _isAnalyzingCharacters = false;
        _characterAnalysisStatus = '';
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Character analysis failed: $e'),
          backgroundColor: Colors.red,
        ),
      );
      print('[CHARACTER ANALYSIS] Error: $e');
    }
  }

  /// Cancel ongoing character analysis
  void _cancelCharacterAnalysis_() {
    setState(() {
      _cancelCharacterAnalysis = true;
      _isAnalyzingCharacters = false; // Immediately stop analysis state
      _characterAnalysisStatus = '';
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('⏸️ Character analysis stopped'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }


  /// Load cookie from connected Chrome browser
  Future<void> _loadCookieFromBrowser() async {
    setState(() => _isLoadingCookie = true);
    
    try {
      // Try to connect to Chrome on ports 9222-9230
      final portsToTry = List.generate(9, (i) => 9222 + i);
      bool chromeFound = false;
      
      for (final port in portsToTry) {
        try {
          final response = await http.get(Uri.parse('http://localhost:$port/json'))
            .timeout(const Duration(seconds: 2));
          
          chromeFound = true;
          final tabs = jsonDecode(response.body) as List;
          
          // Find any labs.google tab
          Map<String, dynamic>? targetTab;
          for (var tab in tabs) {
            final url = tab['url'] as String;
            if (url.contains('labs.google')) {
              targetTab = tab as Map<String, dynamic>;
              break;
            }
          }
          
          // If no labs.google tab found, use first tab
          if (targetTab == null && tabs.isNotEmpty) {
            targetTab = tabs[0] as Map<String, dynamic>;
          }
          
          if (targetTab != null) {
            final wsUrl = targetTab['webSocketDebuggerUrl'] as String;
            final ws = WebSocketChannel.connect(Uri.parse(wsUrl));
            final stream = ws.stream.asBroadcastStream();
            
            // ALWAYS navigate to Whisk first to get fresh cookies
            print('Navigating to Whisk to refresh cookies...');
            ws.sink.add(jsonEncode({
              'id': 1,
              'method': 'Page.navigate',
              'params': {'url': 'https://labs.google/fx/tools/whisk'}
            }));
            
            // Wait for navigation to complete
            await Future.delayed(const Duration(seconds: 6));
            
            // Enable Network domain
            ws.sink.add(jsonEncode({
              'id': 2,
              'method': 'Network.enable',
              'params': {}
            }));
            
            // Wait for enable response
            await stream.firstWhere((msg) {
              final data = jsonDecode(msg as String);
              return data['id'] == 2;
            }).timeout(const Duration(seconds: 3));
            
            // Get cookies from whisk domain
            ws.sink.add(jsonEncode({
              'id': 3,
              'method': 'Network.getCookies',
              'params': {
                'urls': [
                  'https://labs.google',
                  'https://labs.google/fx/tools/whisk'
                ]
              }
            }));
            
            // Wait for cookies response
            final cookieResponse = await stream.firstWhere((msg) {
              final data = jsonDecode(msg as String);
              return data['id'] == 3;
            }).timeout(const Duration(seconds: 5));
            
            final result = jsonDecode(cookieResponse as String) as Map<String, dynamic>;
            
            ws.sink.close();
            
            if (result['result'] != null && result['result']['cookies'] != null) {
              final cookies = result['result']['cookies'] as List;
              
              // Find expiry time from cookies
              DateTime? earliestExpiry;
              for (var cookie in cookies) {
                if (cookie['expires'] != null) {
                  final expiry = DateTime.fromMillisecondsSinceEpoch((cookie['expires'] as num).toInt() * 1000);
                  if (earliestExpiry == null || expiry.isBefore(earliestExpiry)) {
                    earliestExpiry = expiry;
                  }
                }
              }
              
              // Build cookie string
              final cookieStr = cookies
                  .map((c) => '${c['name']}=${c['value']}')
                  .join('; ');
              
              if (cookieStr.isNotEmpty) {
                // Save cookie for later use (with cookie expiry for reference)
                await _saveCookie(cookieStr, earliestExpiry);
                
                // Auto-test the cookie to get REAL session expiry
                try {
                  await widget.whiskApi.checkSession(cookieStr);
                  
                  setState(() {
                    _cookieController.text = cookieStr;
                    // Use API session expiry from whiskApi!
                    _cookieExpiry = widget.whiskApi.sessionExpiry;
                    _updateCookieStatus();
                  });
                  
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('✅ Cookie loaded from browser and verified!'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('⚠️ Cookie loaded but verification failed: $e'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                }
                return;
              }
            }
          }
        } catch (e) {
          // Try next port
          print('Port $port failed: $e');
          continue;
        }
      }
      
      // No Chrome found - launch it
      if (!chromeFound) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🚀 Launching Chrome with remote debugging...'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 3),
            ),
          );
        }
        
        // Launch Chrome with remote debugging
        await _launchChromeWithDebugging();
        
        // Wait for Chrome to start
        await Future.delayed(const Duration(seconds: 5));
        
        // Retry connecting
        await _loadCookieFromBrowser();
        return;
      }
      
      // Chrome found but no cookies
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Could not load cookies. Make sure you are logged into labs.google'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      print('Error loading cookie: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error loading cookie: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingCookie = false);
      }
    }
  }

  /// Launch Chrome with remote debugging enabled
  Future<void> _launchChromeWithDebugging() async {
    try {
      // Common Chrome paths on Windows
      final chromePaths = [
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
        Platform.environment['LOCALAPPDATA'] != null 
          ? '${Platform.environment['LOCALAPPDATA']}\\Google\\Chrome\\Application\\chrome.exe'
          : '',
      ];
      
      String? chromePath;
      for (final path in chromePaths) {
        if (path.isNotEmpty && await File(path).exists()) {
          chromePath = path;
          break;
        }
      }
      
      if (chromePath == null) {
        throw Exception('Chrome not found. Please install Google Chrome.');
      }
      
      // Launch Chrome with remote debugging
      final process = await Process.start(
        chromePath,
        BrowserUtils.getChromeArgs(
          debugPort: 9222,
          profilePath: '${Platform.environment['TEMP']}\\chrome_debug_profile',
          url: 'https://labs.google/fx/tools/whisk',
          windowSize: '650,500', // Compact for Whisk
        ),
        mode: ProcessStartMode.detached,
      );
      
      // Apply Always-On-Top and position at bottom-left if on Windows
      if (Platform.isWindows) {
        BrowserUtils.forceAlwaysOnTop(process.pid, width: 650, height: 500);
      }
      
      print('✅ Chrome launched with remote debugging on port 9222');
    } catch (e) {
      print('❌ Error launching Chrome: $e');
      rethrow;
    }
  }

  void _updateCookieStatus() {
    if (_cookieExpiry == null) {
      _cookieStatus = '';
      return;
    }
    
    final now = DateTime.now();
    if (_cookieExpiry!.isBefore(now)) {
      _cookieStatus = '❌ Expired';
    } else {
      final diff = _cookieExpiry!.difference(now);
      if (diff.inDays > 0) {
        _cookieStatus = '✅ ${diff.inDays}d ${diff.inHours % 24}h remaining';
      } else if (diff.inHours > 0) {
        _cookieStatus = '✅ ${diff.inHours}h ${diff.inMinutes % 60}m remaining';
      } else {
        _cookieStatus = '⚠️ ${diff.inMinutes}m remaining';
      }
    }
  }

  String _buildPrompt(StoryProject p, StoryFrame f) {
    // Build prompt WITHOUT any formatting/labels that could appear in images
    final parts = <String>[];
    
    // Add visual style (no label)
    final style = p.visualStyle.toPromptString();
    if (style.isNotEmpty) parts.add(style);
    
    // Add location description (no label)
    final loc = p.getLocationById(f.locationId);
    if (loc != null && loc.description.isNotEmpty) {
      parts.add(loc.description);
    }
    
    // Add character descriptions (no label, no bullet points)
    if (f.charactersInScene.isNotEmpty) {
      for (final cid in f.charactersInScene) {
        final c = p.getCharacterById(cid);
        if (c != null && c.description.isNotEmpty) {
          parts.add(c.description);
        }
      }
    }
    
    // Add scene prompt (no label)
    if (f.prompt != null && f.prompt!.isNotEmpty) {
      parts.add(f.prompt!);
    }
    
    // Add camera info (no label)
    if (f.camera != null && f.camera!.isNotEmpty) {
      parts.add(f.camera!);
    }
    
    return parts.join('. ');
  }

  Future<void> _loadExistingImages() async {
    print('\n📂 ========================================');
    print('📂 LOADING EXISTING IMAGES');
    print('📂 ========================================');
    print('📁 Folder: ${widget.outputDir}');
    
    final dir = Directory(widget.outputDir);
    if (!await dir.exists()) {
      print('❌ Folder does not exist');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Images folder does not exist'), backgroundColor: Colors.red));
      return;
    }
    
    int loadedCount = 0;
    final files = await dir.list().toList();
    
    for (final entity in files) {
      if (entity is File && entity.path.toLowerCase().endsWith('.png')) {
        final fileName = path.basename(entity.path);
        final frameId = fileName.replaceAll('.png', '');
        
        try {
          final bytes = await entity.readAsBytes();
          widget.onImageGenerated(frameId, bytes);
          loadedCount++;
          print('✅ Loaded: $fileName');
          
          // Also update frame if project is loaded
          if (widget.project != null) {
            final frame = widget.project!.getFrameById(frameId);
            if (frame != null) {
              frame.generatedImagePath = fileName;
            }
          }
        } catch (e) {
          print('❌ Failed to load $fileName: $e');
        }
      }
    }
    
    print('📂 ========================================');
    print('✅ Loaded $loadedCount images');
    print('📂 ========================================\n');
    
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Loaded $loadedCount images from folder'), backgroundColor: Colors.green));
  }

  /// Ultrafast Scene Generator - No reference image upload, batch processing
  Future<void> _generateAllUltrafast() async {
    if (widget.project == null) return;
    
    final framesToGenerate = widget.project!.frames.where((f) => f.generateImage && !widget.imageBytes.containsKey(f.frameId)).toList();
    if (framesToGenerate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All images already generated!'), backgroundColor: Colors.orange));
      return;
    }
    
    // If timelapse mode, force batch size to 1 for sequential processing
    final effectiveBatchSize = _useTimelapse ? 1 : _batchSize;
    
    setState(() {
      _isGeneratingAll = true;
      _currentIdx = 0;
      _totalFrames = framesToGenerate.length;
      _generatedCount = 0;
      _failedCount = 0;
      _generationStatus = _useTimelapse 
        ? 'Starting Timelapse Generator (sequential)...' 
        : 'Starting Ultrafast Scene Generator...';
    });
    
    print('\n⚡ ========================================');
    print('⚡ ${_useTimelapse ? "TIMELAPSE" : "ULTRAFAST"} SCENE GENERATOR');
    print('⚡ Total frames to generate: ${framesToGenerate.length}');
    print('⚡ Batch size: $effectiveBatchSize${_useTimelapse ? " (forced sequential for timelapse)" : ""}');
    print('⚡ Timelapse mode: $_useTimelapse');
    print('⚡ ========================================\n');
    
    // Process in batches (batch=1 for timelapse)
    for (int batchStart = 0; batchStart < framesToGenerate.length; batchStart += effectiveBatchSize) {
      if (!_isGeneratingAll) break;
      
      final batchEnd = (batchStart + effectiveBatchSize).clamp(0, framesToGenerate.length);
      final batch = framesToGenerate.sublist(batchStart, batchEnd);
      
      setState(() => _generationStatus = _useTimelapse
        ? 'Timelapse ${batchStart + 1}/${framesToGenerate.length}...'
        : 'Processing batch ${(batchStart ~/ effectiveBatchSize) + 1}... (${batchStart + 1}-$batchEnd of ${framesToGenerate.length})');
      print('\n📦 Processing batch ${(batchStart ~/ effectiveBatchSize) + 1}: frames ${batchStart + 1} to $batchEnd');
      
      if (_useTimelapse) {
        // Sequential: generate one at a time, using previous as ref
        for (final frame in batch) {
          if (!_isGeneratingAll) break;
          
          // Find the previous frame's image to use as reference
          String? prevRefImageId;
          final frameIndex = widget.project!.frames.indexWhere((f) => f.frameId == frame.frameId);
          if (frameIndex > 0) {
            // Walk backwards to find the nearest generated frame
            for (int i = frameIndex - 1; i >= 0; i--) {
              final prevFrame = widget.project!.frames[i];
              final prevDisplayId = (!prevFrame.generateImage && prevFrame.reuseFrame != null) 
                ? prevFrame.reuseFrame! 
                : prevFrame.frameId;
              if (widget.imageBytes.containsKey(prevDisplayId)) {
                print('🔗 Timelapse: Using $prevDisplayId as reference for ${frame.frameId}');
                setState(() => _generationStatus = 'Uploading ref $prevDisplayId...');
                try {
                  final isFlow = (_selectedSceneModel ?? _sceneImageModels.first).modelType == 'flow';
                  if (isFlow) {
                    // Mirror Character Studio's exact working method:
                    // 1. Initialize with ProfileManager so browser is found
                    // 2. Save bytes to temp file then upload via uploadReferenceImage()
                    _flowService ??= FlowImageGenerationService();
                    _flowService!.initialize(profileManager: VideoGenerationService().profileManager);
                    // Write bytes to temp file
                    final tempPath = path.join(Directory.systemTemp.path, 'sb_ref_$prevDisplayId.png');
                    await File(tempPath).writeAsBytes(widget.imageBytes[prevDisplayId]!);
                    print('📤 [SceneBuilder] Uploading Flow ref via temp file: $tempPath');
                    prevRefImageId = await _flowService!.uploadReferenceImage(imagePath: tempPath);
                    try { await File(tempPath).delete(); } catch (_) {}
                  } else {
                    // For Whisk models: upload via Whisk API
                    prevRefImageId = await widget.whiskApi.uploadUserImage(
                      widget.imageBytes[prevDisplayId]!, '$prevDisplayId.png');
                  }
                  if (prevRefImageId != null) {
                    print('✅ Uploaded ref image: $prevRefImageId');
                  }
                } catch (e) {
                  print('⚠️ Failed to upload timelapse ref: $e');
                }
                break;
              }
            }
          }
          
          // Store the timelapse ref ID so _generateFrameWithRetry can use it
          frame.timelapseRefId = prevRefImageId;
          await _generateFrameWithRetry(frame, isBatchMode: true);
          frame.timelapseRefId = null; // Clear after use
        }
      } else {
        // Generate batch concurrently
        final futures = batch.map((frame) => _generateFrameWithRetry(frame, isBatchMode: true));
        await Future.wait(futures);
      }
      
      setState(() => _currentIdx = batchEnd);
    }
    
    setState(() {
      _isGeneratingAll = false;
      _generationStatus = 'Complete! Generated $_generatedCount, Failed $_failedCount';
    });
    
    print('\n⚡ ========================================');
    print('⚡ GENERATION COMPLETE');
    print('⚡ Generated: $_generatedCount');
    print('⚡ Failed: $_failedCount');
    print('⚡ ========================================\n');
    
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ ${_useTimelapse ? "Timelapse" : "Ultrafast"} complete! Generated $_generatedCount, Failed $_failedCount'),
      backgroundColor: _failedCount == 0 ? Colors.green : Colors.orange));
  }

  /// Generate single frame with retry logic (3 retries, 15 second wait)
  /// @param isBatchMode - if true, respects _isGeneratingAll flag
  Future<void> _generateFrameWithRetry(StoryFrame frame, {bool isBatchMode = false}) async {
    const maxRetries = 3;
    const retryWaitSeconds = 15;
    
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      // Only check _isGeneratingAll during batch mode
      if (isBatchMode && !_isGeneratingAll) return;
      
      // Rotate model for each attempt
      final model = _models[_currentModelIndex % _models.length];
      _currentModelIndex++;
      
      print('\n🖼️ Generating ${frame.frameId} (Attempt $attempt/$maxRetries, Model: $model)');
      setState(() { frame.isGenerating = true; frame.error = null; });
      
      try {
        // If using paired ref images, check if it's an even frame
        String? refImageId;
        if (widget.useOddAsRefForEven) {
          final match = RegExp(r'\d+').firstMatch(frame.frameId);
          if (match != null) {
            final numStr = match.group(0)!;
            final numVal = int.parse(numStr);
            if (numVal % 2 == 0) { // Even frame
              final oddNum = numVal - 1;
              final oddId = frame.frameId.replaceFirst(numStr, oddNum.toString().padLeft(numStr.length, '0'));
              
              print('🔗 ${frame.frameId} is even, waiting for odd ref $oddId...');
              setState(() => frame.error = 'Waiting for $oddId...');
              
              // Wait for odd frame image to be ready (max 5 minutes)
              int waitCounter = 0;
              while (!widget.imageBytes.containsKey(oddId) && waitCounter < 60) {
                 await Future.delayed(const Duration(seconds: 5));
                 waitCounter++;
                 if (isBatchMode && !_isGeneratingAll) return;
                 // Periodically check if the file exists on disk too (in case it was loaded elsewhere)
                 if (waitCounter % 6 == 0) {
                   final oddPath = path.join(widget.outputDir, '$oddId.png');
                   if (await File(oddPath).exists()) {
                     final bytes = await File(oddPath).readAsBytes();
                     widget.onImageGenerated(oddId, bytes);
                     break;
                   }
                 }
              }
              
              if (widget.imageBytes.containsKey(oddId)) {
                 print('🔗 Ref image $oddId found! Uploading to Whisk...');
                 setState(() => frame.error = 'Uploading $oddId...');
                 final oddBytes = widget.imageBytes[oddId]!;
                 refImageId = await widget.whiskApi.uploadUserImage(oddBytes, '$oddId.png');
                 if (refImageId == null) {
                   print('❌ Failed to upload ref image $oddId');
                   // If upload fails, try one more time after a short delay
                   await Future.delayed(const Duration(seconds: 3));
                   refImageId = await widget.whiskApi.uploadUserImage(oddBytes, '$oddId.png');
                 }
                 
                 if (refImageId == null) {
                   throw Exception('Failed to upload reference image $oddId');
                 }
                 setState(() => frame.error = 'Generating with ref $oddId...');
              } else {
                 print('❌ Ref image $oddId timed out');
                 throw Exception('Reference image $oddId not found after waiting');
              }
            }
          }
        }

        // If no reference image set yet (e.g. from Paired Ref), check for Character reference
        // Collect Character references (merging with Paired Ref if exists)
        final allRefIds = <String>[];
        final allRefCaptions = <String>[];
        if (refImageId != null) {
          allRefIds.add(refImageId);
          allRefCaptions.add('previous frame');
        }
        
        // Add timelapse reference if available
        if (frame.timelapseRefId != null && frame.timelapseRefId!.isNotEmpty) {
          if (!allRefIds.contains(frame.timelapseRefId)) {
            allRefIds.add(frame.timelapseRefId!);
            allRefCaptions.add('timelapse previous frame');
            print('🎬 ${frame.frameId}: Using timelapse reference');
          }
        }

        try {
            // Get character reference for this scene
            final frameIndex = widget.project!.frames.indexWhere((f) => f.frameId == frame.frameId);
            if (frameIndex != -1) {
               final sceneIdx = frameIndex + 1;
               final sceneCharIds = _sceneCharacterMap[sceneIdx] ?? [];
               
               if (sceneCharIds.isNotEmpty) {
                  for (final charId in sceneCharIds) {
                     final char = _detectedCharacters.firstWhere(
                       (c) => c.id == charId, 
                       orElse: () => DetectedCharacter(id: '', name: 'Unknown', outfit: '', fullDescription: '')
                     );
                     
                     if (char.id.isNotEmpty && char.referenceMediaId != null && char.referenceMediaId!.isNotEmpty) {
                        if (!allRefIds.contains(char.referenceMediaId)) {
                           allRefIds.add(char.referenceMediaId!);
                           // Use character name + outfit as caption
                           final caption = char.outfit.isNotEmpty 
                             ? '${char.name} in ${char.outfit}'
                             : char.name;
                           allRefCaptions.add(caption);
                           print('🎭 ${frame.frameId}: Added character reference: ${char.name}');
                        }
                     } else if (char.id.isNotEmpty) {
                        print('⚠️ ${frame.frameId}: Character ${char.name} assigned but has no reference image.');
                     }
                  }
               }
            }
        } catch (e) {
            print('⚠️ Error looking up character reference: $e');
        }

        // Use the frame's prompt directly (no fancy formatting)
        final prompt = frame.prompt ?? '';
        if (prompt.isEmpty) {
          print('⚠️ ${frame.frameId}: Empty prompt, skipping');
          setState(() { 
            frame.isGenerating = false; 
            frame.error = 'Empty prompt';
          });
          return;
        }
        
        // Determine which service to use based on selected model
        final currentModel = _selectedSceneModel ?? _sceneImageModels.first;
        final isFlowModel = currentModel.modelType == 'flow';
        
        Uint8List? bytes;
        if (isFlowModel) {
          // === FLOW MODEL — mirrors Character Studio's exact working method ===
          _flowService ??= FlowImageGenerationService();
          // CRITICAL: initialize with ProfileManager so service can find the browser
          // (same as Character Studio line: _flowImageService!.initialize(profileManager: widget.profileManager))
          _flowService!.initialize(profileManager: VideoGenerationService().profileManager);
          final flowModelKey = currentModel.apiModelId ?? 'GEM_PIX_2';
          
          // Map aspect ratio to Flow format
          String flowAspect = 'Landscape';
          if (_selectedAspectRatio.contains('PORTRAIT')) flowAspect = 'Portrait';
          else if (_selectedAspectRatio.contains('SQUARE')) flowAspect = 'Square';

          // allRefIds: may contain Flow-uploaded ref IDs (from timelapse upload above)
          // or Whisk-uploaded character ref IDs — pass them through; Flow API will accept them
          // if they came from the same project session.
          final flowRefIds = allRefIds.isNotEmpty ? allRefIds : null;
          
          // Generate — service auto-finds browser via ProfileManager (no need to pass generator)
          final result = await _flowService!.generateImage(
            prompt: prompt,
            model: flowModelKey,
            aspectRatio: flowAspect,
            referenceImageIds: flowRefIds,
          );
          
          if (result.success && result.image != null) {
            bytes = await result.image!.getImageBytes();
            if (bytes == null) throw Exception('Failed to download Flow image');
          } else {
            throw Exception(result.error ?? 'Flow generation failed');
          }
        } else {
          // Use Whisk API (existing logic)
          bytes = await widget.whiskApi.generateImage(
            prompt: prompt,
            aspectRatio: _selectedAspectRatio,
            imageModel: model,
            refImageIds: allRefIds,
            refCaptions: allRefCaptions,
          );
        }
        
        if (bytes != null) {
          final filePath = path.join(widget.outputDir, '${frame.frameId}.png');
          await File(filePath).writeAsBytes(bytes);
          widget.onImageGenerated(frame.frameId, bytes);
          frame.generatedImagePath = '${frame.frameId}.png';
          
          print('✅ ${frame.frameId}: Generated successfully with $model');
          setState(() { 
            frame.isGenerating = false; 
            if (isBatchMode) _generatedCount++;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('✅ ${frame.frameId} generated!'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ));
          return; // Success, exit retry loop
        } else {
          throw Exception('API returned null');
        }
      } catch (e) {
        print('❌ ${frame.frameId}: Attempt $attempt failed - $e');
        
        if (attempt < maxRetries) {
          print('⏳ Waiting $retryWaitSeconds seconds before retry...');
          setState(() => frame.error = 'Attempt $attempt failed, retrying...');
          await Future.delayed(Duration(seconds: retryWaitSeconds));
        } else {
          print('❌ ${frame.frameId}: All retries exhausted');
          setState(() { 
            frame.isGenerating = false; 
            frame.error = 'Failed after $maxRetries attempts';
            if (isBatchMode) _failedCount++;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('❌ ${frame.frameId} failed: ${frame.error}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ));
        }
      }
    }
  }
  
  /// Generate reference image for a character
  Future<void> _generateCharacterImage(DetectedCharacter character) async {
    final charIndex = _detectedCharacters.indexOf(character);
    if (charIndex == -1) return;
    
    setState(() {
      _detectedCharacters[charIndex].isGeneratingImage = true;
    });
    
    try {
      // Generate image using Whisk (getting details to possibly skip upload)
      final result = await widget.whiskApi.generateImageWithDetails(
        prompt: character.fullDescription,
        aspectRatio: 'IMAGE_ASPECT_RATIO_PORTRAIT', // Character portraits
        imageModel: _selectedModel,
        mediaCategory: 'MEDIA_CATEGORY_SUBJECT', // Mark as subject for proper ID
      );
      
      if (result == null || result['bytes'] == null) {
        throw Exception('Image generation returned null');
      }
      
      final imageBytes = result['bytes'] as Uint8List;
      final generatedMediaId = result['id'] as String?;
      
      // Save image to output directory
      final outputDir = widget.outputDir;
      final charFileName = '${character.id}.png';
      final charFilePath = path.join(outputDir, charFileName);
      
      await File(charFilePath).writeAsBytes(imageBytes);
      await FileImage(File(charFilePath)).evict();
      print('✅ Character image saved: $charFilePath');
      
      // Use generated ID if available, otherwise upload
      String? mediaId = generatedMediaId;
      if (mediaId != null) {
          print('✅ Used generated media ID: $mediaId (Skipped Upload)');
      } else {
          // Upload to Whisk to get media ID for reference (unique name)
          final uploadName = '${character.id}_${DateTime.now().millisecondsSinceEpoch}.png';
          mediaId = await widget.whiskApi.uploadUserImage(imageBytes, uploadName);
      }
      
      setState(() {
        _detectedCharacters[charIndex].referenceImagePath = charFilePath;
        _detectedCharacters[charIndex].referenceMediaId = mediaId;
        _detectedCharacters[charIndex].isGeneratingImage = false;
      });
      
      // Save to persistence
      await _saveCharacterData();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Generated image for ${character.name}'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      setState(() {
        _detectedCharacters[charIndex].isGeneratingImage = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Failed to generate ${character.name}: $e'),
          backgroundColor: Colors.red,
        ),
      );
      print('[CHAR IMAGE] Error generating ${character.id}: $e');
    }
  }

  /// Import character image from local directory and upload to Whisk
  Future<void> _importCharacterImage(DetectedCharacter character) async {
    final charIndex = _detectedCharacters.indexOf(character);
    if (charIndex == -1) return;
    
    try {
      // Open file picker to select image
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      
      if (result == null || result.files.isEmpty) {
        return; // User cancelled
      }
      
      final pickedFile = result.files.first;
      
      if (pickedFile.bytes == null && pickedFile.path == null) {
        throw Exception('No file data available');
      }
      
      setState(() {
        _detectedCharacters[charIndex].isGeneratingImage = true;
      });
      
      // Get image bytes
      Uint8List imageBytes;
      if (pickedFile.bytes != null) {
        imageBytes = pickedFile.bytes!;
      } else {
        imageBytes = await File(pickedFile.path!).readAsBytes();
      }
      
      // Save image to output directory with character ID
      final outputDir = widget.outputDir;
      final charFileName = '${character.id}.png';
      final charFilePath = path.join(outputDir, charFileName);
      
      await File(charFilePath).writeAsBytes(imageBytes);
    await FileImage(File(charFilePath)).evict();
    print('✅ Character image imported: $charFilePath');
    
    // Upload to Whisk with unique name to ensure fresh reference
    final uploadName = '${character.id}_${DateTime.now().millisecondsSinceEpoch}.png';
    final mediaId = await widget.whiskApi.uploadUserImage(imageBytes, uploadName);
    print('✅ Character image uploaded to Whisk with ID: $mediaId');
      
      setState(() {
        _detectedCharacters[charIndex].referenceImagePath = charFilePath;
        _detectedCharacters[charIndex].referenceMediaId = mediaId;
        _detectedCharacters[charIndex].isGeneratingImage = false;
      });
      
      // Save to persistence
      await _saveCharacterData();
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Imported and uploaded image for ${character.name}'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      setState(() {
        _detectedCharacters[charIndex].isGeneratingImage = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Failed to import image: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 4),
        ),
      );
      print('[CHAR IMAGE] Error importing ${character.id}: $e');
    }
  }

  /// Generate images for all characters using batch processing (5 at once)
  /// with quota retry logic (15s wait on rate limit)
  Future<void> _generateAllCharacterImages() async {
    final charsToGenerate = _detectedCharacters
        .where((c) => c.referenceImagePath == null && !c.isGeneratingImage)
        .toList();
    
    if (charsToGenerate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ All characters already have images'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🎨 Starting batch generation for ${charsToGenerate.length} characters...'),
        duration: const Duration(seconds: 2),
      ),
    );
    
    const batchSize = 5;
    int successCount = 0;
    int failCount = 0;
    
    // Process in batches of 5
    for (int batchIndex = 0; batchIndex < charsToGenerate.length; batchIndex += batchSize) {
      final batchEnd = (batchIndex + batchSize).clamp(0, charsToGenerate.length);
      final batch = charsToGenerate.sublist(batchIndex, batchEnd);
      
      print('\\n🎨 ========================================');
      print('🎨 CHARACTER BATCH ${(batchIndex ~/ batchSize) + 1}');
      print('🎨 Generating ${batch.length} characters (${batchIndex + 1}-$batchEnd of ${charsToGenerate.length})');
      print('🎨 ========================================');
      
      // Generate batch with retry logic for quota errors
      bool batchSuccess = false;
      int retryCount = 0;
      const maxRetries = 3;
      
      while (!batchSuccess && retryCount < maxRetries) {
        try {
          // Generate all characters in batch concurrently
          final results = await Future.wait(
            batch.map((char) async {
              final charIndex = _detectedCharacters.indexOf(char);
              if (charIndex == -1) return false;
              
              setState(() {
                _detectedCharacters[charIndex].isGeneratingImage = true;
              });
              
              try {
                // Generate image using Whisk (with details to get Media ID)
                final result = await widget.whiskApi.generateImageWithDetails(
                  prompt: char.fullDescription,
                  aspectRatio: 'IMAGE_ASPECT_RATIO_PORTRAIT',
                  imageModel: _selectedModel,
                );
                
                if (result == null || result['bytes'] == null) {
                  throw Exception('Image generation returned null');
                }
                
                final imageBytes = result['bytes'] as Uint8List;
                final mediaId = result['id'] as String?;
                
                // Save image to output directory
                final outputDir = widget.outputDir;
                final charFileName = '${char.id}.png';
                final charFilePath = path.join(outputDir, charFileName);
                
                await File(charFilePath).writeAsBytes(imageBytes);
                print('✅ ${char.name}: Image saved');
                
                // Use Media ID from generation (no need to upload again!)
                if (mediaId != null) {
                  print('✅ ${char.name}: Using Media ID from generation: $mediaId');
                } else {
                  print('⚠️ ${char.name}: No Media ID in generation, uploading...');
                  // Only upload if Media ID wasn't provided
                  final uploadedId = await widget.whiskApi.uploadUserImage(imageBytes, charFileName);
                  print('✅ ${char.name}: Uploaded with ID $uploadedId');
                }
                
                setState(() {
                  _detectedCharacters[charIndex].referenceImagePath = charFilePath;
                  _detectedCharacters[charIndex].referenceMediaId = mediaId;
                  _detectedCharacters[charIndex].isGeneratingImage = false;
                });
                
                // Save to persistence
                await _saveCharacterData();
                
                return true;
              } catch (e) {
                print('❌ ${char.name}: Generation failed - $e');
                setState(() {
                  _detectedCharacters[charIndex].isGeneratingImage = false;
                });
                
                // Check if it's a quota error
                if (e.toString().contains('429') || 
                    e.toString().contains('quota') || 
                    e.toString().contains('rate limit')) {
                  throw e; // Rethrow to trigger batch retry
                }
                
                return false;
              }
            }),
          );
          
          // Count successes in this batch
          final batchSuccessCount = results.where((r) => r).length;
          final batchFailCount = results.where((r) => !r).length;
          
          successCount += batchSuccessCount;
          failCount += batchFailCount;
          
          print('✅ Batch complete: $batchSuccessCount succeeded, $batchFailCount failed');
          batchSuccess = true;
          
        } catch (e) {
          retryCount++;
          
          // Check if it's a quota/rate limit error
          if (e.toString().contains('429') || 
              e.toString().contains('quota') || 
              e.toString().contains('rate limit')) {
            
            if (retryCount < maxRetries) {
              print('⏳ Quota limit hit! Waiting 15 seconds before retry $retryCount/$maxRetries...');
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('⏳ Quota limit - waiting 15s (retry $retryCount/$maxRetries)'),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 3),
                ),
              );
              
              await Future.delayed(const Duration(seconds: 15));
              print('🔄 Retrying batch...');
            } else {
              print('❌ Max retries reached for this batch');
              failCount += batch.length;
              batchSuccess = true; // Exit retry loop
            }
          } else {
            // Non-quota error, fail the batch
            print('❌ Batch failed with non-quota error: $e');
            failCount += batch.length;
            batchSuccess = true;
          }
        }
      }
      
      // Small delay between batches to avoid hitting rate limits
      if (batchEnd < charsToGenerate.length) {
        print('⏸️  2 second cooldown before next batch...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    
    // Final summary
    print('\\n🎨 ========================================');
    print('🎨 CHARACTER GENERATION COMPLETE');
    print('✅ Success: $successCount');
    print('❌ Failed: $failCount');
    print('📊 Total: ${charsToGenerate.length}');
    print('🎨 ========================================\\n');
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ Generated $successCount/${charsToGenerate.length} character images' + 
                     (failCount > 0 ? ' ($failCount failed)' : '')),
        backgroundColor: failCount > 0 ? Colors.orange : Colors.green,
        duration: const Duration(seconds: 4),
      ),
    );
  }


  /// Generate all scenes using character references with batch processing (5 at once)
  /// and quota retry logic (15s wait on rate limit)
  Future<void> _generateScenesWithCharacters() async {
    if (widget.project == null) return;
    
    // Check if all characters have media IDs
    final charsWithoutMediaId = _detectedCharacters
        .where((c) => c.referenceMediaId == null || c.referenceMediaId!.isEmpty)
        .toList();
    
    if (charsWithoutMediaId.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ ${charsWithoutMediaId.length} characters need images first'),
          backgroundColor: Colors.orange,
          action: SnackBarAction(
            label: 'Generate All',
            onPressed: _generateAllCharacterImages,
          ),
        ),
      );
      return;
    }
    
    setState(() => _isGeneratingScenes = true);
    
    // Get frames that need generation (skip already generated)
    final framesToGenerate = widget.project!.frames
        .where((f) => !widget.imageBytes.containsKey(f.frameId))
        .toList();
    
    if (framesToGenerate.isEmpty) {
      setState(() => _isGeneratingScenes = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ All scenes already generated'),
          backgroundColor: Colors.blue,
        ),
      );
      return;
    }
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🎬 Starting batch generation for ${framesToGenerate.length} scenes...'),
        duration: const Duration(seconds: 2),
      ),
    );
    
    const batchSize = 5;
    int successCount = 0;
    int failCount = 0;
    int skippedCount = 0;
    
    // Process in batches of 5
    for (int batchIndex = 0; batchIndex < framesToGenerate.length; batchIndex += batchSize) {
      // Check if user stopped generation
      if (!_isGeneratingScenes) {
        print('[SCENE GEN] 🛑 Stopped by user at batch ${(batchIndex ~/ batchSize) + 1}');
        break;
      }
      
      final batchEnd = (batchIndex + batchSize).clamp(0, framesToGenerate.length);
      final batch = framesToGenerate.sublist(batchIndex, batchEnd);
      
      print('\n🎬 ========================================');
      print('🎬 SCENE BATCH ${(batchIndex ~/ batchSize) + 1}');
      print('🎬 Generating ${batch.length} scenes (${batchIndex + 1}-$batchEnd of ${framesToGenerate.length})');
      print('🎬 ========================================');
      
      // Generate batch with retry logic for quota errors
      bool batchSuccess = false;
      int retryCount = 0;
      const maxRetries = 3;
      
      while (!batchSuccess && retryCount < maxRetries && _isGeneratingScenes) {
        try {
          // Generate all scenes in batch concurrently
          final results = await Future.wait(
            batch.map((frame) async {
              // Double-check not already generated
              if (widget.imageBytes.containsKey(frame.frameId)) {
                print('[SCENE GEN] Scene ${frame.frameId} already generated, skipping');
                return {'success': false, 'skipped': true};
              }
              
              setState(() => frame.isGenerating = true);
              
              try {
                final prompt = frame.prompt ?? '';
                if (prompt.isEmpty) {
                  print('[SCENE GEN] Scene ${frame.frameId} has empty prompt, skipping');
                  setState(() => frame.isGenerating = false);
                  return {'success': false, 'skipped': true};
                }
                
                // Get character reference for this scene
                // Get character reference for this scene (ROBUST LOOKUP)
                // Get character reference for this scene (ROBUST LOOKUP)
                final frameIndex = widget.project!.frames.indexWhere((f) => f.frameId == frame.frameId);
                final sceneIdx = frameIndex + 1;
                final sceneCharIds = _sceneCharacterMap[sceneIdx] ?? [];
                
                final collectedRefIds = <String>[];
                final collectedCaptions = <String>[];  // Character descriptions for captions
                
                // Use character media IDs as references if available
                if (sceneCharIds.isNotEmpty) {
                  for (final charId in sceneCharIds) {
                     // Find the current character object (ensure we get latest state with media ID)
                     final char = _detectedCharacters.firstWhere(
                       (c) => c.id == charId,
                       orElse: () => DetectedCharacter(id: '', name: '', outfit: '', fullDescription: ''),
                     );
                     
                     if (char.id.isNotEmpty) {
                       if (char.referenceMediaId != null && char.referenceMediaId!.isNotEmpty) {
                          collectedRefIds.add(char.referenceMediaId!);
                          // Use character name + outfit as caption for better AI understanding
                          final caption = char.outfit.isNotEmpty 
                            ? '${char.name} in ${char.outfit}'
                            : char.name;
                          collectedCaptions.add(caption);
                       } else {
                          print('[SCENE GEN] ⚠️ Scene $sceneIdx: Character ${char.name} has no reference image uploaded.');
                       }
                     }
                  }
                }
                
                if (collectedRefIds.isNotEmpty) {
                   print('[SCENE GEN] 🎭 Scene $sceneIdx using refs: ${collectedCaptions.join(", ")}');
                }
                
                // Generate frame — use Flow or Whisk based on selected model
                final currentModel = _selectedSceneModel ?? _sceneImageModels.first;
                final isFlowModel = currentModel.modelType == 'flow';
                
                Uint8List? bytes;
                if (isFlowModel) {
                  _flowService ??= FlowImageGenerationService();
                  final flowModelKey = currentModel.apiModelId ?? 'GEM_PIX_2';
                  String flowAspect = 'Landscape';
                  if (_selectedAspectRatio.contains('PORTRAIT')) flowAspect = 'Portrait';
                  else if (_selectedAspectRatio.contains('SQUARE')) flowAspect = 'Square';
                  
                  final result = await _flowService!.generateImage(
                    prompt: prompt,
                    model: flowModelKey,
                    aspectRatio: flowAspect,
                    referenceImageIds: collectedRefIds.isNotEmpty ? collectedRefIds : null,
                  );
                  if (result.success && result.image != null) {
                    bytes = await result.image!.getImageBytes();
                  } else {
                    throw Exception(result.error ?? 'Flow generation failed');
                  }
                } else {
                  bytes = await widget.whiskApi.generateImage(
                    prompt: prompt,
                    aspectRatio: _selectedAspectRatio,
                    imageModel: _selectedModel,
                    refImageIds: collectedRefIds,
                    refCaptions: collectedCaptions,
                  );
                }
                
                if (bytes != null) {
                  final filePath = path.join(widget.outputDir, '${frame.frameId}.png');
                  await File(filePath).writeAsBytes(bytes);
                  widget.onImageGenerated(frame.frameId, bytes);
                  frame.generatedImagePath = '${frame.frameId}.png';
                  print('✅ Scene ${frame.frameId} generated with ${collectedRefIds.isNotEmpty ? "character ref(s)" : "no ref"}');
                  
                  setState(() => frame.isGenerating = false);
                  return {'success': true, 'skipped': false};
                } else {
                  throw Exception('Image generation returned null');
                }
              } catch (e) {
                print('❌ Scene ${frame.frameId}: Generation failed - $e');
                setState(() => frame.isGenerating = false);
                
                // Check if it's a quota error
                if (e.toString().contains('429') || 
                    e.toString().contains('quota') || 
                    e.toString().contains('rate limit')) {
                  throw e; // Rethrow to trigger batch retry
                }
                
                return {'success': false, 'skipped': false};
              }
            }),
          );
          
          // Count results in this batch
          final batchSuccessCount = results.where((r) => r['success'] == true).length;
          final batchFailCount = results.where((r) => r['success'] == false && r['skipped'] == false).length;
          final batchSkippedCount = results.where((r) => r['skipped'] == true).length;
          
          successCount += batchSuccessCount;
          failCount += batchFailCount;
          skippedCount += batchSkippedCount;
          
          print('✅ Batch complete: $batchSuccessCount succeeded, $batchFailCount failed, $batchSkippedCount skipped');
          batchSuccess = true;
          
        } catch (e) {
          retryCount++;
          
          // Check if it's a quota/rate limit error
          if (e.toString().contains('429') || 
              e.toString().contains('quota') || 
              e.toString().contains('rate limit')) {
            
            if (retryCount < maxRetries && _isGeneratingScenes) {
              print('⏳ Quota limit hit! Waiting 15 seconds before retry $retryCount/$maxRetries...');
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('⏳ Quota limit - waiting 15s (retry $retryCount/$maxRetries)'),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 3),
                ),
              );
              
              await Future.delayed(const Duration(seconds: 15));
              
              if (_isGeneratingScenes) {
                print('🔄 Retrying batch...');
              }
            } else {
              print('❌ Max retries reached or generation stopped');
              failCount += batch.length;
              batchSuccess = true; // Exit retry loop
            }
          } else {
            // Non-quota error, fail the batch
            print('❌ Batch failed with non-quota error: $e');
            failCount += batch.length;
            batchSuccess = true;
          }
        }
      }
      
      // Small delay between batches to avoid hitting rate limits
      if (batchEnd < framesToGenerate.length && _isGeneratingScenes) {
        print('⏸️  2 second cooldown before next batch...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    
    setState(() => _isGeneratingScenes = false);
    
    // Final summary
    print('\n🎬 ========================================');
    print('🎬 SCENE GENERATION COMPLETE');
    print('✅ Success: $successCount');
    print('❌ Failed: $failCount');
    print('⏭️  Skipped: $skippedCount');
    print('📊 Total: ${framesToGenerate.length}');
    print('🎬 ========================================\n');
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ Generated $successCount/${framesToGenerate.length} scenes' +
                     (failCount > 0 ? ' ($failCount failed)' : '') +
                     (skippedCount > 0 ? ' ($skippedCount skipped)' : '')),
        backgroundColor: failCount > 0 ? Colors.orange : Colors.green,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    return LayoutBuilder(
      builder: (context, constraints) {
        final leftWidth = constraints.maxWidth < 1000 ? 300.0 : 360.0;
        final tp = ThemeProvider();
        
        return Row(children: [
          // Left Panel with Tabs (Now full height)
          Container(
            width: leftWidth,
            decoration: BoxDecoration(
              color: tp.surfaceBg,
              boxShadow: [
                BoxShadow(
                  color: tp.shadowColor,
                  blurRadius: 4,
                  offset: const Offset(2, 0),
                ),
              ],
            ),
            child: Column(
              children: [
                // Tab Bar
                Container(
                  height: 32, // Consistent height for tabs
                  decoration: BoxDecoration(
                    color: tp.isDarkMode ? tp.headerBg : Colors.grey[100],
                    border: Border(bottom: BorderSide(color: tp.borderColor)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _leftPanelTabIndex = 0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: _leftPanelTabIndex == 0 ? tp.surfaceBg : Colors.transparent,
                              border: Border(
                                bottom: BorderSide(
                                  color: _leftPanelTabIndex == 0 ? (tp.isDarkMode ? tp.textOnSurface : const Color(0xFF10B981)) : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.settings_suggest,
                                  size: 14,
                                  color: _leftPanelTabIndex == 0 ? (tp.isDarkMode ? tp.textOnSurface : const Color(0xFF10B981)) : tp.textTertiary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  LocalizationService().tr('scene.controls'),
                                  style: TextStyle(
                                    fontWeight: _leftPanelTabIndex == 0 ? FontWeight.bold : FontWeight.normal,
                                    color: _leftPanelTabIndex == 0 ? (tp.isDarkMode ? tp.textOnSurface : const Color(0xFF10B981)) : tp.textTertiary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _leftPanelTabIndex = 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: _leftPanelTabIndex == 1 ? tp.surfaceBg : Colors.transparent,
                              border: Border(
                                bottom: BorderSide(
                                  color: _leftPanelTabIndex == 1 ? (tp.isDarkMode ? tp.textOnSurface : const Color(0xFF8B5CF6)) : Colors.transparent,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.people,
                                  size: 14,
                                  color: _leftPanelTabIndex == 1 ? (tp.isDarkMode ? tp.textOnSurface : const Color(0xFF8B5CF6)) : tp.textTertiary,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  LocalizationService().tr('scene.chars'),
                                  style: TextStyle(
                                    fontWeight: _leftPanelTabIndex == 1 ? FontWeight.bold : FontWeight.normal,
                                    color: _leftPanelTabIndex == 1 ? (tp.isDarkMode ? tp.textOnSurface : const Color(0xFF8B5CF6)) : tp.textTertiary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Tab Content
                Expanded(
                  child: IndexedStack(
                    index: _leftPanelTabIndex,
                    children: [
                      // Tab 0: Controls
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              const Icon(Icons.code, size: 16), const SizedBox(width: 8),
                              Text(LocalizationService().tr('scene.story_json'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: tp.textPrimary)),
                              if (widget.project != null) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: tp.isDarkMode ? Colors.deepPurple.shade900.withOpacity(0.5) : Colors.deepPurple.shade50,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: tp.isDarkMode ? Colors.deepPurple.shade700 : Colors.deepPurple.shade200, width: 0.5),
                                  ),
                                  child: Text(
                                    '${widget.project!.frames.length} prompts',
                                    style: TextStyle(
                                      fontSize: 9, 
                                      fontWeight: FontWeight.w600, 
                                      color: tp.isDarkMode ? Colors.deepPurple.shade300 : Colors.deepPurple.shade700,
                                    ),
                                  ),
                                ),
                              ],
                              const Spacer(),
                              TextButton(
                                onPressed: () { 
                                  _jsonController.clear(); 
                                  widget.onProjectChanged(null); 
                                },
                                child: Text(LocalizationService().tr('home.clear'), style: TextStyle(color: tp.isDarkMode ? tp.textSecondary : Colors.red, fontSize: 11)),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 150,
                              child: TextField(
                                controller: _jsonController,
                                maxLines: null,
                                expands: true,
                                decoration: InputDecoration(
                                  hintText: LocalizationService().tr('scene.paste_json'),
                                  border: OutlineInputBorder(),
                                  isDense: true, // Added isDense
                                  contentPadding: const EdgeInsets.all(8), // Added explicit padding
                                ),
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                              ),
                            ),
                            if (_parseError != null) 
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  _parseError!, 
                                  style: const TextStyle(color: Colors.red, fontSize: 11),
                                ),
                              ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: _parseJson,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                    ),
                                    child: Text(LocalizationService().tr('scene.parse')),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 2,
                                  child: ElevatedButton(
                                    onPressed: _isAnalyzingCharacters ? _cancelCharacterAnalysis_ : _analyzeAndDetectCharacters,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: _isAnalyzingCharacters ? Colors.red : const Color(0xFF8B5CF6),
                                      foregroundColor: Colors.white,
                                    ),
                                    child: _isAnalyzingCharacters
                                        ? Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.stop, size: 14),
                                              SizedBox(width: 8),
                                              Text(LocalizationService().tr('scene.stop_analysis'), style: TextStyle(fontSize: 11)),
                                            ],
                                          )
                                        : Text(LocalizationService().tr('scene.analyze_detect'), style: const TextStyle(fontSize: 11)),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(height: 12),
                            

                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 32, // More compact height
                                    child: TextField(
                                      controller: _cookieController,
                                      obscureText: true,
                                      style: const TextStyle(fontSize: 11),
                                      decoration: InputDecoration(
                                        labelText: LocalizationService().tr('scene.whisk_cookie'), 
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Tooltip(
                                  message: 'Load cookie from connected Chrome browser',
                                  child: SizedBox(
                                    height: 32,
                                    child: ElevatedButton.icon(
                                      onPressed: _isLoadingCookie ? null : _loadCookieFromBrowser,
                                      icon: _isLoadingCookie 
                                        ? const SizedBox(
                                            width: 14,
                                            height: 14,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                            ),
                                          )
                                        : const Icon(Icons.web, size: 14),
                                      label: Text(
                                        _isLoadingCookie ? 'Loading...' : LocalizationService().tr('scene.connect_browser'),
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: _isLoadingCookie ? Colors.grey : Colors.blue,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 10),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(Icons.login, size: 18),
                                  tooltip: 'Test cookie',
                                  padding: EdgeInsets.zero,
                                  onPressed: () async { 
                                    await widget.whiskApi.checkSession(_cookieController.text); 
                                    setState(() {}); 
                                  },
                                ),
                              ],
                            ),
                            // Cookie status display
                            if (_cookieStatus.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2, left: 4),
                                child: Text(
                                  _cookieStatus,
                                  style: TextStyle(
                                    fontSize: 9, // Smaller font
                                    color: _cookieStatus.contains('❌') 
                                      ? Colors.red 
                                      : _cookieStatus.contains('⚠️')
                                        ? Colors.orange
                                        : Colors.green,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 6),
                            
                            // ULTRAFAST SCENE GENERATOR — Premium compact
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              decoration: BoxDecoration(
                                gradient: tp.isDarkMode 
                                  ? LinearGradient(colors: [Colors.deepPurple.shade900.withOpacity(0.3), Colors.purple.shade900.withOpacity(0.15)])
                                  : LinearGradient(colors: [Colors.deepPurple.shade50, Colors.purple.shade50.withOpacity(0.5)]),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: tp.isDarkMode ? Colors.deepPurple.shade800.withOpacity(0.5) : Colors.deepPurple.shade200, width: 0.5),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Row 1: Title + Load Existing
                                  Row(children: [
                                    Icon(Icons.bolt, color: tp.isDarkMode ? Colors.amber.shade300 : Colors.deepPurple.shade700, size: 14),
                                    const SizedBox(width: 4),
                                    Text('Scene Gen', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11.5, 
                                      color: tp.isDarkMode ? Colors.deepPurple.shade200 : Colors.deepPurple.shade800,
                                      letterSpacing: 0.3)),
                                    const Spacer(),
                                    // Load existing — icon only
                                    Tooltip(
                                      message: LocalizationService().tr('scene.load_existing'),
                                      child: InkWell(
                                        onTap: _loadExistingImages,
                                        borderRadius: BorderRadius.circular(4),
                                        child: Padding(
                                          padding: const EdgeInsets.all(3),
                                          child: Icon(Icons.folder_open_outlined, size: 14, color: tp.textSecondary),
                                        ),
                                      ),
                                    ),
                                  ]),
                                  const SizedBox(height: 6),
                                  
                                  // Row 2: Model selector (PopupMenuButton like Character Studio)
                                  Row(children: [
                                    Expanded(
                                      child: Builder(builder: (context) {
                                        final whiskModels = _sceneImageModels.where((m) => m.modelType == 'api').toList();
                                        final flowModels = _sceneImageModels.where((m) => m.modelType == 'flow').toList();
                                        final current = _selectedSceneModel ?? _sceneImageModels.first;
                                        
                                        return PopupMenuButton<String>(
                                          onSelected: (v) {
                                            setState(() {
                                              _selectedSceneModel = _sceneImageModels.firstWhere((m) => m.name == v);
                                            });
                                          },
                                          offset: const Offset(0, 28),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                          color: tp.isDarkMode ? const Color(0xFF1E293B) : Colors.white,
                                          elevation: 8,
                                          constraints: const BoxConstraints(minWidth: 200),
                                          itemBuilder: (context) {
                                            final List<PopupMenuEntry<String>> items = [];
                                            
                                            void addHeader(String title, IconData icon, Color color) {
                                              items.add(PopupMenuItem<String>(
                                                enabled: false,
                                                height: 22,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: color.withOpacity(0.08),
                                                    borderRadius: BorderRadius.circular(3),
                                                    border: Border(left: BorderSide(color: color, width: 2)),
                                                  ),
                                                  child: Row(children: [
                                                    Icon(icon, size: 9, color: color),
                                                    const SizedBox(width: 4),
                                                    Text(title, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: color, letterSpacing: 0.8)),
                                                  ]),
                                                ),
                                              ));
                                            }
                                            
                                            void addModels(List<ImageModelConfig> models, Color dotColor) {
                                              for (final m in models) {
                                                final isSelected = current.name == m.name;
                                                items.add(PopupMenuItem<String>(
                                                  value: m.name,
                                                  height: 30,
                                                  child: Row(children: [
                                                    Container(
                                                      width: 5, height: 5,
                                                      decoration: BoxDecoration(
                                                        color: isSelected ? dotColor : dotColor.withOpacity(0.3),
                                                        shape: BoxShape.circle,
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    Expanded(
                                                      child: Text(m.name, style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                                        color: isSelected 
                                                          ? (tp.isDarkMode ? Colors.white : const Color(0xFF1E40AF))
                                                          : (tp.isDarkMode ? const Color(0xFFCBD5E1) : const Color(0xFF374151)),
                                                      )),
                                                    ),
                                                    if (isSelected)
                                                      Icon(Icons.check, size: 12, color: dotColor),
                                                  ]),
                                                ));
                                              }
                                            }
                                            
                                            if (whiskModels.isNotEmpty) {
                                              addHeader('WHISK MODELS', Icons.auto_awesome, const Color(0xFF7C3AED));
                                              addModels(whiskModels, const Color(0xFF7C3AED));
                                            }
                                            if (flowModels.isNotEmpty) {
                                              if (items.isNotEmpty) items.add(const PopupMenuDivider(height: 4));
                                              addHeader('GOOGLE FLOW', Icons.water_drop, const Color(0xFF059669));
                                              addModels(flowModels, const Color(0xFF059669));
                                            }
                                            
                                            return items;
                                          },
                                          child: Container(
                                            height: 28,
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                            decoration: BoxDecoration(
                                              color: tp.isDarkMode ? tp.inputBg : Colors.white,
                                              border: Border.all(color: tp.isDarkMode ? Colors.deepPurple.shade700 : Colors.deepPurple.shade200, width: 0.5),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Row(children: [
                                              Container(
                                                width: 5, height: 5,
                                                decoration: BoxDecoration(
                                                  color: current.modelType == 'flow' ? const Color(0xFF059669) : const Color(0xFF7C3AED),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(current.name, style: TextStyle(fontSize: 10, color: tp.textPrimary), overflow: TextOverflow.ellipsis),
                                              ),
                                              Icon(Icons.unfold_more, size: 12, color: tp.textTertiary),
                                            ]),
                                          ),
                                        );
                                      }),
                                    ),
                                    const SizedBox(width: 6),
                                    // Batch size — small with label
                                    Text('×', style: TextStyle(fontSize: 11, color: tp.textTertiary, fontWeight: FontWeight.bold)),
                                    const SizedBox(width: 2),
                                    SizedBox(
                                      width: 30,
                                      height: 28,
                                      child: TextField(
                                        keyboardType: TextInputType.number,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(fontSize: 10, color: tp.textPrimary, fontWeight: FontWeight.w500),
                                        decoration: InputDecoration(
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(width: 0.5)),
                                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.isDarkMode ? Colors.deepPurple.shade700 : Colors.deepPurple.shade200, width: 0.5)),
                                          filled: true,
                                          fillColor: tp.isDarkMode ? tp.inputBg : Colors.white,
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                                        ),
                                        controller: TextEditingController(text: _batchSize.toString()),
                                        onChanged: (v) => _batchSize = int.tryParse(v) ?? 5,
                                      ),
                                    ),
                                  ]),
                                  const SizedBox(height: 6),
                                  
                                  // Row 3: Aspect ratio — visual chips with outlined rectangles
                                  Row(children: [
                                    ...[ 
                                      ('IMAGE_ASPECT_RATIO_LANDSCAPE', '16:9', 16.0, 9.0),
                                      ('IMAGE_ASPECT_RATIO_PORTRAIT', '9:16', 9.0, 16.0),
                                      ('IMAGE_ASPECT_RATIO_SQUARE', '1:1', 12.0, 12.0),
                                    ].map((item) {
                                      final isActive = _selectedAspectRatio == item.$1;
                                      return Expanded(
                                        child: GestureDetector(
                                          onTap: () => setState(() => _selectedAspectRatio = item.$1),
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 150),
                                            margin: const EdgeInsets.symmetric(horizontal: 2),
                                            padding: const EdgeInsets.symmetric(vertical: 4),
                                            decoration: BoxDecoration(
                                              color: isActive 
                                                ? (tp.isDarkMode ? Colors.deepPurple.shade800.withOpacity(0.5) : Colors.deepPurple.shade100.withOpacity(0.7))
                                                : Colors.transparent,
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: isActive 
                                                  ? (tp.isDarkMode ? Colors.deepPurple.shade400 : Colors.deepPurple.shade400)
                                                  : (tp.isDarkMode ? tp.borderColor.withOpacity(0.3) : Colors.grey.shade300),
                                                width: isActive ? 1.0 : 0.5,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                // Mini ratio rectangle outline
                                                Container(
                                                  width: item.$3 * 0.9,
                                                  height: item.$4 * 0.9,
                                                  decoration: BoxDecoration(
                                                    border: Border.all(
                                                      color: isActive 
                                                        ? (tp.isDarkMode ? Colors.deepPurple.shade300 : Colors.deepPurple.shade600) 
                                                        : tp.textTertiary,
                                                      width: isActive ? 1.2 : 0.8,
                                                    ),
                                                    borderRadius: BorderRadius.circular(1.5),
                                                  ),
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  item.$2,
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                                                    color: isActive 
                                                      ? (tp.isDarkMode ? Colors.deepPurple.shade200 : Colors.deepPurple.shade800) 
                                                      : tp.textTertiary,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    }),
                                  ]),
                                  const SizedBox(height: 6),
                                  
                                  // Generate button or Progress
                                  if (_isGeneratingAll) ...[
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(4),
                                      child: LinearProgressIndicator(
                                        value: _totalFrames > 0 ? _currentIdx / _totalFrames : 0,
                                        minHeight: 3,
                                        backgroundColor: tp.isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200,
                                        valueColor: AlwaysStoppedAnimation(_useTimelapse ? Colors.teal : Colors.deepPurple),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Row(children: [
                                      Expanded(
                                        child: Text(
                                          '$_currentIdx/$_totalFrames • $_generatedCount✅ $_failedCount❌',
                                          style: TextStyle(fontSize: 9, color: tp.textSecondary),
                                        ),
                                      ),
                                      SizedBox(
                                        height: 22,
                                        child: TextButton(
                                          onPressed: () => setState(() => _isGeneratingAll = false),
                                          style: TextButton.styleFrom(
                                            foregroundColor: Colors.red.shade400,
                                            padding: const EdgeInsets.symmetric(horizontal: 8),
                                            visualDensity: VisualDensity.compact,
                                          ),
                                          child: const Text('Stop', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                                        ),
                                      ),
                                    ]),
                                  ] else ...[  
                                    SizedBox(
                                      height: 32,
                                      child: ElevatedButton(
                                        onPressed: widget.project != null && widget.whiskApi.isAuthenticated 
                                          ? _generateAllUltrafast 
                                          : null,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _useTimelapse ? Colors.teal : Colors.deepPurple,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 10),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          elevation: 0,
                                        ),
                                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                          Icon(_useTimelapse ? Icons.timelapse : Icons.bolt, size: 14),
                                          const SizedBox(width: 5),
                                          Text(
                                            '${_useTimelapse ? "Prev Ref" : "Generate"} ${widget.project?.frames.where((f) => f.generateImage && !widget.imageBytes.containsKey(f.frameId)).length ?? 0} Images',
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                          ),
                                        ]),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      // Tab 1: Characters
                      Container(
                        color: Colors.grey[900],
                        child: Column(
                          children: [
                            // Header
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.grey[850],
                              ),
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      const Text(
                                        'Detected Characters',
                                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                                      ),
                                      Text(
                                        '${_detectedCharacters.length} total',
                                        style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // Generate All button
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: _detectedCharacters.any((c) => c.isGeneratingImage)
                                          ? null
                                          : _generateAllCharacterImages,
                                      icon: const Icon(Icons.auto_awesome, size: 16),
                                      label: const Text('Generate All Images', style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF8B5CF6),
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  // Reset button
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: _resetCharacterData,
                                      icon: const Icon(Icons.delete_forever, size: 16),
                                      label: const Text('Reset All Data', style: TextStyle(fontSize: 12)),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.red,
                                        side: const BorderSide(color: Colors.red),
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            
                            // Character list
                            Expanded(
                              child: _detectedCharacters.isEmpty
                                  ? Center(
                                      child: Text(
                                        _isAnalyzingCharacters 
                                            ? _characterAnalysisStatus
                                            : 'No characters detected yet\n\nUse "Analyze & Detect Characters"\nin the Controls tab',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.grey[500]),
                                      ),
                                    )
                                  : ScrollbarTheme(
                                      data: ScrollbarThemeData(
                                        thumbColor: MaterialStateProperty.all(const Color(0xFF8B5CF6)),
                                        trackColor: MaterialStateProperty.all(const Color(0xFF8B5CF6).withOpacity(0.2)),
                                        trackBorderColor: MaterialStateProperty.all(const Color(0xFF8B5CF6).withOpacity(0.3)),
                                        thickness: MaterialStateProperty.all(12),
                                        radius: const Radius.circular(6),
                                        thumbVisibility: MaterialStateProperty.all(true),
                                        trackVisibility: MaterialStateProperty.all(true),
                                      ),
                                      child: Scrollbar(
                                        controller: _characterScrollController,
                                        child: ListView.builder(
                                        controller: _characterScrollController,
                                        padding: const EdgeInsets.all(8),
                                        itemCount: _detectedCharacters.length,
                                        itemBuilder: (context, index) {
                                          final char = _detectedCharacters[index];
                                          return Card(
                                            color: Colors.grey[850],
                                            margin: const EdgeInsets.only(bottom: 8),
                                            child: Padding(
                                              padding: const EdgeInsets.all(10),
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  // Left: Character image in vertical ratio (portrait)
                                                  // Left: Character image in vertical ratio (portrait) - Draggable
                                                  Draggable<String>(
                                                    data: char.id,
                                                    feedback: Material(
                                                      elevation: 6,
                                                      shadowColor: Colors.black45,
                                                      borderRadius: BorderRadius.circular(6),
                                                      child: SizedBox(
                                                        width: 100,
                                                        height: 150,
                                                        child: char.referenceImagePath != null
                                                            ? ClipRRect(
                                                                borderRadius: BorderRadius.circular(6),
                                                                child: Image.file(
                                                                  File(char.referenceImagePath!),
                                                                  fit: BoxFit.cover,
                                                                ),
                                                              )
                                                            : Container(
                                                                decoration: BoxDecoration(
                                                                  color: Colors.grey[800],
                                                                  borderRadius: BorderRadius.circular(6),
                                                                ),
                                                                child: const Center(child: Icon(Icons.person, size: 40, color: Colors.white)),
                                                              ),
                                                      ),
                                                    ),
                                                    childWhenDragging: SizedBox(
                                                      width: 100,
                                                      child: Opacity(
                                                        opacity: 0.3,
                                                        child: Column(
                                                          children: [
                                                            if (char.referenceImagePath != null)
                                                              ClipRRect(
                                                                borderRadius: BorderRadius.circular(6),
                                                                child: Image.file(
                                                                  File(char.referenceImagePath!),
                                                                  key: ValueKey(char.referenceMediaId),
                                                                  height: 150,
                                                                  width: 100,
                                                                  fit: BoxFit.cover,
                                                                ),
                                                              )
                                                            else
                                                              Container(
                                                                height: 150,
                                                                width: 100,
                                                                decoration: BoxDecoration(
                                                                  color: Colors.grey[800],
                                                                  borderRadius: BorderRadius.circular(6),
                                                                ),
                                                                child: Center(
                                                                  child: Icon(
                                                                    Icons.person,
                                                                    size: 40,
                                                                    color: Colors.grey[600],
                                                                  ),
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                    child: SizedBox(
                                                      width: 100,
                                                      child: Column(
                                                        children: [
                                                          if (char.referenceImagePath != null)
                                                            ClipRRect(
                                                              borderRadius: BorderRadius.circular(6),
                                                              child: Image.file(
                                                                File(char.referenceImagePath!),
                                                                key: ValueKey(char.referenceMediaId),
                                                                height: 150,
                                                                width: 100,
                                                                fit: BoxFit.cover,
                                                              ),
                                                            )
                                                          else
                                                            Container(
                                                              height: 150,
                                                              width: 100,
                                                              decoration: BoxDecoration(
                                                                color: Colors.grey[800],
                                                                borderRadius: BorderRadius.circular(6),
                                                              ),
                                                              child: Center(
                                                                child: Icon(
                                                                  Icons.person,
                                                                  size: 40,
                                                                  color: Colors.grey[600],
                                                                ),
                                                              ),
                                                            ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  
                                                  // Right: Character info and description
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        // Character name
                                                        Text(
                                                          char.name,
                                                          style: const TextStyle(
                                                            fontSize: 14,
                                                            fontWeight: FontWeight.bold,
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                        const SizedBox(height: 6),
                                                        
                                                        // Editable description field
                                                        Container(
                                                          decoration: BoxDecoration(
                                                            color: Colors.grey[800],
                                                            borderRadius: BorderRadius.circular(4),
                                                            border: Border.all(color: Colors.grey[700]!),
                                                          ),
                                                          child: TextField(
                                                            controller: _getCharDescController(char.id, char.fullDescription),
                                                            maxLines: 4,
                                                            style: TextStyle(
                                                              fontSize: 10,
                                                              color: Colors.grey[300],
                                                              height: 1.4,
                                                            ),
                                                            decoration: InputDecoration(
                                                              contentPadding: const EdgeInsets.all(8),
                                                              border: InputBorder.none,
                                                              hintText: 'Edit character description...',
                                                              hintStyle: TextStyle(
                                                                fontSize: 10,
                                                                color: Colors.grey[600],
                                                              ),
                                                            ),
                                                            onChanged: (value) {
                                                              // Update character description directly WITHOUT setState
                                                              // Controller is persistent so cursor position is preserved
                                                              final charIndex = _detectedCharacters.indexWhere((c) => c.id == char.id);
                                                              if (charIndex != -1) {
                                                                _detectedCharacters[charIndex] = DetectedCharacter(
                                                                  id: char.id,
                                                                  name: char.name,
                                                                  outfit: char.outfit,
                                                                  fullDescription: value,
                                                                  referenceImagePath: char.referenceImagePath,
                                                                  referenceMediaId: char.referenceMediaId,
                                                                  appearsInScenes: char.appearsInScenes,
                                                                  isGeneratingImage: char.isGeneratingImage,
                                                                );
                                                              }
                                                            },
                                                          ),
                                                        ),
                                                        const SizedBox(height: 8),
                                                        
                                                        // Action buttons row
                                                        Row(
                                                          children: [
                                                            // Import Image button
                                                            Expanded(
                                                              child: ElevatedButton.icon(
                                                                onPressed: char.isGeneratingImage
                                                                    ? null
                                                                    : () => _importCharacterImage(char),
                                                                icon: const Icon(Icons.folder_open, size: 14),
                                                                label: const Text(
                                                                  'Import',
                                                                  style: TextStyle(fontSize: 10),
                                                                ),
                                                                style: ElevatedButton.styleFrom(
                                                                  backgroundColor: Colors.blue.withOpacity(0.1),
                                                                  foregroundColor: Colors.blue,
                                                                  elevation: 0,
                                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                                  visualDensity: VisualDensity.compact,
                                                                ),
                                                              ),
                                                            ),
                                                            const SizedBox(width: 6),
                                                            // Generate/Regenerate button
                                                            Expanded(
                                                              flex: 2,
                                                              child: ElevatedButton.icon(
                                                                onPressed: char.isGeneratingImage
                                                                    ? null
                                                                    : () => _generateCharacterImage(char),
                                                                icon: Icon(
                                                                  char.referenceImagePath == null 
                                                                    ? Icons.auto_awesome 
                                                                    : Icons.refresh,
                                                                  size: 14,
                                                                ),
                                                                label: char.isGeneratingImage
                                                                    ? const SizedBox(
                                                                        width: 12,
                                                                        height: 12,
                                                                        child: CircularProgressIndicator(
                                                                          strokeWidth: 2,
                                                                          color: Colors.white,
                                                                        ),
                                                                      )
                                                                    : Text(
                                                                        char.referenceImagePath == null
                                                                            ? 'Generate'
                                                                            : 'Regenerate',
                                                                        style: const TextStyle(fontSize: 10),
                                                                      ),
                                                                style: ElevatedButton.styleFrom(
                                                                  backgroundColor: const Color(0xFF10B981),
                                                                  foregroundColor: Colors.white,
                                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                                  visualDensity: VisualDensity.compact,
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Right Panel - Video Clips (Now includes the Parent TabBar at top)
          Expanded(
            child: Column(
              children: [
                // Integrated Parent TabBar (Ultra Narrow)
                Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: tp.surfaceBg,
                    border: Border(bottom: BorderSide(color: tp.borderColor)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TabBar(
                          controller: widget.tabController,
                          labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                          indicatorSize: TabBarIndicatorSize.label,
                          tabs: [
                            Tab(
                              height: 32,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.edit_note, size: 16),
                                  SizedBox(width: 4),
                                  Text(LocalizationService().tr('scene.create_story'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                            Tab(
                              height: 32,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.movie_creation, size: 16),
                                  SizedBox(width: 4),
                                  Text(LocalizationService().tr('scene.generate_videos'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Right Panel Content
                Expanded(
                  child: Container(
                    color: tp.isDarkMode ? tp.scaffoldBg : Colors.grey.shade100,
                    child: widget.project == null ? const Center(child: Text('Parse JSON to view clips'))
                      : Column(children: [
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: tp.surfaceBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: tp.borderColor),
                ),
                child: Row(children: [
                  // Stats — left
                  _buildMiniStat(LocalizationService().tr('scene.total'), widget.project!.frames.length, Colors.blue),
                  _buildMiniStat(LocalizationService().tr('scene.generate_label'), widget.project!.frames.where((f) => f.generateImage).length, Colors.orange),
                  _buildMiniStat(LocalizationService().tr('scene.reuse'), widget.project!.frames.where((f) => !f.generateImage).length, Colors.green),
                  _buildMiniStat(LocalizationService().tr('scene.done_label'), widget.imageBytes.length, Colors.purple),
                  
                  Container(height: 24, width: 1, color: tp.borderColor, margin: const EdgeInsets.symmetric(horizontal: 6)),
                  
                  // Compact toggles — only one active at a time
                  _buildCompactToggle(tp, 'Skip 3,5,7', widget.autoReuse, (v) {
                    if (v) { if (widget.useOddAsRefForEven) widget.onPairedRefChanged(false); if (_useTimelapse) _useTimelapse = false; }
                    widget.onAutoReuseChanged(v); setState(() {});
                  }, 'Skip 3,5,7.. Image', 'When enabled, odd-numbered frames (3, 5, 7...) will be skipped during generation.\n\n• Frame 3 → Skipped (reuses Frame 2)\n• Frame 5 → Skipped (reuses Frame 4)\n\n⚠️ Re-parse JSON after toggling.'),
                  const SizedBox(width: 8),
                  _buildCompactToggle(tp, 'Paired Ref', widget.useOddAsRefForEven, (v) {
                    if (v) { if (widget.autoReuse) widget.onAutoReuseChanged(false); if (_useTimelapse) _useTimelapse = false; }
                    widget.onPairedRefChanged(v); setState(() {});
                  }, 'Paired Reference', 'Odd frames are used as reference for even frames.\n\n• Frame 1 → Generated\n• Frame 2 → Uses Frame 1 as ref\n\nGreat for before/after scenes.'),
                  const SizedBox(width: 8),
                  _buildCompactToggle(tp, 'Prev img as Ref', _useTimelapse, (v) {
                    if (v) { if (widget.autoReuse) widget.onAutoReuseChanged(false); if (widget.useOddAsRefForEven) widget.onPairedRefChanged(false); }
                    setState(() { _useTimelapse = v; _skipVideoActionPrompts = false; });
                    _saveTimelapseState();
                  }, 'Prev Image as Ref (Timelapse)', 'Each image is used as reference for the next frame.\n\n• Frame 2 → Uses Frame 1 as ref\n• Frame 3 → Uses Frame 2 as ref\n\n⚠️ Batch size forced to 1.\nPerfect for timelapse & gradual changes.'),
                  
                  const Spacer(),
                  // Open Output Folder
                  Tooltip(message: 'Open output folder', child: InkWell(onTap: widget.onOpenFolder, child: Row(children: [
                    Icon(Icons.folder_open, color: tp.isDarkMode ? tp.textSecondary : Colors.deepPurple, size: 16),
                    const SizedBox(width: 3),
                    Text(LocalizationService().tr('scene.open_output'), style: TextStyle(color: tp.isDarkMode ? tp.textSecondary : Colors.deepPurple, fontSize: 10, fontWeight: FontWeight.bold)),
                  ]))),
                  const SizedBox(width: 8),
                  // Clear All
                  Tooltip(message: 'Clear all images', child: InkWell(onTap: widget.onClearAllImages, child: Row(children: [
                    Icon(Icons.clear_all, color: tp.isDarkMode ? tp.textSecondary : Colors.red, size: 16),
                    const SizedBox(width: 3),
                    Text(LocalizationService().tr('scene.clear_all_images'), style: TextStyle(color: tp.isDarkMode ? tp.textSecondary : Colors.red, fontSize: 10, fontWeight: FontWeight.bold)),
                  ]))),
                ]),
              ),
              // Video Action Prompts — shown when Prev img as Ref is ON
              if (_useTimelapse && !_skipVideoActionPrompts)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: tp.isDarkMode ? Colors.teal.shade900.withOpacity(0.2) : Colors.teal.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tp.isDarkMode ? Colors.teal.shade700.withOpacity(0.4) : Colors.teal.shade200),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Header row
                    Row(children: [
                      Icon(Icons.movie_creation, size: 14, color: tp.isDarkMode ? Colors.tealAccent : Colors.teal.shade700),
                      const SizedBox(width: 6),
                      Text('Video Action Prompts', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: tp.isDarkMode ? Colors.tealAccent : Colors.teal.shade800)),
                      const SizedBox(width: 8),
                      // Live count badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _videoActionPrompts.isNotEmpty 
                            ? (tp.isDarkMode ? Colors.teal.shade800 : Colors.teal.shade100) 
                            : (tp.isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${_videoActionPrompts.length} prompt${_videoActionPrompts.length == 1 ? '' : 's'}',
                          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: _videoActionPrompts.isNotEmpty 
                            ? (tp.isDarkMode ? Colors.tealAccent : Colors.teal.shade700) 
                            : tp.textTertiary),
                        ),
                      ),
                      if (widget.project != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '(need ${(widget.project!.frames.length - 1).clamp(0, 999)} for ${widget.project!.frames.length} images)',
                          style: TextStyle(fontSize: 9, color: tp.textTertiary),
                        ),
                      ],
                      const Spacer(),
                      // Apply button
                      if (_videoActionPrompts.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _applyVideoActionPrompts();
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('✅ ${_videoActionPrompts.length} video action prompts applied to image pairs'),
                              backgroundColor: Colors.teal,
                              duration: const Duration(seconds: 2),
                            ));
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.teal,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('Apply', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white)),
                          ),
                        ),
                      const SizedBox(width: 6),
                      // Skip button
                      GestureDetector(
                        onTap: () => setState(() => _skipVideoActionPrompts = true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: tp.isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('Skip', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: tp.textSecondary)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    // Input area
                    Container(
                      constraints: const BoxConstraints(maxHeight: 80),
                      child: TextField(
                        controller: _videoActionPromptController,
                        maxLines: null,
                        style: TextStyle(fontSize: 11, color: tp.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Paste video action prompts — one per line or JSON array\ne.g. "Camera slowly pans across the room..."',
                          hintStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
                          contentPadding: const EdgeInsets.all(8),
                          isDense: true,
                          filled: true,
                          fillColor: tp.isDarkMode ? tp.inputBg : Colors.white,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.borderColor)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tp.borderColor)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: Colors.teal.shade400)),
                        ),
                        onChanged: (text) {
                          setState(() {
                            _videoActionPrompts = _parseActionPrompts(text);
                          });
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    // Video Model & Aspect Ratio selectors
                    Row(children: [
                      // Model selector
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: tp.isDarkMode ? tp.inputBg : Colors.white,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: tp.borderColor),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: AppConfig.flowModelOptionsUltra.containsValue(widget.selectedVideoModel)
                                  ? widget.selectedVideoModel
                                  : AppConfig.flowModelOptionsUltra.values.first,
                              isDense: true,
                              isExpanded: true,
                              style: TextStyle(fontSize: 10, color: tp.textPrimary, fontWeight: FontWeight.w500),
                              icon: Icon(Icons.arrow_drop_down, size: 16, color: tp.textSecondary),
                              items: AppConfig.flowModelOptionsUltra.entries.map((e) =>
                                DropdownMenuItem(value: e.value, child: Text(e.key, style: TextStyle(fontSize: 10, color: tp.textPrimary))),
                              ).toList(),
                              onChanged: (val) {
                                if (val != null) widget.onVideoModelChanged(val);
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // Aspect ratio selector
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: tp.isDarkMode ? tp.inputBg : Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: tp.borderColor),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: widget.selectedVideoAspectRatio,
                            isDense: true,
                            style: TextStyle(fontSize: 10, color: tp.textPrimary, fontWeight: FontWeight.w500),
                            icon: Icon(Icons.arrow_drop_down, size: 16, color: tp.textSecondary),
                            items: const [
                              DropdownMenuItem(value: 'VIDEO_ASPECT_RATIO_LANDSCAPE', child: Text('16:9', style: TextStyle(fontSize: 10))),
                              DropdownMenuItem(value: 'VIDEO_ASPECT_RATIO_PORTRAIT', child: Text('9:16', style: TextStyle(fontSize: 10))),
                            ],
                            onChanged: (val) {
                              if (val != null) widget.onVideoAspectRatioChanged(val);
                            },
                          ),
                        ),
                      ),
                    ]),
                  ]),
                ),
                // Generate All Videos button
                if (widget.project != null && widget.project!.videoClips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: SizedBox(
                      width: double.infinity,
                      height: 36,
                      child: ElevatedButton.icon(
                        onPressed: _clipGenerating.isNotEmpty ? null : () => _generateAllVideos(),
                        icon: Icon(
                          _clipGenerating.isNotEmpty ? Icons.hourglass_top : Icons.play_circle_filled,
                          size: 16,
                        ),
                        label: Text(
                          _clipGenerating.isNotEmpty
                              ? 'Generating ${_clipGenerating.length} clip(s)...'
                              : 'Generate All Videos (${_useTimelapse ? (widget.project!.videoClips.length - 1).clamp(0, 999) : widget.project!.videoClips.length})',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _clipGenerating.isNotEmpty
                              ? Colors.grey.shade400
                              : Colors.deepPurple,
                          disabledBackgroundColor: Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white70,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
                // Join All Clips button
                if (widget.project != null && widget.project!.videoClips.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    child: SizedBox(
                      width: double.infinity,
                      height: 32,
                      child: ElevatedButton.icon(
                        onPressed: _isJoiningClips ? null : () => _joinAllClips(),
                        icon: Icon(
                          _isJoiningClips ? Icons.hourglass_top : Icons.merge_type,
                          size: 14,
                        ),
                        label: Text(
                          _isJoiningClips ? 'Joining...' : 'Join All Clips',
                          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isJoiningClips ? Colors.grey.shade400 : Colors.teal.shade700,
                          disabledBackgroundColor: Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white70,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ),
              if (_detectedCharacters.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: ElevatedButton.icon(
                    onPressed: _isGeneratingScenes
                        ? () => setState(() => _isGeneratingScenes = false)
                        : _generateScenesWithCharacters,
                    icon: Icon(
                      _isGeneratingScenes ? Icons.stop : Icons.movie_creation,
                      size: 18,
                    ),
                    label: Text(
                      _isGeneratingScenes
                          ? 'Stop Generating'
                          : 'Generate All Scenes with Characters',
                      style: const TextStyle(fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isGeneratingScenes
                          ? Colors.red
                          : const Color(0xFF10B981),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      minimumSize: const Size(double.infinity, 48),
                    ),
                  ),
                ),
              // Grid View - Dynamic per row with editable prompts
              Expanded(
                child: Builder(
                  builder: (context) {
                    final int itemsPerRow = _selectedAspectRatio == 'IMAGE_ASPECT_RATIO_PORTRAIT' ? 4 : 2;
                    final allFrames = widget.project!.frames;
                    final hasClips = _useTimelapse && widget.project!.videoClips.isNotEmpty;
                    
                    // When hasClips: one row per clip (img_N + connector + img_N+1)
                    // When no clips: original batch-of-frames layout
                    if (hasClips) {
                      final clips = widget.project!.videoClips;
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        itemCount: (clips.length - 1).clamp(0, clips.length), // N frames = N-1 transitions
                        itemBuilder: (ctx, clipIdx) {
                          final clip = clips[clipIdx];
                          // In timelapse mode, clips are N→N (same frame both sides)
                          // because each clip's prompt belongs to frame N,
                          // but the VIDEO goes from frame N → frame N+1.
                          // So: left = frame[clipIdx], right = frame[clipIdx+1]
                          final leftFrame = clipIdx < allFrames.length
                              ? allFrames[clipIdx]
                              : allFrames.last;
                          final rightFrame = (clipIdx + 1) < allFrames.length
                              ? allFrames[clipIdx + 1]
                              : allFrames.last;
                          final globalLeftIdx = clipIdx;
                          final globalRightIdx = (clipIdx + 1).clamp(0, allFrames.length - 1);
                          
                          final ctrlKey = '${clip.firstFrame}_${clip.lastFrame}';
                          if (!_clipPromptControllers.containsKey(ctrlKey)) {
                            _clipPromptControllers[ctrlKey] = TextEditingController(text: clip.veo3Prompt);
                          }
                          final ctrl = _clipPromptControllers[ctrlKey]!;
                          
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Left image card
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: _buildFrameWithPrompt(leftFrame),
                                    ),
                                  ),
                                  // Connector
                                  SizedBox(
                                    width: 180,
                                    child: Container(
                                      margin: const EdgeInsets.symmetric(horizontal: 4),
                                      decoration: BoxDecoration(
                                        color: tp.surfaceBg,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: tp.borderColor),
                                        boxShadow: [BoxShadow(color: tp.shadowColor, blurRadius: 4, offset: const Offset(0, 2))],
                                      ),
                                      child: Column(children: [
                                        // 1. Header
                                        Container(
                                          width: double.infinity,
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: tp.isDarkMode ? tp.headerBg : Colors.grey.shade100,
                                            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                                          ),
                                          child: Column(children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Colors.teal,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: const Text('Video Action Prompt',
                                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                                            ),
                                            const SizedBox(height: 4),
                                            Text('#${globalLeftIdx + 1} → #${globalRightIdx + 1}',
                                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: tp.textPrimary)),
                                          ]),
                                        ),
                                        
                                        // 2. Badges Placeholder
                                        if (_detectedCharacters.isNotEmpty)
                                          const SizedBox(height: 38),

                                        // 3. Video/Thumbnail Area
                                        Expanded(child: Builder(builder: (ctx) {
                                          final videoPath = path.join(_connectorVideosDir, 'scene_${(2001 + clipIdx).toString().padLeft(4, '0')}.mp4');
                                          final videoFile = File(videoPath);
                                          final exists = videoFile.existsSync();
                                          final isGen = _clipGenerating.contains(clipIdx);
                                          // Only show Done / play buttons if file physically exists
                                          final isDone = exists; // file existence is the source of truth
                                          final showActions = exists;

                                          return Container(
                                            color: tp.isDarkMode ? Colors.black12 : Colors.grey.shade200,
                                            padding: EdgeInsets.symmetric(vertical: widget.selectedVideoAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? 12 : 0),
                                            child: Center(
                                              child: ConstrainedBox(
                                                constraints: BoxConstraints(
                                                  maxHeight: widget.selectedVideoAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? 260 : double.infinity,
                                                ),
                                                child: AspectRatio(
                                                  aspectRatio: widget.selectedVideoAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? 9/16 
                                                             : (widget.selectedVideoAspectRatio == 'VIDEO_ASPECT_RATIO_SQUARE' ? 1/1 : 16/9),
                                                  child: Container(
                                                    margin: const EdgeInsets.all(8),
                                                    decoration: BoxDecoration(
                                                      color: tp.isDarkMode ? Colors.black26 : Colors.grey.shade300,
                                                      borderRadius: widget.selectedVideoAspectRatio == 'VIDEO_ASPECT_RATIO_PORTRAIT' ? BorderRadius.circular(4) : BorderRadius.circular(6),
                                                      border: Border.all(color: tp.borderColor.withOpacity(0.5)),
                                                    ),
                                                    child: Stack(fit: StackFit.expand, children: [
                                                      // Background thumbnail
                                                      if (widget.imageBytes.containsKey(allFrames[globalLeftIdx].frameId)) 
                                                        Opacity(
                                                          opacity: 0.5,
                                                          child: Image.memory(widget.imageBytes[allFrames[globalLeftIdx].frameId]!, fit: BoxFit.cover),
                                                        )
                                                      else
                                                        Center(child: Icon(Icons.videocam_outlined, size: 30, color: tp.textTertiary.withOpacity(0.3))),
                                                      
                                                      // Play / Folder overlay icons
                                                      if (showActions)
                                                        Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
                                                          IconButton(
                                                            icon: const Icon(Icons.folder_open, color: Colors.white, size: 20),
                                                            onPressed: () {
                                                              if (exists) {
                                                                _openVideoFolder(videoPath);
                                                              } else {
                                                                // Try to open the videos directory
                                                                _openVideoFolder(_connectorVideosDir);
                                                              }
                                                            },
                                                            tooltip: 'Open folder',
                                                            style: IconButton.styleFrom(backgroundColor: Colors.black54, padding: const EdgeInsets.all(6)),
                                                          ),
                                                          const SizedBox(width: 6),
                                                          IconButton(
                                                            icon: const Icon(Icons.play_arrow, color: Colors.white, size: 24),
                                                            onPressed: () {
                                                              if (exists) {
                                                                _openVideoInVLC(videoPath);
                                                              } else {
                                                                ScaffoldMessenger.of(context).showSnackBar(
                                                                  SnackBar(content: Text('Video file not found at: $videoPath'), backgroundColor: Colors.orange),
                                                                );
                                                              }
                                                            },
                                                            tooltip: 'Play video',
                                                            style: IconButton.styleFrom(backgroundColor: Colors.teal.withOpacity(0.85), padding: const EdgeInsets.all(6)),
                                                          ),
                                                        ])),
                                                      
                                                      // Status overlay
                                                      if (_clipGenerationStatus.containsKey(clipIdx))
                                                        Positioned(bottom: 4, left: 4, right: 4, 
                                                          child: Container(
                                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                                            decoration: BoxDecoration(
                                                              color: Colors.black54,
                                                              borderRadius: BorderRadius.circular(3),
                                                            ),
                                                            child: Text(_clipGenerationStatus[clipIdx]!, 
                                                              style: const TextStyle(color: Colors.white, fontSize: 8), 
                                                              textAlign: TextAlign.center, overflow: TextOverflow.ellipsis),
                                                          ),
                                                        ),
                                                    ]),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          );
                                        })),

                                        // 4. Prompt & Generate Button
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: tp.isDarkMode ? tp.inputBg : Colors.white,
                                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              TextField(
                                                controller: ctrl,
                                                style: TextStyle(fontSize: 10, height: 1.3, color: tp.textPrimary),
                                                maxLines: 3,
                                                decoration: InputDecoration(
                                                  hintText: 'Describe action...',
                                                  hintStyle: TextStyle(fontSize: 10, color: tp.textTertiary),
                                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                                                  isDense: true,
                                                  contentPadding: const EdgeInsets.all(8),
                                                  fillColor: tp.isDarkMode ? tp.headerBg : Colors.grey.shade50,
                                                  filled: true,
                                                ),
                                                onChanged: (text) {
                                                  _clipPromptSaveTimer?.cancel();
                                                  _clipPromptSaveTimer = Timer(const Duration(seconds: 5), () {
                                                    _saveClipPrompt(clipIdx, text);
                                                  });
                                                },
                                              ),
                                              const SizedBox(height: 6),
                                              SizedBox(
                                                width: double.infinity,
                                                height: 32,
                                                child: ElevatedButton.icon(
                                                  onPressed: _clipGenerating.contains(clipIdx) ? null : () => _generateSingleVideo(clipIdx),
                                                  icon: const Icon(Icons.movie_creation, size: 14),
                                                  label: Text(
                                                    _clipGenerating.contains(clipIdx) ? 'Generating...' : 'Generate Video',
                                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                                  ),
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor: Colors.teal,
                                                    foregroundColor: Colors.white,
                                                    disabledBackgroundColor: Colors.grey.shade400,
                                                    disabledForegroundColor: Colors.white70,
                                                    padding: EdgeInsets.zero,
                                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ]),
                                    ),
                                  ),
                                  // Right image card
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: _buildFrameWithPrompt(rightFrame),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    }
                    
                    // No clips — original frame-based grid
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      itemCount: (allFrames.length / itemsPerRow).ceil(),
                      itemBuilder: (ctx, rowIndex) {
                        final startIdx = rowIndex * itemsPerRow;
                        final frames = allFrames.skip(startIdx).take(itemsPerRow).toList();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (int i = 0; i < frames.length; i++) ...[
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6),
                                      child: _buildFrameWithPrompt(frames[i]),
                                    ),
                                  ),
                                ],
                                if (frames.length < itemsPerRow) 
                                  ...List.generate(itemsPerRow - frames.length, (_) => const Expanded(child: SizedBox())),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
               ),
            ]),  // Column children (line 4342)
          ),  // Container (line 4339)
        ),  // Expanded (line 4338)
      ],  // Column children (line 4292)
    ),  // Column (line 4291)
  ),  // Expanded (line 4290)
        ],
      );
      },
    );
  }


  /// Save an edited clip prompt back to the project's videoClips
  void _saveClipPrompt(int clipIdx, String newPrompt) {
    if (widget.project == null || clipIdx < 0 || clipIdx >= widget.project!.videoClips.length) return;
    final old = widget.project!.videoClips[clipIdx];
    widget.project!.videoClips[clipIdx] = VideoClip(
      clipId: old.clipId,
      firstFrame: old.firstFrame,
      lastFrame: old.lastFrame,
      durationSeconds: old.durationSeconds,
      veo3Prompt: newPrompt,
      audioDescription: old.audioDescription,
    );
    print('💾 Auto-saved action prompt for clip ${old.clipId}: ${newPrompt.length > 40 ? '${newPrompt.substring(0, 40)}...' : newPrompt}');
  }

  /// Parse action prompts from text — supports JSON array or newline-separated
  List<String> _parseActionPrompts(String text) {
    if (text.trim().isEmpty) return [];
    // Try JSON array first
    final trimmed = text.trim();
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded.map((e) => e.toString().trim()).where((s) => s.isNotEmpty).toList();
        }
      } catch (_) {}
    }
    // Fall back to newline-separated
    return text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  }

  /// Apply video action prompts to image pairs and store as VideoClips
  void _applyVideoActionPrompts() {
    if (widget.project == null) return;
    final frames = widget.project!.frames;
    if (frames.length < 2) return;
    
    final clips = <VideoClip>[];
    for (int i = 0; i < frames.length - 1; i++) {
      final prompt = i < _videoActionPrompts.length ? _videoActionPrompts[i] : '';
      clips.add(VideoClip(
        clipId: 'video_${(i + 1).toString().padLeft(3, '0')}',
        firstFrame: frames[i].frameId,
        lastFrame: frames[i + 1].frameId,
        durationSeconds: 5,
        veo3Prompt: prompt,
        audioDescription: '',
      ));
    }
    // Update the project's videoClips
    widget.project!.videoClips.clear();
    widget.project!.videoClips.addAll(clips);
    setState(() {});
    print('🎬 Applied ${clips.length} video action prompts to image pairs');
  }

  Widget _buildCompactToggle(dynamic tp, String label, bool isActive, Function(bool) onToggle, String infoTitle, String infoContent) {
    final color = tp.isDarkMode 
      ? (isActive ? Colors.deepPurple.shade300 : tp.textSecondary) 
      : (isActive ? Colors.deepPurple.shade700 : tp.textSecondary);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: TextStyle(fontSize: 10, fontWeight: isActive ? FontWeight.w600 : FontWeight.w400, color: color)),
      Transform.scale(
        scale: 0.5,
        child: Switch(
          value: isActive,
          onChanged: onToggle,
          activeColor: Colors.deepPurple,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      GestureDetector(
        onTap: () => showDialog(context: context, builder: (ctx) => AlertDialog(
          title: Text(infoTitle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          content: Text(infoContent, style: const TextStyle(fontSize: 13, height: 1.5)),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
        )),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(Icons.info_outline, size: 14, color: tp.isDarkMode ? Colors.blueGrey.shade300 : Colors.blueGrey.shade600),
        ),
      ),
    ]);
  }

  // Track SceneData objects for each clip so we can poll their status
  final Map<int, SceneData> _clipScenes = {};
  Timer? _clipPollTimer;

  Future<void> _generateSingleVideo(int clipIdx) async {
    if (widget.project == null || clipIdx < 0 || clipIdx >= widget.project!.videoClips.length) return;
    final clip = widget.project!.videoClips[clipIdx];
    
    // Check browsers
    final connectedCount = VideoGenerationService().profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please connect browsers first in Generate Videos tab')));
      return;
    }

    setState(() => _clipGenerationStatus[clipIdx] = '⏳ Preparing...');

    try {
      // 1. Resolve frames based on mode:
      // - Timelapse: frame[N] → frame[N+1]
      // - Normal:    clip.firstFrame → clip.lastFrame
      final allFrames = widget.project!.frames;
      if (clipIdx >= allFrames.length) throw 'Clip index out of range';
      late final StoryFrame f1;
      StoryFrame? f2;
      if (_useTimelapse) {
        f1 = allFrames[clipIdx];
        f2 = (clipIdx + 1) < allFrames.length ? allFrames[clipIdx + 1] : null;
      } else {
        final lf = widget.project!.getFrameById(clip.firstFrame);
        final rf = widget.project!.getFrameById(clip.lastFrame);
        if (lf == null) throw 'Missing first frame';
        f1 = lf;
        f2 = (rf != null && rf.frameId != lf.frameId) ? rf : null;
      }

      final p1 = path.join(widget.outputDir, '${f1.frameId}.png');
      final p2 = f2 != null ? path.join(widget.outputDir, '${f2.frameId}.png') : null;

      if (!File(p1).existsSync()) throw 'Missing first frame image: ${f1.frameId}.png';
      if (p2 != null && !File(p2).existsSync()) throw 'Missing last frame image: ${f2!.frameId}.png';

      // 2. Create SceneData
      final scene = SceneData(
        sceneId: 2001 + clipIdx,
        prompt: clip.veo3Prompt,
        status: 'queued',
        firstFramePath: p1,
        lastFramePath: p2,
      );

      // 3. Track this scene
      _clipScenes[clipIdx] = scene;

      setState(() {
        _clipGenerationStatus[clipIdx] = '⏳ Generating...';
        _clipGenerating.add(clipIdx);
      });

      print('🎬 Generating clip $clipIdx with model: ${widget.selectedVideoModel}, first: $p1, last: $p2');

      // CRITICAL: Set project folder so videos download to the correct directory
      // Service adds /videos/ subfolder automatically
      VideoGenerationService().setProjectFolder(path.join(Directory.current.path, 'v_output'));

      // Start polling timer if not already running
      _startClipPollTimer();

      // Fire and forget — don't await. The poll timer will track completion.
      VideoGenerationService().startBatch(
        [scene],
        model: widget.selectedVideoModel,
        aspectRatio: widget.selectedVideoAspectRatio,
      );

    } catch (e) {
      setState(() {
        _clipGenerationStatus[clipIdx] = '❌ Error: $e';
        _clipGenerating.remove(clipIdx);
      });
    }
  }

  /// Generate ALL video clips at once as a single batch
  Future<void> _generateAllVideos() async {
    if (widget.project == null || widget.project!.videoClips.isEmpty) return;

    // Check browsers
    final connectedCount = VideoGenerationService().profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please connect browsers first in Generate Videos tab')));
      return;
    }

    final clips = widget.project!.videoClips;
    final List<SceneData> allScenes = [];

    // In timelapse mode: N frames → N-1 transitions. Normal mode: process all clips.
    final loopLimit = _useTimelapse ? clips.length - 1 : clips.length;
    for (int clipIdx = 0; clipIdx < loopLimit; clipIdx++) {
      // Skip already generating or completed clips
      if (_clipGenerating.contains(clipIdx)) continue;
      final existingScene = _clipScenes[clipIdx];
      if (existingScene != null && existingScene.status == 'completed') {
        // Only skip if the video file actually still exists — if user deleted it, re-generate
        final videoPath = path.join(_connectorVideosDir, 'scene_${(2001 + clipIdx).toString().padLeft(4, '0')}.mp4');
        if (File(videoPath).existsSync()) continue;
        // File was deleted — reset status so it gets re-queued
        existingScene.status = 'queued';
      }

      final clip = clips[clipIdx];
      final allFrames = widget.project!.frames;
      if (clipIdx >= allFrames.length) continue;

      // Frame resolution:
      // - Timelapse: frame[N] → frame[N+1]  (index-based transition)
      // - Normal:    clip.firstFrame → clip.lastFrame (as defined in project)
      late final StoryFrame f1;
      StoryFrame? f2;
      if (_useTimelapse) {
        f1 = allFrames[clipIdx];
        f2 = (clipIdx + 1) < allFrames.length ? allFrames[clipIdx + 1] : null;
      } else {
        final lf = widget.project!.getFrameById(clip.firstFrame);
        final rf = widget.project!.getFrameById(clip.lastFrame);
        if (lf == null) { setState(() => _clipGenerationStatus[clipIdx] = '❌ Missing frame'); continue; }
        f1 = lf;
        f2 = (rf != null && rf.frameId != lf.frameId) ? rf : null;
      }

      final p1 = path.join(widget.outputDir, '${f1.frameId}.png');
      final p2 = f2 != null ? path.join(widget.outputDir, '${f2.frameId}.png') : null;

      if (!File(p1).existsSync()) {
        setState(() => _clipGenerationStatus[clipIdx] = '❌ Missing image: ${f1.frameId}.png');
        continue;
      }
      if (p2 != null && !File(p2).existsSync()) {
        setState(() => _clipGenerationStatus[clipIdx] = '❌ Missing image: ${f2!.frameId}.png');
        continue;
      }

      final scene = SceneData(
        sceneId: 2001 + clipIdx,
        prompt: clip.veo3Prompt,
        status: 'queued',
        firstFramePath: p1,
        lastFramePath: p2,
      );

      _clipScenes[clipIdx] = scene;
      allScenes.add(scene);

      setState(() {
        _clipGenerationStatus[clipIdx] = '⏳ Queued...';
        _clipGenerating.add(clipIdx);
      });
    }

    if (allScenes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No clips to generate (all completed or missing images)')));
      return;
    }

    print('🎬 Generating ALL ${allScenes.length} clips with model: ${widget.selectedVideoModel}');

    // Set project folder
    VideoGenerationService().setProjectFolder(path.join(Directory.current.path, 'v_output'));

    // Start polling timer
    _startClipPollTimer();

    // Fire single batch with all scenes
    VideoGenerationService().startBatch(
      allScenes,
      model: widget.selectedVideoModel,
      aspectRatio: widget.selectedVideoAspectRatio,
    );
  }

  /// Join all downloaded video clips into one combined video using FFmpeg
  Future<void> _joinAllClips() async {
    if (_connectorVideosDir.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No video directory set')));
      return;
    }

    setState(() => _isJoiningClips = true);

    try {
      final videosDir = Directory(_connectorVideosDir);
      if (!videosDir.existsSync()) {
        throw 'Videos directory does not exist: $_connectorVideosDir';
      }

      // Find all scene video files, sorted by name
      final videoFiles = videosDir.listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.mp4'))
          .toList()
        ..sort((a, b) => path.basename(a.path).compareTo(path.basename(b.path)));

      if (videoFiles.isEmpty) {
        throw 'No video files found in $_connectorVideosDir';
      }

      print('[JOIN] Found ${videoFiles.length} video files to join');

      // Create concat list file for FFmpeg
      final concatListPath = path.join(_connectorVideosDir, '_concat_list.txt');
      final concatContent = videoFiles.map((f) => "file '${f.path.replaceAll('\\', '/')}'").join('\n');
      await File(concatListPath).writeAsString(concatContent);

      // Output file
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final outputPath = path.join(_connectorVideosDir, 'joined_$timestamp.mp4');

      // Get FFmpeg path
      final ffmpegPath = await FFmpegUtils.getFFmpegPath();

      print('[JOIN] Running FFmpeg concat...');
      print('[JOIN] Output: $outputPath');

      // Run FFmpeg concat
      final result = await Process.run(
        ffmpegPath,
        [
          '-f', 'concat',
          '-safe', '0',
          '-i', concatListPath,
          '-c', 'copy',
          '-y',
          outputPath,
        ],
      );

      // Clean up concat list
      try { await File(concatListPath).delete(); } catch (_) {}

      if (result.exitCode != 0) {
        print('[JOIN] FFmpeg stderr: ${result.stderr}');
        throw 'FFmpeg failed (exit code ${result.exitCode})';
      }

      final outputFile = File(outputPath);
      if (!outputFile.existsSync()) {
        throw 'Output file not created';
      }

      final sizeMB = (outputFile.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
      print('[JOIN] ✅ Joined ${videoFiles.length} clips → $outputPath ($sizeMB MB)');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ Joined ${videoFiles.length} clips ($sizeMB MB)')),
        );
      }

      // Auto-open output folder
      _openVideoFolder(_connectorVideosDir);

    } catch (e) {
      print('[JOIN] ❌ Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('❌ Join failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isJoiningClips = false);
    }
  }

  /// Starts a periodic timer that checks all tracked clip scenes for completion.
  void _startClipPollTimer() {
    if (_clipPollTimer != null && _clipPollTimer!.isActive) return; // Already running
    
    _clipPollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) {
        _clipPollTimer?.cancel();
        return;
      }
      
      bool anyStillGenerating = false;
      
      for (final entry in _clipScenes.entries) {
        final clipIdx = entry.key;
        final scene = entry.value;
        
        if (!_clipGenerating.contains(clipIdx)) continue; // Already resolved
        
        // Check if file exists on disk (most reliable signal)
        final videoPath = path.join(_connectorVideosDir, 'scene_${scene.sceneId.toString().padLeft(4, '0')}.mp4');
        final fileExists = File(videoPath).existsSync();
        
        if (scene.status == 'completed' || fileExists) {
          setState(() {
            _clipGenerationStatus[clipIdx] = '✅ Done';
            _clipGenerating.remove(clipIdx);
          });
          print('✅ Clip $clipIdx completed (scene ${scene.sceneId}, file: $fileExists)');
        } else if (scene.status == 'failed') {
          setState(() {
            _clipGenerationStatus[clipIdx] = '❌ ${scene.error ?? "Failed"}';
            _clipGenerating.remove(clipIdx);
          });
          print('❌ Clip $clipIdx failed: ${scene.error}');
        } else {
          anyStillGenerating = true;
        }
      }
      
      // Stop timer if nothing is generating
      if (!anyStillGenerating) {
        _clipPollTimer?.cancel();
        _clipPollTimer = null;
      }
      
      // Force UI rebuild to update file existence checks
      if (mounted) setState(() {});
    });
  }

  Future<void> _openVideoInVLC(String videoPath) async {
    try {
      if (Platform.isWindows) {
        // Try to find VLC or just use default player
        await Process.run('cmd', ['/c', 'start', '', videoPath]);
      } else {
        await Process.run('open', [videoPath]);
      }
    } catch (e) {
      print('Error opening video: $e');
    }
  }

  Future<void> _openVideoFolder(String videoPath) async {
    try {
      final isDir = FileSystemEntity.isDirectorySync(videoPath);
      final dir = path.dirname(videoPath);
      if (Platform.isWindows) {
        if (isDir) {
          await Process.run('explorer', [videoPath]);
        } else {
          await Process.run('explorer', ['/select,', videoPath]);
        }
      } else {
        await Process.run('open', [isDir ? videoPath : dir]);
      }
    } catch (e) {
      print('Error opening folder: $e');
    }
  }

  Widget _buildFeatureToggle({
    required dynamic tp,
    required IconData icon,
    required String label,
    required bool isActive,
    required MaterialColor accentColor,
    required Function(bool) onToggle,
    required String infoTitle,
    required String infoContent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isActive 
          ? (tp.isDarkMode ? accentColor.shade900.withOpacity(0.4) : accentColor.shade50)
          : (tp.isDarkMode ? tp.inputBg : Colors.grey.shade50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive 
            ? (tp.isDarkMode ? accentColor.shade600 : accentColor.shade300)
            : (tp.isDarkMode ? tp.borderColor.withOpacity(0.3) : Colors.grey.shade300),
          width: 0.8,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: isActive 
          ? (tp.isDarkMode ? accentColor.shade300 : accentColor.shade700) 
          : tp.textSecondary),
        const SizedBox(width: 3),
        Text(label, style: TextStyle(
          fontSize: 9, fontWeight: FontWeight.w500,
          color: isActive 
            ? (tp.isDarkMode ? accentColor.shade200 : accentColor.shade800) 
            : tp.textSecondary,
        )),
        Transform.scale(
          scale: 0.55,
          child: Switch(
            value: isActive,
            onChanged: onToggle,
            activeColor: accentColor,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        GestureDetector(
          onTap: () => showDialog(context: context, builder: (ctx) => AlertDialog(
            title: Row(children: [
              Icon(icon, color: accentColor, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(infoTitle, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
            ]),
            content: Text(infoContent, style: const TextStyle(fontSize: 13, height: 1.5)),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
          )),
          child: Icon(Icons.info_outline, size: 11, 
            color: isActive 
              ? (tp.isDarkMode ? accentColor.shade400 : accentColor.shade400)
              : tp.textTertiary.withOpacity(0.5)),
        ),
      ]),
    );
  }

  Widget _buildMiniStat(String label, int value, Color color) {
    final tp = ThemeProvider();
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          Text('$value', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
          Text(label, style: TextStyle(fontSize: 9, color: tp.textTertiary)),
        ]),
      ),
    );
  }

  Widget _buildFrameWithPrompt(StoryFrame frame) {
    final tp = ThemeProvider();
    final isReused = !frame.generateImage && frame.reuseFrame != null;
    final displayFrameId = isReused ? frame.reuseFrame! : frame.frameId;
    final hasImg = widget.imageBytes.containsKey(displayFrameId);
    
    // Get the video clip for this frame
    final clip = widget.project!.videoClips.where((c) => c.firstFrame == frame.frameId || c.lastFrame == frame.frameId).firstOrNull;
    
    return DragTarget<String>(
      onWillAccept: (data) {
        if (data == null) return false;
        final frameIdx = widget.project!.frames.indexOf(frame) + 1;
        final existing = _sceneCharacterMap[frameIdx] ?? [];
        return !existing.contains(data);
      },
      onAccept: (charId) {
        final frameIdx = widget.project!.frames.indexOf(frame) + 1;
        setState(() {
          if (_sceneCharacterMap[frameIdx] == null) _sceneCharacterMap[frameIdx] = [];
          if (!_sceneCharacterMap[frameIdx]!.contains(charId)) {
             _sceneCharacterMap[frameIdx]!.add(charId);
          }
        });
        _saveCharacterData();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Character assigned to Scene $frameIdx'), 
          duration: const Duration(milliseconds: 800),
          backgroundColor: Colors.green,
        ));
      },
      builder: (context, candidateData, rejectedData) {
        return Container(
          decoration: BoxDecoration(
            color: tp.surfaceBg,
            borderRadius: BorderRadius.circular(8),
            border: candidateData.isNotEmpty 
              ? Border.all(color: Colors.greenAccent, width: 3)
              : Border.all(color: tp.borderColor),
            boxShadow: [BoxShadow(color: tp.shadowColor, blurRadius: 4, offset: const Offset(0, 2))],
          ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isReused 
                ? (tp.isDarkMode ? tp.inputBg : Colors.blue.shade50) 
                : (tp.isDarkMode ? tp.headerBg : Colors.grey.shade100),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isReused 
                    ? Colors.blue 
                    : Colors.deepPurple,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(frame.frameId.replaceAll('frame_', '#'), 
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
              ),
              if (isReused) ...[
                const SizedBox(width: 6),
                Icon(Icons.link, size: 14, color: Colors.blue.shade600),
                Text(' ${frame.reuseFrame!.replaceAll("frame_", "")}', 
                  style: TextStyle(fontSize: 10, color: Colors.blue.shade600)),
              ],
              const Spacer(),
              if (frame.isGenerating)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              else if (hasImg)
                Icon(Icons.check_circle, size: 16, color: Colors.green.shade500)
              else if (frame.generateImage)
                Icon(Icons.pending_outlined, size: 16, color: Colors.orange.shade400),
             ]),
          ),
          // Character badges (if any detected for this scene)
          if (_detectedCharacters.isNotEmpty) Builder(
            builder: (context) {
              // Get frame index
              final frameIdx = widget.project!.frames.indexOf(frame) + 1;
              // Get characters for this scene
              final sceneCharIds = _sceneCharacterMap[frameIdx] ?? [];
              final sceneChars = sceneCharIds
                  .map((id) => _detectedCharacters.firstWhere(
                        (c) => c.id == id,
                        orElse: () => DetectedCharacter(
                          id: '',
                          name: '',
                          outfit: '',
                          fullDescription: '',
                          appearsInScenes: [],
                        ),
                      ))
                  .where((c) => c.id.isNotEmpty)
                  .toList();
              
              if (sceneChars.isEmpty) return const SizedBox.shrink();
              
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: tp.isDarkMode ? Colors.purple.withOpacity(0.15) : Colors.purple.shade50,
                  border: Border(
                    bottom: BorderSide(color: tp.borderColor),
                  ),
                ),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: sceneChars.map((char) {
                    return GestureDetector(
                      onTap: () {
                         final frameIdx = widget.project!.frames.indexOf(frame) + 1;
                         setState(() {
                             _sceneCharacterMap[frameIdx]?.remove(char.id); 
                         });
                         _saveCharacterData();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.purple.shade600,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 2, offset: const Offset(0, 1))],
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                           Text(
                             char.name,
                             style: const TextStyle(
                               color: Colors.white,
                               fontSize: 10,
                               fontWeight: FontWeight.w600,
                             ),
                           ),
                           const SizedBox(width: 4),
                           const Icon(Icons.close, size: 10, color: Colors.white70),
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
          // Image - Dynamic Aspect Ratio
          Container(
            color: tp.isDarkMode ? Colors.black12 : Colors.grey.shade200,
            padding: EdgeInsets.symmetric(vertical: _selectedAspectRatio == 'IMAGE_ASPECT_RATIO_PORTRAIT' ? 12 : 0),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: _selectedAspectRatio == 'IMAGE_ASPECT_RATIO_PORTRAIT' ? 260 : double.infinity,
                ),
                child: AspectRatio(
                  aspectRatio: _selectedAspectRatio == 'IMAGE_ASPECT_RATIO_PORTRAIT' ? 9/16 
                             : (_selectedAspectRatio == 'IMAGE_ASPECT_RATIO_SQUARE' ? 1/1 : 16/9),
                  child: hasImg 
                    ? Stack(fit: StackFit.expand, children: [
                        ClipRRect(
                          borderRadius: _selectedAspectRatio == 'IMAGE_ASPECT_RATIO_PORTRAIT' ? BorderRadius.circular(4) : BorderRadius.zero,
                          child: Container(
                            color: tp.isDarkMode ? Colors.black : Colors.grey.shade300,
                            child: Image.memory(widget.imageBytes[displayFrameId]!, fit: BoxFit.cover),
                          ),
                        ),
                        // Delete button
                        if (!isReused) Positioned(top: 4, right: 4,
                          child: IconButton(
                            icon: const Icon(Icons.close, size: 14),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black54,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.all(4),
                              minimumSize: const Size(24, 24),
                            ),
                            onPressed: () => setState(() => widget.imageBytes.remove(frame.frameId)),
                          ),
                        ),
                      ])
                    : Container(
                        color: tp.isDarkMode ? tp.inputBg : Colors.grey.shade100,
                        child: Center(
                          child: frame.isGenerating 
                            ? const CircularProgressIndicator(strokeWidth: 2)
                            : Column(mainAxisSize: MainAxisSize.min, children: [
                                Icon(isReused ? Icons.link : Icons.image_outlined, size: 32, color: Colors.grey.shade400),
                                if (isReused) Text('Uses ${frame.reuseFrame}', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                              ]),
                        ),
                      ),
                ),
              ),
            ),
          ),
          // Editable Prompt
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tp.isDarkMode ? tp.headerBg : Colors.grey.shade50,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Prompt TextField
                _PromptInputField(
                  initialValue: frame.prompt ?? clip?.veo3Prompt ?? '',
                  onChanged: (v) => frame.prompt = v,
                ),
                const SizedBox(height: 6),
                // Regenerate button
                Row(children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: isReused || frame.isGenerating || !widget.whiskApi.isAuthenticated
                        ? null 
                        : () => _generateFrameWithRetry(frame),
                      icon: Icon(frame.isGenerating ? Icons.hourglass_empty : Icons.refresh, size: 14),
                      label: Text(frame.isGenerating ? 'Generating...' : (hasImg ? 'Regenerate' : 'Generate'), 
                        style: const TextStyle(fontSize: 10)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepPurple,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        minimumSize: const Size(0, 28),
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
    },
    );
  }

  Widget _buildCompactFrameCard(StoryFrame frame) {
    final isReused = !frame.generateImage && frame.reuseFrame != null;
    final displayFrameId = isReused ? frame.reuseFrame! : frame.frameId;
    final hasImg = widget.imageBytes.containsKey(displayFrameId);
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isReused ? Colors.blue.shade200 : Colors.grey.shade300),
      ),
      child: Column(children: [
        // Compact header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isReused ? Colors.blue.shade50 : Colors.grey.shade100,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
          ),
          child: Row(children: [
            Text(frame.frameId, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10)),
            const Spacer(),
            if (isReused) 
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(3)),
                child: Text('↩${frame.reuseFrame!.replaceAll("frame_", "")}', 
                  style: const TextStyle(color: Colors.white, fontSize: 8)),
              )
            else if (!frame.generateImage)
              const Icon(Icons.check, color: Colors.green, size: 12),
          ]),
        ),
        // Image
        Expanded(
          child: hasImg 
            ? Stack(fit: StackFit.expand, children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                  child: Image.memory(widget.imageBytes[displayFrameId]!, fit: BoxFit.cover),
                ),
                if (frame.isGenerating)
                  Container(
                    color: Colors.black38,
                    child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
              ])
            : Container(
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(7)),
                ),
                child: Center(
                  child: frame.isGenerating 
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(isReused ? Icons.link : Icons.image, size: 24, color: Colors.grey.shade400),
                ),
              ),
        ),
      ]),
    );
  }

  Widget _buildStatusSummary() {
    if (widget.project == null) return const SizedBox();
    
    final totalFrames = widget.project!.frames.length;
    final framesToGenerate = widget.project!.frames.where((f) => f.generateImage).length;
    final reusedFrames = widget.project!.frames.where((f) => !f.generateImage && f.reuseFrame != null).length;
    final generatedCount = widget.imageBytes.length;
    
    return Row(children: [
      _buildMiniStat('Total', totalFrames, Colors.blue),
      _buildMiniStat('Generate', framesToGenerate, Colors.orange),
      _buildMiniStat('Reuse', reusedFrames, Colors.green),
      _buildMiniStat('Done', generatedCount, Colors.purple),
    ]);
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(children: [
        Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: TextStyle(fontSize: 9, color: Colors.grey.shade600)),
      ]),
    );
  }

  Widget _buildClipCard(VideoClip clip) {
    final first = widget.project!.getFrameById(clip.firstFrame);
    final last = widget.project!.getFrameById(clip.lastFrame);
    final isSingleFrame = clip.firstFrame == clip.lastFrame;
    
    return Card(margin: const EdgeInsets.only(bottom: 16), child: Column(children: [
      Container(padding: const EdgeInsets.all(12), color: Colors.deepPurple.shade50,
        child: Row(children: [
          Chip(label: Text(clip.clipId), backgroundColor: Colors.deepPurple, labelStyle: const TextStyle(color: Colors.white)),
          const SizedBox(width: 8), Text('${clip.durationSeconds}s'),
          const SizedBox(width: 16), Expanded(child: Text(clip.veo3Prompt, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
        ])),
      Padding(padding: const EdgeInsets.all(12), child: isSingleFrame
        // Single frame mode - show one larger frame
        ? (first != null ? _buildFrameCard(first) : const SizedBox())
        // Two frame mode - show first and last with arrow
        : Row(children: [
            if (first != null) Expanded(child: _buildFrameCard(first)),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, color: Colors.grey)),
            if (last != null) Expanded(child: _buildFrameCard(last)),
          ])),
    ]));
  }

  Widget _buildFrameCard(StoryFrame frame) {
    // Check if frame reuses another frame's image
    final isReused = !frame.generateImage && frame.reuseFrame != null;
    final displayFrameId = isReused ? frame.reuseFrame! : frame.frameId;
    final hasImg = widget.imageBytes.containsKey(displayFrameId);
    
    return Container(decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Container(padding: const EdgeInsets.all(8), color: isReused ? Colors.blue.shade50 : Colors.grey.shade100,
          child: Row(children: [
            Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(
              color: frame.framePosition == 'first' ? Colors.green : Colors.orange, borderRadius: BorderRadius.circular(4)),
              child: Text(frame.framePosition.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 10))),
            const SizedBox(width: 8), 
            Text(frame.frameId, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 11)),
            const SizedBox(width: 4),
            // Show generation status indicator
            if (!frame.generateImage) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade600,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: const [
                  Icon(Icons.check_circle, color: Colors.white, size: 10),
                  SizedBox(width: 2),
                  Text('NO GEN', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                ]),
              ),
            ],
            // Show reuse indicator
            if (isReused) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: 'Reuses ${frame.reuseFrame}',
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade600,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.link, size: 10, color: Colors.white),
                    const SizedBox(width: 2),
                    Text(frame.reuseFrame!.replaceAll('frame_', ''), 
                      style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            ],
          ])),
        AspectRatio(
          aspectRatio: _selectedAspectRatio == 'IMAGE_ASPECT_RATIO_PORTRAIT' ? 9/16 
                     : (_selectedAspectRatio == 'IMAGE_ASPECT_RATIO_SQUARE' ? 1/1 : 16/9),
          child: hasImg ? Stack(fit: StackFit.expand, children: [
          Image.memory(widget.imageBytes[displayFrameId]!, fit: BoxFit.cover),
          // Show "REUSED" badge overlay if this frame reuses another
          if (isReused) Positioned(
            top: 8, left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.blue.shade700.withOpacity(0.9),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white, width: 1),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.link, color: Colors.white, size: 12),
                const SizedBox(width: 4),
                Text('FROM ${frame.reuseFrame}', 
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
              ]),
            ),
          ),
          if (!isReused) Positioned(top: 4, right: 4, child: IconButton(icon: const Icon(Icons.close, size: 16), 
            style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
            onPressed: () => setState(() => widget.imageBytes.remove(frame.frameId)))),
        ]) : Container(color: Colors.grey.shade200, child: frame.isGenerating 
          ? const Center(child: CircularProgressIndicator())
          : Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(isReused ? Icons.link : Icons.image, color: Colors.grey),
              if (isReused) Text('Reuses ${frame.reuseFrame}', 
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
            ])))),
        Padding(padding: const EdgeInsets.all(8), child: ElevatedButton(
          onPressed: isReused ? null : (frame.isGenerating ? null : () => _generateFrameWithRetry(frame)),
          style: ElevatedButton.styleFrom(
            backgroundColor: isReused ? Colors.blue.shade100 : null,
          ),
          child: Text(
            isReused ? 'Reused Frame' : (frame.isGenerating ? 'Generating...' : 'Generate'),
            style: TextStyle(color: isReused ? Colors.blue.shade700 : null),
          ))),
        ExpansionTile(title: const Text('Prompt', style: TextStyle(fontSize: 12)), children: [
          Container(height: 100, margin: const EdgeInsets.all(8), padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4)),
            child: Scrollbar(child: SingleChildScrollView(
              child: SelectableText(frame.processedPrompt ?? '', style: const TextStyle(fontSize: 9, fontFamily: 'monospace'))))),
        ]),
      ]));
  }
}

// ============================================================================
// CLONE YOUTUBE TAB
// ============================================================================
// ============================================================================
// CLONE YOUTUBE TAB - Frame Sequencer Implementation
// ============================================================================
class CloneYouTubeTab extends StatefulWidget {
  final GeminiService geminiApi;
  final WhiskApiService whiskApi;
  final Function(StoryProject) onProjectLoaded;

  const CloneYouTubeTab({super.key, required this.geminiApi, required this.whiskApi, required this.onProjectLoaded});

  @override State<CloneYouTubeTab> createState() => _CloneYouTubeTabState();
}

class _CloneYouTubeTabState extends State<CloneYouTubeTab> {
  final _urlController = TextEditingController();
  final _clipsController = TextEditingController();
  String _selectedModel = 'gemini-3-flash-preview';
  int _numClips = 5;
  bool _isAnalyzing = false;
  String? _error, _result;
  bool _copied = false;
  int _apiKeyCount = 0;

  final List<Map<String, String>> _models = [
    {'id': 'gemini-3-flash-preview', 'name': 'Gemini 3 Flash'},
    {'id': 'gemini-3-pro-preview', 'name': 'Gemini 3 Pro'},
    {'id': 'gemini-2.5-flash-latest', 'name': 'Gemini 2.5 Flash'},
    {'id': 'gemini-2.5-pro-latest', 'name': 'Gemini 2.5 Pro'},
  ];

  @override
  void initState() {
    super.initState();
    _clipsController.text = _numClips.toString();
    _loadSettings();
    _loadApiKeyCount();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _clipsController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKeyCount() async {
    try {
      final service = await GeminiApiService.loadFromFile();
      setState(() => _apiKeyCount = service.keyCount);
      print('✅ Loaded ${service.keyCount} API keys from Settings');
    } catch (e) {
      print('⚠️  Could not load API keys: $e');
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settingsFile = File('${Directory.current.path}/frame_sequencer_settings.json');
      if (await settingsFile.exists()) {
        final json = jsonDecode(await settingsFile.readAsString());
        final loadedModel = json['selected_model'] ?? 'gemini-3-flash-preview';
        // Validate model exists in our list, otherwise use default
        final validModelIds = _models.map((m) => m['id']).toList();
        final validModel = validModelIds.contains(loadedModel) ? loadedModel : 'gemini-3-flash-preview';
        
        setState(() {
          _urlController.text = json['youtube_url'] ?? 'https://www.youtube.com/watch?v=84AI0Qa1k8o';
          _selectedModel = validModel;
          _numClips = json['num_clips'] ?? 5;
          _clipsController.text = _numClips.toString();
        });
        print('✅ Loaded saved settings (model: $validModel)');
      }
    } catch (e) {
      print('⚠️  Could not load settings: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final settingsFile = File('${Directory.current.path}/frame_sequencer_settings.json');
      await settingsFile.writeAsString(jsonEncode({
        'youtube_url': _urlController.text,
        'selected_model': _selectedModel,
        'num_clips': _numClips,
      }));
      print('💾 Settings saved');
    } catch (e) {
      print('⚠️  Could not save settings: $e');
    }
  }

  Future<void> _analyze() async {
    if (_urlController.text.isEmpty) {
      setState(() => _error = 'Enter YouTube URL');
      return;
    }
    
    if (_apiKeyCount == 0) {
      setState(() => _error = 'No API keys configured. Please add Gemini API keys in Settings.');
      return;
    }
    
    await _saveSettings();
    setState(() { _isAnalyzing = true; _error = null; _result = null; });
    
    try {
      // Load GeminiApiService with rotation support
      final geminiService = await GeminiApiService.loadFromFile();
      
      if (geminiService.apiKeys.isEmpty) {
        throw Exception('No API keys found. Please add keys in Settings > Gemini API.');
      }
      
      print('🔑 Using ${geminiService.keyCount} API keys with rotation');
      
      final prompt = '''Deconstruct this video into $_numClips distinct visual scenes/keyframes.
          
TASK 1: CHARACTER PROFILING
Identify every key character. Provide an EXTREMELY DETAILED, standalone physical description for each (face, body, clothes, style, accessories). 
The description must be thorough enough for an AI to generate the character from scratch without external context.
Assign IDs: [CHAR_1], [CHAR_2], etc.
          
TASK 2: SCENE GENERATION
Generate a flat array of keyframes representing these scenes.
          
For each frame, provide:
- description: A vivid visual description of the action/composition using Character IDs (e.g., "[CHAR_1] is standing next to [CHAR_2]").
- char_ids: An array of the Character IDs present in this specific frame.
          
OUTPUT FORMAT:
Strict JSON.''';

      // Use GeminiApiService with structured schema
      final jsonSchema = {
        "type": "object",
        "properties": {
          "characters": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "id": {"type": "string"},
                "description": {"type": "string"}
              },
              "required": ["id", "description"]
            }
          },
          "frames": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "description": {"type": "string"},
                "char_ids": {
                  "type": "array",
                  "items": {"type": "string"}
                }
              },
              "required": ["description", "char_ids"]
            }
          }
        },
        "required": ["characters", "frames"]
      };

      // Note: GeminiApiService doesn't support fileData yet, so we'll use direct HTTP
      // But we'll use the rotated API key from the service
      final apiKey = geminiService.currentKey!;
      
      final requestBody = {
        "contents": [{
          "parts": [
            {"fileData": {"fileUri": _urlController.text, "mimeType": "video/mp4"}},
            {"text": prompt}
          ]
        }],
        "generationConfig": {
          "temperature": 0.7,
          "maxOutputTokens": 8192,
          "responseMimeType": "application/json",
          "responseSchema": jsonSchema
        }
      };

      final response = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$_selectedModel:generateContent?key=$apiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );

      if (response.statusCode == 200) {
        final responseJson = jsonDecode(response.body);
        final text = responseJson['candidates']?[0]?['content']?['parts']?[0]?['text'] ?? '';
        
        if (text.isEmpty) {
          throw Exception('Empty response from API');
        }

        // Parse and process the response
        final data = jsonDecode(text);
        int counter = 1;

        // Create character map
        final charMap = <String, String>{};
        for (final char in (data['characters'] ?? [])) {
          charMap[char['id']] = char['description'];
        }

        // Process frames - replace character IDs with descriptions
        final processedFrames = <Map<String, dynamic>>[];
        for (final frame in (data['frames'] ?? [])) {
          final frameId = counter.toString().padLeft(3, '0');
          counter++;
          
          String visualPrompt = frame['description'];
          final charInScene = <String>[];

          // Replace character IDs with full descriptions to make self-contained prompts
          charMap.forEach((id, desc) {
            visualPrompt = visualPrompt.replaceAll(id, '($desc)');
          });

          // Build char_in_this_scene array
          if (frame['char_ids'] != null && frame['char_ids'] is List) {
            for (final id in frame['char_ids']) {
              final desc = charMap[id];
              if (desc != null) {
                charInScene.add(desc);
              }
            }
          }

          processedFrames.add({
            'id': frameId,
            'visual_prompt': visualPrompt,
            'char_in_this_scene': charInScene,
          });
        }

        // Display the processed frames as JSON
        if (mounted) {
          setState(() {
            _result = const JsonEncoder.withIndent('  ').convert(processedFrames);
            _isAnalyzing = false;
          });
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ Generated ${processedFrames.length} frames'), backgroundColor: Colors.green),
          );
        }
      } else if (response.statusCode == 429 || response.body.contains('quota')) {
        // Quota exceeded - rotation will happen automatically on next request
        throw Exception('Quota exceeded. Please try again (will use next API key).');
      } else {
        throw Exception('API error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isAnalyzing = false;
        });
      }
    }
  }

  void _copyJson() {
    if (_result == null) return;
    Clipboard.setData(ClipboardData(text: _result!));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF050505),
      child: Column(
        children: [
          // Header Section
          Container(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // Title
                const Text(
                  'FRAME SEQUENCER',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    letterSpacing: -1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Deconstruct cinema into a clean visual prompt JSON sequence',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
                
                const SizedBox(height: 32),
                
                // Input Row
                Row(
                  children: [
                    // URL Input
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _urlController,
                        style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                        decoration: InputDecoration(
                          hintText: 'YouTube URL...',
                          hintStyle: TextStyle(color: Colors.grey.shade700),
                          filled: true,
                          fillColor: Colors.grey.shade900.withOpacity(0.5),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: Colors.grey.shade800),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: Colors.grey.shade800),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: const BorderSide(color: Color(0xFF10B981)),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        ),
                      ),
                    ),
                    
                    const SizedBox(width: 12),
                    
                    // API Key Counter Display
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: _apiKeyCount > 0 
                            ? const Color(0xFF10B981).withOpacity(0.1) 
                            : Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _apiKeyCount > 0 
                              ? const Color(0xFF10B981) 
                              : Colors.red,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _apiKeyCount > 0 ? Icons.key : Icons.warning,
                            color: _apiKeyCount > 0 
                                ? const Color(0xFF10B981) 
                                : Colors.red,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _apiKeyCount > 0 
                                ? '$_apiKeyCount KEY${_apiKeyCount > 1 ? 'S' : ''}' 
                                : 'NO KEYS',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              color: _apiKeyCount > 0 
                                  ? const Color(0xFF10B981) 
                                  : Colors.red,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(width: 12),
                    
                    // Model Selector
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade900.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade800),
                      ),
                      child: DropdownButton<String>(
                        value: _selectedModel,
                        dropdownColor: Colors.grey.shade900,
                        underline: const SizedBox(),
                        style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),
                        items: _models.map((m) => DropdownMenuItem(
                          value: m['id'],
                          child: Text(m['name']!),
                        )).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() => _selectedModel = v);
                            _saveSettings();
                          }
                        },
                      ),
                    ),
                    
                    const SizedBox(width: 12),
                    
                    // Clips Counter
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade900.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade800),
                      ),
                      child: Row(
                        children: [
                          Text(
                            'CLIPS',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              color: Colors.grey.shade600,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 50,
                            child: TextField(
                              controller: _clipsController,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                              keyboardType: TextInputType.number,
                              onChanged: (v) {
                                final num = int.tryParse(v);
                                if (num != null && num >= 1 && num <= 100) {
                                  setState(() => _numClips = num);
                                  _saveSettings();
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    
                    const SizedBox(width: 12),
                    
                    // Generate Button
                    ElevatedButton(
                      onPressed: _isAnalyzing ? null : _analyze,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        elevation: 0,
                      ),
                      child: Text(
                        _isAnalyzing ? 'PROCESSING' : 'GENERATE JSON',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ],
                ),
                
                // Error Display
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.2)),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.red,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 2,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          ),
          
          // Loading State
          if (_isAnalyzing)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 64,
                      height: 64,
                      child: CircularProgressIndicator(
                        strokeWidth: 4,
                        valueColor: AlwaysStoppedAnimation<Color>(const Color(0xFF10B981).withOpacity(0.8)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'DECONSTRUCTING CINEMATIC DNA',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: const Color(0xFF10B981).withOpacity(0.8),
                        letterSpacing: 4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // Results Display
          if (_result != null && !_isAnalyzing)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header Row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'SEQUENTIAL FRAME OUTPUT',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.white.withOpacity(0.3),
                            letterSpacing: 4,
                          ),
                        ),
                        ElevatedButton(
                          onPressed: _copyJson,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _copied ? const Color(0xFF10B981) : Colors.transparent,
                            foregroundColor: _copied ? Colors.black : Colors.grey.shade500,
                            side: BorderSide(
                              color: _copied ? const Color(0xFF10B981) : Colors.grey.shade800,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            elevation: _copied ? 8 : 0,
                            shadowColor: _copied ? const Color(0xFF10B981).withOpacity(0.4) : null,
                          ),
                          child: Text(
                            _copied ? 'COPIED' : 'COPY JSON SEQUENCE',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    // JSON Output
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.grey.shade900.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(color: Colors.grey.shade800),
                        ),
                        padding: const EdgeInsets.all(40),
                        child: Stack(
                          children: [
                            // Top gradient line
                            Positioned(
                              top: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                height: 1,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.transparent,
                                      const Color(0xFF10B981).withOpacity(0.2),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            
                            // Scrollable JSON
                            Scrollbar(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.only(right: 16),
                                child: SelectableText(
                                  _result!,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.6,
                                    color: const Color(0xFF10B981).withOpacity(0.8),
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
              ),
            ),
          ]
        )
      )
    ;
  }
}

// ============================================================================
// GENERATE VIDEOS TAB - Using VideoGenerationService
// ============================================================================
class GenerateVideosTab extends StatefulWidget {
  final TabController? tabController;
  final StoryProject? project;
  final String outputDir;
  final ProfileManagerService? profileManager;
  final MultiProfileLoginService? loginService;
  
  // Shared settings
  final String selectedModel;
  final String selectedAspectRatio;
  final bool useFirstAndLastFrame;
  final Function(String) onModelChanged;
  final Function(String) onAspectRatioChanged;
  final Function(bool) onUseFirstAndLastFrameChanged;

  const GenerateVideosTab({
    super.key,
    this.tabController,
    this.project,
    required this.outputDir,
    this.profileManager,
    this.loginService,
    required this.selectedModel,
    required this.selectedAspectRatio,
    required this.useFirstAndLastFrame,
    required this.onModelChanged,
    required this.onAspectRatioChanged,
    required this.onUseFirstAndLastFrameChanged,
  });

  @override
  State<GenerateVideosTab> createState() => _GenerateVideosTabState();
}

class _GenerateVideosTabState extends State<GenerateVideosTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isGenerating = false;
  final List<String> _logs = [];
  final ScrollController _logScrollController = ScrollController();
  
  // Scene tracking
  final List<SceneData> _videoScenes = [];
  final Map<String, SceneData> _videoSceneStates = {};
  
  // Video generation service subscription
  StreamSubscription<String>? _videoStatusSubscription;
  
  
  bool _isConnecting = false; // Track browser connection in progress
  String _videosOutputDir = '';

  @override
  void initState() {
    super.initState();
    _initOutputDir();
    _initializeVideoGeneration();
    _loadSavedState(); // Load persisted state
  }

  Future<void> _initOutputDir() async {
    // Use absolute path — widget.outputDir may be empty during async init
    _videosOutputDir = path.join(Directory.current.path, 'v_output');
    await Directory(_videosOutputDir).create(recursive: true);
  }

  Future<void> _initializeVideoGeneration() async {
    // Initialize VideoGenerationService
    VideoGenerationService().initialize(
      profileManager: widget.profileManager,
      loginService: widget.loginService,
      // Pass existing account type if we had one (though service now protects it)
    );

    // Listen to status updates
    _videoStatusSubscription = VideoGenerationService().statusStream.listen((msg) {
      _log(msg);
      
      // Update UI and save state when generation completes
      if (mounted && (msg.contains('✅') || msg.contains('❌'))) {
        setState(() {});
        _saveState(); // Save state when videos complete
      }
    });
  }
  
  /// Load saved video scenes from SharedPreferences and scan v_output folder
  Future<void> _loadSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedJson = prefs.getString('scenebuilder_video_scenes');
      
      if (savedJson != null) {
        final List<dynamic> decoded = jsonDecode(savedJson);
        _videoScenes.clear();
        
        for (var item in decoded) {
          final scene = SceneData.fromJson(item as Map<String, dynamic>);
          // Verify video file still exists
          if (scene.videoPath != null && await File(scene.videoPath!).exists()) {
            _videoScenes.add(scene);
          }
        }
        
        _log('📂 Loaded ${_videoScenes.length} saved videos');
      }
      
      // Also scan v_output folder for any videos not in saved state
      await _scanOutputFolder();
      
      if (mounted) setState(() {});
    } catch (e) {
      _log('⚠️ Error loading saved state: $e');
    }
  }
  
  /// Scan v_output folder and add any videos not already tracked
  Future<void> _scanOutputFolder() async {
    try {
      final dir = Directory(_videosOutputDir);
      if (!await dir.exists()) return;
      
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mp4')).toList();
      
      for (var file in files) {
        final filePath = file.path;
        // Check if this video is already in our list
        final exists = _videoScenes.any((s) => s.videoPath == filePath);
        
        if (!exists) {
          // Extract scene ID from filename (e.g., scene_0001.mp4)
          final fileName = path.basename(filePath);
          final match = RegExp(r'scene_(\d+)').firstMatch(fileName);
          final sceneId = match != null ? int.parse(match.group(1)!) : _videoScenes.length + 1;
          
          final stat = await file.stat();
          
          final scene = SceneData(
            sceneId: sceneId,
            prompt: 'Imported from folder',
            status: 'completed',
            videoPath: filePath,
            fileSize: stat.size,
            generatedAt: stat.modified.toIso8601String(),
          );
          
          _videoScenes.add(scene);
        }
      }
      
      if (files.isNotEmpty) {
        _log('📂 Found ${files.length} videos in output folder');
      }
    } catch (e) {
      _log('⚠️ Error scanning output folder: $e');
    }
  }
  
  /// Save video scenes to SharedPreferences
  Future<void> _saveState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final completedScenes = _videoScenes.where((s) => s.status == 'completed').toList();
      final jsonList = completedScenes.map((s) => s.toJson()).toList();
      await prefs.setString('scenebuilder_video_scenes', jsonEncode(jsonList));
    } catch (e) {
      _log('⚠️ Error saving state: $e');
    }
  }
  
  /// Clear all videos from UI and optionally delete files
  Future<void> _clearAllVideos({bool deleteFiles = false}) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Videos'),
        content: Text(deleteFiles 
          ? 'This will remove all videos from the list AND delete the video files. This cannot be undone.'
          : 'This will clear the video list but keep the files in the output folder.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      if (deleteFiles) {
        // Delete video files
        for (var scene in _videoScenes) {
          if (scene.videoPath != null) {
            try {
              final file = File(scene.videoPath!);
              if (await file.exists()) {
                await file.delete();
              }
            } catch (e) {
              _log('⚠️ Error deleting ${scene.videoPath}: $e');
            }
          }
        }
      }
      
      setState(() {
        _videoScenes.clear();
        _selectedVideoPath = null;
      });
      
      // Clear saved state
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('scenebuilder_video_scenes');
      
      _log('🗑️ Cleared all videos');
    }
  }

  @override
  void dispose() {
    _videoStatusSubscription?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    print(message);
    if (mounted) {
      setState(() {
        _logs.add('[${DateTime.now().toIso8601String().substring(11, 19)}] $message');
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
  }

  Future<String?> _getImagePath(StoryFrame? frame) async {
    if (frame == null) return null;
    
    String sourceFrameId = frame.frameId;
    if (!frame.generateImage && frame.reuseFrame != null) {
      sourceFrameId = frame.reuseFrame!;
    }
    
    final imageFile = File(path.join(widget.outputDir, '$sourceFrameId.png'));
    if (await imageFile.exists()) {
      return imageFile.path;
    }
    return null;
  }

  Future<void> _generateAllVideos() async {
    if (widget.project == null) {
      _log('❌ No project loaded');
      return;
    }

    final clips = widget.project!.videoClips;
    if (clips.isEmpty) {
      _log('❌ No video clips to generate');
      return;
    }

    // Check if browsers are connected
    final connectedCount = widget.profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      _log('❌ No browsers connected. Please connect browsers first.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please connect to Chrome browsers first')),
        );
      }
      return;
    }

    setState(() {
      _isGenerating = true;
      _videoScenes.clear();
      _videoSceneStates.clear();
    });

    // Detect skip mode: project has reuse frames
    final hasReuseFrames = widget.project!.frames.any((f) => !f.generateImage && f.reuseFrame != null);
    final useSkipMode = hasReuseFrames && widget.useFirstAndLastFrame;
    
    if (useSkipMode) {
      _log('🔄 Skip mode detected: will skip reuse clips and use first+last frames');
    } else if (widget.useFirstAndLastFrame) {
      _log('📸 First+Last frame mode: using adjacent frames for each clip');
    } else {
      _log('🖼️ Single frame mode: using first frame only');
    }

    // Convert VideoClips to SceneData
    int skippedReuse = 0;
    for (int i = 0; i < clips.length; i++) {
      final clip = clips[i];
      
      // Get first frame and check if it's a reuse frame
      final firstFrame = widget.project!.getFrameById(clip.firstFrame);
      
      // Only skip reuse clips when skip mode is active (has reuse frames + first+last frame ON)
      if (useSkipMode && firstFrame != null && !firstFrame.generateImage && firstFrame.reuseFrame != null) {
        _log('⏭️ Skipping Scene ${i + 1} (reuse of ${firstFrame.reuseFrame})');
        skippedReuse++;
        continue;
      }
      
      final firstFramePath = await _getImagePath(firstFrame);
      
      if (firstFramePath == null) {
        _log('⚠️ Skipping ${clip.clipId}: missing first frame image');
        continue;
      }

      // Get last frame ONLY when first+last frame toggle is enabled
      String? lastFramePath;
      if (widget.useFirstAndLastFrame) {
        // First try to use the clip's explicit last frame
        if (clip.lastFrame.isNotEmpty) {
          final lastFrame = widget.project!.getFrameById(clip.lastFrame);
          lastFramePath = await _getImagePath(lastFrame);
          // Make sure it's not the same as first frame
          if (lastFramePath == firstFramePath) {
            lastFramePath = null; // Same image, not useful
          }
        }
        
        if (useSkipMode) {
          // Skip mode: find the next GENERATE clip's first frame (skip reuse clips)
          if (lastFramePath == null) {
            for (int j = i + 1; j < clips.length; j++) {
              final candidateClip = clips[j];
              final candidateFrame = widget.project!.getFrameById(candidateClip.firstFrame);
              
              // Skip reuse frames — find next clip with a unique generated frame
              if (candidateFrame != null && candidateFrame.generateImage) {
                final candidatePath = await _getImagePath(candidateFrame);
                if (candidatePath != null && candidatePath != firstFramePath) {
                  lastFramePath = candidatePath;
                  _log('📸 Scene ${i + 1}: Last frame = Scene ${j + 1}\'s first frame');
                  break;
                }
              }
            }
          }
        } else {
          // Non-skip mode: simply use the next clip's first frame
          if (lastFramePath == null && i + 1 < clips.length) {
            final nextClip = clips[i + 1];
            final nextFirstFrame = widget.project!.getFrameById(nextClip.firstFrame);
            final nextPath = await _getImagePath(nextFirstFrame);
            if (nextPath != null && nextPath != firstFramePath) {
              lastFramePath = nextPath;
              _log('📸 Scene ${i + 1}: Last frame = Scene ${i + 2}\'s first frame');
            }
          }
        }
        
        if (lastFramePath != null) {
          _log('📸 Scene ${i + 1}: Using both first and last frames');
        } else {
          _log('⚠️ Scene ${i + 1}: No last frame available, using first frame only');
        }
      }

      // Build prompt
      String fullPrompt = clip.veo3Prompt;
      if (clip.audioDescription.isNotEmpty) {
        fullPrompt += '\n\nAudio: ${clip.audioDescription}';
      }

      final scene = SceneData(
        sceneId: i + 1,
        prompt: fullPrompt,
        firstFramePath: firstFramePath,
        lastFramePath: lastFramePath, // null when first+last frame toggle is off
        status: 'queued',
        aspectRatio: widget.selectedAspectRatio,
      );

      _videoScenes.add(scene);
      _videoSceneStates[firstFramePath] = scene;
    }

    _log('✅ Prepared ${_videoScenes.length} scenes${skippedReuse > 0 ? " ($skippedReuse reuse skipped)" : ""}');

    try {
      // CRITICAL: Set project folder so videos download to v_output
      VideoGenerationService().setProjectFolder(_videosOutputDir);
      
      await VideoGenerationService().startBatch(
        _videoScenes,
        model: widget.selectedModel, 
        aspectRatio: widget.selectedAspectRatio,
        maxConcurrentOverride: 4,
      );
      
      _log('✅ Batch generation started');
    } catch (e) {
      _log('❌ Start failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = VideoGenerationService().isRunning);
      }
    }
  }

  void _stopGeneration() {
    VideoGenerationService().stop();
    setState(() => _isGenerating = false);
    _log('⏹️ Generation stopped');
  }
  
  Future<void> _retryFailedVideos() async {
    if (widget.project == null) {
      _log('❌ No project loaded');
      return;
    }

    // Get all failed scenes
    final failedScenes = _videoScenes.where((s) => s.status == 'failed').toList();
    
    if (failedScenes.isEmpty) {
      _log('✅ No failed videos to retry');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No failed videos to retry'), backgroundColor: Colors.orange),
      );
      return;
    }

    // Check if browsers are connected
    final connectedCount = widget.profileManager?.countConnectedProfiles() ?? 0;
    if (connectedCount == 0) {
      _log('❌ No browsers connected. Please connect browsers first.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please connect to Chrome browsers first')),
        );
      }
      return;
    }

    setState(() => _isGenerating = true);

    _log('🔄 Retrying ${failedScenes.length} failed videos...');

    // Reset failed scenes to queued status
    for (var scene in failedScenes) {
      scene.status = 'queued';
      scene.error = null;
    }

    try {
      // Ensure project folder is set for downloads
      VideoGenerationService().setProjectFolder(_videosOutputDir);
      
      await VideoGenerationService().startBatch(
        failedScenes,
        model: widget.selectedModel,
        aspectRatio: widget.selectedAspectRatio,
        maxConcurrentOverride: 4,
        autoRetry: false, // Manual retry should not auto-retry
      );
      
      _log('✅ Retry started for ${failedScenes.length} videos');
    } catch (e) {
      _log('❌ Retry failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isGenerating = VideoGenerationService().isRunning);
      }
    }
  }

  Future<void> _openOutputFolder() async {
    // VideoGenerationService saves to {projectFolder}/videos/ subfolder
    final videosSubDir = path.join(_videosOutputDir, 'videos');
    String folderToOpen = _videosOutputDir;
    
    if (await Directory(videosSubDir).exists()) {
      folderToOpen = videosSubDir;
    }
    
    if (folderToOpen.isNotEmpty && await Directory(folderToOpen).exists()) {
      final uri = Uri.file(folderToOpen.replaceAll('/', '\\'));
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } else {
      _log('⚠️ Output folder does not exist yet: $folderToOpen');
    }
  }
  
  Future<void> _openVideoFile(String? videoPath) async {
    if (videoPath == null || videoPath.isEmpty) {
      _log('❌ No video path provided');
      return;
    }
    
    final file = File(videoPath);
    if (!await file.exists()) {
      _log('❌ Video file not found: $videoPath');
      return;
    }
    
    try {
      final uri = Uri.file(videoPath);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        _log('▶️ Opening video: ${path.basename(videoPath)}');
      } else {
        _log('❌ Cannot open video file');
      }
    } catch (e) {
      _log('❌ Error opening video: $e');
    }
  }

  
  // Track selected video for preview
  String? _selectedVideoPath;

  int get _completedCount => _videoScenes.where((s) => s.status == 'completed').length;
  int get _failedCount => _videoScenes.where((s) => s.status == 'failed').length;
  int get _activeCount => _videoScenes.where((s) => 
    s.status == 'generating' || s.status == 'uploading' || s.status == 'polling' || s.status == 'downloading'
  ).length;

  /// Connect to already-opened Chrome browsers (same as Home screen)
  Future<void> _handleConnectOpened() async {
    if (widget.profileManager == null) {
      _log('❌ Profile manager not available');
      return;
    }

    setState(() => _isConnecting = true);
    _log('🔗 Connecting to opened browsers...');

    try {
      final connectedCount = await widget.profileManager!.connectToOpenProfiles(2);
      
      if (connectedCount > 0) {
        // Re-initialize video generation service with updated profile manager
        VideoGenerationService().initialize(
          profileManager: widget.profileManager,
          loginService: widget.loginService,
        );
        _log('✅ Connected to $connectedCount browser(s)');
        
        // Count how many have tokens
        final tokenCount = widget.profileManager!.profiles.where((p) => 
          p.accessToken != null && p.accessToken!.isNotEmpty
        ).length;
        
        if (tokenCount > 0) {
          _log('🔑 $tokenCount browser(s) have valid tokens');
        } else {
          _log('⚠️ Connected but no tokens found - please login in browsers');
        }
      } else {
        _log('⚠️ No browsers found. Launch Chrome with --remote-debugging-port first.');
      }
    } catch (e) {
      _log('❌ Connect failed: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  /// Open new Chrome browsers without auto-login (same as Home screen)
  Future<void> _handleOpenNoLogin() async {
    if (widget.profileManager == null) {
      _log('❌ Profile manager not available');
      return;
    }

    setState(() => _isConnecting = true);
    _log('🚀 Opening browser without login...');

    try {
      final launchedCount = await widget.profileManager!.launchProfilesWithoutLogin(1, headless: false);
      
      if (launchedCount > 0) {
        // Re-initialize video generation service with updated profile manager
        VideoGenerationService().initialize(
          profileManager: widget.profileManager,
          loginService: widget.loginService,
        );
        _log('✅ Opened $launchedCount browser(s) - please login manually');
      } else {
        _log('❌ Failed to open browser');
      }
    } catch (e) {
      _log('❌ Open browser failed: $e');
    } finally {
      if (mounted) setState(() => _isConnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    final clips = widget.project?.videoClips ?? [];
    final connectedCount = widget.profileManager?.countConnectedProfiles() ?? 0;
    final tp = ThemeProvider();

    return Column(
      children: [
        // Integrated Parent TabBar (Ultra Narrow)
        Container(
          height: 32,
          decoration: BoxDecoration(
            color: tp.surfaceBg,
            border: Border(bottom: BorderSide(color: tp.borderColor)),
          ),
          child: Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: widget.tabController,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 8),
                  indicatorSize: TabBarIndicatorSize.label,
                  tabs: [
                    Tab(
                      height: 32,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.edit_note, size: 16),
                          SizedBox(width: 4),
                          Text(LocalizationService().tr('scene.create_story'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    Tab(
                      height: 32,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.movie_creation, size: 16),
                          SizedBox(width: 4),
                          Text(LocalizationService().tr('scene.generate_videos'), style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        
        Expanded(
          child: Row(
            children: [
        // Left Panel - Controls (reduced width)
        Container(
          width: 320,
          color: tp.surfaceBg,
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.movie_creation, color: Colors.deepPurple.shade700),
                    const SizedBox(width: 8),
                    Text('VEO3 Generator', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: tp.textPrimary)),
                  ],
                ),
                const SizedBox(height: 16),

                // Connection Status
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: connectedCount > 0 
                      ? (tp.isDarkMode ? tp.inputBg : Colors.green.shade50) 
                      : (tp.isDarkMode ? tp.inputBg : Colors.orange.shade50),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tp.borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        connectedCount > 0 ? Icons.check_circle : Icons.warning,
                        color: connectedCount > 0 ? Colors.green.shade700 : Colors.orange.shade700,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          connectedCount > 0 
                            ? '$connectedCount browser(s)' 
                            : 'No browsers',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 8),
                
                // Connect Opened & Open No Login buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isConnecting ? null : _handleConnectOpened,
                        icon: _isConnecting 
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.link, size: 14),
                        label: Text(
                          _isConnecting ? 'Connecting...' : 'Connect Opened',
                          style: const TextStyle(fontSize: 11),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: tp.isDarkMode ? const Color(0xFF2E7D32) : Colors.green.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _isConnecting ? null : _handleOpenNoLogin,
                        icon: const Icon(Icons.open_in_browser, size: 14),
                        label: const Text('Open No Login', style: TextStyle(fontSize: 11)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: tp.isDarkMode ? const Color(0xFF5D4037) : Colors.orange.shade600,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Model Selection
                DropdownButtonFormField<String>(
                  value: widget.selectedModel,
                  decoration: const InputDecoration(labelText: 'Model', border: OutlineInputBorder(), isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'Veo 3.1 - Fast', child: Text('Veo 3.1 - Fast')),
                    DropdownMenuItem(value: 'Veo 3.1 - Fast [Lower Priority]', child: Text('Veo 3.1 - Fast [Lower Priority]')),
                    DropdownMenuItem(value: 'Veo 3.1 - Quality', child: Text('Veo 3.1 - Quality')),
                    DropdownMenuItem(value: 'Veo 2 - Fast', child: Text('Veo 2 - Fast')),
                    DropdownMenuItem(value: 'Veo 2 - Quality', child: Text('Veo 2 - Quality')),
                  ],
                  onChanged: (v) => widget.onModelChanged(v!),
                ),
                
                const SizedBox(height: 12),
 
                // Aspect Ratio
                DropdownButtonFormField<String>(
                  value: widget.selectedAspectRatio,
                  decoration: const InputDecoration(labelText: 'Aspect Ratio', border: OutlineInputBorder(), isDense: true),
                  items: const [
                    DropdownMenuItem(value: 'VIDEO_ASPECT_RATIO_LANDSCAPE', child: Text('Landscape (16:9)')),
                    DropdownMenuItem(value: 'VIDEO_ASPECT_RATIO_PORTRAIT', child: Text('Portrait (9:16)')),
                  ],
                  onChanged: (v) => widget.onAspectRatioChanged(v!),
                ),
 
                const SizedBox(height: 12),
 
                // First + Last Frame Toggle
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: tp.borderColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SwitchListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    title: const Text('1st Frame + Last Frame', style: TextStyle(fontSize: 13)),
                    subtitle: Text(
                      widget.useFirstAndLastFrame ? 'Using both frames' : 'Using first frame only',
                      style: TextStyle(fontSize: 11, color: tp.textTertiary),
                    ),
                    value: widget.useFirstAndLastFrame,
                    onChanged: (value) => widget.onUseFirstAndLastFrameChanged(value),
                    activeColor: Colors.deepPurple,
                  ),
                ),

                const SizedBox(height: 12),

                // Stats
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: tp.isDarkMode ? tp.inputBg : Colors.grey.shade100, borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Project: ${widget.project?.title ?? 'None'}', style: TextStyle(fontWeight: FontWeight.w500, fontSize: 11, color: tp.textSecondary)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _buildStat('Total', clips.length, Colors.blue),
                          _buildStat('Done', _completedCount, Colors.green),
                          _buildStat('Failed', _failedCount, Colors.red),
                          _buildStat('Active', _activeCount, Colors.orange),
                        ],
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),

                // Buttons
                if (_isGenerating) ...[
                  LinearProgressIndicator(value: clips.isNotEmpty ? _completedCount / clips.length : 0),
                  const SizedBox(height: 8),
                  Text('Complete: $_completedCount/${clips.length}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11)),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _stopGeneration,
                    icon: const Icon(Icons.stop, size: 18),
                    label: const Text('Stop All', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                  ),
                ] else ...[
                  ElevatedButton.icon(
                    onPressed: clips.isNotEmpty && connectedCount > 0 ? _generateAllVideos : null,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Generate All', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.deepPurple, foregroundColor: Colors.white),
                  ),
                ],
                
                const SizedBox(height: 12),
                
                // Retry Failed Button (only show if there are failed videos and not generating)
                if (!_isGenerating && _failedCount > 0) ...[
                  ElevatedButton.icon(
                    onPressed: _retryFailedVideos,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text('Retry Failed ($_failedCount)', style: const TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                
                ElevatedButton.icon(
                  onPressed: _openOutputFolder,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Open Folder', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),

        // Center Panel - Video Preview
        Expanded(
          child: Container(
            color: tp.isDarkMode ? tp.scaffoldBg : Colors.grey.shade100,
            child: Column(
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tp.surfaceBg,
                    border: Border(bottom: BorderSide(color: tp.borderColor)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.video_library, size: 20),
                      const SizedBox(width: 8),
                      Text('Generated Videos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: tp.textPrimary)),
                      const Spacer(),
                      Text('${_completedCount} completed', style: TextStyle(fontSize: 12, color: tp.textTertiary)),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _openOutputFolder,
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Open Folder', style: TextStyle(fontSize: 11)),
                        style: TextButton.styleFrom(
                          foregroundColor: tp.isDarkMode ? Colors.blue.shade300 : Colors.blue.shade700,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        ),
                      ),
                      if (_completedCount > 0) ...[
                        const SizedBox(width: 4),
                        TextButton.icon(
                          onPressed: () => _clearAllVideos(deleteFiles: false),
                          icon: const Icon(Icons.clear_all, size: 16),
                          label: const Text('Clear All', style: TextStyle(fontSize: 11)),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Video Grid
                Expanded(
                  child: _completedCount == 0
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.video_library_outlined, size: 64, color: Colors.grey.shade300),
                            const SizedBox(height: 16),
                            Text('No videos yet', style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
                            const SizedBox(height: 8),
                            Text('Generated videos will appear here', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                          ],
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(16),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 16 / 9,
                        ),
                        itemCount: _videoScenes.where((s) => s.status == 'completed').length,
                        itemBuilder: (context, index) {
                          final completedScenes = _videoScenes.where((s) => s.status == 'completed').toList();
                          final scene = completedScenes[index];
                          final isSelected = _selectedVideoPath == scene.videoPath;
                          
                          return GestureDetector(
                            onTap: () => _openVideoFile(scene.videoPath),
                            child: Container(
                              decoration: BoxDecoration(
                                color: tp.surfaceBg,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? Colors.deepPurple : tp.borderColor,
                                  width: isSelected ? 3 : 1,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: tp.shadowColor,
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          // Show first frame image as thumbnail
                                          if (scene.firstFramePath != null && File(scene.firstFramePath!).existsSync())
                                            Image.file(
                                              File(scene.firstFramePath!),
                                              fit: BoxFit.cover,
                                            )
                                          else
                                            Container(
                                              color: Colors.grey.shade200,
                                              child: Icon(Icons.video_file, size: 48, color: Colors.grey.shade400),
                                            ),
                                          
                                          // Play button overlay
                                          Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                begin: Alignment.topCenter,
                                                end: Alignment.bottomCenter,
                                                colors: [
                                                  Colors.black.withOpacity(0.0),
                                                  Colors.black.withOpacity(0.3),
                                                ],
                                              ),
                                            ),
                                            child: Center(
                                              child: Container(
                                                padding: const EdgeInsets.all(8),
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withOpacity(0.6),
                                                  shape: BoxShape.circle,
                                                ),
                                                child: const Icon(
                                                  Icons.play_arrow,
                                                  color: Colors.white,
                                                  size: 32,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Scene ${scene.sceneId}',
                                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        if (scene.fileSize != null)
                                          Text(
                                            '${(scene.fileSize! / 1024 / 1024).toStringAsFixed(1)} MB',
                                            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                ),
              ],
            ),
          ),
        ),

        // Right Panel - Logs (reduced width)
        Container(
          width: 400,
          color: Colors.grey.shade900,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Generation Log', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade700),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Scrollbar(
                    controller: _logScrollController,
                    child: ListView.builder(
                      controller: _logScrollController,
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return SelectableText(
                          _logs[index],
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 11, fontFamily: 'monospace', height: 1.3),
                        );
                      },
                    ),
                  ),
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

  Widget _buildStat(String label, int value, Color color) {
    final tp = ThemeProvider();
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: tp.isDarkMode ? color.withOpacity(0.15) : color.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
        child: Column(
          children: [
            Text('$value', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20, color: color)),
            Text(label, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }
}

