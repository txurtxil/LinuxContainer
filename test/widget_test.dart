import 'package:flutter_test/flutter_test.dart';
import 'package:linux_container_app/main.dart';

void main() {
  testWidgets('App should launch', (WidgetTester tester) async {
    await tester.pumpWidget(const LinuxContainerApp());
    expect(find.text('Linux Container'), findsOneWidget);
  });
}
