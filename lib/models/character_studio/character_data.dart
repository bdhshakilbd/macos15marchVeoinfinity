/// Model for character data in Character Studio
class CharacterData {
  String id;
  String name;
  String description;
  List<String> keyPath;
  List<String> images;
  bool isGenerating = false; // Transient UI state
  
  /// Whisk/Google API mediaGenerationId — stored so we don't re-upload
  String? whiskMediaId;
  /// Caption from Whisk API captioning
  String? whiskCaption;
  /// Upload error message (transient, for UI display)
  String? uploadError;
  /// Whether to use auto-ref from base outfit (e.g. outfit_001) during generation
  /// Nullable so existing objects from before this field existed don't crash
  bool? _useAutoRef;
  bool get useAutoRef => _useAutoRef ?? true;
  set useAutoRef(bool val) => _useAutoRef = val;

  CharacterData({
    required this.id,
    required this.name,
    this.description = '',
    this.keyPath = const [],
    this.images = const [],
    this.isGenerating = false,
    this.whiskMediaId,
    this.whiskCaption,
    bool useAutoRef = true,
  }) : _useAutoRef = useAutoRef;

  factory CharacterData.fromJson(Map<String, dynamic> json) {
    return CharacterData(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? json['visual_description'] as String? ?? '',
      keyPath: (json['key_path'] as List<dynamic>?)?.cast<String>() ?? [],
      images: (json['images'] as List<dynamic>?)?.cast<String>() ?? [],
      whiskMediaId: json['whisk_media_id'] as String?,
      whiskCaption: json['whisk_caption'] as String?,
      useAutoRef: json['use_auto_ref'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'key_path': keyPath,
    'images': images,
    if (whiskMediaId != null) 'whisk_media_id': whiskMediaId,
    if (whiskCaption != null) 'whisk_caption': whiskCaption,
    'use_auto_ref': useAutoRef,
  };
  
  /// Whether this character has a stored Whisk ref ID (skip upload)
  bool get hasWhiskRef => whiskMediaId != null && whiskMediaId!.isNotEmpty;
}
