import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'video_generation_service.dart'; // For DesktopGenerator
import 'profile_manager_service.dart';
import '../utils/ffmpeg_utils.dart';

/// Flow Image Generation Service
/// Generates images using Google Flow's batchGenerateImages API via CDP.
///
/// Supports 3 image models:
///   - Nano Banana Pro  (GEM_PIX_2)
///   - Nano Banana 2    (NARWHAL)
///   - Imagen 4         (IMAGEN_3_5)
///
/// Features:
///   - Single or batch image generation
///   - Reference image support (upload + generate with refs)
///   - Multi-profile support via ChromeProfile
///   - Auto-detects project ID from browser URL
///
/// Uses the same CDP pattern as the existing video generation service.
class FlowImageGenerationService {
  static final FlowImageGenerationService _instance =
      FlowImageGenerationService._internal();
  factory FlowImageGenerationService() => _instance;
  FlowImageGenerationService._internal();

  // â”€â”€â”€ Constants â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  static const String recaptchaSiteKey =
      '6LdsFiUsAAAAAIjVDZcuLhaHiDn5nnHVXVRQGeMV';
  static const String recaptchaAction = 'IMAGE_GENERATION';

  static const String apiBase = 'https://aisandbox-pa.googleapis.com/v1';

  /// Map of user-friendly model names to API model keys
  static const Map<String, String> modelKeys = {
    'Nano Banana Pro': 'GEM_PIX_2',
    'Nano Banana 2': 'NARWHAL',
    'Imagen 4': 'IMAGEN_3_5',
  };

  /// Map of aspect ratio labels to API values
  static const Map<String, String> aspectRatioKeys = {
    'Landscape': 'IMAGE_ASPECT_RATIO_LANDSCAPE',
    '16:9': 'IMAGE_ASPECT_RATIO_LANDSCAPE',
    'Portrait': 'IMAGE_ASPECT_RATIO_PORTRAIT',
    '9:16': 'IMAGE_ASPECT_RATIO_PORTRAIT',
    'Square': 'IMAGE_ASPECT_RATIO_SQUARE',
    '1:1': 'IMAGE_ASPECT_RATIO_SQUARE',
  };

  // â”€â”€â”€ State â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  final _statusController = StreamController<String>.broadcast();
  Stream<String> get statusStream => _statusController.stream;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  int _successCount = 0;
  int _failedCount = 0;
  int get successCount => _successCount;
  int get failedCount => _failedCount;

  ProfileManagerService? _profileManager;

  // Cooldown between reCAPTCHA fetches (5s minimum interval)
  DateTime? _lastRecaptchaTime;

  void initialize({ProfileManagerService? profileManager}) {
    _profileManager = profileManager;
  }

  void _safeAdd(String msg) {
    try {
      if (!_statusController.isClosed) _statusController.add(msg);
    } catch (_) {}
  }

  void _log(String msg) {
    print(msg);
    _safeAdd(msg);
  }

  /// Generate a random UUID v4
  String _generateUuid() {
    final r = Random();
    String hex(int len) => List.generate(len, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
  }

  /// Compress an image to under maxSizeKB (default 100KB) using FFmpeg.
  /// Returns the compressed file path, or original if already small enough.
  Future<String> compressImageForUpload(String imagePath, {int maxSizeKB = 100, int maxDimension = 512}) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) return imagePath;
      
      final sizeKB = (await file.length()) / 1024;
      if (sizeKB <= maxSizeKB) {
        _log('[FlowImage] Image already under ${maxSizeKB}KB (${sizeKB.toStringAsFixed(0)}KB)');
        return imagePath;
      }
      
      _log('[FlowImage] Compressing ${path.basename(imagePath)} (${sizeKB.toStringAsFixed(0)}KB â†’ <${maxSizeKB}KB)...');
      
      final ffmpegPath = await FFmpegUtils.getFFmpegPath();
      final compressedPath = path.join(
        Directory.systemTemp.path, 
        'flow_compressed_${DateTime.now().millisecondsSinceEpoch}.jpg'
      );
      
      // FFmpeg: resize longest side to maxDimension, then JPEG quality 8 (2=best, 31=worst)
      final result = await Process.run(ffmpegPath, [
        '-y', '-i', imagePath,
        '-vf', 'scale=\'min($maxDimension,iw)\':\'min($maxDimension,ih)\':force_original_aspect_ratio=decrease',
        '-q:v', '8',
        compressedPath,
      ]);
      
      if (result.exitCode == 0 && File(compressedPath).existsSync()) {
        final newSizeKB = (await File(compressedPath).length()) / 1024;  
        _log('[FlowImage] Compressed: ${sizeKB.toStringAsFixed(0)}KB â†’ ${newSizeKB.toStringAsFixed(0)}KB');
        return compressedPath;
      }
      
      _log('[FlowImage] âš ï¸ Compression failed, using original');
      return imagePath;
    } catch (e) {
      _log('[FlowImage] âš ï¸ Compression error: $e');
      return imagePath;
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC API â€” Parallel Batch Generation (FAST PATH)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Generate images with SLIDING WINDOW concurrency.
  /// Instead of "batch of N â†’ wait â†’ next batch", keeps N concurrent slots filled.
  /// Each request launches 10s apart with a fresh reCAPTCHA token.
  /// When one completes, the next queued prompt takes its slot.
  /// Stuck requests (>120s) get killed and re-queued with new tokens.
  Future<List<FlowImageResult>> generateImagesBatch({
    required List<String> prompts,
    String model = 'Nano Banana Pro',
    String aspectRatio = 'Landscape',
    List<String>? referenceImageIds,
    int debugPort = 9222,
    String? projectId,
    DesktopGenerator? generator,
    int maxConcurrent = 5,
    /// Called immediately when a scene completes successfully.
    /// Parameters: (promptIndex, result)
    void Function(int promptIndex, FlowImageResult result)? onImageReady,
  }) async {
    if (prompts.isEmpty) return [];
    
    _isRunning = true;
    try {
      _log('[FlowImage] ðŸš€ Sliding window: ${prompts.length} images, max $maxConcurrent concurrent');
      
      final modelKey = modelKeys[model] ?? model;
      final aspectKey = aspectRatioKeys[aspectRatio] ?? aspectRatio;
      
      final gen = generator ?? await _getGenerator(debugPort);
      
      _log('[FlowImage] ðŸ”‘ Getting access token...');
      final accessToken = await gen.getAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('Failed to get access token.');
      }
      
      final resolvedProjectId = projectId ?? await _getProjectId(gen) ?? _generateUuid();
      
      // Results array â€” one per prompt
      final results = List<FlowImageResult>.filled(prompts.length, 
        FlowImageResult(success: false, error: 'Not started', images: []),
      );
      
      // Queue of prompt indices to process
      final queue = List<int>.generate(prompts.length, (i) => i);
      final activeSlots = <int, Future<void>>{}; // index -> running future

      
      // Launch a single request with fresh token + 120s timeout
      Future<void> launchRequest(int promptIdx) async {
        try {
          // Enforce 10s interval between launches
          if (_lastRecaptchaTime != null) {
            final elapsed = DateTime.now().difference(_lastRecaptchaTime!).inMilliseconds;
            final waitMs = 10000 - elapsed;
            if (waitMs > 0) {
              _log('[FlowImage] â³ ${(waitMs / 1000).toStringAsFixed(1)}s before scene ${promptIdx + 1}...');
              await Future.delayed(Duration(milliseconds: waitMs));
            }
          }
          
          // Get fresh reCAPTCHA token RIGHT before this request
          final token = await _getRecaptchaToken(gen);
          _lastRecaptchaTime = DateTime.now();
          if (token == null) {
            results[promptIdx] = FlowImageResult(success: false, error: 'No reCAPTCHA token', images: []);
            _failedCount++;
            return;
          }
          _log('[FlowImage] ðŸš€ Scene ${promptIdx + 1} launched');
          
          // Run HTTP request with 120s hard timeout
          final result = await _sendGenerationRequestHttp(
            accessToken: accessToken,
            projectId: resolvedProjectId,
            modelKey: modelKey,
            aspectKey: aspectKey,
            prompt: prompts[promptIdx],
            outputCount: 1,
            recaptchaToken: token,
            referenceImageIds: referenceImageIds,
          ).timeout(const Duration(seconds: 120), onTimeout: () {
            _log('[FlowImage] âŒ Scene ${promptIdx + 1}: TIMEOUT (120s) â€” killed');
            return FlowImageResult(success: false, error: 'Timeout (120s)', images: []);
          });
          
          results[promptIdx] = result;
          if (result.success) {
            _successCount++;
            _log('[FlowImage] \u2705 Scene ${promptIdx + 1}: OK');
            // Fire instant callback so UI can display the image immediately
            onImageReady?.call(promptIdx, result);
          } else {
            _failedCount++;
            _log('[FlowImage] âŒ Scene ${promptIdx + 1}: ${result.error}');
          }
        } catch (e) {
          results[promptIdx] = FlowImageResult(success: false, error: '$e', images: []);
          _failedCount++;
          _log('[FlowImage] âŒ Scene ${promptIdx + 1}: $e');
        }
      }
      
      // === Sliding window loop ===
      // Fill initial slots (up to maxConcurrent), launching 10s apart
      while (queue.isNotEmpty || activeSlots.isNotEmpty) {
        // Fill empty slots from queue
        while (activeSlots.length < maxConcurrent && queue.isNotEmpty) {
          final idx = queue.removeAt(0);
          
          
          // Each launch is a fire-and-forget future
          final future = launchRequest(idx);
          activeSlots[idx] = future;
          
          // Don't launch the next one yet â€” we'll wait 10s in the loop
          // But first let's break to check if we need to wait
          break;
        }
        
        if (activeSlots.isEmpty) break;
        
        // Wait for ANY slot to complete, OR 10s to pass (whichever first)
        // This allows launching the next request every 10s while others run
        await Future.any([
          Future.wait(activeSlots.values.toList()).then((_) {}),
          Future.delayed(const Duration(seconds: 10)),
        ]);
        
        // Remove completed slots
        final completed = <int>[];
        for (final entry in activeSlots.entries) {
          // Check if the future completed by trying to await with zero timeout
          bool done = false;
          try {
            await entry.value.timeout(Duration.zero);
            done = true;
          } catch (e) {
            // TimeoutException means still running, other exceptions mean done with error
            if (e is! TimeoutException) done = true;
          }
          if (done) completed.add(entry.key);
        }
        for (final idx in completed) {
          activeSlots.remove(idx);
        }
      }
      
      // === Retry failed ones ===
      final failedIndices = <int>[];
      for (int i = 0; i < results.length; i++) {
        if (!results[i].success) failedIndices.add(i);
      }
      
      if (failedIndices.isNotEmpty) {
        _log('[FlowImage] ðŸ”„ Retrying ${failedIndices.length} failed scene(s)...');
        for (final idx in failedIndices) {
          try {
            // Wait 10s before retry token
            await Future.delayed(const Duration(seconds: 10));
            final retryToken = await _getRecaptchaToken(gen);
            _lastRecaptchaTime = DateTime.now();
            if (retryToken == null) continue;
            
            _log('[FlowImage] ðŸ”„ Retrying scene ${idx + 1}...');
            final retryResult = await _sendGenerationRequestHttp(
              accessToken: accessToken,
              projectId: resolvedProjectId,
              modelKey: modelKey,
              aspectKey: aspectKey,
              prompt: prompts[idx],
              outputCount: 1,
              recaptchaToken: retryToken,
              referenceImageIds: referenceImageIds,
            ).timeout(const Duration(seconds: 120), onTimeout: () {
              return FlowImageResult(success: false, error: 'Retry timeout', images: []);
            });
            
            results[idx] = retryResult;
            if (retryResult.success) {
              _successCount++;
              _failedCount--;
              _log('[FlowImage] âœ… Retry scene ${idx + 1}: OK');
              onImageReady?.call(idx, retryResult);
            }
          } catch (e) {
            _log('[FlowImage] âŒ Retry scene ${idx + 1}: $e');
          }
        }
      }
      
      final s = results.where((r) => r.success).length;
      final f = results.where((r) => !r.success).length;
      _log('[FlowImage] âœ… Done: $s success, $f failed');
      _safeAdd('UPDATE');
      
      return results;
    } catch (e) {
      _log('[FlowImage] âŒ Batch error: $e');
      return prompts.map((_) => FlowImageResult(
        success: false, error: e.toString(), images: [],
      )).toList();
    } finally {
      _isRunning = false;
    }
  }

  /// Send a single image generation request using dart:io HttpClient.
  /// Each call creates its own HTTP client for independence.
  /// Includes CORS preflight + browser-like headers.
  Future<FlowImageResult> _sendGenerationRequestHttp({
    required String accessToken,
    required String projectId,
    required String modelKey,
    required String aspectKey,
    required String prompt,
    required int outputCount,
    required String recaptchaToken,
    List<String>? referenceImageIds,
  }) async {
    final random = Random();
    String hex(int length) =>
        List.generate(length, (_) => random.nextInt(16).toRadixString(16)).join();
    final batchId = '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}';
    final sessionId = ';${DateTime.now().millisecondsSinceEpoch}';

    final imageInputs = <Map<String, dynamic>>[];
    if (referenceImageIds != null) {
      for (final refId in referenceImageIds) {
        imageInputs.add({
          'imageInputType': 'IMAGE_INPUT_TYPE_REFERENCE',
          'name': refId,
        });
      }
    }

    final requests = List.generate(outputCount, (i) {
      return {
        'clientContext': {
          'recaptchaContext': {
            'token': recaptchaToken,
            'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB',
          },
          'projectId': projectId,
          'tool': 'PINHOLE',
          'sessionId': sessionId,
        },
        'imageModelName': modelKey,
        'imageAspectRatio': aspectKey,
        'structuredPrompt': {
          'parts': [
            {'text': prompt}
          ],
        },
        'seed': random.nextInt(1000000),
        'imageInputs': imageInputs,
      };
    });

    final payload = jsonEncode({
      'clientContext': {
        'recaptchaContext': {
          'token': recaptchaToken,
          'applicationType': 'RECAPTCHA_APPLICATION_TYPE_WEB',
        },
        'projectId': projectId,
        'tool': 'PINHOLE',
        'sessionId': sessionId,
      },
      'mediaGenerationContext': {
        'batchId': batchId,
      },
      'useNewMedia': true,
      'requests': requests,
    });

    final endpoint = Uri.parse('$apiBase/projects/$projectId/flowMedia:batchGenerateImages');

    try {
      // CORS Preflight
      try {
        final pfReq = await HttpClient().openUrl('OPTIONS', endpoint);
        pfReq.headers.set('accept', '*/*');
        pfReq.headers.set('access-control-request-headers', 'authorization');
        pfReq.headers.set('access-control-request-method', 'POST');
        pfReq.headers.set('origin', 'https://labs.google');
        pfReq.headers.set('referer', 'https://labs.google/');
        final pfResp = await pfReq.close().timeout(const Duration(seconds: 8));
        await pfResp.drain();
      } catch (_) {}

      // POST request with its own HttpClient
      final httpClient = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..idleTimeout = const Duration(seconds: 15);
      
      try {
        final request = await httpClient.postUrl(endpoint);
        request.headers.set('authorization', 'Bearer $accessToken');
        request.headers.set('content-type', 'text/plain;charset=UTF-8');
        request.headers.set('origin', 'https://labs.google');
        request.headers.set('referer', 'https://labs.google/');
        request.headers.set('sec-fetch-dest', 'empty');
        request.headers.set('sec-fetch-mode', 'cors');
        request.headers.set('sec-fetch-site', 'cross-site');
        request.write(payload);
        
        final response = await request.close().timeout(const Duration(seconds: 120));
        final responseBody = await response.transform(utf8.decoder).join()
            .timeout(const Duration(seconds: 30));
        
        if (response.statusCode != 200) {
          final errorBody = responseBody.length > 300 ? responseBody.substring(0, 300) : responseBody;
          return FlowImageResult(
            success: false,
            error: response.statusCode == 429
                ? 'Rate limited (429)'
                : 'HTTP ${response.statusCode}: $errorBody',
            images: [],
            statusCode: response.statusCode,
          );
        }

        // Parse response
        final data = jsonDecode(responseBody) as Map<String, dynamic>;
        final mediaList = data['media'] as List? ?? [];
        final images = <FlowGeneratedImage>[];

        for (final media in mediaList) {
          final image = media['image']?['generatedImage'];
          if (image != null) {
            images.add(FlowGeneratedImage(
              name: media['name']?.toString(),
              seed: image['seed'],
              mediaGenerationId: image['mediaGenerationId']?.toString(),
              fifeUrl: image['fifeUrl']?.toString(),
              encodedImage: image['encodedImage']?.toString(),
              prompt: image['prompt']?.toString(),
              modelName: image['modelNameType']?.toString(),
              aspectRatio: image['aspectRatio']?.toString(),
              width: media['image']?['dimensions']?['width'],
              height: media['image']?['dimensions']?['height'],
              workflowId: image['workflowId']?.toString(),
            ));
          }
        }

        return FlowImageResult(
          success: images.isNotEmpty,
          images: images,
          batchId: batchId,
          statusCode: 200,
        );
      } finally {
        httpClient.close(force: false);
      }
    } catch (e) {
      return FlowImageResult(
        success: false,
        error: 'HTTP error: $e',
        images: [],
      );
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC API â€” Single Image Generation
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Generate a SINGLE image. This is the primary method.
  ///
  /// [prompt] - Text prompt for image generation.
  /// [model] - 'Nano Banana Pro', 'Nano Banana 2', 'Imagen 4'
  ///           or API keys: 'GEM_PIX_2', 'NARWHAL', 'IMAGEN_3_5'
  /// [aspectRatio] - 'Landscape', 'Portrait', 'Square'
  /// [referenceImageIds] - Optional list of uploaded image IDs to use as references.
  ///                       Get these IDs from [uploadReferenceImage].
  /// [debugPort] - Chrome debug port (default 9222)
  /// [projectId] - Flow project ID (auto-detected from browser URL if null)
  /// [generator] - Optional DesktopGenerator instance
  ///
  /// Returns a [FlowImageResult] with the generated image.
  Future<FlowImageResult> generateImage({
    required String prompt,
    String model = 'Nano Banana Pro',
    String aspectRatio = 'Landscape',
    List<String>? referenceImageIds,
    int debugPort = 9222,
    String? projectId,
    DesktopGenerator? generator,
  }) async {
    return generateImages(
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      outputCount: 1,
      referenceImageIds: referenceImageIds,
      debugPort: debugPort,
      projectId: projectId,
      generator: generator,
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC API â€” Batch Image Generation
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Generate multiple images from a single prompt.
  ///
  /// [outputCount] - Number of images to generate (1-4).
  /// [referenceImageIds] - Optional list of uploaded image IDs to use as references.
  ///
  /// See [generateImage] for other parameter descriptions.
  Future<FlowImageResult> generateImages({
    required String prompt,
    String model = 'Nano Banana Pro',
    String aspectRatio = 'Landscape',
    int outputCount = 1,
    List<String>? referenceImageIds,
    int debugPort = 9222,
    String? projectId,
    DesktopGenerator? generator,
  }) async {
    _isRunning = true;

    try {
      _log('[FlowImage] ðŸŽ¨ Starting image generation...');
      _log('[FlowImage]   Prompt: "${prompt.length > 60 ? prompt.substring(0, 60) + '...' : prompt}"');
      _log('[FlowImage]   Model: $model | Aspect: $aspectRatio | Count: $outputCount');
      if (referenceImageIds != null && referenceImageIds.isNotEmpty) {
        _log('[FlowImage]   ðŸ“Ž Reference images: ${referenceImageIds.length}');
      }

      // Resolve model key
      final modelKey = modelKeys[model] ?? model;
      if (!modelKeys.containsValue(modelKey)) {
        throw Exception(
            'Invalid model: $model. Use one of: ${modelKeys.keys.join(", ")}');
      }

      // Resolve aspect ratio
      final aspectKey = aspectRatioKeys[aspectRatio] ?? aspectRatio;

      // Get or create generator
      final gen = generator ?? await _getGenerator(debugPort);

      // Get access token
      _log('[FlowImage] ðŸ”‘ Getting access token...');
      final accessToken = await gen.getAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('Failed to get access token. Please ensure you are logged in.');
      }
      _log('[FlowImage] âœ… Access token obtained');

      // Get project ID from browser if not provided, or generate random one
      final resolvedProjectId = projectId ?? await _getProjectId(gen) ?? _generateUuid();
      _log('[FlowImage] ðŸ“ Project: $resolvedProjectId');

      // Enforce 5s cooldown between reCAPTCHA token fetches
      if (_lastRecaptchaTime != null) {
        final elapsed = DateTime.now().difference(_lastRecaptchaTime!).inMilliseconds;
        final waitMs = 2500 - elapsed;
        if (waitMs > 0) {
          _log('[FlowImage] â³ Waiting ${(waitMs / 1000).toStringAsFixed(1)}s before reCAPTCHA...');
          await Future.delayed(Duration(milliseconds: waitMs));
        }
      }
      
      // Get reCAPTCHA token
      _log('[FlowImage] ðŸ›¡ï¸ Getting reCAPTCHA token...');
      final recaptchaToken = await _getRecaptchaToken(gen);
      _lastRecaptchaTime = DateTime.now();
      if (recaptchaToken == null) {
        throw Exception('Failed to get reCAPTCHA token');
      }
      _log('[FlowImage] âœ… reCAPTCHA token obtained');

      // Build and send request
      _log('[FlowImage] ðŸ“¤ Sending generation request...');
      final result = await _sendGenerationRequestHttp(
        accessToken: accessToken,
        projectId: resolvedProjectId,
        modelKey: modelKey,
        aspectKey: aspectKey,
        prompt: prompt,
        outputCount: outputCount,
        recaptchaToken: recaptchaToken,
        referenceImageIds: referenceImageIds,
      );

      if (result.success) {
        _successCount++;
        _log('[FlowImage] âœ… Generated ${result.images.length} image(s) successfully!');
      } else {
        _failedCount++;
        _log('[FlowImage] âŒ Generation failed: ${result.error}');
      }

      _safeAdd('UPDATE');
      return result;
    } catch (e) {
      _failedCount++;
      _log('[FlowImage] âŒ Error: $e');
      return FlowImageResult(
        success: false,
        error: e.toString(),
        images: [],
      );
    } finally {
      _isRunning = false;
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC API â€” Reference Image Upload
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Upload a reference image to Flow. Returns the image ID (name).
  ///
  /// This ID can then be passed to [generateImage] or [generateImages]
  /// via the [referenceImageIds] parameter.
  ///
  /// [imagePath] - Local file path to the image.
  /// [generator] - Optional DesktopGenerator instance.
  /// [debugPort] - Chrome debug port (default 9222).
  /// [projectId] - Flow project ID (auto-detected if null).
  ///
  /// Returns the uploaded image's ID (name UUID), or null on failure.
  Future<String?> uploadReferenceImage({
    required String imagePath,
    DesktopGenerator? generator,
    int debugPort = 9222,
    String? projectId,
  }) async {
    try {
      _log('[FlowImage] ðŸ“¤ Uploading reference image: ${path.basename(imagePath)}');

      final file = File(imagePath);
      if (!await file.exists()) {
        throw Exception('File not found: $imagePath');
      }

      // Auto-compress to <100KB before uploading
      final actualPath = await compressImageForUpload(imagePath);

      final bytes = await File(actualPath).readAsBytes();
      final b64 = base64Encode(bytes);
      final ext = path.extension(actualPath).toLowerCase();
      final mimeType = ext == '.png' ? 'image/png' 
                     : ext == '.webp' ? 'image/webp'
                     : ext == '.gif' ? 'image/gif'
                     : 'image/jpeg';
      final fileName = path.basename(imagePath); // Keep original name

      final gen = generator ?? await _getGenerator(debugPort);

      // Get access token
      final accessToken = await gen.getAccessToken();
      if (accessToken == null) throw Exception('No access token');

      // Get project ID
      final resolvedProjectId = projectId ?? await _getProjectId(gen) ?? _generateUuid();

      // Upload via direct HTTP from Flutter
      final uploadPayload = jsonEncode({
        'clientContext': {
          'projectId': resolvedProjectId,
          'tool': 'PINHOLE',
          'sessionId': ';${DateTime.now().millisecondsSinceEpoch}',
        },
        'imageBytes': b64,
        'isUserUploaded': true,
        'isHidden': false,
        'mimeType': mimeType,
        'fileName': fileName,
      });

      final response = await http.post(
        Uri.parse('$apiBase/flow/uploadImage'),
        headers: {
          'authorization': 'Bearer $accessToken',
          'content-type': 'text/plain;charset=UTF-8',
        },
        body: uploadPayload,
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        _log('[FlowImage] âŒ Upload failed: HTTP ${response.statusCode}');
        return null;
      }

      final result = jsonDecode(response.body);
      if (result['error'] != null) {
        _log('[FlowImage] âŒ Upload failed: ${result['error']}');
        return null;
      }

      // Extract the media name (UUID) from the response
      final mediaName = result['media']?['name']?.toString();
      if (mediaName != null) {
        _log('[FlowImage] âœ… Uploaded: $mediaName');
        return mediaName;
      }

      _log('[FlowImage] âš ï¸ Upload response missing media.name: $result');
      return null;
    } catch (e) {
      _log('[FlowImage] âŒ Upload error: $e');
      return null;
    }
  }

  /// Upload multiple reference images. Returns list of image IDs.
  Future<List<String>> uploadReferenceImages({
    required List<String> imagePaths,
    DesktopGenerator? generator,
    int debugPort = 9222,
    String? projectId,
  }) async {
    final gen = generator ?? await _getGenerator(debugPort);
    final ids = <String>[];

    for (final imagePath in imagePaths) {
      final id = await uploadReferenceImage(
        imagePath: imagePath,
        generator: gen,
        debugPort: debugPort,
        projectId: projectId,
      );
      if (id != null) ids.add(id);
    }

    _log('[FlowImage] ðŸ“¦ Uploaded ${ids.length}/${imagePaths.length} reference images');
    return ids;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC API â€” Generate + Save Convenience
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Generate a single image and save it to a file.
  /// Returns the saved file path, or null on failure.
  Future<String?> generateAndSaveImage({
    required String prompt,
    required String outputPath,
    String model = 'Nano Banana Pro',
    String aspectRatio = 'Landscape',
    List<String>? referenceImageIds,
    int debugPort = 9222,
    String? projectId,
    DesktopGenerator? generator,
  }) async {
    final result = await generateImage(
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      referenceImageIds: referenceImageIds,
      debugPort: debugPort,
      projectId: projectId,
      generator: generator,
    );

    if (!result.success || result.images.isEmpty) {
      _log('[FlowImage] âŒ ${result.error ?? "No image generated"}');
      return null;
    }

    final image = result.images.first;
    final saved = await _downloadAndSave(image, outputPath);
    return saved;
  }

  /// Generate multiple images and save them to a directory.
  /// Returns list of saved file paths.
  Future<List<String>> generateAndSaveImages({
    required String prompt,
    required String outputDir,
    String model = 'Nano Banana Pro',
    String aspectRatio = 'Landscape',
    int outputCount = 1,
    List<String>? referenceImageIds,
    int debugPort = 9222,
    String? projectId,
    String? filePrefix,
    DesktopGenerator? generator,
  }) async {
    final result = await generateImages(
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      outputCount: outputCount,
      referenceImageIds: referenceImageIds,
      debugPort: debugPort,
      projectId: projectId,
      generator: generator,
    );

    if (!result.success || result.images.isEmpty) {
      throw Exception(result.error ?? 'No images generated');
    }

    // Ensure output directory exists
    final dir = Directory(outputDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final savedPaths = <String>[];
    final prefix = filePrefix ?? 'flow_image';
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    for (var i = 0; i < result.images.length; i++) {
      final fileName = '${prefix}_${timestamp}_$i.png';
      final filePath = path.join(outputDir, fileName);
      final saved = await _downloadAndSave(result.images[i], filePath);
      if (saved != null) savedPaths.add(saved);
    }

    _log('[FlowImage] ðŸ“¦ Saved ${savedPaths.length}/${result.images.length} images');
    return savedPaths;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PUBLIC API â€” Profile-based Generation
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  /// Generate a single image using a specific ChromeProfile.
  Future<FlowImageResult> generateWithProfile({
    required String prompt,
    required ChromeProfile profile,
    String model = 'Nano Banana Pro',
    String aspectRatio = 'Landscape',
    int outputCount = 1,
    List<String>? referenceImageIds,
    String? projectId,
  }) async {
    if (profile.generator == null) {
      throw Exception('Profile ${profile.name} has no generator.');
    }
    final gen = profile.generator as DesktopGenerator;
    return generateImages(
      prompt: prompt,
      model: model,
      aspectRatio: aspectRatio,
      outputCount: outputCount,
      referenceImageIds: referenceImageIds,
      generator: gen,
      projectId: projectId,
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // PRIVATE â€” Core Implementation
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

  Future<DesktopGenerator> _getGenerator(int debugPort) async {
    // 1. Try local profile manager first â€” ANY connected generator
    if (_profileManager != null) {
      for (final p in _profileManager!.profiles) {
        if (p.generator is DesktopGenerator) {
          final gen = p.generator as DesktopGenerator;
          if (gen.isConnected) {
            _log('[FlowImage] Using browser: ${p.name} (port ${p.debugPort})');
            return gen;
          }
        }
      }
    }
    
    // 2. Try VideoGenerationService's shared profile manager
    try {
      final vgs = VideoGenerationService();
      final sharedPM = vgs.profileManager;
      if (sharedPM != null) {
        for (final p in sharedPM.profiles) {
          if (p.generator is DesktopGenerator) {
            final gen = p.generator as DesktopGenerator;
            if (gen.isConnected) {
              _log('[FlowImage] Using connected browser: ${p.name}');
              return gen;
            }
          }
        }
      }
    } catch (_) {}
    
    // 3. Scan multiple ports for Playwright-managed browsers (9222-9225)
    _log('[FlowImage] Scanning ports for browsers...');
    for (int port = debugPort; port <= debugPort + 3; port++) {
      try {
        final gen = DesktopGenerator(debugPort: port);
        await gen.connect().timeout(const Duration(seconds: 5));
        if (gen.isConnected) {
          _log('[FlowImage] Connected to browser on port $port');
          return gen;
        }
      } catch (_) {
        // Port not available, try next
      }
    }
    
    // 4. Final fallback - direct CDP on specified port
    _log('[FlowImage] Connecting to port $debugPort...');
    final gen = DesktopGenerator(debugPort: debugPort);
    await gen.connect();
    return gen;
  }

  Future<String?> _getProjectId(DesktopGenerator gen) async {
    try {
      final result = await gen.executeJs('''
        (() => {
          const parts = window.location.pathname.split('/');
          const projIdx = parts.indexOf('project');
          if (projIdx >= 0 && projIdx + 1 < parts.length) return parts[projIdx + 1];
          for (let i = parts.length - 1; i >= 0; i--) {
            if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$/.test(parts[i])) return parts[i];
          }
          return null;
        })()
      ''');
      return result is String ? result : null;
    } catch (e) {
      _log('[FlowImage] âš ï¸ Could not get project ID: $e');
      return null;
    }
  }

  Future<String?> _getRecaptchaToken(DesktopGenerator gen) async {
    // IMPORTANT: Each generation call MUST get a fresh reCAPTCHA token.
    // reCAPTCHA tokens are single-use and expire after ~2 minutes.
    
    // Method 1: Use Playwright's dedicated IMAGE reCAPTCHA endpoint (preferred)
    // Uses action='IMAGE_GENERATION' â€” correct for Flow image generation
    try {
      final token = await gen.getImageRecaptchaToken();
      if (token != null && token.length > 20) {
        return token;
      }
    } catch (_) {}
    
    // Method 2: Fallback to executeJs with custom action
    try {
      final token = await gen.executeJs('''
        (async () => {
          return await grecaptcha.enterprise.execute(
            "$recaptchaSiteKey", { action: '$recaptchaAction' }
          );
        })()
      ''');
      if (token is String && token.length > 20) {
        return token;
      }
      _log('[FlowImage] âš ï¸ reCAPTCHA returned invalid token');
      return null;
    } catch (e) {
      _log('[FlowImage] âš ï¸ reCAPTCHA error: $e');
      return null;
    }
  }

  /// Download an image and save it to a file.
  Future<String?> _downloadAndSave(FlowGeneratedImage image, String filePath) async {
    if (image.fifeUrl != null && image.fifeUrl!.isNotEmpty) {
      try {
        final response = await http.get(Uri.parse(image.fifeUrl!))
            .timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) {
          await File(filePath).writeAsBytes(response.bodyBytes);
          final sizeKb = (response.bodyBytes.length / 1024).toStringAsFixed(1);
          _log('[FlowImage] ✅ Saved: ${path.basename(filePath)} (${sizeKb}KB)');
          return filePath;
        }
      } catch (e) {
        _log('[FlowImage] ⚠️ Download failed: $e');
      }
    }

    // Try base64 encoded image
    if (image.encodedImage != null && image.encodedImage!.isNotEmpty) {
      try {
        final bytes = base64Decode(image.encodedImage!);
        await File(filePath).writeAsBytes(bytes);
        _log('[FlowImage] ✅ Saved from base64: ${path.basename(filePath)}');
        return filePath;
      } catch (e) {
        _log('[FlowImage] ⚠️ Base64 save failed: $e');
      }
    }

    return null;
  }

  /// Send a CORS preflight OPTIONS request (mimics browser behavior).
  static Future<void> cors_preflight(String url) async {
    try {
      final uri = Uri.parse(url);
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 8);
      final request = await client.openUrl('OPTIONS', uri);
      request.headers.set('accept', '*/*');
      request.headers.set('access-control-request-headers', 'authorization');
      request.headers.set('access-control-request-method', 'POST');
      request.headers.set('origin', 'https://labs.google');
      request.headers.set('referer', 'https://labs.google/');
      request.headers.set('sec-fetch-dest', 'empty');
      request.headers.set('sec-fetch-mode', 'cors');
      request.headers.set('sec-fetch-site', 'cross-site');
      final response = await request.close().timeout(const Duration(seconds: 8));
      await response.drain();
      client.close(force: false);
    } catch (_) {
      // Preflight failure is non-fatal
    }
  }
}


// ═══════════════════════════════════════════════════════════════════
// Data Classes
// ═══════════════════════════════════════════════════════════════════

class FlowImageResult {
  final bool success;
  final List<FlowGeneratedImage> images;
  final String? error;
  final String? workflowName;
  final String? batchId;
  final int? statusCode;

  /// Convenience getter: first image or null.
  FlowGeneratedImage? get image => images.isNotEmpty ? images.first : null;

  FlowImageResult({
    required this.success,
    required this.images,
    this.error,
    this.workflowName,
    this.batchId,
    this.statusCode,
  });
}

class FlowGeneratedImage {
  final String? name;
  final dynamic seed;
  final String? mediaGenerationId;
  final String? fifeUrl;
  final String? encodedImage;
  final String? prompt;
  final String? modelName;
  final String? aspectRatio;
  final dynamic width;
  final dynamic height;
  final String? workflowId;

  FlowGeneratedImage({
    this.name,
    this.seed,
    this.mediaGenerationId,
    this.fifeUrl,
    this.encodedImage,
    this.prompt,
    this.modelName,
    this.aspectRatio,
    this.width,
    this.height,
    this.workflowId,
  });

  /// Download image bytes from fifeUrl, or decode from base64.
  Future<Uint8List?> getImageBytes() async {
    // Try fifeUrl first
    if (fifeUrl != null && fifeUrl!.isNotEmpty) {
      try {
        final response = await HttpClient()
          .getUrl(Uri.parse(fifeUrl!))
          .then((req) => req.close())
          .timeout(const Duration(seconds: 30));
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
        }
        if (bytes.isNotEmpty) return Uint8List.fromList(bytes);
      } catch (_) {}
    }
    // Try base64 encoded image
    if (encodedImage != null && encodedImage!.isNotEmpty) {
      try {
        return base64Decode(encodedImage!);
      } catch (_) {}
    }
    return null;
  }
}
