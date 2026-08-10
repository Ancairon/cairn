import 'dart:convert';

/// How a saved filter narrows the rated-albums list. All set fields are
/// combined with AND — e.g. ownership=either + minRating=4 means "owned on
/// CD or vinyl, and rated 4 or 5".
class FilterCriteria {
  /// null = no ownership requirement. Otherwise one of: cd, vinyl, either, both.
  final String? ownership;
  final int? minRating;
  final int? maxRating;

  const FilterCriteria({this.ownership, this.minRating, this.maxRating});

  Map<String, dynamic> toJson() => {
        'ownership': ownership,
        'minRating': minRating,
        'maxRating': maxRating,
      };

  factory FilterCriteria.fromJson(Map<String, dynamic> json) => FilterCriteria(
        ownership: json['ownership'] as String?,
        minRating: json['minRating'] as int?,
        maxRating: json['maxRating'] as int?,
      );

  /// The SQL WHERE fragment (joined with existing ratings/albums columns)
  /// and its bound parameters, in the order the '?' placeholders appear.
  (String, List<Object?>) toSqlWhere() {
    final clauses = <String>[];
    final params = <Object?>[];

    switch (ownership) {
      case 'cd':
        clauses.add('albums.owns_cd = 1');
      case 'vinyl':
        clauses.add('albums.owns_vinyl = 1');
      case 'either':
        clauses.add('(albums.owns_cd = 1 OR albums.owns_vinyl = 1)');
      case 'both':
        clauses.add('(albums.owns_cd = 1 AND albums.owns_vinyl = 1)');
    }
    if (minRating != null) {
      clauses.add('ratings.stars >= ?');
      params.add(minRating);
    }
    if (maxRating != null) {
      clauses.add('ratings.stars <= ?');
      params.add(maxRating);
    }

    return (clauses.isEmpty ? '1=1' : clauses.join(' AND '), params);
  }
}

class SavedFilter {
  final int? id;
  final String name;
  final FilterCriteria criteria;

  const SavedFilter({this.id, required this.name, required this.criteria});

  String encodeCriteria() => jsonEncode(criteria.toJson());

  static FilterCriteria decodeCriteria(String json) =>
      FilterCriteria.fromJson(jsonDecode(json) as Map<String, dynamic>);
}
