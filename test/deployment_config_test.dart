import 'dart:convert';
import 'package:dragon_wallet/core/wallet_api.dart';
import 'package:dragon_wallet/core/wallet_controller.dart';
import 'package:dragon_wallet/trading_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'wallet_test.dart' as fixtures;

void main() {
  test('injected HTTP origins allow only their exact service and port', () {
    if (WalletController.defaultEndpoint.isEmpty || tradingServiceUrl.isEmpty) {
      expect(() => validateEndpoint('http://wallet.example.com:9999'),
          throwsFormatException);
      expect(tradingOrigin('http://exchange.example.com'), isNull);
      return;
    }
    expect(validateEndpoint(WalletController.defaultEndpoint).toString(),
        WalletController.defaultEndpoint);
    expect(tradingOrigin(tradingServiceUrl)?.origin, tradingServiceUrl);
    expect(() => validateEndpoint('http://wallet.example.com:9998'),
        throwsFormatException);
    expect(
        () => validateEndpoint('http://wallet.example.com.evil.example:9999'),
        throwsFormatException);
    expect(tradingOrigin('http://exchange.example.com:8081'), isNull);
    expect(tradingOrigin('http://exchange.example.com.evil.example'), isNull);
  });
  test('injected aliases migrate settings while custom URLs remain', () async {
    const aliases = String.fromEnvironment('WALLET_API_LEGACY_URLS');
    if (aliases.isEmpty) return;
    for (final saved in [...aliases.split(','), 'https://custom.example.com']) {
      final store = fixtures.MemoryStore()
        ..value = jsonEncode({'address': null, 'endpoint': saved});
      final wallet = fixtures.controller(store: store);
      await wallet.initialize();
      expect(
          wallet.endpoint,
          saved == 'https://custom.example.com'
              ? saved
              : WalletController.defaultEndpoint);
      expect(wallet.error, isNull);
      wallet.dispose();
    }
  });
}
