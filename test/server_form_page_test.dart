import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:claude_ssh/core/storage/server_repository.dart';
import 'package:claude_ssh/features/servers/server_form_page.dart';
import 'package:claude_ssh/features/servers/server_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingRepository extends ServerRepository {
  _FailingRepository(super.preferences, super.secureStorage);

  @override
  Future<void> save(ServerProfile profile, SshCredentials credentials) {
    throw StateError('keystore unavailable');
  }
}

String _value(WidgetTester tester, String label) {
  final field = find.descendant(
    of: find.widgetWithText(TextFormField, label),
    matching: find.byType(EditableText),
  );
  return tester.widget<EditableText>(field).controller.text;
}

void main() {
  testWidgets('a failed save re-enables the button and shows the error', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = _FailingRepository(
      preferences,
      const FlutterSecureStorage(),
    );

    await tester.pumpWidget(
      MaterialApp(home: ServerFormPage(repository: repository)),
    );

    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'VPS');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Host'),
      'example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Username'),
      'zoiyo',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Private key (PEM)'),
      'KEY',
    );

    final save = find.byType(FilledButton);
    await tester.scrollUntilVisible(
      save,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.text('Save'), findsOneWidget);
    expect(find.textContaining('Could not save'), findsOneWidget);
  });

  testWidgets(
    'typed values survive leaving and reopening the form; secrets are not stored',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = ServerRepository(
        preferences,
        const FlutterSecureStorage(),
      );

      Future<void> open() => tester.pumpWidget(
        MaterialApp(home: ServerFormPage(repository: repository)),
      );

      await open();
      await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'VPS');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Host'),
        'example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Private key (PEM)'),
        'SECRET-KEY',
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Leaving the screen (for example, switching apps and coming back).
      await tester.pumpWidget(const SizedBox());
      await open();
      await tester.pump();

      expect(_value(tester, 'Name'), 'VPS');
      expect(_value(tester, 'Host'), 'example.com');
      expect(_value(tester, 'Private key (PEM)'), isEmpty);
      expect(
        preferences.getString('server.draft.new'),
        isNot(contains('SECRET-KEY')),
      );
    },
  );

  testWidgets('duplicating prefills the copy and leaves the original alone', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = ServerRepository(
      preferences,
      const FlutterSecureStorage(),
    );
    const original = ServerProfile(
      id: 'orig',
      name: 'VPS',
      host: 'example.com',
      port: 2222,
      username: 'zoiyo',
      auth: AuthMethod.password,
      workingDirectory: '~/app',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ServerFormPage(repository: repository, template: original),
      ),
    );
    await tester.pump();

    expect(find.text('Duplicate server'), findsOneWidget);
    expect(_value(tester, 'Name'), 'VPS (copy)');
    expect(_value(tester, 'Host'), 'example.com');
    expect(_value(tester, 'Port'), '2222');
    expect(_value(tester, 'Project directory (optional)'), '~/app');
    expect(preferences.getString('server.draft.copy.orig'), isNull);
    expect(await repository.loadAll(), isEmpty);
  });
}
