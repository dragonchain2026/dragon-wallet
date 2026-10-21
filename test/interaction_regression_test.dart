import 'dart:convert';
import 'package:dragon_wallet/address_name_dialog.dart';
import 'package:dragon_wallet/core/app_language.dart';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/main.dart';
import 'package:dragon_wallet/transfer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    AppLanguage.instance.apply('zh');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null);
  });

  testWidgets('name dialog validates blank input and cancel preserves value',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      return TextButton(
          onPressed: () async {
            result = await askAddressName(context, 'Savings');
          },
          child: const Text('open'));
    })));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Savings');
    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text(tr('保存名称')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.errorText,
        isNotNull);
    await tester.enterText(find.byType(TextField), 'Temporary');
    await tester.tap(find.text(tr('取消')));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '中文 Savings');
    await tester.tap(find.text(tr('保存名称')));
    await tester.pumpAndSettle();
    expect(result, '中文 Savings');
  });

  testWidgets(
      'ordinary transfer preview cancels without signing or broadcasting',
      (tester) async {
    var prepared = 0;
    final wallet = fixtures.controller(handler: (request) async {
      expect(request.url.path.endsWith('/prepare'), isTrue,
          reason: 'Interaction regression must never broadcast');
      return http.Response(
          jsonEncode({
            'network': 'mainnet',
            'address': fixtures.address,
            'utxos': [],
            'available_atomic': '200000000',
            'fee_rate': 1,
          }),
          200);
    })
      ..address = fixtures.address
      ..endpoint = 'https://wallet.example.com'
      ..token = fixtures.token
      ..localKeys = [
        VaultKey({'id': 'interaction-only', 'address': fixtures.address})
      ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, (call) async {
      expect(call.method, anyOf('prepareTransfer', 'quoteTransfer'),
          reason: 'Interaction regression must never sign');
      if (call.method == 'prepareTransfer') prepared++;
      return {
        'ticket': 'interaction-only',
        'sender': fixtures.address,
        'recipient': fixtures.address,
        'amount_atomic':
            call.method == 'quoteTransfer' ? '199998300' : '100000000',
        'fee_atomic': '1700',
        'change_atomic': '99998300',
      };
    });
    Future<void> settle() async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(
        home: TransferPage(
            wallet: wallet, pendingStore: fixtures.MemoryStore())));
    await settle();
    await tester.ensureVisible(find.text(tr('预览转账')));
    await tester.tap(find.text(tr('预览转账')));
    await settle();
    expect(find.text(tr('请输入有效的 Dragonchain 主网钱包')), findsOneWidget);
    expect(prepared, 0);
    await tester.enterText(find.byType(TextField).at(0), fixtures.address);
    await tester.enterText(find.byType(TextField).at(1), '0');
    await tester.ensureVisible(find.text(tr('预览转账')));
    await tester.tap(find.text(tr('预览转账')));
    await settle();
    expect(find.text(tr('金额须在 0.00000546 至 21000000 之间')), findsOneWidget);
    expect(prepared, 0);
    await tester.enterText(find.byType(TextField).at(1), '1');
    await tester.enterText(find.byType(TextField).at(2), '0');
    await tester.ensureVisible(find.text(tr('预览转账')));
    await tester.tap(find.text(tr('预览转账')));
    await settle();
    expect(find.text(tr('手续费率须为 1–1000 最小单位/虚拟字节')), findsOneWidget);
    expect(prepared, 0);
    await tester.enterText(find.byType(TextField).at(2), '1');
    await tester.ensureVisible(find.text(tr('全部转出')));
    await tester.tap(find.text(tr('全部转出')));
    await settle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).enabled, false);
    await tester.tap(find.text(tr('全部转出')));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).enabled, true);
    await tester.enterText(find.byType(TextField).at(1), '1');
    await tester.ensureVisible(find.text(tr('预览转账')));
    await tester.tap(find.text(tr('预览转账')));
    await settle();
    expect(prepared, 1);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('0.000017'), findsWidgets);
    await tester.tap(find.text(tr('取消')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        fixtures.address);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  for (final language in ['zh', 'en']) {
    testWidgets('phone navigation with large text in $language',
        (tester) async {
      tester.view.physicalSize = const Size(393, 873);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AppLanguage.instance.apply(language);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              KeyVault.channel, (call) async => <Object>[]);
      final wallet = fixtures.controller();
      await wallet.initialize();
      await wallet.configure(fixtures.address, '', '',
          name: '长钱包名称 Long wallet name');
      await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.3)),
              child: child!),
          home: WalletHome(controller: wallet)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final index in [1, 2, 0]) {
        await tester.tap(find.byType(NavigationDestination).at(index));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip(tr('连接与钱包设置')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(WalletHome), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      wallet.dispose();
    });
  }
}
