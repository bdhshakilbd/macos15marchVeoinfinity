/// Model for saved image model configurations
class ImageModelConfig {
  String name;
  String url;
  String modelType; // 'cdp', 'api', 'flow', or 'runway'
  String? apiModelId; // For API models: 'IMAGEN_3_5', 'GEM_PIX', 'GEM_PIX_2'
                      // For runway models: 'gen4', 'nano2', 'nanopro', 'gen4_ref'

  ImageModelConfig({
    required this.name,
    required this.url,
    this.modelType = 'cdp',
    this.apiModelId,
  });

  /// Returns true if this model requires AI Studio connection (CDP models)
  bool get requiresAIStudio => modelType == 'cdp';

  /// Returns true if this model uses Google Flow (flow models via CDP to labs.google)
  bool get requiresFlow => modelType == 'flow';

  /// Returns true if this model uses RunwayML API
  bool get requiresRunway => modelType == 'runway';

  /// Returns the provider category: 'google' or 'runway'
  String get provider => modelType == 'runway' ? 'runway' : 'google';

  factory ImageModelConfig.fromJson(Map<String, dynamic> json) {
    return ImageModelConfig(
      name: json['name'] as String? ?? 'Unknown',
      url: json['url'] as String? ?? '',
      modelType: json['modelType'] as String? ?? 'cdp',
      apiModelId: json['apiModelId'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'modelType': modelType,
    if (apiModelId != null) 'apiModelId': apiModelId,
  };
}
