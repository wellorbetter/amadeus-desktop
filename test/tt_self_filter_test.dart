import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/tt_api.dart';

void main() {
  test('self activity names are filtered case-insensitively and exactly', () {
    expect(TtApi.isSelfApp('timepet.exe'), isTrue);
    expect(TtApi.isSelfApp(' TIMEPET '), isTrue);
    expect(TtApi.isSelfApp('Amadeus-Desktop.exe'), isTrue);
    expect(TtApi.isSelfApp('timepet-notes.exe'), isFalse);
    expect(TtApi.isSelfApp(''), isFalse);
  });

  test('history parser removes self activity defensively', () {
    final day = DayInfo.fromJson({
      'date': '2026-08-09',
      'top_apps': [
        {'app': 'timepet.exe', 'minutes': 90},
        {'app': 'Editor', 'minutes': 20},
      ],
    });
    expect(day.topApps.map((app) => app.name), ['Editor']);
  });
}
