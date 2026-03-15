/// RunwayML Video Generation Service
/// Generates videos using RunwayML's internal API via CDP authentication.
///
/// Supports:
///   - Image-to-Video (i2v) with reference image upload
///   - Text-to-Video (t2v) prompt-only generation
///
/// Models:
///   - Gen-4.5 (gen4_5)
///   - Gen-4 Turbo (gen4_turbo)
///   - Gen-4 (gen4)
///
/// Requires Chrome running with --remote-debugging-port=9222
/// and RunwayML logged in at https://app.runwayml.com

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// RunwayML Video Model configuration
class RunwayVideoModel {
  final String key;        // API taskType key
  final String label;      // Display name
  final List<int> durations; // Supported durations in seconds
  final List<String> routes; // Supported routes: i2v, t2v

  const RunwayVideoModel({
    required this.key,
    required this.label,
    required this.durations,
    required this.routes,
  });
}

/// Result of a RunwayML video generation
class RunwayVideoResult {
  final bool success;
  final String? taskId;
  final String? videoUrl;
  final String? videoPath;
  final String? error;
  final int? fileSizeBytes;

  RunwayVideoResult({
    required this.success,
    this.taskId,
    this.videoUrl,
    this.videoPath,
    this.error,
    this.fileSizeBytes,
  });
}

class RunwayVideoGenerationService {
  static final RunwayVideoGenerationService _instance =
      RunwayVideoGenerationService._internal();
  factory RunwayVideoGenerationService() => _instance;
  RunwayVideoGenerationService._internal();

  // CDP config
  String _cdpHost = 'localhost';
  int _cdpPort = 9222;

  // Auth
  String? _token;
  String? _teamId;
  String? _cachedAssetGroupId;

  // Config
  static const String _apiBase = 'https://api.runwayml.com';
  static const Duration _httpTimeout = Duration(seconds: 120);
  static const Duration _pollInterval = Duration(seconds: 3);
  static const Duration _maxWait = Duration(seconds: 600); // 10 min for video

  // Status stream
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  // ── Model Definitions ────────────────────────────────────────────
  static const List<RunwayVideoModel> videoModels = [
    RunwayVideoModel(
      key: 'gen4_5',
      label: 'Gen-4.5',
      durations: [5, 10],
      routes: ['i2v', 't2v'],
    ),
    RunwayVideoModel(
      key: 'gen4_turbo',
      label: 'Gen-4 Turbo',
      durations: [5, 10],
      routes: ['i2v', 't2v'],
    ),
    RunwayVideoModel(
      key: 'gen4',
      label: 'Gen-4',
      durations: [5, 10],
      routes: ['i2v', 't2v'],
    ),
  ];

  /// Quick lookup: key → model
  static RunwayVideoModel? getModel(String key) {
    try {
      return videoModels.firstWhere((m) => m.key == key);
    } catch (_) {
      return null;
    }
  }

  /// Map for dropdowns: display label → key
  static Map<String, String> get modelOptions =>
      {for (final m in videoModels) m.label: m.key};

  bool get isAuthenticated => _token != null && _teamId != null;

  // ── Logging ──────────────────────────────────────────────────────
  void _log(String msg) {
    print('[RunwayVideo] $msg');
    if (!_statusController.isClosed) {
      _statusController.add(msg);
    }
  }

  // ── Authentication ───────────────────────────────────────────────
  /// Extract token from RunwayML tab via CDP
  Future<bool> authenticate({int cdpPort = 9222}) async {
    _cdpPort = cdpPort;
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final req =
          await client.getUrl(Uri.parse('http://$_cdpHost:$_cdpPort/json'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      final targets = jsonDecode(body) as List;
      client.close();

      // Find RunwayML tab
      Map<String, dynamic>? runwayTarget;
      for (final t in targets) {
        if (t is Map &&
            t['type'] == 'page' &&
            (t['url'] ?? '').toString().contains('runwayml.com')) {
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

      _token = await completer.future
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
      await ws.close();

      if (_token == null || _token!.isEmpty) {
        _log('❌ Could not extract RW_USER_TOKEN');
        return false;
      }

      _teamId = _extractTeamId(_token!);
      if (_teamId == null) {
        _log('❌ Could not extract team ID from token');
        return false;
      }

      _log('✅ RunwayML Video auth OK (Team: $_teamId)');
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
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      final decoded = utf8.decode(base64Decode(payload));
      final json = jsonDecode(decoded);
      return json['id']?.toString();
    } catch (_) {
      return null;
    }
  }

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Origin': 'https://app.runwayml.com',
        'Referer': 'https://app.runwayml.com/',
      };

  // ── Asset Group ──────────────────────────────────────────────────
  Future<String?> _getAssetGroupId() async {
    if (_cachedAssetGroupId != null) return _cachedAssetGroupId;
    try {
      final resp = await http
          .get(
            Uri.parse('$_apiBase/v1/asset_groups?asTeamId=$_teamId'),
            headers: _headers,
          )
          .timeout(_httpTimeout);
      if (resp.statusCode == 200) {
        final groups = jsonDecode(resp.body);
        if (groups is List && groups.isNotEmpty) {
          _cachedAssetGroupId = groups[0]['id']?.toString();
          return _cachedAssetGroupId;
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Image Upload (3-step: Init → S3 PUT → Complete) ──────────────
  /// Upload a reference image for i2v. Returns {assetId, url} or null.
  Future<Map<String, String>?> uploadImage(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      _log('❌ File not found: $filePath');
      return null;
    }

    final filename = filePath.split(Platform.pathSeparator).last;
    final fileBytes = await file.readAsBytes();
    _log('📤 Uploading $filename (${fileBytes.length} bytes)...');

    try {
      // Step A: Initialize upload
      final initResp = await http
          .post(
            Uri.parse('$_apiBase/v1/uploads'),
            headers: _headers,
            body: jsonEncode(
                {'filename': filename, 'numberOfParts': 1, 'type': 'DATASET'}),
          )
          .timeout(_httpTimeout);

      if (initResp.statusCode != 200) {
        _log('❌ Upload init failed (${initResp.statusCode})');
        return null;
      }

      final initData = jsonDecode(initResp.body);
      final uploadId = initData['id'] as String;
      final s3Url = (initData['uploadUrls'] as List).first as String;

      // Step B: PUT to S3
      final ext = filename.split('.').last.toLowerCase();
      final contentType = {
            'png': 'image/png',
            'jpg': 'image/jpeg',
            'jpeg': 'image/jpeg',
            'webp': 'image/webp'
          }[ext] ??
          'application/octet-stream';

      final s3Req = http.Request('PUT', Uri.parse(s3Url));
      s3Req.headers['Content-Type'] = contentType;
      s3Req.bodyBytes = fileBytes;
      final s3Resp =
          await http.Client().send(s3Req).timeout(_httpTimeout);

      if (s3Resp.statusCode != 200) {
        _log('❌ S3 upload failed (${s3Resp.statusCode})');
        return null;
      }

      final etag = s3Resp.headers['etag']?.replaceAll('"', '') ?? '';

      // Step C: Complete upload
      final completeResp = await http
          .post(
            Uri.parse('$_apiBase/v1/uploads/$uploadId/complete'),
            headers: _headers,
            body: jsonEncode({
              'parts': [
                {'PartNumber': 1, 'ETag': etag}
              ]
            }),
          )
          .timeout(_httpTimeout);

      if (completeResp.statusCode != 200) {
        _log('❌ Upload complete failed (${completeResp.statusCode})');
        return null;
      }

      final assetData = jsonDecode(completeResp.body);
      final assetUrl = assetData['url'] as String? ?? '';

      _log('✅ Uploaded: ${uploadId.substring(0, 12)}...');
      return {'assetId': uploadId, 'url': assetUrl};
    } catch (e) {
      _log('❌ Upload error: $e');
      return null;
    }
  }

  /// Upload image from bytes (e.g. from memory) instead of file path
  Future<Map<String, String>?> uploadImageBytes(
      Uint8List bytes, String filename) async {
    _log('📤 Uploading $filename (${bytes.length} bytes)...');

    try {
      final initResp = await http
          .post(
            Uri.parse('$_apiBase/v1/uploads'),
            headers: _headers,
            body: jsonEncode(
                {'filename': filename, 'numberOfParts': 1, 'type': 'DATASET'}),
          )
          .timeout(_httpTimeout);

      if (initResp.statusCode != 200) return null;

      final initData = jsonDecode(initResp.body);
      final uploadId = initData['id'] as String;
      final s3Url = (initData['uploadUrls'] as List).first as String;

      final ext = filename.split('.').last.toLowerCase();
      final contentType = {
            'png': 'image/png',
            'jpg': 'image/jpeg',
            'jpeg': 'image/jpeg',
            'webp': 'image/webp'
          }[ext] ??
          'application/octet-stream';

      final s3Req = http.Request('PUT', Uri.parse(s3Url));
      s3Req.headers['Content-Type'] = contentType;
      s3Req.bodyBytes = bytes;
      final s3Resp =
          await http.Client().send(s3Req).timeout(_httpTimeout);
      if (s3Resp.statusCode != 200) return null;

      final etag = s3Resp.headers['etag']?.replaceAll('"', '') ?? '';

      final completeResp = await http
          .post(
            Uri.parse('$_apiBase/v1/uploads/$uploadId/complete'),
            headers: _headers,
            body: jsonEncode({
              'parts': [
                {'PartNumber': 1, 'ETag': etag}
              ]
            }),
          )
          .timeout(_httpTimeout);
      if (completeResp.statusCode != 200) return null;

      final assetData = jsonDecode(completeResp.body);
      final assetUrl = assetData['url'] as String? ?? '';

      _log('✅ Uploaded: ${uploadId.substring(0, 12)}...');
      return {'assetId': uploadId, 'url': assetUrl};
    } catch (e) {
      _log('❌ Upload error: $e');
      return null;
    }
  }

  // ── Task Creation ────────────────────────────────────────────────

  /// Create an Image-to-Video task. Returns taskId or null.
  Future<String?> createI2VTask({
    required String prompt,
    required Map<String, String> imageAsset, // {assetId, url}
    String modelKey = 'gen4_turbo',
    int duration = 5,
    int width = 1280,
    int height = 720,
    int? seed,
  }) async {
    if (!isAuthenticated) {
      final ok = await authenticate(cdpPort: _cdpPort);
      if (!ok) return null;
    }

    final model = getModel(modelKey) ?? videoModels[1]; // default gen4_turbo
    seed ??= Random().nextInt(999999999) + 1;
    final sessionId = _generateUuid();
    final assetGroupId = await _getAssetGroupId();

    final payload = {
      'taskType': model.key,
      'options': {
        'route': 'i2v',
        'name': '${model.label} ${prompt.length > 50 ? prompt.substring(0, 50) : prompt} $seed',
        'text_prompt': prompt,
        'seconds': duration,
        'width': width,
        'height': height,
        'init_image': imageAsset['url'],
        'imageAssetId': imageAsset['assetId'],
        'exploreMode': false,
        'creationSource': 'tool-mode',
        'seed': seed,
        'watermark': true,
        if (assetGroupId != null) 'assetGroupId': assetGroupId,
      },
      'asTeamId': _teamId!,
      'sessionId': sessionId,
    };

    _log('🎬 Creating I2V task (${model.label}, ${duration}s)...');

    return _submitTask(payload);
  }

  /// Create a Text-to-Video task (no image). Returns taskId or null.
  Future<String?> createT2VTask({
    required String prompt,
    String modelKey = 'gen4_turbo',
    int duration = 5,
    int width = 1280,
    int height = 720,
    int? seed,
  }) async {
    if (!isAuthenticated) {
      final ok = await authenticate(cdpPort: _cdpPort);
      if (!ok) return null;
    }

    final model = getModel(modelKey) ?? videoModels[1];
    seed ??= Random().nextInt(999999999) + 1;
    final sessionId = _generateUuid();
    final assetGroupId = await _getAssetGroupId();

    final payload = {
      'taskType': model.key,
      'options': {
        'route': 't2v',
        'name': '${model.label} ${prompt.length > 50 ? prompt.substring(0, 50) : prompt} $seed',
        'text_prompt': prompt,
        'seconds': duration,
        'width': width,
        'height': height,
        'exploreMode': false,
        'creationSource': 'tool-mode',
        'seed': seed,
        'watermark': true,
        if (assetGroupId != null) 'assetGroupId': assetGroupId,
      },
      'asTeamId': _teamId!,
      'sessionId': sessionId,
    };

    _log('🎬 Creating T2V task (${model.label}, ${duration}s)...');

    return _submitTask(payload);
  }

  Future<String?> _submitTask(Map<String, dynamic> payload) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$_apiBase/v1/tasks'),
            headers: _headers,
            body: jsonEncode(payload),
          )
          .timeout(_httpTimeout);

      if (resp.statusCode != 200 && resp.statusCode != 201) {
        _log('❌ Task creation failed (${resp.statusCode}): ${resp.body.length > 300 ? resp.body.substring(0, 300) : resp.body}');
        return null;
      }

      final taskData = jsonDecode(resp.body);
      final taskId =
          (taskData['task']?['id'] ?? taskData['id'])?.toString();
      _log('📋 Task: ${taskId?.substring(0, 12)}...');
      return taskId;
    } catch (e) {
      _log('❌ Task submission error: $e');
      return null;
    }
  }

  // ── Polling ──────────────────────────────────────────────────────

  /// Poll until task completes. Returns video URL or null.
  Future<String?> pollToCompletion(String taskId) async {
    final url = '$_apiBase/v1/tasks/$taskId?asTeamId=$_teamId';
    final start = DateTime.now();

    while (DateTime.now().difference(start) < _maxWait) {
      try {
        final resp = await http.get(Uri.parse(url), headers: {
          'Authorization': 'Bearer $_token',
        }).timeout(_httpTimeout);

        final task = jsonDecode(resp.body)['task'] as Map<String, dynamic>?;
        if (task == null) continue;

        final status = task['status'] as String? ?? 'UNKNOWN';
        final progress =
            double.tryParse(task['progressRatio']?.toString() ?? '0') ?? 0;

        _log('⏳ ${taskId.substring(0, 8)}: ${(progress * 100).toInt()}% — $status');

        if (status == 'SUCCEEDED') {
          _log('✅ Video generation complete!');

          // Extract video URL from artifacts or output
          final artifacts = task['artifacts'] as List? ?? [];
          if (artifacts.isNotEmpty) {
            return artifacts.first['url'] as String?;
          }
          final output = task['output'];
          if (output is List && output.isNotEmpty) {
            return output.first?.toString();
          }
          if (output is String) return output;

          _log('⚠️ No video URL in result');
          return null;
        } else if (status == 'FAILED' || status == 'CANCELLED') {
          _log('❌ $status: ${task['error'] ?? 'unknown'}');
          return null;
        }
      } catch (e) {
        _log('⚠️ Poll error: $e');
      }

      await Future.delayed(_pollInterval);
    }

    _log('⏰ Timed out after ${_maxWait.inSeconds}s');
    return null;
  }

  // ── Full Generation Flow ─────────────────────────────────────────

  /// Generate video from image + prompt (complete flow: upload → create → poll → download).
  Future<RunwayVideoResult> generateFromImage({
    required String prompt,
    required String imagePath,
    String modelKey = 'gen4_turbo',
    int duration = 5,
    int width = 1280,
    int height = 720,
    String? outputPath,
  }) async {
    // 1. Auth
    if (!isAuthenticated) {
      final ok = await authenticate(cdpPort: _cdpPort);
      if (!ok) {
        return RunwayVideoResult(success: false, error: 'Authentication failed');
      }
    }

    // 2. Upload image
    _log('📤 Uploading reference image...');
    final imageAsset = await uploadImage(imagePath);
    if (imageAsset == null) {
      return RunwayVideoResult(success: false, error: 'Image upload failed');
    }

    // 3. Create task
    final taskId = await createI2VTask(
      prompt: prompt,
      imageAsset: imageAsset,
      modelKey: modelKey,
      duration: duration,
      width: width,
      height: height,
    );
    if (taskId == null) {
      return RunwayVideoResult(success: false, error: 'Task creation failed');
    }

    // 4. Poll
    final videoUrl = await pollToCompletion(taskId);
    if (videoUrl == null) {
      return RunwayVideoResult(
        success: false,
        taskId: taskId,
        error: 'Generation failed or timed out',
      );
    }

    // 5. Download if output path specified
    String? savedPath;
    int? fileSize;
    if (outputPath != null) {
      final downloadResult = await downloadVideo(videoUrl, outputPath);
      savedPath = downloadResult?['path'];
      fileSize = int.tryParse(downloadResult?['size'] ?? '');
    }

    return RunwayVideoResult(
      success: true,
      taskId: taskId,
      videoUrl: videoUrl,
      videoPath: savedPath,
      fileSizeBytes: fileSize,
    );
  }

  /// Generate video from text prompt only (no image).
  Future<RunwayVideoResult> generateFromText({
    required String prompt,
    String modelKey = 'gen4_turbo',
    int duration = 5,
    int width = 1280,
    int height = 720,
    String? outputPath,
  }) async {
    if (!isAuthenticated) {
      final ok = await authenticate(cdpPort: _cdpPort);
      if (!ok) {
        return RunwayVideoResult(success: false, error: 'Authentication failed');
      }
    }

    final taskId = await createT2VTask(
      prompt: prompt,
      modelKey: modelKey,
      duration: duration,
      width: width,
      height: height,
    );
    if (taskId == null) {
      return RunwayVideoResult(success: false, error: 'Task creation failed');
    }

    final videoUrl = await pollToCompletion(taskId);
    if (videoUrl == null) {
      return RunwayVideoResult(
        success: false,
        taskId: taskId,
        error: 'Generation failed or timed out',
      );
    }

    String? savedPath;
    int? fileSize;
    if (outputPath != null) {
      final downloadResult = await downloadVideo(videoUrl, outputPath);
      savedPath = downloadResult?['path'];
      fileSize = int.tryParse(downloadResult?['size'] ?? '');
    }

    return RunwayVideoResult(
      success: true,
      taskId: taskId,
      videoUrl: videoUrl,
      videoPath: savedPath,
      fileSizeBytes: fileSize,
    );
  }

  // ── Download ─────────────────────────────────────────────────────
  /// Download a video from URL to local file. Returns {path, size} or null.
  Future<Map<String, String>?> downloadVideo(
      String videoUrl, String outputPath) async {
    try {
      _log('⬇️ Downloading video...');
      final resp =
          await http.get(Uri.parse(videoUrl)).timeout(const Duration(seconds: 120));
      if (resp.statusCode != 200) {
        _log('❌ Download failed (${resp.statusCode})');
        return null;
      }

      final file = File(outputPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(resp.bodyBytes);

      final size = resp.bodyBytes.length;
      _log('✅ Saved: ${outputPath.split(Platform.pathSeparator).last} (${(size / 1024).toStringAsFixed(1)} KB)');
      return {'path': outputPath, 'size': size.toString()};
    } catch (e) {
      _log('❌ Download error: $e');
      return null;
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────
  String _generateUuid() {
    final rng = Random();
    String hex(int len) =>
        List.generate(len, (_) => rng.nextInt(16).toRadixString(16)).join();
    final variant = ['8', '9', 'a', 'b'][rng.nextInt(4)];
    return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
  }

  /// Estimate credit cost for a generation
  Future<int?> estimateCost({
    required String modelKey,
    int duration = 5,
    int width = 1280,
    int height = 720,
    String route = 'i2v',
  }) async {
    if (!isAuthenticated) return null;
    try {
      final resp = await http
          .post(
            Uri.parse('$_apiBase/v1/billing/estimate_feature_cost_credits'),
            headers: _headers,
            body: jsonEncode({
              'feature': modelKey,
              'count': 1,
              'asTeamId': _teamId!,
              'taskOptions': {
                'height': height,
                'width': width,
                'init_image': '',
                'imageAssetId': '',
                'seconds': duration,
                'route': route,
              },
            }),
          )
          .timeout(_httpTimeout);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        return data['cost'] as int?;
      }
    } catch (_) {}
    return null;
  }

  void dispose() {
    _statusController.close();
  }
}
