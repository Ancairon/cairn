import 'dart:convert';
import 'package:http/http.dart' as http;

// MusicBrainz's usage policy asks for a descriptive User-Agent with contact
// info. Update this once the project has a public repo URL or contact email.
const userAgent = 'cairn/0.1.0 (local development build)';

class HttpException implements Exception {
  final String message;
  HttpException(this.message);

  @override
  String toString() => 'HttpException: $message';
}

/// Thin wrapper over package:http adding the shared User-Agent and JSON
/// decoding every remote client needs.
class ApiHttpClient {
  final http.Client _client;

  ApiHttpClient([http.Client? client]) : _client = client ?? http.Client();

  // MusicBrainz (and occasionally other sources) return 503 under load —
  // documented, expected behavior, not a fatal error. A couple of short
  // retries clears almost all of these without complicating every caller.
  static const _retryableStatusCodes = {503, 429};
  static const _maxAttempts = 3;

  Future<dynamic> getRaw(Uri url, {Map<String, String>? headers}) async {
    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      final response = await _client.get(url, headers: {'User-Agent': userAgent, ...?headers});
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      if (!_retryableStatusCodes.contains(response.statusCode) || attempt == _maxAttempts) {
        throw HttpException('${response.statusCode} for $url');
      }
      await Future.delayed(Duration(milliseconds: 500 * attempt));
    }
    throw StateError('unreachable');
  }

  Future<Map<String, dynamic>> getJson(Uri url, {Map<String, String>? headers}) async {
    return await getRaw(url, headers: headers) as Map<String, dynamic>;
  }

  void close() => _client.close();
}
