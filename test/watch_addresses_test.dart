import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/core/wallet_api.dart';
import 'package:dragon_wallet/transfer_page.dart';
import 'package:dragon_wallet/watch_addresses_page.dart';
import 'wallet_test.dart' show MemoryStore, address;

const second = 'dragon1qdd50l75jh64clmhlg5034z9y5tmmetr9mcy3nh';

void main() {
  testWidgets(
      'list switches a saved watch address without waiting for a network',
      (tester) async {
    final wallet = WalletController(
        api: WalletApi(), store: MemoryStore(), namesStore: MemoryStore());
    await wallet.configure(address, 'https://wallet.example.com', '');
    await wallet.configure(second, wallet.endpoint, '');
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => WatchAddressesPage(
                              wallet: wallet, onAdd: () async {}))),
                  child: const Text('open'),
                ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(address), findsOneWidget);
    expect(find.text(second), findsOneWidget);
    await tester.tap(find.text('切换').first);
    await tester.pumpAndSettle();
    expect(wallet.address, address);
    expect(wallet.selectedKey, isNull);
    expect(find.byType(WatchAddressesPage), findsNothing);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
  test('legacy watch address migrates; list survives switching and removal',
      () async {
    final store = MemoryStore()
      ..value = jsonEncode(
          {'address': address, 'endpoint': 'https://wallet.example.com'});
    final names = MemoryStore();
    WalletController create() =>
        WalletController(api: WalletApi(), store: store, namesStore: names);
    final wallet = create();
    await wallet.initialize();
    expect(wallet.watchAddresses, [address]);
    await wallet.configure(second, wallet.endpoint, '', name: '第二个观察钱包');
    await wallet.configure(address, wallet.endpoint, '');
    expect(wallet.watchAddresses, [address, second]);
    final restored = create();
    await restored.initialize();
    expect(restored.watchAddresses, [address, second]);
    expect(restored.nameFor(second), '第二个观察钱包');
    expect(restored.selectedKey, isNull);
    await restored.forget();
    expect(restored.address, isNull);
    expect(restored.watchAddresses, [second]);
    final again = create();
    await again.initialize();
    expect(again.watchAddresses, [second]);
    await again.configure(second, again.endpoint, '');
    await again.forget();
    expect(again.watchAddresses, isEmpty);
    wallet.dispose();
    restored.dispose();
    again.dispose();
  });

  testWidgets(
      'watch-only route cannot prepare or broadcast even with a pending record',
      (tester) async {
    final wallet = WalletController(
        api: WalletApi(), store: MemoryStore(), namesStore: MemoryStore())
      ..address = address;
    final pending = MemoryStore()..value = '{"hex":"unused-pending"}';
    await tester.pumpWidget(
        MaterialApp(home: TransferPage(wallet: wallet, pendingStore: pending)));
    await tester.pumpAndSettle();
    expect(find.text('观察钱包仅支持查看余额、交易记录和收款，不能转账'), findsOneWidget);
    expect(find.text('预览转账'), findsNothing);
    expect(find.text('重试发送同一笔交易'), findsNothing);
    expect(pending.value, '{"hex":"unused-pending"}');
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
}
