import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import '../models/scene_data.dart';

/// Persists video scene states locally so they survive app restarts.
/// Saves scene status, operation names, video paths, and thumbnails.
/// Stored in the output folder as `_scene_states.json`.
class SceneStatePersistence {
  static final SceneStatePersistence _instance = SceneStatePersistence._();
  factory SceneStatePersistence() => _instance;
  SceneStatePersistence._();

  String? _outputFolder;

  /// Set the output folder (called when output folder is known)
  void setOutputFolder(String folder) {
    _outputFolder = folder;
  }

  /// Get the state file path
  String? get _stateFilePath {
    if (_outputFolder == null) return null;
    return path.join(_outputFolder!, '_scene_states.json');
  }

  /// Save all scene states to disk
  Future<void> saveSceneStates(List<SceneData> scenes) async {
    final filePath = _stateFilePath;
    if (filePath == null) return;

    try {
      final statesJson = scenes.map((s) => s.toJson()).toList();
      final json = {
        'version': 1,
        'savedAt': DateTime.now().toIso8601String(),
        'sceneCount': scenes.length,
        'scenes': statesJson,
      };
      
      final file = File(filePath);
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      print('[SceneState] 💾 Saved ${scenes.length} scene states');
    } catch (e) {
      print('[SceneState] ❌ Save error: $e');
    }
  }

  /// Load scene states from disk
  /// Returns the list of saved scenes, or empty list if none found
  Future<List<SceneData>> loadSceneStates() async {
    final filePath = _stateFilePath;
    if (filePath == null) return [];

    try {
      final file = File(filePath);
      if (!await file.exists()) {
        print('[SceneState] 📂 No saved states found');
        return [];
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final scenesJson = json['scenes'] as List? ?? [];

      final scenes = <SceneData>[];
      for (final sceneJson in scenesJson) {
        try {
          final scene = SceneData.fromJson(sceneJson as Map<String, dynamic>);
          
          // Validate: if video path exists, verify file is still there
          if (scene.videoPath != null && !File(scene.videoPath!).existsSync()) {
            // Video file was deleted — keep data but clear path
            print('[SceneState] ⚠️ Scene ${scene.sceneId}: video file missing, clearing path');
            scene.videoPath = null;
            // If status was completed but video is gone, reset to queued
            if (scene.status == 'completed') {
              scene.status = 'queued';
            }
          }
          
          // If scene was in a transient state (generating/downloading), 
          // preserve 'polling' for resume, mark others as failed
          if (scene.status == 'generating' || scene.status == 'downloading') {
            if (scene.operationName != null && scene.operationName!.isNotEmpty) {
              // Had an operation — can resume polling
              scene.status = 'polling';
              print('[SceneState] 🔄 Scene ${scene.sceneId}: was ${scene.status}, resuming as polling');
            } else {
              scene.status = 'queued';
              print('[SceneState] 🔄 Scene ${scene.sceneId}: was in transit, reset to queued');
            }
          }
          
          // Reset progress since it's not persisted meaningfully
          scene.progress = 0;
          
          scenes.add(scene);
        } catch (e) {
          print('[SceneState] ⚠️ Error parsing scene: $e');
        }
      }

      print('[SceneState] 📂 Loaded ${scenes.length} scene states');
      return scenes;
    } catch (e) {
      print('[SceneState] ❌ Load error: $e');
      return [];
    }
  }

  /// Merge loaded states with incoming prompts
  /// If we have saved state for a scene, restore its status/paths
  /// If a scene is new (not in saved states), keep it as queued
  List<SceneData> mergeWithSavedStates(List<SceneData> loadedScenes, List<SceneData> savedStates) {
    if (savedStates.isEmpty) return loadedScenes;

    // Build a map of saved states by sceneId
    final savedMap = <int, SceneData>{};
    for (final saved in savedStates) {
      savedMap[saved.sceneId] = saved;
    }

    final merged = <SceneData>[];
    for (final scene in loadedScenes) {
      final saved = savedMap[scene.sceneId];
      if (saved != null) {
        // Restore the saved state, but use the latest prompt from loadedScenes
        saved.prompt = scene.prompt;
        // Keep first/last frame paths from loaded if provided
        if (scene.firstFramePath != null) saved.firstFramePath = scene.firstFramePath;
        if (scene.lastFramePath != null) saved.lastFramePath = scene.lastFramePath;
        merged.add(saved);
      } else {
        merged.add(scene);
      }
    }

    // Also add any saved scenes that aren't in loadedScenes
    for (final saved in savedStates) {
      if (!loadedScenes.any((s) => s.sceneId == saved.sceneId)) {
        merged.add(saved);
      }
    }

    // Sort by sceneId
    merged.sort((a, b) => a.sceneId.compareTo(b.sceneId));

    final completedCount = merged.where((s) => s.status == 'completed').length;
    final pollingCount = merged.where((s) => s.status == 'polling').length;
    print('[SceneState] 📂 Merged: ${merged.length} scenes ($completedCount completed, $pollingCount need polling)');

    return merged;
  }

  /// Get scenes that need polling (have operation names and are in polling state)
  List<SceneData> getScenesNeedingPolling(List<SceneData> scenes) {
    return scenes.where((s) => 
      s.status == 'polling' && 
      s.operationName != null && 
      s.operationName!.isNotEmpty
    ).toList();
  }

  /// Delete saved states file
  Future<void> clearSavedStates() async {
    final filePath = _stateFilePath;
    if (filePath == null) return;
    
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
        print('[SceneState] 🗑️ Cleared saved states');
      }
    } catch (e) {
      print('[SceneState] ❌ Clear error: $e');
    }
  }
}
