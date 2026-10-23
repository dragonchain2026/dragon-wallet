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
          'time': 1700000000,
          'height': 1,
          'confirmations': 101,
          'delta_atomic': '100000001',
          'coinbase': 0,
        },
      ],
      'utxos': [
        {
          'txid': 'transaction',
          'time': 1700000000,
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
          (request) async {
            final response = await (handler ??
                (request) async =>
                    http.Response(jsonEncode(responseData()), 200))(request);
            if (!request.url.path.startsWith('/w/v1/') ||
                response.statusCode != 200 ||
                request.method != 'GET') {
              return response;
            }
            Map<String, dynamic> data;
            try {
              data = jsonDecode(response.body) as Map<String, dynamic>;
            } catch (_) {
              return response;
            }
            if (!data.containsKey('tip') ||
                !data.containsKey('balance_atomic')) {
              return response;
            }
            return http.Response(
                jsonEncode({
                  ...data,
                  'height': (data['tip'] as Map)['height'],
                  'index': data['tip'],
                  'data_time': 1700000000,
                  'items': request.url.path.endsWith('/utxo')
                      ? data['utxos']
                      : (data['transactions'] as List)
                          .where((tx) =>
                              (tx['coinbase'] == 1) ==
                              (request.url.queryParameters['type'] == 'mining'))
                          .toList(),
                  'next_cursor':
                      data['next_offset'] == null ? null : 'fixture-cursor',
                }),
                200);
          },
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

  testWidgets('startup, minute polling and button refresh; background pauses',
      (tester) async {
    var requests = 0;
    var connections = 0;
    final wallet = controller(streamFactory: (_, token, address) {
      connections++;
      return const Stream.empty();
    }, handler: (request) async {
      if (request.url.path.endsWith('/balance')) requests++;
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
    expect(requests, 2);
    expect(connections, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(minutes: 2));
    expect(requests, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    expect(requests, 3);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(find.byTooltip('刷新'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, 4);
    expect(wallet.snapshot, isNotNull);
    await tester.pump(const Duration(seconds: 30));
    expect(requests, 4);
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
            'address': request.url.queryParameters['address'],
          }),
          200);
    });
    addTearDown(wallet.dispose);
    await wallet.configure(address, 'https://wallet.example.com', token);
    const other = 'dragon1qjctnj8237jyucklkscaghh92rfp6lcf9fuvx0c';
    await wallet.configure(other, 'https://wallet.example.com', token);
    expect(requests.length, 5);
    expect(
        requests.every((r) =>
            r.path.endsWith('/height') ||
            r.queryParameters['address'] == other),
        isTrue);
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
            responseData(
                nextOffset: request.url.queryParameters.containsKey('cursor')
                    ? null
                    : 50),
          ),
          200,
        );
      },
    );
    addTearDown(wallet.dispose);
    await wallet.configure(address, 'https://wallet.example.com', token);
    await wallet.refresh();
    await wallet.refresh(more: true);
    expect(requests.last.url.queryParameters['cursor'], 'fixture-cursor');
    expect(requests.last.headers['X-Version'], 'android/v1');
    expect(requests.last.headers['Authorization'], 'Bearer $token');
    expect(wallet.snapshot!.transactions.length, 2);
  });

  test(
      'expired history pagination automatically reloads without technical errors',
      () async {
    var calls = 0;
    final wallet = controller(handler: (request) async {
      if (request.url.queryParameters['type'] == 'normal') calls++;
      if (request.url.queryParameters.containsKey('cursor')) {
        return http.Response('{}', 409);
      }
      final data = responseData(nextOffset: calls == 1 ? 50 : null);
      data.remove('synced');
      data.remove('node_height');
      data['tip'] = {'hash': 'tip'};
      return http.Response(jsonEncode(data), 200);
    });
    addTearDown(wallet.dispose);
    await wallet.configure(address, 'https://wallet.example.com', token);
    await wallet.refresh();
    await wallet.refresh(more: true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 3);
    expect(wallet.error, isNull);
    expect(wallet.snapshot!.transactions.length, 1);
  });

  testWidgets(
      'refresh frequency applies immediately, manual pauses, and setting survives restart',
      (tester) async {
    final store = MemoryStore();
    var requests = 0;
    final wallet = controller(
        store: store,
        handler: (request) async {
          if (request.url.path.endsWith('/balance')) requests++;
          return http.Response(jsonEncode(responseData()), 200);
        });
    await wallet.configure(address, 'https://wallet.example.com', token);
    await tester.pumpWidget(DragonWalletApp(controller: wallet));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('连接与钱包设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 秒').last);
    await tester.pumpAndSettle();
    expect(wallet.refreshSeconds, 10);
    Navigator.of(tester.element(find.byType(ImportPage))).pop();
    await tester.pumpAndSettle();
    final before = requests;
    await tester.pump(const Duration(seconds: 10));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(requests, before + 1);
    await wallet.setRefreshSeconds(0);
    await tester.pump(const Duration(minutes: 31));
    expect(requests, before + 1);
    await tester.runAsync(() => wallet.refresh());
    expect(requests, before + 2);
    await wallet.forget();
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
    final restored = controller(store: store);
    await tester.runAsync(() => restored.initialize());
    expect(restored.refreshSeconds, 0);
    restored.dispose();
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
    await tester.tap(find.text('添加观察钱包'));
    await tester.pumpAndSettle();
    expect(find.text('访问令牌'), findsNothing);
    expect(find.byType(TextFormField), findsNWidgets(2));
    await tester.enterText(find.byType(TextFormField).last, address);
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('观察钱包列表'))).pop();
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
    await tester.tap(find.byType(NavigationDestination).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('观察钱包列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移除'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '移除'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('观察钱包列表'))).pop();
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
      expect(find.text('确认数：100'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      wallet.dispose();
    },
  );
}
