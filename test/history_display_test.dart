import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/main.dart';
import 'package:dragon_wallet/wallet_panel_view.dart';
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(KeyVault.channel, (_) async => <Object>[]));
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(KeyVault.channel, null));

  testWidgets(
      'original native layout switches history while refreshing independent endpoints',
      (tester) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <http.Request>[];
    final wallet = fixtures.controller(handler: (r) async {
      requests.add(r);
      final data = fixtures.responseData();
      final tx = (data['transactions'] as List).first as Map;
      final mining = r.url.queryParameters['type'] == 'mining';
      data['transactions'] = List.generate(mining ? 10 : 1,
          (n) => {...tx, 'txid': 'tx-$n', 'coinbase': mining ? 1 : 0});
      final output = (data['utxos'] as List).first as Map;
      data['utxos'] = List.generate(10, (n) => {...output, 'txid': 'utxo-$n'});
      return http.Response(jsonEncode(data), 200);
    });
    await wallet.initialize();
    await tester.runAsync(() async {
      await wallet.configure(
          fixtures.address, 'https://wallet.example.com', fixtures.token);
      await wallet.refresh();
    });
    expect(requests.length, 5);
    expect(
        requests.every((r) => r.headers['X-Version'] == 'android/v1'), isTrue);
    expect(
        requests
            .map((r) => '${r.url.path}:${r.url.queryParameters['type']}')
            .toSet()
            .length,
        5);
    await tester.pumpWidget(MaterialApp(home: WalletHome(controller: wallet)));
    await tester.pumpAndSettle();
    expect(find.byType(WalletPanelView), findsNWidgets(2));
    expect(find.byType(WebViewWidget), findsNothing);
    expect(find.text('仅展示最新十条记录'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(10));
    expect(find.textContaining('区块时间：'), findsNWidgets(10));
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    expect(find.byType(WalletPanelView), findsOneWidget);
    expect(find.byType(WebViewWidget), findsNothing);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('挖矿奖励').last);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('仅展示最近十条数据'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(10));
    await tester.runAsync(() => wallet.refresh());
    expect(wallet.panels.states['mining']!.data!['items'].length, 10);
    expect(requests.length, 10);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  test('height refresh updates cached confirmations and failure retains height',
      () async {
    var latest = 101, fail = false;
    final wallet = fixtures.controller(handler: (r) async {
      if (r.url.path.endsWith('/height')) {
        if (fail) return http.Response('{}', 503);
        return http.Response(
            jsonEncode(
                {'network': 'mainnet', 'height': latest, 'data_time': 1}),
            200);
      }
      return http.Response(jsonEncode(fixtures.responseData()), 200);
    });
    await wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token);
    expect(wallet.panels.confirmations({'height': 1}), '—');
    await wallet.refresh();
    expect(wallet.panels.confirmations({'height': 1}), 100);
    expect(wallet.panels.confirmations({'height': 101}), 0);
    expect(wallet.panels.confirmations({'height': 102}), 0);
    latest = 102;
    await wallet.panels.load('height');
    expect(wallet.panels.confirmations({'height': 1}), '>100');
    fail = true;
    await wallet.panels.load('height');
    expect(wallet.panels.confirmations({'height': 1}), '>100');
    expect(wallet.panels.states['height']!.error, isNotNull);
    wallet.dispose();
  });

  test('slow UTXO does not block other pages or their next refresh', () async {
    final pending = Completer<http.Response>();
    final calls = <String, int>{};
    final wallet = fixtures.controller(handler: (r) async {
      final kind = r.url.queryParameters['type'] ?? r.url.pathSegments.last;
      calls[kind] = (calls[kind] ?? 0) + 1;
      if (kind == 'utxo') return pending.future;
      return http.Response(jsonEncode(fixtures.responseData()), 200);
    });
    await wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token);
    final first = wallet.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(wallet.panels.states['utxo']!.loading, isTrue);
    for (final k in ['balance', 'normal', 'mining']) {
      expect(wallet.panels.states[k]!.data, isNotNull);
    }
    final second = wallet.refresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls['balance'], 2);
    expect(calls['utxo'], 1);
    pending.complete(http.Response('{}', 503));
    await first;
    await second;
    expect(wallet.panels.states['utxo']!.error, isNotNull);
    expect(wallet.panels.states['balance']!.error, isNull);
    wallet.dispose();
  });

  test('switching wallet discards old pagination and refresh responses',
      () async {
    final pending = Completer<http.Response>();
    final wallet = fixtures.controller(handler: (r) async {
      if (r.url.queryParameters.containsKey('cursor')) return pending.future;
      return http.Response(
          jsonEncode({
            ...fixtures.responseData(nextOffset: 50),
            'address': r.url.queryParameters['address']
          }),
          200);
    });
    await wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token);
    await wallet.refresh();
    final oldPage = wallet.panels.load('normal', more: true);
    await Future<void>.delayed(Duration.zero);
    const other = 'dragon1qjctnj8237jyucklkscaghh92rfp6lcf9fuvx0c';
    await wallet.configure(other, 'https://wallet.example.com', fixtures.token);
    pending.complete(http.Response(jsonEncode(fixtures.responseData()), 200));
    await oldPage;
    expect(wallet.panels.states['normal']!.data!['address'], other);
    expect(wallet.panels.states['normal']!.data!['items'].length, 1);
    wallet.dispose();
  });
}
