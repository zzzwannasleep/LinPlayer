import 'package:flutter/foundation.dart';

import 'app_feature_flags.dart';
import 'app_product.dart';

@immutable
class AppConfig {
  const AppConfig({
    required this.product,
    required this.githubOwner,
    required this.githubRepo,
    required this.features,
    required this.emosBaseUrl,
  });

  final AppProduct product;
  final String githubOwner;
  final String githubRepo;
  final AppFeatureFlags features;
  final String emosBaseUrl;

  String get displayName => product.displayName;

  String get repoUrl => 'https://github.com/$githubOwner/$githubRepo';

  String get userAgentProduct => displayName;

  static const String _envProduct =
      String.fromEnvironment('APP_PRODUCT', defaultValue: 'lin');
  static const String _envGitHubOwner =
      String.fromEnvironment('APP_GITHUB_OWNER', defaultValue: 'zzzwannasleep');
  static const String _envGitHubRepo =
      String.fromEnvironment('APP_GITHUB_REPO', defaultValue: 'LinPlayer');
  static const String _envEmosBaseUrl = String.fromEnvironment(
    'APP_EMOS_BASE_URL',
    defaultValue: 'https://emos.best',
  );

  static AppConfig fromEnvironment() {
    final product = appProductFromId(_envProduct);
    final features = AppFeatureFlags.forProduct(product);
    final owner = _envGitHubOwner.trim().isEmpty
        ? 'zzzwannasleep'
        : _envGitHubOwner.trim();
    final repo =
        _envGitHubRepo.trim().isEmpty ? 'LinPlayer' : _envGitHubRepo.trim();
    final emosBaseUrl =
        _envEmosBaseUrl.trim().isEmpty ? 'https://emos.best' : _envEmosBaseUrl.trim();
    return AppConfig(
      product: product,
      githubOwner: owner,
      githubRepo: repo,
      features: features,
      emosBaseUrl: emosBaseUrl,
    );
  }

  static final AppConfig current = AppConfig.fromEnvironment();

  @override
  bool operator ==(Object other) {
    return other is AppConfig &&
        other.product == product &&
        other.githubOwner == githubOwner &&
        other.githubRepo == githubRepo &&
        other.features == features &&
        other.emosBaseUrl == emosBaseUrl;
  }

  @override
  int get hashCode =>
      Object.hash(product, githubOwner, githubRepo, features, emosBaseUrl);
}
