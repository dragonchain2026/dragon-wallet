import 'dart:io';
import 'package:dragon_wallet/core/app_language.dart';
import 'package:dragon_wallet/core/translations.dart';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/core/wallet_api.dart';
import 'package:dragon_wallet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppLanguage original;
  String? saved;
  setUp(() {
    original = AppLanguage.instance;
    saved = null;
    AppLanguage.instance = AppLanguage(
        read: () async => saved,
        write: (value) async {
          saved = value;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel,
            (call) async => call.method == 'list' ? <Object>[] : null);
  });
  tearDown(() {
    AppLanguage.instance = original;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null);
  });
  test('defaults to English, persists language, preserves name arguments',
      () async {
    await AppLanguage.instance.initialize();
    expect(AppLanguage.instance.code, 'en');
    expect(tr('钱包名称：{0}', ['我的钱包{1}']), 'Wallet name: 我的钱包{1}');
    expect(tr('主网收款地址无效'), 'Invalid mainnet receiving wallet');
    await AppLanguage.instance.select('zh');
    final restored = AppLanguage(read: () async => saved);
    await restored.initialize();
    expect(restored.code, 'zh');
    expect(tr('钱包名称'), '钱包名称');
    expect(tr('主网收款地址无效'), '主网收款钱包无效');
  });
  testWidgets('home marks only wallets without a matching local key',
      (tester) async {
    final wallet = fixtures.controller();
    await wallet.configure(fixtures.address, '', '', name: 'Savings');
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester.pumpAndSettle();
    for (final language in ['en', 'zh']) {
      AppLanguage.instance.apply(language);
      for (final ownsKey in [false, true, false]) {
        wallet.localKeys = [
          VaultKey({
            'id': 'test-key',
            'address': ownsKey
                ? fixtures.address
                : 'dragon1qdd50l75jh64clmhlg5034z9y5tmmetr9mcy3nh',
          })
        ];
        await wallet.configure(fixtures.address, '', '');
        await tester.pumpAndSettle();
        final watchName =
            language == 'zh' ? 'Savings(观察)' : 'Savings(Watch-only)';
        final title = find.text(ownsKey ? 'Savings' : watchName);
        await tester.scrollUntilVisible(title, 150,
            scrollable: find.byType(Scrollable).first);
        expect(title, findsOneWidget);
        expect(find.text(ownsKey ? watchName : 'Savings'), findsNothing);
        expect(wallet.nameFor(fixtures.address), 'Savings');
      }
    }
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
  test('English catalogue covers all static translated templates', () {
    final pattern = RegExp(r'''tr\(\s*["']([^"']*[\u3400-\u9fff][^"']*)["']''');
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))) {
      for (final match in pattern.allMatches(file.readAsStringSync())) {
        final key = match[1]!.replaceAll(r'\n', '\n');
        expect(englishMessages.containsKey(key), true,
            reason: '$key in ${file.path}');
      }
    }
    for (final entry in englishMessages.entries) {
      final placeholders = RegExp(r'\{\d+\}');
      expect(
          placeholders.allMatches(entry.value).map((m) => m[0]).toList()
            ..sort(),
          placeholders.allMatches(entry.key).map((m) => m[0]).toList()..sort(),
          reason: entry.key);
    }
  });
  testWidgets('settings switches English and Chinese without losing route',
      (tester) async {
    final wallet = fixtures.controller();
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(WalletHome));
    Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ImportPage(controller: wallet)));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中文').last);
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(saved, 'zh');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  testWidgets('empty wallet saves settings and restores language after restart',
      (tester) async {
    final store = fixtures.MemoryStore();
    final names = fixtures.MemoryStore();
    final wallet =
        WalletController(api: WalletApi(), store: store, namesStore: names);
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(WalletHome))).push(
        MaterialPageRoute<void>(
            builder: (_) => ImportPage(controller: wallet)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('中文').last);
    await tester.pumpAndSettle();
    expect(saved, 'zh');
    await tester.enterText(
        find.byType(TextFormField).last, 'https://exchange.example.com:9999');
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportPage), findsNothing);
    expect(wallet.address, isNull);
    expect(names.value, isNull);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
    AppLanguage.instance = AppLanguage(read: () async => saved);
    await AppLanguage.instance.initialize();
    final restored =
        WalletController(api: WalletApi(), store: store, namesStore: names);
    await restored.initialize();
    expect(AppLanguage.instance.code, 'zh');
    expect(restored.address, isNull);
    expect(restored.endpoint, 'https://exchange.example.com:9999');
    expect(restored.error, isNull);
    restored.dispose();
  });
}
