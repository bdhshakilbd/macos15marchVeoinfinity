import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../gemini_key_service.dart';
import '../../models/story/story_audio_part.dart';
import '../../models/story/story_audio_state.dart'; // Added for ReelTemplate
import '../../models/story/alignment_item.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class GeminiAlignmentService {
  List<String> _apiKeys = [];
  int _currentKeyIndex = 0;

  /// Get the number of loaded API keys (for concurrent processing)
  int get apiKeyCount => _apiKeys.length;

  /// Load API keys from gemini_api_keys.txt
  Future<void> loadApiKeys() async {
    try {
      File keysFile;
      if (Platform.isAndroid) {
        final dir = Directory('/storage/emulated/0/veo3');
        keysFile = File(path.join(dir.path, 'gemini_api_keys.txt'));
      } else if (Platform.isIOS) {
        final dir = await getApplicationDocumentsDirectory();
        keysFile = File(path.join(dir.path, 'gemini_api_keys.txt'));
      } else {
        final exePath = Platform.resolvedExecutable;
        final exeDir = File(exePath).parent.path;
        keysFile = File(path.join(exeDir, 'gemini_api_keys.txt'));
      }

      if (!await keysFile.exists()) {
        final global = await GeminiKeyService.loadKeys();
        if (global.isNotEmpty) {
          _apiKeys = global.where((k) => k.trim().isNotEmpty).toList();
          print('[ALIGNMENT] Loaded ${_apiKeys.length} API keys from GeminiKeyService (global)');
        } else {
          throw Exception('gemini_api_keys.txt not found at: ${keysFile.path}');
        }
      } else {
        final content = await keysFile.readAsString();
        _apiKeys = content
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty && !line.startsWith('#'))
            .toList();

        if (_apiKeys.isEmpty) {
          final global = await GeminiKeyService.loadKeys();
          if (global.isNotEmpty) {
            _apiKeys = global.where((k) => k.trim().isNotEmpty).toList();
            print('[ALIGNMENT] Loaded ${_apiKeys.length} API keys from GeminiKeyService (global)');
          } else {
            throw Exception('No API keys found in gemini_api_keys.txt');
          }
        } else {
          print('[ALIGNMENT] Loaded ${_apiKeys.length} API keys');
        }
      }
    } catch (e) {
      throw Exception('Failed to load API keys: $e');
    }
  }

  /// Get current API key (with rotation)
  String _getCurrentApiKey() {
    if (_apiKeys.isEmpty) {
      throw Exception('No API keys loaded');
    }
    final key = _apiKeys[_currentKeyIndex];
    _currentKeyIndex = (_currentKeyIndex + 1) % _apiKeys.length;
    return key;
  }

  /// Generate alignment JSON using Gemini AI
  Future<List<AlignmentItem>> generateAlignment({
    required List<StoryAudioPart> storyParts,
    required String videoPromptsRaw,
    required String model,
  }) async {
    try {
      print('[ALIGNMENT] Generating alignment with model: $model');
      
      final apiKey = _getCurrentApiKey();
      final url = Uri.parse(
        'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
      );

      // Build story parts JSON
      final storyPartsJson = storyParts.map((part) => {
        'part_index': part.index,
        'text': part.text,
      }).toList();

      // System prompt
      final systemPrompt = '''You are an expert video editor and synchronization specialist. 
TASK: Given a list of story narration "parts" (audio segments) and a raw "Action Prompts" input (which contains visual scene descriptions), create a precise alignment JSON mapping each story part to the most relevant visual clip(s).

The "Action Prompts" input might be a block of plain text or a structured JSON object containing a list of scenes. 
Your first task is to IDENTIFY all the distinct visual scenes/prompts within that input. 
Then, map each "audio_part_index" to the corresponding scene(s).

**MAPPING RULES:**
1. **FULL COVERAGE**: EVERY single "audio_part_index" from the input MUST be present in the output array. Do NOT skip any parts.
2. **SMART EXTRACTION**: If the input is a JSON object with a "scenes" or "visuals" list, use those specific scenes. If it's plain text, treat each logical scene description as a target.
3. **SEMANTIC MATCHING**: Match the narration text with the visual action. Identify characters, actions (movement, expressions, gestures), and environment.
4. **SEQUENCE AWARENESS**: Alignment typically follows chronological order. Part 1 -> Scene 1, Part 2 -> Scene 2, etc.
5. **MULTIPLE VIDEOS**: Assign a LIST of relevant scenes to each audio part if the narration covers multiple visual beats.
6. **IDENTIFIERS**: In the "matching_videos" list, identify each video by a logical ID (e.g., "prompt1video", "prompt2video") based on its order in the input.

**OUTPUT STRUCTURE (STRICT JSON ARRAY):**
[
  {
    "audio_part_index": 1,
    "text": "Exact text from the audio part...",
    "matching_videos": [
      {"id": "prompt1video"}
    ]
  }
]

Verify your mapping. Ensure that if a specific action (like "pouring water") is mentioned in an audio part, it is aligned with the scene describing that specific action.''';

      // User prompt
      final userPrompt = '''Please create alignment for:

STORY PARTS (Narration):
${jsonEncode(storyPartsJson)}

ACTION PROMPTS (Visual Script/Scenes):
$videoPromptsRaw

Return ONLY the JSON array, no explanation.''';

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {'text': '$systemPrompt\n\n$userPrompt'}
              ]
            }
          ],
          'generationConfig': {
            'temperature': 0.7,
            'topK': 40,
            'topP': 0.95,
            'maxOutputTokens': 8192,
          },
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        // Robust extraction with null safety
        final candidates = data['candidates'] as List?;
        if (candidates == null || candidates.isEmpty) {
          print('[ALIGNMENT] API returned 200 but no candidates. Body: ${response.body}');
          throw Exception('Gemini returned no response candidates. Possible safety block?');
        }

        final firstCandidate = candidates[0] as Map<String, dynamic>;
        final content = firstCandidate['content'] as Map<String, dynamic>?;
        
        if (content == null) {
          final finishReason = firstCandidate['finishReason'];
          print('[ALIGNMENT] Candidate has no content. FinishReason: $finishReason. Body: ${response.body}');
          throw Exception('Gemini returned no content. Reason: $finishReason');
        }

        final parts = content['parts'] as List?;
        if (parts == null || parts.isEmpty) {
          throw Exception('Gemini returned content but no parts.');
        }

        var responseText = parts[0]['text'] as String? ?? '';
        if (responseText.isEmpty) {
          throw Exception('Gemini returned an empty text response.');
        }
        
        // Remove markdown code blocks if present
        responseText = responseText.replaceAll(RegExp(r'```json\s*', multiLine: true), '');
        responseText = responseText.replaceAll(RegExp(r'```\s*', multiLine: true), '');
        responseText = responseText.trim();
        
        try {
          // Parse JSON
          final alignmentData = jsonDecode(responseText) as List;
          
          // Convert to AlignmentItem objects
          final alignmentItems = alignmentData
              .map((item) => AlignmentItem.fromJson(item as Map<String, dynamic>))
              .toList();
          
          print('[ALIGNMENT] ✓ Generated ${alignmentItems.length} alignment items');
          return alignmentItems;
        } catch (e) {
          print('[ALIGNMENT] JSON Parse Error: $e. Raw response start: ${responseText.substring(0, min(100, responseText.length))}');
          throw Exception('Failed to parse alignment JSON: $e');
        }
      } else {
        final errorBody = response.body;
        print('[ALIGNMENT] API Error ${response.statusCode}: $errorBody');
        throw Exception('API returned ${response.statusCode}: $errorBody');
      }
    } catch (e) {
      print('[ALIGNMENT] Error: $e');
      rethrow;
    }
  }

  /// Generate Batch Reel Content (Multiple Variations in one go)
  Future<List<Map<String, dynamic>>> generateBatchReelContent({
    required String topic,
    required String characterType,
    required String model,
    required String language,
    required int count,
    int scenesPerStory = 12, // Number of visual scenes per story
    ReelTemplate? template,
    bool voiceCueEnabled = true, // If true, AI generates voice_cue for each visual
    String voiceCueLanguage = 'English', // Language for voice cues
    bool narrationEnabled = true, // If false, no central narration text is generated
  }) async {
    try {
      print('[REEL] Generating batch of $count reels. Scenes/Story: $scenesPerStory. Lang: $language. VoiceCueLang: $voiceCueLanguage. Template: ${template?.name ?? "Default"}. VoiceCue: $voiceCueEnabled, Narration: $narrationEnabled');
      
      // API key selected in retry loop below

      String systemPrompt;
      
      if (template != null) {
         // Use the Custom Template
         // We need to ensure the template prompt still respects the JSON format requirement,
         // so we might append the FORMAT instructions if the template doesn't include them,
         // but ideally the "Analysis" phase should've baked them in.
         // For safety, we will append the JSON FORMAT + Language rules to the end if not clearly present.
         
         systemPrompt = template.systemPrompt;
         
         // Inject specific instructions to ensure connectivity
         systemPrompt += '''
         
         IMPORTANT OVERRIDES:
         1. **CRITICAL - LANGUAGE**: ALL 'text' fields MUST be written ENTIRELY in $language language. Do NOT write narration/dialogue in English if the language is $language. The spoken content must be in $language.
         ${narrationEnabled ? "2. INSTRUCTION: Generate $count UNIQUE variations. Use the topic \"$topic\" and character main type \"$characterType\" as the core subject/theme." : "2. NARRATION IS OFF: The 'text' field MUST be an empty string \\\"\\\". Generate 0 words of narration. Focus entirely on video prompts. Generate $count UNIQUE variations for Topic: \"$topic\" and Character: \"$characterType\"."}
         3. ADAPTATION: You MUST ADAPT the user's topic/character to FIT the specific Plot Structure and Visual Style defined in the System Prompt above. Do not ignore the System Prompt's structural rules.
         4. OUTPUT FORMAT: STRICT JSON as defined.
         5. PROMPTS: Keep visual/scene description parts of 'prompt', 'art_style', 'character_description' in English. EXCEPTION: any quoted character dialogue or spoken text inside the prompt MUST be in $voiceCueLanguage (see rule 6).
         ${voiceCueEnabled ? "6. **CRITICAL - VEO3 AUDIO LANGUAGE**: Both 'voice_cue' AND any dialogue embedded inside 'prompt' MUST be in $voiceCueLanguage ONLY. Override any language baked into this template. Veo3 reads the prompt to generate audio — the dialogue text quoted inside the prompt determines the spoken language. Format: \"...[visual description in English], character shouts in $voiceCueLanguage: '[dialogue in $voiceCueLanguage]'\". Do NOT hardcode Bengali or any other language." : "6. VOICE CUE OFF: Set 'voice_cue' to null for ALL visuals. No dialogue or speech in prompts."}
         
         JSON FORMAT REMINDER:
         {
           "reels": [
             {
               "title": "...",
               "content": [
                  { "text": "...", "visuals": [ { "scene_number": 1, "prompt": "[art_style], [character description], [visual in English], character speaks in $voiceCueLanguage: '[dialogue in $voiceCueLanguage]'", "active": true, ... } ] }
               ]
             }
           ]
         }
         ''';
         
      } else {
         // Default Hardcoded Prompt (Boy saves animals)
         systemPrompt = '''You are an expert Short Video Script Writer.
      
TASK: Generate $count UNIQUE variations of a story based on the user's TOPIC.
Each variation must follow the EXACT PLOT STRUCTURE below but use **COMPLETELY DIFFERENT** Animals, Transports, Methods, and Settings for each variation to ensure diversity.

**CRITICAL INSTRUCTION FOR VARIETY:**
- If the user's topic is specific (e.g., "Boy saves a crocodile"), use that for the FIRST variation only.
- For the other variations, **CHANGE THE ANIMAL AND SETTING**. (e.g., Girl & Tiger in Jungle, Robot & Alien in Space, Boy & Giant Turtle in Desert).
- The "Structure" (Rescue -> Growth -> Conflict -> Cloud Request) remains the same, but the "Ingredients" (Entities/Places) MUST change drastically.

REFERENCE PLOT (TEMPLATE):
1. Intro: Character brings [Unique Animal] from [Location] to [Home/Pool].
2. Growth: Feeds it, it grows huge.
3. Conflict: Naughty [Enemy] comes and drinks/removes water/resource.
4. Action: Character builds [Unique Vehicle] and flies/goes to Cloud.
5. Dialogue 1: "Give rain/help. My pet is suffering."
6. Dialogue 2 (Cloud): "If kids LIKE & SUBSCRIBE, I will."
7. Dialogue 3 (Character): "They will like & subscribe, give rain."
8. Resolution: Cloud gives rain, problem solved.

OUTPUT JSON FORMAT:
{
  "reels": [
    {
      "title": "A short, catchy title...",
      "content": [
         {
           "text": ${narrationEnabled ? '"Full sentence of narration or dialogue (Spoken words only)..."' : '""'},
           "visuals": [
              {
                "scene_number": 1,
                "art_style": "3D Animation, Pixar-style, 8k render, vibrant colors",
                "character_description": "FULL description of characters...",
                "visual": "Specific action description... character shouts in $voiceCueLanguage: '[dialogue in $voiceCueLanguage here]'",
                "bg_score": "Music mood...",
                "voice_cue": ${voiceCueEnabled ? '"[Dialogue in $voiceCueLanguage for this scene]"' : 'null'},
                "previous_prompts_for_context": ["Summary of prev scene..."],
                "prompt": "[art_style], [character_description], [visual description in English], character shouts in $voiceCueLanguage: '[exact dialogue in $voiceCueLanguage]'",
                "active": true
              }
           ]
         },
         ...
      ]
    },
    ...
  ]
}

${voiceCueEnabled ? 'VOICE CUE & VEO3 AUDIO RULES:\n- Each visual MUST have a voice_cue with character dialogue in $voiceCueLanguage\n- **CRITICAL FOR VEO3 AUDIO GENERATION**: The spoken dialogue MUST also be embedded directly inside the "prompt" field — Veo3 reads the prompt to generate the audio track, so the language of dialogue INSIDE the prompt determines the language of the generated voice\n- Prompt format for scenes with speech: "[art_style], [character_description], [visual action in English], character speaks in $voiceCueLanguage: \'[exact dialogue in $voiceCueLanguage]\'"\n- The visual/scene description parts of the prompt stay in English\n- The quoted dialogue text inside the prompt MUST be in $voiceCueLanguage — NOT Bengali or any other language unless that is the selected language\n- Do NOT hardcode dialogue in Bengali or any other language in prompts unless $voiceCueLanguage is that language' : 'AMBIENT MODE:\n- Set voice_cue to null for all visuals\n- Video should have nature sounds, ambient music, or silence only\n- No character speech in prompts'}

CHARACTER CONSISTENCY RULES:
1. Define Master Description(s) per variation.
2. Include this FULL description in 'character_description' AND 'prompt' for EVERY scene.
3. 'prompt' MUST be: art_style + ", " + character_description + ", " + visual_action (in English) + (if speech scene: ", character speaks in $voiceCueLanguage: '[dialogue in $voiceCueLanguage]'").

NARRATIVE STYLE & RULES:
1. **CRITICAL - LANGUAGE**: The 'text' fields MUST be written ENTIRELY in $language language. Do NOT use English for the narration text if $language is not English. All spoken dialogue and narration must be in $language.
${narrationEnabled ? "2. STYLE: Simple, direct, fairytale-like. Short sentences. (e.g. for English: \\\"One day a boy found a tiger. He fed it.\\\")\\n3. TEXT CONTENT: Spoken words only. NO labels. The text is what will be spoken aloud in $language." : "2. NARRATION IS OFF: Ensure 'text' is ALWAYS an empty string \\\"\\\" for all scenes."}
4. STRUCTURE: 5-7 meaningful audio segments matching the Reference Plot.
5. VISUALS: Generate EXACTLY $scenesPerStory scenes per reel.
6. PROMPTS: Keep visual/scene description parts of 'prompt' in English. EXCEPTION: quoted character dialogue embedded inside the prompt MUST be in $voiceCueLanguage — this is required for Veo3 to generate audio in the correct language.
''';
      }

      final userPrompt = 'Topic: $topic\nMain Character: $characterType\nCount: $count';

      // Multi-key retry loop: try up to 5 different API keys on 503/429
      final maxKeyRetries = min(5, _apiKeys.length);
      Exception? lastError;
      
      for (int attempt = 0; attempt < maxKeyRetries; attempt++) {
        final apiKey = _getCurrentApiKey();
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
        );

        print('[REEL] Sending request to $model... (key ${attempt + 1}/$maxKeyRetries)');
        
        http.Response response;
        try {
          response = await http.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'contents': [
                {
                   'parts': [
                     {'text': '$systemPrompt\n\n$userPrompt'}
                   ]
                }
              ],
              'generationConfig': {
                 'temperature': 0.9, 
                 'maxOutputTokens': 65536,
                 'responseMimeType': 'application/json',
              }
            }),
          ).timeout(const Duration(seconds: 60), onTimeout: () {
             throw Exception('Request timed out after 60 seconds.');
          });
        } catch (e) {
          print('[REEL] Key attempt ${attempt + 1} network/timeout error: $e');
          lastError = e is Exception ? e : Exception(e.toString());
          await Future.delayed(Duration(seconds: min(1 << attempt, 8)));
          continue;
        }

        print('[REEL] Response received. Status: ${response.statusCode}');
        
        // Rotate key on 503/429
        if (response.statusCode == 503 || response.statusCode == 429) {
          print('[REEL] Key ${attempt + 1} got ${response.statusCode} — rotating to next key...');
          lastError = Exception('API Error: ${response.statusCode} ${response.body}');
          final delaySec = min(1 << attempt, 8);
          print('[REEL] Backoff: ${delaySec}s before next key...');
          await Future.delayed(Duration(seconds: delaySec));
          continue;
        }
        
        if (response.statusCode == 200) {
          print('[REEL] Parsing response...');
          final data = jsonDecode(response.body);
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
             var text = candidates[0]['content']['parts'][0]['text'] as String;
             text = text.replaceAll(RegExp(r'^```json\s*', multiLine: true), '')
                        .replaceAll(RegExp(r'^```\s*', multiLine: true), '')
                        .replaceAll(RegExp(r'```\s*$', multiLine: true), '')
                        .trim();
             
             print('[REEL] Text length: ${text.length}. Sample: ${text.substring(0, min(100, text.length))}...');

             Map<String, dynamic>? json;
             try {
                json = jsonDecode(text) as Map<String, dynamic>;
             } catch (e) {
                print('[REEL] JSON Parse Error: $e. Attempting repair...');
                int openBraces = text.split('{').length - 1;
                int closeBraces = text.split('}').length - 1;
                int openBrackets = text.split('[').length - 1;
                int closeBrackets = text.split(']').length - 1;
                
                String repairedText = text;
                while (openBrackets > closeBrackets) { repairedText += ']'; closeBrackets++; }
                while (openBraces > closeBraces) { repairedText += '}'; closeBraces++; }
                
                try {
                  json = jsonDecode(repairedText) as Map<String, dynamic>;
                  print('[REEL] Repair successful.');
                } catch (e2) {
                   print('[REEL] Repair failed: $e2');
                   throw FormatException('JSON Parse failed: $e2\nText snippet: ${text.substring(max(0, text.length - 200))}');
                }
             }

             if (json != null && json.containsKey('reels')) {
                final reels = json['reels'] as List;
                return reels.map((r) => Map<String, dynamic>.from(r)).toList();
             }
          }
          throw Exception('No content or invalid format');
        } else {
          throw Exception('API Error: ${response.statusCode} ${response.body}');
        }
      }
      
      // All key attempts exhausted
      throw lastError ?? Exception('All $maxKeyRetries API keys failed with 503/429');
    } catch (e) {
      print('[REEL] Batch Error: $e');
      rethrow;
    }
  }


  /// Analyze a story/style and create a reusable template (System Prompt).
  Future<String> generateTemplateFromExample({
      required String model,
      String? exampleStory,
      String? additionalInstructions,
  }) async {
      try {
          final apiKey = _getCurrentApiKey();
          final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
          
          final analysisPrompt = '''
You are an expert Prompt Engineer for AI Video Generation Agents.
Your task is to analyze the provided EXAMPLE CONTENT and/or INSTRUCTION and create a strictly structured **SYSTEM PROMPT**.
This System Prompt will be used by another AI to generate *new* stories that follow the exact same style, pacing, and visual density as the example.

INPUTS:
Example Story/Script: "$exampleStory"
Specific Instructions: "$additionalInstructions"

REQUIREMENTS FOR THE GENERATED SYSTEM PROMPT:
1. It must instruct the AI to act as a Story Writer.
2. It must enforce the **JSON Output Format** required by the system:
   {
      "reels": [
         {
            "title": "...",
            "content": [
               {
                  "text": "Narration text...",
                  "visuals": [
                     {
                        "scene_number": 1,
                        "art_style": "...",
                        "character_description": "...",
                        "visual": "...",
                        "bg_score": "...",
                        "previous_prompts_for_context": [],
                        "prompt": "...",
                        "active": true
                     }
                  ]
               }
            ]
         }
      ]
   }
3. It must capture the "Plot Structure" of the example (if provided) and generalize it so it can be applied to new Topics.
4. It must capture the "Visual Style" requested.
5. It must include instructions to generate consistent Characters.

Return ONLY the raw text of the System Prompt you created. Do not include "Here is the prompt:".
''';
          
          final response = await http.post(
             url,
             headers: {'Content-Type': 'application/json'},
             body: jsonEncode({
                'contents': [{'parts': [{'text': analysisPrompt}]}],
                'generationConfig': {
                   'temperature': 0.7,
                   'responseMimeType': 'text/plain'
                }
             })
          );
          
          if (response.statusCode == 200) {
             final data = jsonDecode(response.body);
             final text = data['candidates'][0]['content']['parts'][0]['text'] as String;
             return text.trim();
          } else {
             throw Exception('Failed to analyze template. Status: ${response.statusCode}');
          }

      } catch (e) {
         print('[ALIGNMENT] Template Analysis Error: $e');
         rethrow;
      }
  }

  /// Analyze a YouTube video to create a template using direct API video analysis
  Future<String> generateTemplateFromYoutube({
     required String model,
     required String youtubeUrl,
     String? additionalInstructions,
  }) async {
     try {
        print('[ALIGNMENT] analyzing YouTube video via Gemini Video Understanding: $youtubeUrl using model: $model');
        
        final apiKey = _getCurrentApiKey();
        // Use a model capable of video understanding (e.g. gemini-1.5-pro or flash)
        // If the passed model is not capable, it might fail. The user snippet used "gemini-1.5-flash".
        final url = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
        
        final analysisPrompt = '''
You are an expert Prompt Engineer for AI Video Generation Agents.
Your task is to analyze the provided VIDEO and create a strictly structured **SYSTEM PROMPT**.
This System Prompt will be used by another AI to generate *new* stories that follow the exact same style, pacing, and visual density as the example video.

INPUTS:
Video: [Attached]
Specific Instructions: "$additionalInstructions"

REQUIREMENTS FOR THE GENERATED SYSTEM PROMPT:
1. It must instruct the AI to act as a Story Writer.
2. It must enforce the **JSON Output Format** required by the system:
   {
      "reels": [
         {
            "title": "...",
            "content": [
               {
                  "text": "Narration text...",
                  "visuals": [
                     {
                        "scene_number": 1,
                        "art_style": "...",
                        "character_description": "...",
                        "visual": "...",
                        "bg_score": "...",
                        "previous_prompts_for_context": [],
                        "prompt": "...",
                        "active": true
                     }
                  ]
               }
            ]
         }
      ]
   }
3. It must capture the "Plot Structure" of the video and generalize it so it can be applied to new Topics.
4. It must capture the "Visual Style" seen in the video.
5. It must include instructions to generate consistent Characters.

Return ONLY the raw text of the System Prompt you created.
''';

        final response = await http.post(
           url,
           headers: {'Content-Type': 'application/json'},
           body: jsonEncode({
              'contents': [
                {
                  'parts': [
                    {'text': analysisPrompt},
                    {
                      'file_data': {
                        'mime_type': 'video/mp4', // Assuming mp4 for general video handling
                        'file_uri': youtubeUrl
                      }
                    }
                  ]
                }
              ],
              'generationConfig': {
                 'temperature': 0.7,
                 'responseMimeType': 'text/plain'
              }
           })
        );
        
        if (response.statusCode == 200) {
           final data = jsonDecode(response.body);
           final candidates = data['candidates'] as List?;
           if (candidates != null && candidates.isNotEmpty) {
               final text = candidates[0]['content']['parts'][0]['text'] as String;
               return text.trim();
           }
           throw Exception('No analysis content returned');
        } else {
           print('[ALIGNMENT] API Error Body: ${response.body}');
           throw Exception('Failed to analyze video. API returned ${response.statusCode}: ${response.body}');
        }

     } catch (e) {
        print('[ALIGNMENT] YouTube Analysis Error: $e');
        rethrow;
     }
  }

  /// Generate voice style instruction based on story content
  Future<String> generateVoiceStyle({
     required String storyTitle,
     required List<String> storyTexts,
     required String language,
  }) async {
     try {
        print('[VOICE STYLE] Generating voice style for: $storyTitle');
        
        final apiKey = _getCurrentApiKey();
        final url = Uri.parse(
           'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$apiKey'
        );

        final storyContent = storyTexts.join('\n');
        
        final prompt = '''Analyze this short story/reel script and generate a TTS voice style instruction.

STORY TITLE: $storyTitle
LANGUAGE: $language

STORY CONTENT:
$storyContent

TASK: Create a SHORT, impactful voice style instruction for a TTS system.
The instruction should describe HOW to read this story to make it engaging.

REQUIREMENTS:
1. Maximum 2-3 short sentences
2. Focus on: tone, pace, emotion, energy level
3. Consider the story mood (funny, dramatic, exciting, heartwarming)
4. Make it specific to THIS story
5. Voice should captivate listeners in 40-50 second reel

OUTPUT ONLY THE VOICE STYLE INSTRUCTION:''';

        final response = await http.post(
           url,
           headers: {'Content-Type': 'application/json'},
           body: jsonEncode({
              'contents': [{'parts': [{'text': prompt}]}],
              'generationConfig': {
                 'temperature': 0.8,
                 'maxOutputTokens': 200,
                 'responseMimeType': 'text/plain'
              }
           })
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
           final data = jsonDecode(response.body);
           final candidates = data['candidates'] as List?;
           if (candidates != null && candidates.isNotEmpty) {
              final text = candidates[0]['content']['parts'][0]['text'] as String;
              print('[VOICE STYLE] Generated: ${text.trim()}');
              return text.trim();
           }
        }
        
        return 'Engaging and expressive storytelling with natural emotion';
     } catch (e) {
        print('[VOICE STYLE] Error: $e');
        return 'Engaging and expressive storytelling with natural emotion';
     }
  }
}
