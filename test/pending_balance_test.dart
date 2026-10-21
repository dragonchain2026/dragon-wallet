import 'dart:convert';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/pending_balance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(KeyVault.channel, (call) async => <Object>[]));
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(KeyVault.channel, null));
  testWidgets(
      'pending balance is collapsed and fetched on demand, failures do not show zero',
      (tester) async {
    var requests = 0;
    var fail = false;
    final wallet = fixtures.controller(handler: (request) async {
      if (request.url.path.endsWith('/pending')) {
        requests++;
        return http.Response(
            jsonEncode({
              'network': 'mainnet',
              'address': fixtures.address,
              'scope': 'mempool_net_change',
              'pending_atomic': '-125000000',
              'immature_atomic': '200000000',
              'total_pending_atomic': '75000000'
            }),
            fail ? 503 : 200);
      }
      return http.Response(jsonEncode(fixtures.responseData()), 200);
    });
    await wallet.initialize();
    await tester.runAsync(() => wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token));
    await tester.runAsync(() => wallet.refresh());
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PendingBalance(wallet: wallet))));
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.text('0.75 Dragonchain'), findsNothing);
    await tester.tap(find.text('未确认余额'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(find.text('0.75 Dragonchain'), findsOneWidget);
    expect(find.text('未成熟挖矿奖励：2'), findsOneWidget);
    expect(find.text('未确认转账净额：-1.25'), findsOneWidget);
    fail = true;
    await tester.tap(find.byTooltip('刷新'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法查询'), findsOneWidget);
    expect(find.text('0.75 Dragonchain'), findsNothing);
    expect(find.text('0 Dragonchain'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
}
