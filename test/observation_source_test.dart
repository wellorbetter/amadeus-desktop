import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/observation_source.dart';
import 'package:timepet/services/tt_api.dart';

void main() {
  test('activity awareness is modeled as observation, not memory', () {
    final ObservationSource source = TtApi(base: 'http://127.0.0.1:1');

    expect(source.id, 'activity_awareness');
    expect(source.displayName, '活动感知');
    expect(source.hasData, isFalse);
  });
}
