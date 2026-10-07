// Isolated review proof, not a runtime repair. Copy into an extracted fixture's test/.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final routeOwnsController in [false, true]) {
    testWidgets('Link lifetime routeOwnsController=$routeOwnsController', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
          return TextButton(onPressed: () async {
            if (routeOwnsController) {
              await showDialog<void>(context: context, builder: (_) => const _OwnedDialog());
            } else {
              final destination = TextEditingController();
              await showDialog<void>(context: context, builder: (context) => _dialog(context, destination));
              // The current SDK's ownership: the result resolves before the exit animation.
              destination.dispose();
            }
          }, child: const Text('Open'));
        })));
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'https://example.test');
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsNothing);
      } finally {
        semantics.dispose();
      }
    });
  }
}

Widget _dialog(BuildContext context, TextEditingController controller) => AlertDialog(
  title: const Text('Add link'),
  content: TextField(controller: controller, autofocus: true),
  actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel'))],
);

class _OwnedDialog extends StatefulWidget {
  const _OwnedDialog();
  @override
  State<_OwnedDialog> createState() => _OwnedDialogState();
}

class _OwnedDialogState extends State<_OwnedDialog> {
  final destination = TextEditingController();
  @override
  Widget build(BuildContext context) => _dialog(context, destination);
  @override
  void dispose() {
    destination.dispose();
    super.dispose();
  }
}
