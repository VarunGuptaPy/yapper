/// Pulls the actual name out of a `person` note's title.
///
/// Titles are written by the structuring model to describe who someone is —
/// "Parvesh Rawal - AI expert, potential co-founder/CTO" — but Sarvam's
/// keyterms are meant to be short proper nouns. Feeding it whole descriptive
/// phrases makes the decoder emit them verbatim, and biases it hard enough
/// that an unfamiliar name gets snapped onto an existing one. Only the name
/// belongs in a keyterm.
String? extractPersonName(String title) {
  final flat = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return null;

  // Anything from the first separator onwards is description, not name.
  final head = flat.split(_descriptionStart).first.trim();
  if (head.isEmpty) return null;

  // Keep the leading run of capitalised words: that is the name, and it stops
  // at the first ordinary word ("Ritu Sharma from college" -> "Ritu Sharma").
  final words = head.split(' ');
  final name = <String>[];
  for (final word in words) {
    if (name.length == _maxWords) break;
    if (!_startsCapitalised(word)) break;
    name.add(word);
  }

  if (name.isEmpty) return null;
  final result = name.join(' ');
  return result.length > 64 ? result.substring(0, 64).trim() : result;
}

/// A name is rarely more than this, and every extra word is extra bias.
const _maxWords = 4;

/// Punctuation that introduces a description rather than continuing a name.
final _descriptionStart = RegExp(r'[-–—:,;(/|]');

bool _startsCapitalised(String word) {
  for (final rune in word.runes) {
    final char = String.fromCharCode(rune);
    // Skip leading punctuation such as a quote.
    if (!_letter.hasMatch(char)) continue;

    final upper = char.toUpperCase();
    final lower = char.toLowerCase();
    // Devanagari and other caseless scripts have no capitals to test for, and
    // a name written in one must not be thrown away for failing a Latin rule.
    if (upper == lower) return true;
    return char == upper;
  }
  return false;
}

final _letter = RegExp(r'\p{L}', unicode: true);
