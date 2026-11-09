// Automatic tags from file names.
//
// Rules (as specified by the owner):
//  * The name (without extension) is split at spaces.
//  * A name with no spaces at all (e.g. "PXL_20261106_120300.mp4" or
//    "Beach.jpg") gives no tags: a word only counts when a space separates it
//    from the rest of the name.
//  * Any word containing a digit or an underscore is ignored
//    ("2024", "IMG_1234", "4K", "PXL_2026110612030045").
//  * Brackets and punctuation at the ends of a word are removed, and
//    duplicates (ignoring upper/lower case) are skipped.
//
//   "Beach trip with Sam 2024 (2).mp4"  ->  Beach, trip, with, Sam

final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _digitOrUnderscore = RegExp(r'[\p{Nd}_]', unicode: true);
final RegExp _edgePunctuation =
    RegExp(r'^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$', unicode: true);

/// Returns the tag words for [fileName], in order, without duplicates.
List<String> tagWordsFromFileName(String fileName) {
  var base = fileName;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  final words =
      base.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.length < 2) return const [];
  final out = <String>[];
  final seen = <String>{};
  for (final raw in words) {
    if (_digitOrUnderscore.hasMatch(raw)) continue;
    final word = raw.replaceAll(_edgePunctuation, '');
    if (word.isEmpty || !_letter.hasMatch(word)) continue;
    if (seen.add(word.toLowerCase())) out.add(word);
  }
  return out;
}

/// True if [tagName] could never be produced by the current rules
/// (it contains a digit or an underscore).
bool isInvalidAutoTagName(String tagName) =>
    _digitOrUnderscore.hasMatch(tagName);
