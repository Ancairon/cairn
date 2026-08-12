import 'dart:convert';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:cairn/core/network/http_client.dart';
import 'package:cairn/data/repositories/update_check_repository.dart';

void main() {
  group('isNewerVersion', () {
    test('true when the latest version is numerically greater', () {
      expect(isNewerVersion('0.2.0', '0.1.76'), isTrue);
      expect(isNewerVersion('0.1.77', '0.1.76'), isTrue);
      expect(isNewerVersion('1.0.0', '0.9.9'), isTrue);
    });

    test('false when equal or the latest is not actually newer', () {
      expect(isNewerVersion('0.1.76', '0.1.76'), isFalse);
      expect(isNewerVersion('0.1.0', '0.1.76'), isFalse);
    });

    test('compares patch numerically, not lexicographically', () {
      // A plain string compare would rank '0.1.9' above '0.1.10'.
      expect(isNewerVersion('0.1.10', '0.1.9'), isTrue);
    });

    test('treats a missing/non-numeric segment as 0 rather than throwing',
        () {
      expect(isNewerVersion('0.2', '0.1.76'), isTrue);
      expect(isNewerVersion('not-a-version', '0.1.76'), isFalse);
    });
  });

  group('UpdateCheckRepository.latestVersion', () {
    test('strips a leading v from the release tag', () async {
      final httpClient = ApiHttpClient(MockClient((request) async {
        expect(request.url.toString(), UpdateCheckRepository.releasesApiUrl);
        return http.Response(jsonEncode({'tag_name': 'v0.2.0'}), 200);
      }));
      final repo = UpdateCheckRepository(httpClient);
      expect(await repo.latestVersion(), '0.2.0');
    });

    test('returns null on a network/HTTP failure rather than throwing',
        () async {
      final httpClient =
          ApiHttpClient(MockClient((request) async => http.Response('', 500)));
      final repo = UpdateCheckRepository(httpClient);
      expect(await repo.latestVersion(), isNull);
    });

    test('returns null when the response has no tag_name', () async {
      final httpClient = ApiHttpClient(
          MockClient((request) async => http.Response(jsonEncode({}), 200)));
      final repo = UpdateCheckRepository(httpClient);
      expect(await repo.latestVersion(), isNull);
    });
  });
}
