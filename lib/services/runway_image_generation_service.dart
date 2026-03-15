/// RunwayML Image Generation Service
/// Generates images using RunwayML's internal API via CDP authentication.
///
/// Supports:
///   - Text-to-image (Gen-4, Nano Banana variants)
///   - Reference image upload + Gen-4 Turbo generation
///
/// Requires Chrome running with --remote-debugging-port=9222
/// and RunwayML logged in at https://app.runwayml.com

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:veo3_another/utils/config.dart';

class RunwayImageGenerationService {
  static final RunwayImageGenerationService _instance = RunwayImageGenerationService._internal();
  factory RunwayImageGenerationService() => _instance;
  RunwayImageGenerationService._internal();

  // CDP config
  String _cdpHost = 'localhost';
  int _cdpPort = 9222;

  // Auth
  String? _token;
  String? _teamId;

  // Config
  static const String _apiBase = 'https://api.runwayml.com';
  static const Duration _httpTimeout = Duration(seconds: 180);
  static const Duration _pollInterval = Duration(seconds: 5);
  static const Duration _maxWait = Duration(seconds: 300);

  // Cancellation
  bool _cancelled = false;

  /// Cancel all in-flight operations (uploads, polling, generation).
  void cancelAll() {
    _cancelled = true;
    _log('🛑 RunwayML: All operations cancelled');
  }

  /// Reset cancellation flag (call before starting a new generation batch).
  void resetCancel() {
    _cancelled = false;
  }

  /// Whether operations have been cancelled.
  bool get isCancelled => _cancelled;

  // Status stream
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  // RunwayML model configurations
  static const Map<String, Map<String, String?>> modelConfigs = {
    'gen4': {'feature': null, 'model': null, 'label': 'Gen-4 (Default)', 'taskType': 'text_to_image'},
    'gen4_turbo': {'feature': null, 'model': null, 'label': 'Gen-4 Turbo', 'taskType': 'text_to_image'},
    'nano2': {'feature': 'gemini_3_1_flash_image', 'model': 'gemini-3.1-flash-image-preview', 'label': 'Nano Banana 2', 'taskType': 'text_to_image'},
    'nano': {'feature': 'gemini_image', 'model': 'gemini-2.1-flash-image-preview', 'label': 'Nano Banana', 'taskType': 'text_to_image'},
    'nanopro': {'feature': 'gemini_3_pro_image', 'model': 'gemini-3-pro-image-preview', 'label': 'Nano Banana Pro', 'taskType': 'text_to_image'},
    'gen4_ref': {'feature': null, 'model': null, 'label': 'Gen-4 Turbo (Ref Image)', 'taskType': 'ref_image_to_image_turbo'},
  };

  void _log(String msg) {
    if (!_statusController.isClosed) {
      _statusController.add(msg);
    }
  }

  // ============================================================
  // Authentication
  // ============================================================

  /// Extract token from RunwayML tab via CDP
  Future<bool> authenticate({int cdpPort = 9222}) async {
    _cdpPort = cdpPort;
    try {
      // Get CDP targets
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse('http://$_cdpHost:$_cdpPort/json'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final targets = jsonDecode(body) as List;
      client.close();

      // Find RunwayML tab
      Map<String, dynamic>? runwayTarget;
      for (final t in targets) {
        if (t is Map && t['type'] == 'page' && (t['url'] ?? '').toString().contains('runwayml.com')) {
          runwayTarget = Map<String, dynamic>.from(t);
          break;
        }
      }

      if (runwayTarget == null) {
        _log('❌ No RunwayML tab found in Chrome:$_cdpPort');
        return false;
      }

      final wsUrl = runwayTarget['webSocketDebuggerUrl'] as String;

      // Connect via WebSocket and extract token
      final ws = await WebSocket.connect(wsUrl);
      final completer = Completer<String?>();

      ws.listen((data) {
        try {
          final result = jsonDecode(data);
          final value = result?['result']?['result']?['value'];
          if (!completer.isCompleted) completer.complete(value?.toString());
        } catch (_) {
          if (!completer.isCompleted) completer.complete(null);
        }
      });

      ws.add(jsonEncode({
        'id': 1,
        'method': 'Runtime.evaluate',
        'params': {
          'expression': "localStorage.getItem('RW_USER_TOKEN')",
          'returnByValue': true,
        }
      }));

      _token = await completer.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
      await ws.close();

      if (_token == null || _token!.isEmpty) {
        _log('❌ Could not extract RW_USER_TOKEN');
        return false;
      }

      // Decode JWT to get team ID
      _teamId = _extractTeamId(_token!);
      if (_teamId == null) {
        _log('❌ Could not extract team ID from token');
        return false;
      }

      _log('✅ RunwayML authenticated (Team: $_teamId)');
      return true;
    } catch (e) {
      _log('❌ RunwayML auth failed: $e');
      return false;
    }
  }

  String? _extractTeamId(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      String payload = parts[1];
      // Pad base64
      while (payload.length % 4 != 0) payload += '=';
      final decoded = utf8.decode(base64Decode(payload));
      final json = jsonDecode(decoded);
      final id = json['id'];
      return id?.toString();
    } catch (_) {
      return null;
    }
  }

  bool get isAuthenticated => _token != null && _teamId != null;

  /// Clear cached auth tokens — forces re-authentication on next API call.
  /// Use this when switching RunwayML accounts.
  void clearAuth() {
    _token = null;
    _teamId = null;
    _cachedAssetGroupId = null;
    clearRefImageCache();
    _log('🔄 RunwayML auth cleared — will re-authenticate on next use');
  }

  // ============================================================
  // Persistent Reference Image Upload Cache
  // ============================================================
  // Keyed by CONTENT HASH (not file path) so the same image content
  // always resolves to the same cached asset, even if the file path
  // changes (e.g., temp files). Persisted to disk as JSON so cached
  // asset IDs survive app restarts. Only cleared on "Refresh Cookies".

  /// In-memory cache: contentHash → uploaded asset info map
  final Map<String, Map<String, String>> _refImageCache = {};

  /// Whether the disk cache has been loaded into memory
  bool _cacheLoaded = false;

  /// Path to the persistent cache file
  static String get _cacheFilePath {
    final appDataDir = AppConfig.getAppDataDir();
    return '$appDataDir${Platform.pathSeparator}RunwayML${Platform.pathSeparator}runway_ref_cache.json';
  }

  /// Compute a content hash for file bytes (fast: uses size + sample bytes)
  String _contentHash(Uint8List bytes) {
    // Use file size + first 512 bytes + last 512 bytes for a fast fingerprint
    final sb = StringBuffer();
    sb.write('sz${bytes.length}_');
    final head = bytes.length > 512 ? 512 : bytes.length;
    for (int i = 0; i < head; i++) sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    if (bytes.length > 1024) {
      sb.write('_');
      for (int i = bytes.length - 512; i < bytes.length; i++) sb.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// Load the persistent cache from disk (called once, lazily)
  Future<void> _loadCacheFromDisk() async {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    try {
      final file = File(_cacheFilePath);
      if (await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map) {
          for (final entry in json.entries) {
            if (entry.value is Map) {
              _refImageCache[entry.key] = Map<String, String>.from(entry.value);
            }
          }
          _log('📂 Loaded ${_refImageCache.length} cached RunwayML ref images from disk');
        }
      }
    } catch (e) {
      _log('⚠️ Failed to load ref cache from disk: $e');
    }
  }

  /// Save the in-memory cache to disk
  Future<void> _saveCacheToDisk() async {
    try {
      final file = File(_cacheFilePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(_refImageCache));
    } catch (e) {
      _log('⚠️ Failed to save ref cache to disk: $e');
    }
  }

  /// Check if a reference image (by content hash) is already cached.
  Map<String, String>? getCachedRefAsset(String filePath) => _refImageCache[filePath];

  /// Clear the reference image upload cache (memory + disk).
  void clearRefImageCache() {
    _refImageCache.clear();
    _cacheLoaded = false;
    // Delete the disk cache file
    try {
      final file = File(_cacheFilePath);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    _log('♻️ RunwayML ref image cache cleared (memory + disk)');
  }

  /// Number of cached reference images.
  int get refImageCacheSize => _refImageCache.length;

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $_token',
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'Origin': 'https://app.runwayml.com',
  };

  // ============================================================
  // Asset Group
  // ============================================================

  Future<String?> _getAssetGroupId() async {
    try {
      final resp = await http.get(
        Uri.parse('$_apiBase/v1/asset_groups?asTeamId=$_teamId'),
        headers: _headers,
      ).timeout(_httpTimeout);

      if (resp.statusCode == 200) {
        final groups = jsonDecode(resp.body);
        if (groups is List && groups.isNotEmpty) {
          return groups[0]['id']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  // ============================================================
  // Image Upload (3-step: Init → S3 PUT → Complete)
  // ============================================================

  /// Upload a reference image. Returns asset info map or null.
  /// Uses persistent content-hash cache — same image content is never
  /// re-uploaded, even across app restarts. Cache survives until
  /// "Refresh Runway Cookies" is clicked.
  Future<Map<String, String>?> uploadReferenceImage(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _log('❌ File not found: $filePath');
      return null;
    }

    final fileBytes = await file.readAsBytes();
    final hash = _contentHash(Uint8List.fromList(fileBytes));

    // Load persistent cache from disk (lazy, once per session)
    await _loadCacheFromDisk();

    // Check cache by content hash — skip upload if already done
    final cached = _refImageCache[hash];
    if (cached != null) {
      _log('♻️ Using cached ref: ${filePath.split(Platform.pathSeparator).last} (from disk cache)');
      return cached;
    }

    final filename = filePath.split(Platform.pathSeparator).last;
    _log('📤 Uploading $filename (${fileBytes.length} bytes)...');

    try {
      // Step A: Initialize upload
      final initResp = await http.post(
        Uri.parse('$_apiBase/v1/uploads'),
        headers: _headers,
        body: jsonEncode({'filename': filename, 'numberOfParts': 1, 'type': 'DATASET'}),
      ).timeout(_httpTimeout);

      if (initResp.statusCode != 200) {
        _log('❌ Upload init failed: ${initResp.body}');
        return null;
      }

      final initData = jsonDecode(initResp.body);
      final uploadId = initData['id'] as String;
      final s3Url = (initData['uploadUrls'] as List).first as String;

      // Step B: PUT to S3
      final ext = filename.split('.').last.toLowerCase();
      final contentType = {'png': 'image/png', 'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'webp': 'image/webp'}[ext] ?? 'application/octet-stream';

      final s3Req = http.Request('PUT', Uri.parse(s3Url));
      s3Req.headers['Content-Type'] = contentType;
      s3Req.bodyBytes = fileBytes;
      final s3Resp = await http.Client().send(s3Req).timeout(_httpTimeout);

      if (s3Resp.statusCode != 200) {
        _log('❌ S3 upload failed: ${s3Resp.statusCode}');
        return null;
      }

      final etag = s3Resp.headers['etag']?.replaceAll('"', '') ?? '';

      // Step C: Complete upload
      final completeResp = await http.post(
        Uri.parse('$_apiBase/v1/uploads/$uploadId/complete'),
        headers: _headers,
        body: jsonEncode({'parts': [{'PartNumber': 1, 'ETag': etag}]}),
      ).timeout(_httpTimeout);

      if (completeResp.statusCode != 200) {
        _log('❌ Upload complete failed: ${completeResp.body}');
        return null;
      }

      final assetData = jsonDecode(completeResp.body);
      final assetUrl = assetData['url'] as String? ?? '';

      final assetInfo = {'assetId': uploadId, 'url': assetUrl, 'tag': 'IMG_1'};
      
      // Cache by content hash (memory + disk)
      _refImageCache[hash] = assetInfo;
      await _saveCacheToDisk();
      _log('✅ Uploaded & cached to disk: ${uploadId.substring(0, 12)}...');
      return assetInfo;
    } catch (e) {
      _log('❌ Upload error: $e');
      return null;
    }
  }

  // ============================================================
  // Text-to-Image Generation
  // ============================================================

  /// Generate image(s) from text prompt (blocking: creates task + polls to completion).
  /// For concurrent generation, use createTask() + waitForProgress() + pollToCompletion() instead.
  Future<RunwayImageResult> generateImage({
    required String prompt,
    String modelKey = 'gen4',
    int width = 1088,
    int height = 1088,
    int numImages = 1,
    List<Map<String, String>>? referenceAssets,
  }) async {
    if (_cancelled) return RunwayImageResult(success: false, error: 'Cancelled');
    
    final taskId = await createTask(
      prompt: prompt, modelKey: modelKey , width: width, height: height,
      numImages: numImages, referenceAssets: referenceAssets,
    );
    if (taskId == null) {
      return RunwayImageResult(success: false, error: 'Task creation failed');
    }
    
    if (_cancelled) return RunwayImageResult(success: false, error: 'Cancelled');
    
    final images = await pollToCompletion(taskId);
    if (images == null || images.isEmpty) {
      return RunwayImageResult(success: false, error: _cancelled ? 'Cancelled' : 'Generation failed or timed out');
    }
    return RunwayImageResult(success: true, imageBytes: images);
  }

  // ============================================================
  // Task Creation (separated for concurrent generation)
  // ============================================================

  String? _cachedAssetGroupId;

  /// Create a RunwayML task and return the taskId (does NOT poll).
  Future<String?> createTask({
    required String prompt,
    String modelKey = 'gen4',
    int width = 1088,
    int height = 1088,
    int numImages = 1,
    List<Map<String, String>>? referenceAssets,
  }) async {
    if (!isAuthenticated) {
      final ok = await authenticate(cdpPort: _cdpPort);
      if (!ok) return null;
    }

    final config = modelConfigs[modelKey] ?? modelConfigs['gen4']!;
    final taskType = referenceAssets != null && referenceAssets.isNotEmpty
        ? 'ref_image_to_image_turbo'
        : (config['taskType'] ?? 'text_to_image');

    final hasRefs = referenceAssets != null && referenceAssets.isNotEmpty;
    final refCount = referenceAssets?.length ?? 0;
    _log('🎨 RunwayML: ${config['label']} | taskType=$taskType | refs=$refCount');
    if (hasRefs) {
      for (int ri = 0; ri < referenceAssets!.length; ri++) {
        final ref = referenceAssets![ri];
        _log('  📎 Ref[$ri]: assetId=${ref['assetId']?.substring(0, 12) ?? 'null'}... tag=${ref['tag']}');
      }
    }

    final seed = Random().nextInt(900000) + 100000;
    final sessionId = _generateUuid();
    _cachedAssetGroupId ??= await _getAssetGroupId();

    final options = <String, dynamic>{
      'name': 'API ${DateTime.now().millisecondsSinceEpoch}',
      'text_prompt': prompt,
      'width': width,
      'height': height,
      'num_images': numImages,
      'seed': seed,
      'exploreMode': false,
      'creationSource': 'tool-mode',
    };

    if (config['feature'] != null) options['feature'] = config['feature'];
    if (config['model'] != null) options['model'] = config['model'];
    if (_cachedAssetGroupId != null) options['assetGroupId'] = _cachedAssetGroupId;

    if (hasRefs) {
      options['reference_images'] = referenceAssets;
    }

    final payload = {
      'taskType': taskType,
      'options': options,
      'asTeamId': _teamId!,
      'sessionId': sessionId,
    };

    try {
      final resp = await http.post(
        Uri.parse('$_apiBase/v1/tasks'),
        headers: _headers,
        body: jsonEncode(payload),
      ).timeout(_httpTimeout);

      if (resp.statusCode != 200) {
        _log('❌ Task creation failed (${resp.statusCode}): ${resp.body}');
        return null;
      }

      final taskData = jsonDecode(resp.body);
      final taskId = taskData['task']['id'] as String;
      _log('📋 Task: ${taskId.substring(0, 12)}... ($taskType${hasRefs ? " + $refCount refs" : ""})');
      return taskId;
    } catch (e) {
      _log('❌ Task creation error: $e');
      return null;
    }
  }

  // ============================================================
  // Progress-gated Polling
  // ============================================================

  /// Wait until a task reaches [minProgress] (0.0–1.0). Returns current progress or -1 on failure.
  /// Used for staggered concurrent launches: wait for 5% before starting the next task.
  Future<double> waitForProgress(String taskId, double minProgress, {Duration? timeout}) async {
    final url = '$_apiBase/v1/tasks/$taskId?asTeamId=$_teamId';
    final maxWait = timeout ?? const Duration(seconds: 120);
    final start = DateTime.now();

    while (DateTime.now().difference(start) < maxWait && !_cancelled) {
      try {
        final resp = await http.get(Uri.parse(url), headers: {
          'Authorization': 'Bearer $_token',
        }).timeout(_httpTimeout);

        final task = jsonDecode(resp.body)['task'] as Map<String, dynamic>?;
        if (task == null) continue;

        final status = task['status'] as String? ?? 'UNKNOWN';
        final progress = double.tryParse(task['progressRatio']?.toString() ?? '0') ?? 0;

        if (progress >= minProgress) {
          _log('✅ Task ${taskId.substring(0, 8)} reached ${(progress * 100).toInt()}%');
          return progress;
        }

        if (status == 'FAILED' || status == 'CANCELLED') {
          _log('❌ Task ${taskId.substring(0, 8)} $status before reaching ${(minProgress * 100).toInt()}%');
          return -1;
        }
      } catch (e) {
        _log('⚠️ Progress check error: $e');
      }

      await Future.delayed(const Duration(seconds: 3));
    }

    if (_cancelled) {
      _log('🛑 Task ${taskId.substring(0, 8)} cancelled');
      return -1;
    }
    _log('⚠️ Task ${taskId.substring(0, 8)} did not reach ${(minProgress * 100).toInt()}% in time, continuing...');
    return 0; // Return 0 (not -1) so caller can still proceed
  }

  /// Poll until task completes, then download images. Returns image bytes or null.
  Future<List<Uint8List>?> pollToCompletion(String taskId) async {
    final url = '$_apiBase/v1/tasks/$taskId?asTeamId=$_teamId';
    final start = DateTime.now();

    while (DateTime.now().difference(start) < _maxWait && !_cancelled) {
      try {
        final resp = await http.get(Uri.parse(url), headers: {
          'Authorization': 'Bearer $_token',
        }).timeout(_httpTimeout);

        final task = jsonDecode(resp.body)['task'] as Map<String, dynamic>?;
        if (task == null) continue;

        final status = task['status'] as String? ?? 'UNKNOWN';
        final progress = double.tryParse(task['progressRatio']?.toString() ?? '0') ?? 0;

        _log('⏳ ${taskId.substring(0, 8)}: ${(progress * 100).toInt()}% — $status');

        if (status == 'SUCCEEDED') {
          _log('✅ ${taskId.substring(0, 8)} complete!');
          final artifacts = task['artifacts'] as List? ?? [];
          final images = <Uint8List>[];

          for (final art in artifacts) {
            if (_cancelled) return null;
            final imgUrl = art['url'] as String?;
            if (imgUrl == null) continue;

            try {
              final imgResp = await http.get(Uri.parse(imgUrl)).timeout(const Duration(seconds: 60));
              if (imgResp.statusCode == 200) {
                images.add(imgResp.bodyBytes);
              }
            } catch (_) {}
          }

          return images;
        } else if (status == 'FAILED' || status == 'CANCELLED') {
          _log('❌ ${taskId.substring(0, 8)} $status: ${task['error'] ?? 'unknown'}');
          return null;
        }
      } catch (e) {
        _log('⚠️ Poll error: $e');
      }

      await Future.delayed(_pollInterval);
    }

    if (_cancelled) {
      _log('🛑 ${taskId.substring(0, 8)} cancelled by user');
      return null;
    }
    _log('⏰ ${taskId.substring(0, 8)} timed out after ${_maxWait.inSeconds}s');
    return null;
  }

  // ============================================================
  // Helpers
  // ============================================================

  String _generateUuid() {
    final rng = Random();
    String hex(int len) => List.generate(len, (_) => rng.nextInt(16).toRadixString(16)).join();
    // RFC4122 v4: xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx
    final variant = ['8', '9', 'a', 'b'][rng.nextInt(4)];
    return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
  }

  void dispose() {
    _statusController.close();
  }
}

/// Result of a RunwayML image generation
class RunwayImageResult {
  final bool success;
  final List<Uint8List> imageBytes;
  final String? error;

  RunwayImageResult({
    required this.success,
    this.imageBytes = const [],
    this.error,
  });
}
