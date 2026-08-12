import '../../core/network/http_client.dart';

/// Checks GitHub Releases for a newer version than the one currently
/// running. This app has no in-app auto-update mechanism — installing a
/// newer APK is always a manual download from the Releases page; this only
/// tells the user one exists.
class UpdateCheckRepository {
  final ApiHttpClient http;

  static const releasesApiUrl =
      'https://api.github.com/repos/Ancairon/cairn/releases/latest';
  static const releasesPageUrl = 'https://github.com/Ancairon/cairn/releases';

  UpdateCheckRepository(this.http);

  /// The latest published release's version, with any leading 'v' stripped
  /// from the tag (e.g. tag `v0.2.0` -> `'0.2.0'`). Null if the check failed
  /// (network error, no releases yet, unexpected response shape) — treated
  /// as "nothing to report" rather than surfaced as an error to the user.
  Future<String?> latestVersion() async {
    try {
      final json = await http.getJson(Uri.parse(releasesApiUrl));
      final tag = json['tag_name'] as String?;
      if (tag == null) return null;
      return tag.startsWith('v') ? tag.substring(1) : tag;
    } catch (_) {
      return null;
    }
  }
}

/// True if [latest] is a newer 'major.minor.patch' version than [current].
/// Missing/non-numeric segments compare as 0 rather than throwing, so an
/// unexpected version string never crashes the check — it just compares as
/// equal/older instead.
bool isNewerVersion(String latest, String current) {
  final latestParts = _versionParts(latest);
  final currentParts = _versionParts(current);
  for (var i = 0; i < 3; i++) {
    if (latestParts[i] != currentParts[i]) {
      return latestParts[i] > currentParts[i];
    }
  }
  return false;
}

List<int> _versionParts(String version) {
  final parts = version.split('.');
  return List.generate(
      3, (i) => int.tryParse(i < parts.length ? parts[i] : '0') ?? 0);
}
