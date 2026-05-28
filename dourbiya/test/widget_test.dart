import 'package:flutter_test/flutter_test.dart';

import 'package:dourbiya/main.dart';

void main() {
  testWidgets('Home screen shows main action', (WidgetTester tester) async {
    await tester.pumpWidget(const DourbiyaApp());
    expect(find.text('TAP TO LISTEN'), findsOneWidget);
  });
}
