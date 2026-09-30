import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:void_factor/features/projection/model_artifact.dart';
import 'package:void_factor/features/projection/model_download_link.dart';

const fixture = ModelArtifact(
  version: 'gemma-fixture-v1',
  filename: 'fixture.litertlm',
  sourceRepository: 'test/model',
  sourceRevision: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  sizeBytes: 3,
  sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  termsVersion: '2026-04-01',
);

Map<String, Object> descriptor() => {
  'version': fixture.version,
  'filename': fixture.filename,
  'source_repository': fixture.sourceRepository,
  'source_revision': fixture.sourceRevision,
  'size_bytes': fixture.sizeBytes,
  'sha256': fixture.sha256,
  'terms_version': fixture.termsVersion,
};

void main() {
  test(
    'sends matching identity and accepted terms, validates descriptor',
    () async {
      final client = ModelDownloadLinkClient(
        baseUrl: 'https://api.example.test',
        caller: () async => (uid: 'u1', idToken: 'token'),
        client: MockClient((request) async {
          expect(request.url.path, '/api/v1/models/gemma/download-link');
          expect(request.headers['authorization'], 'Bearer token');
          expect(request.headers['x-user-id'], 'u1');
          expect(jsonDecode(request.body), {
            'accepted_terms_version': fixture.termsVersion,
          });
          return http.Response(
            jsonEncode({
              'url': 'https://models.example.test/fixture?signature=secret',
              'expires_at': '2099-01-01T00:00:00Z',
              'model': descriptor(),
            }),
            200,
          );
        }),
      );
      final issued = await client.request(fixture);
      expect(issued.uid, 'u1');
      expect(issued.link.url.host, 'models.example.test');
    },
  );

  test('rejects a server descriptor with a different digest', () async {
    final changed = descriptor()..['sha256'] = '0' * 64;
    final client = ModelDownloadLinkClient(
      baseUrl: 'https://api.example.test',
      caller: () async => (uid: 'u1', idToken: 'token'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'url': 'https://models.example.test/fixture?signature=secret',
            'expires_at': '2099-01-01T00:00:00Z',
            'model': changed,
          }),
          200,
        ),
      ),
    );
    await expectLater(
      client.request(fixture),
      throwsA(isA<ModelDownloadException>()),
    );
  });

  test('rejects expired and non-HTTPS URLs', () async {
    for (final url in [
      'http://models.example.test/fixture',
      'https://models.example.test/fixture',
    ]) {
      final client = ModelDownloadLinkClient(
        baseUrl: 'https://api.example.test',
        caller: () async => (uid: 'u1', idToken: 'token'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'url': url,
              'expires_at': url.startsWith('http:')
                  ? '2099-01-01T00:00:00Z'
                  : '2000-01-01T00:00:00Z',
              'model': descriptor(),
            }),
            200,
          ),
        ),
      );
      await expectLater(
        client.request(fixture),
        throwsA(isA<ModelDownloadException>()),
      );
    }
  });

  test('never includes a signed URL in errors', () async {
    final client = ModelDownloadLinkClient(
      baseUrl: 'https://api.example.test',
      caller: () async => (uid: 'u1', idToken: 'token'),
      client: MockClient((_) async => http.Response('secret-url', 503)),
    );
    try {
      await client.request(fixture);
      fail('Expected failure');
    } on ModelDownloadException catch (e) {
      expect(e.message, isNot(contains('secret')));
    }
  });
}
