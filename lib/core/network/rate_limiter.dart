/// Throttles calls to at most one per [interval]. MusicBrainz's usage policy
/// requires staying at or under 1 request/second.
class RateLimiter {
  final Duration interval;
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);

  RateLimiter(this.interval);

  Future<void> wait() async {
    final elapsed = DateTime.now().difference(_lastCall);
    if (elapsed < interval) {
      await Future.delayed(interval - elapsed);
    }
    _lastCall = DateTime.now();
  }
}
