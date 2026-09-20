import 'package:flutter_test/flutter_test.dart';

import 'package:jarvisol/l10n/generated/app_localizations.dart';
import 'package:jarvisol/screens/settings_screen.dart';

void main() {
  test('settings app-language selector exposes every generated locale', () {
    final selectorCodes = SettingsScreen.supportedAppLocaleCodes
        .where((code) => code.isNotEmpty)
        .toSet();
    final generatedCodes = AppLocalizations.supportedLocales
        .map((locale) => locale.languageCode)
        .toSet();

    expect(selectorCodes, generatedCodes);
    expect(selectorCodes, contains('zh'));
  });
}
