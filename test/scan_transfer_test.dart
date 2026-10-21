import 'dart:convert';

import 'package:dragon_wallet/core/wallet_api.dart';
import 'package:dragon_wallet/core/key_vault.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/scan_transfer_page.dart';
import 'package:dragon_wallet/transfer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'wallet_test.dart' show MemoryStore, address, token;

void main() {
  testWidgets(
      'scan validates recipients, fills once, and never sends a transfer',
      (tester) async {
    var requests = 0;
    final wallet = WalletController(
      api: WalletApi(client: MockClient((request) async {
        requests++;
        expect(request.url.path.endsWith('/prepare'), isTrue);
        return http.Response(
            jsonEncode({
              'network': 'mainnet',
              'address': address,
              'utxos': [],
              'available_atomic': '100000000',
              'fee_rate': 1,
            }),
            200);
      })),
      store: MemoryStore(),
      namesStore: MemoryStore(),
    )
      ..address = address
      ..localKeys = [VaultKey({'id': 'scan-test-key', 'address': address})]
      ..endpoint = 'http://localhost:9999'
      ..token = token;
    await tester.pumpWidget(MaterialApp(
      home: TransferPage(wallet: wallet, pendingStore: MemoryStore()),
    ));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), address);
    await tester.enterText(find.byType(TextField).at(1), '0.5');
    await tester.tap(find.byTooltip('扫码转账'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final detect =
        tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!;
    detect(BarcodeCapture(barcodes: [
      const Barcode(
          rawValue: 'https://example.com', format: BarcodeFormat.qrCode),
    ]));
    await tester.pump();
    expect(find.text('无效的收款二维码，请扫描 Dragonchain 主网钱包'), findsOneWidget);
    const witness = 'dragon1qdd50l75jh64clmhlg5034z9y5tmmetr9mcy3nh';
    detect(BarcodeCapture(barcodes: [
      const Barcode(rawValue: address, format: BarcodeFormat.qrCode),
      const Barcode(rawValue: witness, format: BarcodeFormat.qrCode),
    ]));
    await tester.pump();
    expect(find.text('检测到多个收款钱包，请只对准一个二维码'), findsOneWidget);
    final valid = BarcodeCapture(barcodes: [
      Barcode(rawValue: witness.toUpperCase(), format: BarcodeFormat.qrCode),
    ]);
    detect(valid);
    detect(valid);
    await tester.pumpAndSettle();
    expect(find.byType(ScanTransferPage), findsNothing);
    expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        witness);
    expect(
        tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
        '0.5');
    expect(requests, 1);
    await tester.tap(find.byTooltip('扫码转账'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('返回手动填写'));
    await tester.pumpAndSettle();
    expect(
        tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text,
        witness);
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox());
    wallet.dispose();
  });
}
