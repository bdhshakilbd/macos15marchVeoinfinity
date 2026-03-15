/// Entity types for scene consistency
enum EntityType {
  location,      // Outdoor scenes, backgrounds, environments
  interior,      // Indoor scenes, rooms, buildings inside
  object,        // Props, items, vehicles
  damaged,       // Damaged or destroyed versions of objects/locations
  building,      // Buildings, houses, structures
  environment,   // Weather, lighting conditions, time of day
}

/// Model for entity data in Character Studio (locations, objects, etc.)
class EntityData {
  String id;
  String name;
  String description;
  EntityType type;
  List<String> images;
  Map<String, String> variants; // For damaged/alternate versions
  bool isGenerating = false; // Transient UI state
  
  /// Whisk/Google API mediaGenerationId — stored so we don't re-upload
  String? whiskMediaId;
  /// Caption from Whisk API captioning
  String? whiskCaption;
  /// Upload error message (transient, for UI display)
  String? uploadError;

  EntityData({
    required this.id,
    required this.name,
    this.description = '',
    this.type = EntityType.location,
    this.images = const [],
    this.variants = const {},
    this.isGenerating = false,
    this.whiskMediaId,
    this.whiskCaption,
  });

  factory EntityData.fromJson(Map<String, dynamic> json) {
    EntityType parseType(String? typeStr) {
      switch (typeStr?.toLowerCase()) {
        case 'location':
          return EntityType.location;
        case 'interior':
          return EntityType.interior;
        case 'object':
          return EntityType.object;
        case 'damaged':
          return EntityType.damaged;
        case 'building':
          return EntityType.building;
        case 'environment':
          return EntityType.environment;
        default:
          return EntityType.location;
      }
    }

    return EntityData(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String? ?? json['visual_description'] as String? ?? '',
      type: parseType(json['type'] as String?),
      images: (json['images'] as List<dynamic>?)?.cast<String>() ?? [],
      variants: (json['variants'] as Map<String, dynamic>?)?.cast<String, String>() ?? {},
      whiskMediaId: json['whisk_media_id'] as String?,
      whiskCaption: json['whisk_caption'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'type': type.name,
    'images': images,
    'variants': variants,
    if (whiskMediaId != null) 'whisk_media_id': whiskMediaId,
    if (whiskCaption != null) 'whisk_caption': whiskCaption,
  };
  
  /// Whether this entity has a stored Whisk ref ID (skip upload)
  bool get hasWhiskRef => whiskMediaId != null && whiskMediaId!.isNotEmpty;

  String get typeLabel {
    switch (type) {
      case EntityType.location:
        return '🌍 Location';
      case EntityType.interior:
        return '🏠 Interior';
      case EntityType.object:
        return '📦 Object';
      case EntityType.damaged:
        return '💥 Damaged';
      case EntityType.building:
        return '🏢 Building';
      case EntityType.environment:
        return '🌤️ Environment';
    }
  }
}
