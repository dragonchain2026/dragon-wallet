import 'package:dragon_wallet/core/app_language.dart';
import 'package:dragon_wallet/trading_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('trading URL permits HTTPS, local development and deployed origin', () {
    expect(tradingServiceUrl, isEmpty);
    expect(tradingOrigin(tradingServiceUrl), isNull);
    expect(tradingOrigin('https://exchange.example.com')?.port, 443);
    expect(tradingOrigin('http://127.0.0.1:8081')?.toString(),
        'http://127.0.0.1:8081/');
    expect(tradingOrigin('https://exchange.example')?.host, 'exchange.example');
    for (final value in [
      '',
      'http://remote.example',
      'file:///tmp/page',
      'https://user:pass@exchange.example',
      'https://exchange.example/?token=a',
      'https://exchange.example/admin',
      'javascript:alert(1)'
    ]) {
      expect(tradingOrigin(value), isNull, reason: value);
    }
    final origin = Uri.parse('http://127.0.0.1:8081/');
    expect(isTradingNavigation(origin, 'http://127.0.0.1:8081/'), isTrue);
    for (final route in [
      'trade',
      'deposit',
      'withdraw',
      'account',
      'security'
    ]) {
      expect(
          isTradingNavigation(origin, 'http://127.0.0.1:8081/$route'), isTrue);
    }
    for (final value in [
      'http://127.0.0.1:9999/',
      'https://other.example/',
      'http://127.0.0.1:8081/admin',
      'http://127.0.0.1:8081/assets/admin.html',
      'http://127.0.0.1:8081/%61dmin',
      'http://127.0.0.1:8081/v1/admin/verification-settings',
      'javascript:alert(1)',
      'data:text/html,test',
      '/relative'
    ]) {
      expect(isTradingNavigation(origin, value), isFalse, reason: value);
    }
  });

  testWidgets(
      'independent trading route can return to wallet when unconfigured',
      (tester) async {
    final original = AppLanguage.instance;
    AppLanguage.instance = AppLanguage()..apply('en');
    addTearDown(() => AppLanguage.instance = original);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const TradingPage(serviceUrl: ''))),
                    child: const Text('Open trading'))))));
    await tester.tap(find.text('Open trading'));
    await tester.pumpAndSettle();
    expect(find.text('Trading service is not configured'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    await tester.tap(find.text('Back to wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Open trading'), findsOneWidget);
  });
}
