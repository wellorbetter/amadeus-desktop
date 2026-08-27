import 'package:flutter_test/flutter_test.dart';
import 'package:timepet/services/observation_source.dart';
import 'package:timepet/services/tt_api.dart';

void main() {
  test('TimeTrace is modeled as an observation capability, not memory', () {
    final ObservationSource source = TtApi(base: 'http://127.0.0.1:1');

    expect(source.id, 'timetrace');
    expect(source.displayName, 'TimeTrace');
    expect(source.hasData, isFalse);
  });
}
