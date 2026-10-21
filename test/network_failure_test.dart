import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:dragon_wallet/main.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/key_page.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dragon_wallet/transfer_page.dart';
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('unresponsive refresh does not block receive or local keys',
      (tester) async {
    var requests = 0;
    final pending = Completer<http.Response>();
    final wallet = fixtures.controller(handler: (_) {
      requests++;
      return pending.future;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel,
            (call) async => call.method == 'list' ? <Object>[] : null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null));
    await wallet.configure(
        fixtures.address, 'https://offline.example.com', fixtures.token);
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(wallet.busy, true);
    final receive = find.descendant(
        of: find.byType(NavigationBar), matching: find.text('收款'));
    await tester.tap(receive);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(fixtures.address), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate((widget) =>
                widget is IconButton && widget.tooltip == '连接与钱包设置'))
            .onPressed,
        isNotNull);
    await tester.tap(find.byTooltip('本地钱包与私钥'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(KeyPage), findsOneWidget);
    expect(find.text('生成 WIF 钱包'), findsOneWidget);
    await tester.tap(find.text('生成 WIF 钱包'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('新建钱包名称'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AlertDialog), findsNothing);
    expect(requests, 1);
    pending.complete(http.Response('{}', 503));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  final failures = <String, Future<http.Response> Function()>{
    'DNS or disconnected': () async => throw http.ClientException('offline'),
    'timeout': () async => throw TimeoutException('timeout'),
    'unauthorized': () async => http.Response('{}', 401),
    'rate limited': () async => http.Response('{}', 429),
    'unavailable': () async => http.Response('{}', 503),
    'HTML instead of JSON': () async =>
        http.Response('<html>error</html>', 200),
    'incomplete JSON': () async => http.Response('{}', 200),
  };
  for (final entry in failures.entries) {
    test('${entry.key}: retains snapshot and can retry successfully', () async {
      var fail = false;
      final wallet = fixtures.controller(
          handler: (_) => fail
              ? entry.value()
              : Future.value(
                  http.Response(jsonEncode(fixtures.responseData()), 200)));
      addTearDown(wallet.dispose);
      await wallet.configure(
          fixtures.address, 'https://offline.example.com', fixtures.token);
      await wallet.refresh();
      final previous = wallet.snapshot;
      final updated = wallet.updatedAt;
      fail = true;
      await wallet.refresh();
      expect(wallet.snapshot, same(previous));
      expect(wallet.updatedAt, updated);
      expect(wallet.error, isNotEmpty);
      expect(wallet.busy, false);
      await wallet.renameAddress(fixtures.address, 'Offline name');
      expect(wallet.nameFor(fixtures.address), 'Offline name');
      fail = false;
      await wallet.refresh();
      expect(wallet.error, isNull);
      expect(wallet.busy, false);
      expect(wallet.snapshot!.balance, previous!.balance);
    });
  }

  test('late response from old service cannot replace a new profile', () async {
    final pending = Completer<http.Response>();
    final wallet = fixtures.controller(handler: (_) => pending.future);
    addTearDown(wallet.dispose);
    await wallet.configure(
        fixtures.address, 'https://offline.example.com', fixtures.token);
    final refresh = wallet.refresh();
    await Future<void>.delayed(Duration.zero);
    const other = 'dragon1qjctnj8237jyucklkscaghh92rfp6lcf9fuvx0c';
    await wallet.configure(other, 'https://new.example.com', fixtures.token,
        refreshOnSwitch: false);
    pending.complete(http.Response(jsonEncode(fixtures.responseData()), 200));
    await refresh;
    expect(wallet.address, other);
    expect(wallet.snapshot, isNull);
    expect(wallet.error, isNull);
    expect(wallet.busy, false);
  });

  testWidgets('can leave transfer while prepare service is unresponsive',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final wallet = fixtures.controller(handler: (_) {
      requests++;
      return pending.future;
    });
    wallet.address = fixtures.address;
    wallet.endpoint = 'https://offline.example.com';
    wallet.token = fixtures.token;
    wallet.localKeys = [
      VaultKey({'id': 'offline-transfer-key', 'address': fixtures.address})
    ];
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => TransferPage(
                            wallet: wallet,
                            pendingStore: fixtures.MemoryStore()))),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(requests, 1);
    await tester.tap(find.text('返回钱包'));
    await tester.pumpAndSettle();
    expect(find.byType(TransferPage), findsNothing);
    expect(pending.isCompleted, false);
    pending.complete(http.Response('{}', 503));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  testWidgets('settings save returns without waiting for an unreachable API',
      (tester) async {
    final pending = Completer<http.Response>();
    var requests = 0;
    final wallet = fixtures.controller(handler: (_) {
      requests++;
      return pending.future;
    });
    await wallet.loadNames();
    wallet.address = fixtures.address;
    wallet.endpoint = 'https://offline.example.com';
    wallet.token = fixtures.token;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => ImportPage(controller: wallet))),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    const other = 'dragon1qjctnj8237jyucklkscaghh92rfp6lcf9fuvx0c';
    await tester.enterText(find.byType(TextFormField).first, other);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.byType(ImportPage), findsNothing);
    expect(wallet.address, other);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(requests, WalletController.bundledToken.isEmpty ? 0 : 1);
    expect(pending.isCompleted, false);
    pending.complete(http.Response('{}', 503));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
}
