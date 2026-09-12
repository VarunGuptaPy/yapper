import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/models/person_name.dart';

void main() {
  group('extractPersonName', () {
    test('leaves a plain name alone', () {
      expect(extractPersonName('Ritu Sharma'), 'Ritu Sharma');
      expect(extractPersonName('Shivank Tripathi'), 'Shivank Tripathi');
      expect(extractPersonName('Aakash'), 'Aakash');
    });

    // The titles that actually poisoned transcripts on device: Sarvam was
    // handed the whole descriptive title and emitted it verbatim.
    test('drops the description after a dash', () {
      expect(
        extractPersonName('Parvesh Rawal - AI expert'),
        'Parvesh Rawal',
      );
      expect(
        extractPersonName(
            'Parvesh Rawal - AI expert, potential co-founder/CTO'),
        'Parvesh Rawal',
      );
      expect(
        extractPersonName('Manas Mahendra - potential source for paying gigs'),
        'Manas Mahendra',
      );
    });

    test('handles the other separators a title might use', () {
      expect(extractPersonName('Ritu Sharma – video editor'), 'Ritu Sharma');
      expect(extractPersonName('Ritu Sharma — video editor'), 'Ritu Sharma');
      expect(extractPersonName('Ritu Sharma: video editor'), 'Ritu Sharma');
      expect(extractPersonName('Ritu Sharma, video editor'), 'Ritu Sharma');
      expect(extractPersonName('Ritu Sharma (video editor)'), 'Ritu Sharma');
      expect(extractPersonName('Ritu Sharma / editor'), 'Ritu Sharma');
      expect(extractPersonName('Ritu Sharma | editor'), 'Ritu Sharma');
    });

    test('stops at the first ordinary word', () {
      expect(
        extractPersonName('Ritu Sharma from the Goa wedding shoot'),
        'Ritu Sharma',
      );
      expect(extractPersonName('Archit Sethia who does admissions'),
          'Archit Sethia');
    });

    test('caps a run of capitals at four words', () {
      expect(
        extractPersonName('One Two Three Four Five Six'),
        'One Two Three Four',
      );
    });

    test('collapses stray whitespace', () {
      expect(extractPersonName('  Ritu   Sharma  '), 'Ritu Sharma');
      expect(extractPersonName('Ritu\nSharma - editor'), 'Ritu Sharma');
    });

    test('returns null when there is no name to find', () {
      expect(extractPersonName(''), isNull);
      expect(extractPersonName('   '), isNull);
      expect(extractPersonName('- just a dash'), isNull);
      expect(extractPersonName('someone from college'), isNull,
          reason: 'a lowercase description is not a name');
    });

    test('never emits a separator, which Sarvam rejects outright', () {
      const titles = [
        'Parvesh Rawal - AI expert, potential co-founder/CTO',
        'Archit Sethia, Unirely',
        'Manas; Mahendra - gigs',
        'Ritu Sharma (editor)',
      ];
      for (final title in titles) {
        final name = extractPersonName(title);
        if (name == null) continue;
        for (final separator in ['-', ',', ';', ':', '/', '|', '(', ')']) {
          expect(name, isNot(contains(separator)), reason: 'from "$title"');
        }
      }
    });

    test('keeps the result short enough to be a sane keyterm', () {
      final name = extractPersonName('${'Averylongname ' * 8}- description');
      expect(name, isNotNull);
      expect(name!.length, lessThanOrEqualTo(64));
    });

    test('handles a non-Latin name without crashing', () {
      expect(extractPersonName('विट्टू - friend'), isNotNull);
    });
  });
}
