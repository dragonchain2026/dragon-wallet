import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:dragon_wallet/main.dart';
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          KeyVault.channel, (MethodCall call) async => <Object>[]));
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(KeyVault.channel, null));
  testWidgets(
      'ten UTXOs initially; multi-select history defaults to ordinary and uses local time',
      (tester) async {
    tester.view.physicalSize = const Size(800, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Uri>[];
    final epoch = DateTime.utc(2026, 10, 18).millisecondsSinceEpoch ~/ 1000;
    final wallet = fixtures.controller(handler: (request) async {
      requests.add(request.url);
      final data = fixtures.responseData();
      final ordinary = {
        ...(data['transactions'] as List).first as Map<String, dynamic>,
        'time': epoch
      };
      final mining = {
        ...ordinary,
        'txid': 'mining',
        'coinbase': 1,
        'delta_atomic': '5000000000'
      };
      final types = request.url.queryParameters['types']!.split(',');
      data['transactions'] = [
        if (types.contains('normal')) ordinary,
        if (types.contains('mining')) mining
      ];
      data['utxos'] = List.generate(
          21,
          (i) => {
                ...(data['utxos'] as List).first as Map<String, dynamic>,
                'txid': 'utxo-$i'
              });
      data['utxo_count'] = 21;
      return http.Response(jsonEncode(data), 200);
    });
    await wallet.initialize();
    await tester.runAsync(() => wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token));
    await tester.runAsync(() => wallet.refresh());
    await tester.pumpWidget(MaterialApp(home: WalletHome(controller: wallet)));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['types'], 'normal');
    expect(find.byWidgetPredicate((w) => w is ListTile && w.trailing is Icon),
        findsNWidgets(10));
    await tester.tap(find.text('再显示 10 个 UTXO'));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is ListTile && w.trailing is Icon),
        findsNWidgets(20));
    await tester.tap(find.text('再显示 10 个 UTXO'));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is ListTile && w.trailing is Icon),
        findsNWidgets(21));
    expect(find.text('再显示 10 个 UTXO'), findsNothing);
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    final local = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    final localClock =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
    expect(
        find.textContaining(
            '${local.year == DateTime.now().year ? '' : '${local.year}-'}10-18 $localClock'),
        findsOneWidget);
    expect(find.textContaining('UTC'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, '挖矿奖励'));
    await tester.runAsync(() => wallet.refresh());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['types'], 'mining,normal');
    expect(find.byType(ListTile), findsNWidgets(2));
    await tester.tap(find.widgetWithText(FilterChip, '普通交易'));
    await tester.runAsync(() => wallet.refresh());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['types'], 'mining');
    expect(find.text('+50'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, '挖矿奖励'));
    await tester.runAsync(() => wallet.refresh());
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('请勾选要显示的交易类型'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  test('changing filters discards in-flight old pagination', () async {
    final delayed = Completer<http.Response>();
    final requests = <Uri>[];
    final wallet = fixtures.controller(handler: (request) async {
      requests.add(request.url);
      if (request.url.queryParameters['offset'] == '50') return delayed.future;
      final data = fixtures.responseData(nextOffset: 50);
      if (request.url.queryParameters['types'] == 'mining') {
        (data['transactions'] as List).first['coinbase'] = 1;
        (data['transactions'] as List).first['txid'] = 'mining';
      }
      return http.Response(jsonEncode(data), 200);
    });
    await wallet.initialize();
    await wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token);
    await wallet.refresh();
    final more = wallet.refresh(more: true);
    await Future<void>.delayed(Duration.zero);
    await wallet.setHistoryTypes({'mining'});
    await wallet.refresh();
    delayed.complete(http.Response(jsonEncode(fixtures.responseData()), 200));
    await more;
    expect(wallet.snapshot!.transactions.single['txid'], 'mining');
    expect(requests.last.queryParameters['offset'], '0');
    expect(requests.last.queryParameters.containsKey('tip'), isFalse);
    wallet.dispose();
  });

  test('UTXO pagination passes tip, reaches all outputs and preserves history',
      () async {
    final requests = <Uri>[];
    final wallet = fixtures.controller(handler: (request) async {
      requests.add(request.url);
      final data = fixtures.responseData();
      final offset =
          int.parse(request.url.queryParameters['utxo_offset'] ?? '0');
      final template = (data['utxos'] as List).first as Map<String, dynamic>;
      data['utxos'] = List.generate(offset == 0 ? 100 : 3,
          (i) => {...template, 'txid': 'output-${offset + i}'});
      data['utxo_count'] = 103;
      data['utxos_truncated'] = offset == 0;
      return http.Response(jsonEncode(data), 200);
    });
    await wallet.initialize();
    await wallet.configure(
        fixtures.address, 'https://wallet.example.com', fixtures.token);
    await wallet.refresh();
    await wallet.loadMoreUtxos();
    expect(requests.last.queryParameters['utxo_offset'], '100');
    expect(requests.last.queryParameters['tip'], 'tip');
    expect(wallet.snapshot!.utxos.length, 103);
    expect(wallet.snapshot!.utxos.map((u) => u['txid']).toSet().length, 103);
    expect(wallet.snapshot!.transactions.length, 1);
    expect(wallet.snapshot!.data['utxos_truncated'], false);
    await wallet.refresh();
    expect(wallet.snapshot!.utxos.length, 103);
    wallet.dispose();
  });
}
