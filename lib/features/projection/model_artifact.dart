import 'dart:convert';

import 'package:flutter/services.dart';

/// The exact artifact accepted by both the app and the download-link API.
/// The server must use the same JSON file; no response can silently switch
/// the model, size, digest, or terms accepted by the user.
class ModelArtifact {
  const ModelArtifact({
    required this.version,
    required this.filename,
    required this.sourceRepository,
    required this.sourceRevision,
    required this.sizeBytes,
    required this.sha256,
    required this.termsVersion,
  });

  final String version;
  final String filename;
  final String sourceRepository;
  final String sourceRevision;
  final int sizeBytes;
  final String sha256;
  final String termsVersion;

  static const assetPath = 'assets/models/gemma3_1b_q4.json';

  static Future<ModelArtifact> bundled() async => ModelArtifact.fromJson(
    jsonDecode(await rootBundle.loadString(assetPath)) as Map<String, dynamic>,
  );

  factory ModelArtifact.fromJson(Map<String, dynamic> json) {
    final artifact = ModelArtifact(
      version: json['version'] as String,
      filename: json['filename'] as String,
      sourceRepository: json['source_repository'] as String,
      sourceRevision: json['source_revision'] as String,
      sizeBytes: json['size_bytes'] as int,
      sha256: json['sha256'] as String,
      termsVersion: json['terms_version'] as String,
    );
    if (!RegExp(r'^[a-z0-9-]+$').hasMatch(artifact.version) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(artifact.sha256) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(artifact.sourceRevision) ||
        artifact.sizeBytes <= 0 ||
        !RegExp(r'^[A-Za-z0-9_.-]+\.litertlm$').hasMatch(artifact.filename) ||
        artifact.termsVersion.isEmpty) {
      throw const FormatException('Invalid model manifest');
    }
    return artifact;
  }

  bool matches(ModelArtifact other) =>
      version == other.version &&
      filename == other.filename &&
      sourceRepository == other.sourceRepository &&
      sourceRevision == other.sourceRevision &&
      sizeBytes == other.sizeBytes &&
      sha256 == other.sha256 &&
      termsVersion == other.termsVersion;

  Map<String, dynamic> toJson() => {
    'version': version,
    'filename': filename,
    'source_repository': sourceRepository,
    'source_revision': sourceRevision,
    'size_bytes': sizeBytes,
    'sha256': sha256,
    'terms_version': termsVersion,
  };
}
