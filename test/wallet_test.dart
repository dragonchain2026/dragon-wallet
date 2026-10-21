import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dragon_wallet/core/address.dart';
import 'package:dragon_wallet/core/wallet_api.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/main.dart';
import 'package:dragon_wallet/core/key_vault.dart';

const address = 'SNrExv4meNtf7QKvwj5EWudgZUrE14xFqc';
const token = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class MemoryStore implements WalletStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String input) async {
    value = input;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

Map<String, dynamic> responseData({int? nextOffset}) => {
      'network': 'mainnet',
      'address': address,
      'balance_atomic': '100000001',
      'balance_scope': 'confirmed_chain_only',
      'mempool_included': false,
      'synced': true,
      'tip': {'height': 101, 'hash': 'tip'},
      'node_height': 101,
      'utxo_count': 1,
      'utxos_truncated': false,
      'next_offset': nextOffset,
      'transactions': [
        {
          'txid': 'transaction',
          'height': 1,
          'confirmations': 101,
          'time': 1700000000,
          'delta_atomic': '100000001',
          'coinbase': 0,
        },
      ],
      'utxos': [
        {
          'txid': 'transaction',
          'height': 1,
          'confirmations': 101,
          'vout': 0,
          'value_atomic': '100000001',
          'coinbase': 0,
        },
      ],
    };

WalletController controller({
  MemoryStore? store,
  Stream<void> Function(Uri, String, String)? streamFactory,
  Future<http.Response> Function(http.Request)? handler,
}) =>
    WalletController(
      namesStore: MemoryStore(),
      store: store ?? MemoryStore(),
      api: WalletApi(
        streamFactory:
            streamFactory ?? (_, token, address) => const Stream.empty(),
        client: MockClient(
          handler ??
              (request) async => http.Response(jsonEncode(responseData()), 200),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            KeyVault.channel, (MethodCall call) async => <Object>[]);
  });
  test(
      'mainnet address vectors match backend; reject foreign networks and corrupt checksums',
      () {
    final vectors = jsonDecode(
      File('test/fixtures/address_vectors.json').readAsStringSync(),
    ) as Map;
    for (final vector in vectors['valid'] as List) {
      expect(
        normalizeAddress(vector['address'] as String),
        vector['normalized'],
      );
    }
    for (final input in vectors['invalid'] as List) {
      expect(() => normalizeAddress(input as String), throwsFormatException);
    }
  });

  test('amounts retain atomic precision above JavaScript safe integers', () {
    expect(formatAmount(BigInt.one), '0.00000001');
    expect(formatAmount(BigInt.parse('9007199254740993')), '90071992.54740993');
    expect(formatAmount(BigInt.from(-100000001)), '-1.00000001');
  });

  test('only the configured deployment permits remote HTTP', () {
    expect(
      validateEndpoint('https://wallet.example.com').host,
      'wallet.example.com',
    );
    expect(validateEndpoint('http://10.0.2.2:8080').port, 8080);
    expect(validateEndpoint('https://exchange.example.com').port, 443);
    expect(validateEndpoint('https://exchange.example.com:9999/').toString(),
        'https://exchange.example.com:9999');
    for (final value in [
      'http://wallet.example.com',
      'http://192.0.2.10:8080',
      'http://192.0.2.11:9999',
      'https://user:password@example.com',
      'https://example.com/v1',
      'https://example.com?token=secret',
    ]) {
      expect(() => validateEndpoint(value), throwsFormatException);
    }
  });

  testWidgets('startup, wallet events and button refresh; background pauses',
      (tester) async {
    var requests = 0;
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    final wallet = controller(
        streamFactory: (_, token, address) => changes.stream,
        handler: (_) async {
          requests++;
          return http.Response(jsonEncode(responseData()), 200);
        });
    await wallet.configure(address, 'https://wallet.example.com', token);
    expect(requests, 0);
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(requests, 1);
    await tester.pump(const Duration(seconds: 30));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, 1);
    changes.add(null);
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(minutes: 2));
    expect(requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await wallet.setHistoryTypes({'mining'});
    await tester.pumpAndSettle();
    expect(requests, 2);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.byTooltip('刷新'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, 3);
    expect(wallet.snapshot, isNotNull);
    await tester.pump(const Duration(seconds: 30));
    expect(requests, 3);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  test('switching the selected address refreshes the new address once',
      () async {
    final requests = <Uri>[];
    final wallet = controller(handler: (request) async {
      requests.add(request.url);
      return http.Response(
          jsonEncode({
            ...responseData(),
            'address': request.url.pathSegments[2],
          }),
          200);
    });
    addTearDown(wallet.dispose);
    await wallet.configure(address, 'https://wallet.example.com', token);
    const other = 'dragon1qjctnj8237jyucklkscaghh92rfp6lcf9fuvx0c';
    await wallet.configure(other, 'https://wallet.example.com', token);
    expect(requests.length, 1);
    expect(requests.single.pathSegments[2], other);
    expect(wallet.snapshot!.data['address'], other);
  });

  test('persist public profile, never token, and restore offline', () async {
    final store = MemoryStore();
    final wallet = controller(store: store);
    addTearDown(wallet.dispose);
    await wallet.initialize();
    await wallet.configure(address, 'https://wallet.example.com', token);
    await wallet.refresh();
    expect(wallet.snapshot!.balance, BigInt.from(100000001));
    expect(store.value, isNot(contains(token)));
    final restored = controller(store: store);
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.address, address);
    expect(restored.token, isEmpty);
    expect(restored.connected, isFalse);
  });

  test('default API restores blank legacy settings and preserves custom URLs',
      () async {
    for (final savedEndpoint in [
      null,
      '',
      '   ',
      'https://wallet.example.com'
    ]) {
      final store = MemoryStore();
      store.value = jsonEncode({'address': null, 'endpoint': savedEndpoint});
      final wallet = controller(store: store);
      await wallet.initialize();
      expect(
          wallet.endpoint,
          savedEndpoint == 'https://wallet.example.com'
              ? savedEndpoint
              : WalletController.defaultEndpoint);
      expect(wallet.error, isNull);
      expect(wallet.address, isNull);
      wallet.dispose();
    }
    final store = MemoryStore();
    final wallet = controller(store: store);
    expect(wallet.endpoint, WalletController.defaultEndpoint);
    await wallet.configure('', '', '');
    expect(wallet.endpoint, WalletController.defaultEndpoint);
    expect(
        jsonDecode(store.value!)['endpoint'], WalletController.defaultEndpoint);
    wallet.dispose();
  });

  test(
    'network failure preserves previous snapshot with visible error',
    () async {
      var fail = false;
      final wallet = controller(
        handler: (_) async => fail
            ? http.Response('{}', 503)
            : http.Response(jsonEncode(responseData()), 200),
      );
      addTearDown(wallet.dispose);
      await wallet.configure(address, 'https://wallet.example.com', token);
      await wallet.refresh();
      fail = true;
      await wallet.refresh();
      expect(wallet.snapshot!.balance, BigInt.from(100000001));
      expect(wallet.error, contains('503'));
      expect(wallet.busy, isFalse);
    },
  );

  test('forget invalidates an in-flight response', () async {
    final pending = Completer<http.Response>();
    final wallet = controller(handler: (_) => pending.future);
    addTearDown(wallet.dispose);
    await wallet.configure(
      address,
      'https://wallet.example.com',
      token,
    );
    final saving = wallet.refresh();
    await Future<void>.delayed(Duration.zero);
    await wallet.forget();
    pending.complete(http.Response(jsonEncode(responseData()), 200));
    await saving;
    expect(wallet.address, isNull);
    expect(wallet.snapshot, isNull);
    expect(wallet.busy, isFalse);
  });

  test('pagination binds to the same indexed tip', () async {
    final requests = <http.Request>[];
    final wallet = controller(
      handler: (request) async {
        requests.add(request);
        return http.Response(
          jsonEncode(
            responseData(nextOffset: requests.length == 1 ? 50 : null),
          ),
          200,
        );
      },
    );
    addTearDown(wallet.dispose);
    await wallet.configure(address, 'https://wallet.example.com', token);
    await wallet.refresh();
    await wallet.refresh(more: true);
    expect(requests.last.url.queryParameters['tip'], 'tip');
    expect(requests.last.url.queryParameters['offset'], '50');
    expect(requests.last.headers['Authorization'], 'Bearer $token');
    expect(wallet.snapshot!.transactions.length, 2);
  });

  test('wrong address or network response is rejected', () async {
    for (final change in [
      {'network': 'testnet'},
      {'address': 'other'},
      {'balance_atomic': '-1'},
    ]) {
      final wallet = controller(
        handler: (_) async =>
            http.Response(jsonEncode({...responseData(), ...change}), 200),
      );
      await wallet.configure(address, 'https://wallet.example.com', token);
      await wallet.refresh();
      expect(wallet.snapshot, isNull);
      expect(wallet.error, isNotNull);
      wallet.dispose();
    }
  });

  testWidgets('import address offline, show receive QR, remove address', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final wallet = controller();
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入观察钱包'));
    await tester.pumpAndSettle();
    expect(find.text('访问令牌'), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(3));
    await tester.enterText(find.byType(TextFormField).at(0), address);
    await tester.ensureVisible(find.text('保存设置'));
    await tester.tap(find.text('保存设置'));
    await tester.pumpAndSettle();
    expect(find.text('已确认余额'), findsOneWidget);
    expect(find.text('转账'), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '转账'))
            .onPressed,
        isNull);
    expect(find.text('—'), findsOneWidget);
    await tester.tap(find.byType(NavigationDestination).at(1));
    await tester.pumpAndSettle();
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text(address), findsOneWidget);
    await tester.tap(find.byTooltip('连接与钱包设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('移除观察钱包'));
    await tester.tap(find.text('移除观察钱包'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(find.text('导入观察钱包'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });

  testWidgets(
    'connected wallet displays exact balance and transaction detail',
    (tester) async {
      final wallet = controller();
      await tester.runAsync(
        () async {
          await wallet.configure(address, 'https://wallet.example.com', token);
          await wallet.refresh();
        },
      );
      await tester.pumpWidget(DragonWalletApp(controller: wallet));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pumpAndSettle();
      expect(find.text('1.00000001'), findsWidgets);
      await tester.tap(find.byType(NavigationDestination).at(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+1.00000001'));
      await tester.pumpAndSettle();
      expect(find.text('交易详情'), findsOneWidget);
      expect(find.text('确认数：101'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      wallet.dispose();
    },
  );
}
