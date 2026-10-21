import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/key_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'wallet_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('switch returns before a slow balance refresh completes',
      (tester) async {
    final response = Completer<http.Response>();
    var queried = false;
    final wallet = fixtures.controller(handler: (_) {
      queried = true;
      return response.future;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            KeyVault.channel,
            (call) async => call.method == 'list'
                ? [
                    {
                      'id': 'switch-key',
                      'address': fixtures.address,
                      'backup_type': 'wif'
                    }
                  ]
                : null);
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null));
    await wallet.initialize();
    wallet.address = 'dragon1qjctnj8237jyucklkscaghh92rfp6lcf9fuvx0c';
    wallet.endpoint = 'https://wallet.example.com';
    wallet.token = fixtures.token;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => KeyPage(wallet: wallet))),
                child: const Text('open')))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('切换'));
    await tester.tap(find.text('切换'));
    await tester.pumpAndSettle();
    expect(wallet.address, fixtures.address);
    expect(find.byType(KeyPage), findsNothing);
    expect(response.isCompleted, false);
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    expect(queried, true);
    response.complete(http.Response('{}', 503));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
  testWidgets('delete updates list only after success without rereading vault',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var deletionAttempted = false;
    var failDelete = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, (call) async {
      if (call.method == 'list') {
        if (deletionAttempted) throw PlatformException(code: 'unavailable');
        return [
          {'id': 'existing', 'address': fixtures.address, 'backup_type': 'wif'}
        ];
      }
      if (call.method == 'delete') {
        expect(call.arguments['id'], 'existing');
        deletionAttempted = true;
        if (failDelete) throw PlatformException(code: 'vault', message: '删除失败');
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null));
    final wallet = fixtures.controller();
    await wallet.initialize();
    await tester.pumpWidget(MaterialApp(home: KeyPage(wallet: wallet)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('删除'));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deletionAttempted, false);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已备份，删除'));
    await tester.pumpAndSettle();
    expect(find.text(fixtures.address), findsOneWidget);
    expect(find.text('删除失败'), findsOneWidget);
    failDelete = false;
    await tester.ensureVisible(find.text('删除'));
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已备份，删除'));
    await tester.pumpAndSettle();
    expect(find.text(fixtures.address), findsNothing);
    expect(find.text('本地密钥 · 0'), findsOneWidget);
    expect(find.text('尚未生成或导入私钥。'), findsOneWidget);
    expect(find.text('已删除本地私钥。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
  for (final mnemonic in [false, true]) {
    testWidgets(
        '${mnemonic ? 'mnemonic' : 'WIF'} generation shows returned key without rereading list',
        (tester) async {
      tester.view.physicalSize = const Size(400, 750);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var generated = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(KeyVault.channel, (call) async {
        if (call.method == 'list') {
          if (generated) throw PlatformException(code: 'unavailable');
          return <Map<String, String>>[];
        }
        if (call.method == (mnemonic ? 'generateMnemonic' : 'generate')) {
          generated = true;
          return {
            'id': 'new-key',
            'address': fixtures.address,
            'backup_type': mnemonic ? 'mnemonic' : 'wif',
          };
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(KeyVault.channel, null));
      final wallet = fixtures.controller();
      await wallet.initialize();
      await tester.pumpWidget(MaterialApp(home: KeyPage(wallet: wallet)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(mnemonic ? '生成助记词钱包' : '生成 WIF 钱包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(generated, true);
      expect(find.text('本地密钥 · 1'), findsOneWidget);
      expect(find.text(mnemonic ? '钱包1(助记词)' : '钱包1(wif)').hitTestable(),
          findsOneWidget);
      expect(find.text(fixtures.address), findsOneWidget);
      expect(find.text('本地密钥操作失败，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      wallet.dispose();
    });
    testWidgets(
        '${mnemonic ? 'mnemonic' : 'WIF'} naming, import, authenticated view and explicit copy',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      final keys = <Map<String, String>>[];
      final secret =
          mnemonic ? 'abandon ' * 11 + 'about' : 'synthetic-wif-' * 125;
      final importMethod = mnemonic ? 'importMnemonic' : 'import';
      final viewMethod = mnemonic ? 'viewMnemonic' : 'viewWif';
      final importLabel = mnemonic ? '导入助记词' : '导入 WIF 私钥';
      final viewLabel = mnemonic ? '助记词' : '私钥';
      var allowView = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(KeyVault.channel, (call) async {
        calls.add(call);
        if (call.method == 'list') return keys;
        if (call.method == importMethod) {
          expect(call.arguments, {mnemonic ? 'mnemonic' : 'wif': secret});
          final key = {
            'id': 'synthetic',
            'address': fixtures.address,
            'backup_type': mnemonic ? 'mnemonic' : 'wif'
          };
          keys.add(key);
          return key;
        }
        if (call.method == viewMethod) {
          if (!allowView) throw PlatformException(code: 'cancelled');
          return secret;
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(KeyVault.channel, null));
      final wallet = fixtures.controller();
      await wallet.initialize();
      await tester.pumpWidget(MaterialApp(home: KeyPage(wallet: wallet)));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('文件导入'), findsNothing);
      await tester.tap(find.text(importLabel));
      await tester.pumpAndSettle();
      expect(find.text('导入钱包名称'), findsOneWidget);
      expect(find.text('钱包1'), findsOneWidget);
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == importMethod), isEmpty);
      await tester.tap(find.text('导入钱包'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == importMethod), isEmpty);
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).obscureText, isTrue);
      await tester.enterText(field, secret);
      await tester.tap(find.text('导入钱包'));
      await tester.pumpAndSettle();
      expect(wallet.nameFor(fixtures.address), '钱包1');
      expect(wallet.address, isNull);
      expect(find.text(secret), findsNothing);
      expect(find.text(mnemonic ? '私钥' : '助记词'), findsNothing);
      expect(find.text(mnemonic ? '钱包1(助记词)' : '钱包1(wif)'), findsOneWidget);
      expect(find.textContaining('备份方式：'), findsNothing);
      await tester.ensureVisible(find.text(viewLabel));
      await tester.tap(find.text(viewLabel));
      await tester.pumpAndSettle();
      expect(find.text(secret), findsNothing);
      expect(find.text('操作已取消，可继续操作或返回钱包。'), findsOneWidget);
      allowView = true;
      await tester.ensureVisible(find.text(viewLabel));
      await tester.tap(find.text(viewLabel));
      await tester.pumpAndSettle();
      expect(find.text(secret), findsOneWidget);
      expect(calls.where((c) => c.method == 'copySecret'), isEmpty);
      await tester.tap(find.text('复制到剪贴板'));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'copySecret').single.arguments,
          {'text': secret});
      expect(find.text('已复制到剪贴板'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text(secret), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls.last.arguments, {'enabled': false});
      expect(
          calls.where((c) =>
              c.method.contains('File') || c.method.startsWith('export')),
          isEmpty);
      wallet.dispose();
    });
  }

  testWidgets(
      'cancel paste does not allocate name; background clears pasted input',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, (call) async {
      if (call.method == 'list') return <Map<String, String>>[];
      if (call.method == 'import') {
        fail('Cancelled import must not reach native vault');
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(KeyVault.channel, null));
    final wallet = fixtures.controller();
    await wallet.initialize();
    await tester.pumpWidget(MaterialApp(home: KeyPage(wallet: wallet)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导入 WIF 私钥'));
    await tester.tap(find.text('导入 WIF 私钥'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'synthetic-input');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(wallet.suggestedName, '钱包1');
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    wallet.dispose();
  });
}
