// Automatic tags from file names.
//
// When a file is added, every space-separated word of its name (without the
// extension) becomes a tag. Words that are only numbers are ignored, and
// brackets/punctuation stuck to the ends of a word are removed.
//
//   "Beach trip with Sam 2024 (2).mp4"  ->  Beach, trip, with, Sam

final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _edgePunctuation =
    RegExp(r'^[\s\p{P}\p{S}]+|[\s\p{P}\p{S}]+$', unicode: true);

/// Returns the tag words for [fileName], in order, without duplicates
/// (duplicates compared ignoring upper/lower case).
List<String> tagWordsFromFileName(String fileName) {
  var base = fileName;
  final dot = base.lastIndexOf('.');
  if (dot > 0) base = base.substring(0, dot);
  final out = <String>[];
  final seen = <String>{};
  for (final raw in base.split(RegExp(r'\s+'))) {
    final word = raw.replaceAll(_edgePunctuation, '');
    if (word.isEmpty) continue;
    // Ignore numbers: a word needs at least one letter.
    if (!_letter.hasMatch(word)) continue;
    if (seen.add(word.toLowerCase())) out.add(word);
  }
  return out;
}
