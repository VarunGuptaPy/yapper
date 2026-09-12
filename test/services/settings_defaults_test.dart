import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/services/settings/settings_model.dart';

void main() {
  test('speech-recognition biasing is off by default', () {
    // It replaced unrelated words with known names on real recordings twice.
    // Known-name spelling is handled by the structuring model instead.
    expect(const YapSettings().keytermsEnabled, isFalse);
  });

  test('the other transcription defaults are unchanged', () {
    const settings = YapSettings();
    expect(settings.sarvamModel, SarvamModel.v4);
    expect(settings.sarvamMode, SarvamMode.codemix);
  });
}
