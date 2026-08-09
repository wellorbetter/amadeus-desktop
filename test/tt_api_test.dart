import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/tt_api.dart';

void main() {
  test('TimeTrace day parser tolerates malformed optional fields', () {
    final day = DayInfo.fromJson({
      'date': 'not-a-date',
      'active_min': 'bad',
      'idle_min': -2,
      'top_apps': [
        {'app': 'Editor', 'minutes': 25},
        {'app': 'noise', 'minutes': -1},
        {'app': 'missing'},
      ],
      'peak_hours': [
        {'hour': 9, 'minutes': 20},
        {'hour': 'bad'},
      ],
      'diary': {'has_entry': true},
    });

    expect(day.date, 'not-a-date');
    expect(day.activeMin, 0);
    expect(day.topApps.map((e) => e.name), ['Editor']);
    expect(day.peakHours.single.hour, 9);
    expect(day.diaryHas, isTrue);
    expect(day.readableDate, 'not-a-date');
  });
}
