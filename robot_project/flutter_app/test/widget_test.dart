import 'package:flutter_test/flutter_test.dart';
import 'package:robot_controller/main.dart';

void main() {
  testWidgets('App launches login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const RobotControllerApp());
    expect(find.text('Delivery Robot Controller'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
  });
}
