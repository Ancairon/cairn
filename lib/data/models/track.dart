class Track {
  final int? id;
  final String albumMbid;
  final String? recordingMbid;
  final int? position;
  final String title;
  final int? durationMs;

  Track({
    this.id,
    required this.albumMbid,
    this.recordingMbid,
    this.position,
    required this.title,
    this.durationMs,
  });
}
