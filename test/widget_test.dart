import 'package:nexaclip/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the initial screen', (tester) async {
    await tester.pumpWidget(const ClipboardApp());

    expect(find.text('NexaClip'), findsOneWidget);
    expect(
      find.text('Ứng dụng đang được xây dựng. Lịch sử clipboard chưa được lưu.'),
      findsOneWidget,
    );
  });
}
