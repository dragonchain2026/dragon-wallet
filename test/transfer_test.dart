import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/core/wallet_api.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/transfer_page.dart';
import 'wallet_test.dart' show MemoryStore, address, token;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('amounts are exact and bounded without floating point', () {
    expect(parseTransferAmount('1.00000001').toString(), '100000001');
    for (final invalid in [
      '0',
      '-1',
      '0.00000001',
      '1e2',
      '1.000000001',
      '21000001',
      'NaN'
    ]) {
      expect(() => parseTransferAmount(invalid), throwsFormatException);
    }
  });
  test('ownership requires private key for the selected address', () async {
    final wallet = WalletController(
        api: WalletApi(), store: MemoryStore(), namesStore: MemoryStore());
    wallet.address = address;
    expect(wallet.addressLabel, '观察钱包');
    wallet.localKeys = [
      VaultKey({'id': 'key', 'address': address})
    ];
    expect(wallet.addressLabel, '我的钱包');
    wallet.address = null;
    expect(wallet.selectedKey, isNull);
    wallet.dispose();
  });
  test('existing local legacy selection migrates to its SegWit address',
      () async {
    const witness = 'dragon1qdd50l75jh64clmhlg5034z9y5tmmetr9mcy3nh';
    const legacy = 'SX5w7tZdEJtVQbiFzLe3qQVy7aXT59CmUn';
    final store = MemoryStore();
    final wallet = WalletController(
        api: WalletApi(), store: store, namesStore: MemoryStore())
      ..address = legacy;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            KeyVault.channel,
            (call) async => [
                  {
                    'id': 'local-key',
                    'address': witness,
                    'legacy_address': legacy
                  }
                ]);
    await wallet.refreshKeys();
    expect(wallet.address, witness);
    expect(wallet.addressLabel, '我的钱包');
    expect(jsonDecode(store.value!)['address'], witness);
    wallet.dispose();
  });
  testWidgets('truncated send-all shows net amount and refreshed preview limit',
      (tester) async {
    var preparations = 0;
    var signatures = 0;
    final api = WalletApi(client: MockClient((request) async {
      expect(request.url.path.endsWith('prepare'), true);
      preparations++;
      return http.Response(
          jsonEncode({
            'network': 'mainnet',
            'address': address,
            'utxos': [],
            'available_atomic': '200000000',
            'fee_rate': 1,
            'truncated': true,
          }),
          200);
    }));
    final wallet = WalletController(
        api: api, store: MemoryStore(), namesStore: MemoryStore())
      ..address = address
      ..endpoint = 'http://localhost:9999'
      ..token = token
      ..localKeys = [
        VaultKey({'id': 'key', 'address': address})
      ];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, (call) async {
      if (call.method == 'signTransfer') {
        signatures++;
        return null;
      }
      expect(call.arguments['send_all'], true);
      expect(call.arguments['truncated'], true);
      return {
        'ticket': 'limited',
        'recipient': address,
        'amount_atomic': call.method == 'prepareTransfer'
            ? '149998300'
            : call.arguments['fee_rate'] == 2
                ? '199996600'
                : '199998300',
        'fee_atomic': '1700',
        'change_atomic': '0',
      };
    });
    Future<void> settle() async {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(
        home: TransferPage(wallet: wallet, pendingStore: MemoryStore())));
    await settle();
    await tester.enterText(find.byType(TextField).at(0), address);
    await tester.ensureVisible(find.text('全部转出'));
    await tester.tap(find.text('全部转出'));
    await settle();
    expect(find.textContaining('可转账 1.999983 Dragonchain'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(2), '2');
    await settle();
    expect(find.textContaining('可转账 1.999966 Dragonchain'), findsOneWidget);
    expect(find.textContaining('可转账 1.999983 Dragonchain'), findsNothing);
    await tester.ensureVisible(find.text('预览转账'));
    await tester.tap(find.text('预览转账'));
    await settle();
    expect(preparations, 2);
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('可转账 1.499983 Dragonchain')),
        findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(signatures, 0);
    await tester.ensureVisible(find.text('全部转出'));
    await tester.tap(find.text('全部转出'));
    await tester.pumpAndSettle();
    expect(find.textContaining('可转账 1.499983 Dragonchain'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null);
    wallet.dispose();
  });
  testWidgets(
      'cancel never signs; retry after reopening reuses persisted bytes',
      (tester) async {
    final store = MemoryStore();
    final broadcasts = <String>[];
    var signatures = 0;
    final api = WalletApi(client: MockClient((request) async {
      if (request.url.path.endsWith('prepare')) {
        return http.Response(
            jsonEncode({
              'network': 'mainnet',
              'address': address,
              'utxos': [],
              'available_atomic': '200000000',
              'fee_rate': 1
            }),
            200);
      }
      if (request.url.path.endsWith('broadcast')) {
        expect(store.value, isNotNull);
        broadcasts.add(jsonDecode(request.body)['hex'] as String);
        if (broadcasts.length == 1) throw http.ClientException('offline');
        return http.Response(jsonEncode({'txid': 'a' * 64}), 200);
      }
      return http.Response('{}', 503);
    }));
    final wallet = WalletController(
        api: api, store: MemoryStore(), namesStore: MemoryStore())
      ..address = address
      ..endpoint = 'http://10.0.2.2:8080'
      ..token = token
      ..localKeys = [
        VaultKey({'id': 'key', 'address': address})
      ];
    final summary = {
      'sender': address,
      'recipient': address,
      'amount_atomic': '100000000',
      'fee_atomic': '1700',
      'change_atomic': '99998300'
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, (call) async {
      if (call.method == 'prepareTransfer') {
        return {...summary, 'ticket': 'one'};
      }
      if (call.method == 'quoteTransfer') {
        expect(call.arguments['send_all'], true);
        return {
          ...summary,
          'amount_atomic':
              call.arguments['fee_rate'] == 2 ? '199996600' : '199998300'
        };
      }
      if (call.method == 'signTransfer') {
        signatures++;
        return {...summary, 'hex': 'deadbeef', 'txid': 'a' * 64};
      }
      return null;
    });
    Future<void> flush() => tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpWidget(
        MaterialApp(home: TransferPage(wallet: wallet, pendingStore: store)));
    await flush();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), address);
    await tester.ensureVisible(find.text('全部转出'));
    await tester.tap(find.text('全部转出'));
    await flush();
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        '1.999983');
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).enabled, false);
    await tester.enterText(find.byType(TextField).at(2), '2');
    await flush();
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        '1.999966');
    await tester.tap(find.text('全部转出'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).enabled, true);
    await tester.enterText(find.byType(TextField).at(1), '1');
    await tester.ensureVisible(find.text('预览转账'));
    await tester.tap(find.text('预览转账'));
    await flush();
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(signatures, 0);
    expect(broadcasts, isEmpty);
    await tester.tap(find.text('预览转账'));
    await flush();
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并发送'));
    await flush();
    await tester.pumpAndSettle();
    expect(signatures, 1);
    expect(find.text('重试发送同一笔交易'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
        MaterialApp(home: TransferPage(wallet: wallet, pendingStore: store)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送同一笔交易'));
    await flush();
    await tester.pumpAndSettle();
    expect(signatures, 1);
    expect(broadcasts, ['deadbeef', 'deadbeef']);
    expect(find.text('已提交，等待链上确认'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
}
