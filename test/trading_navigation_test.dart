import 'package:dragon_wallet/trading_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class TestWebPlatform extends WebViewPlatform {
  late TestWebController controller;

  @override
  PlatformWebViewController createPlatformWebViewController(
          PlatformWebViewControllerCreationParams params) =>
      controller = TestWebController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
          PlatformNavigationDelegateCreationParams params) =>
      TestNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
          PlatformWebViewWidgetCreationParams params) =>
      TestWebWidget(params);
}

class TestWebController extends PlatformWebViewController {
  TestWebController(super.params) : super.implementation();
  final channels = <String, JavaScriptChannelParams>{};
  late TestNavigationDelegate delegate;
  String url = 'https://exchange.example.com/';
  bool hasHistory = true;
  int backCalls = 0;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  @override
  Future<void> setBackgroundColor(Color color) async {}
  @override
  Future<void> setOnJavaScriptConfirmDialog(
      Future<bool> Function(JavaScriptConfirmDialogRequest) callback) async {}
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channels[params.name] = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
      PlatformNavigationDelegate handler) async {
    delegate = handler as TestNavigationDelegate;
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    url = params.uri.toString();
    delegate.finished?.call(url);
  }

  @override
  Future<void> runJavaScript(String script) async {}
  @override
  Future<String?> currentUrl() async => url;
  @override
  Future<bool> canGoBack() async => hasHistory;
  @override
  Future<void> goBack() async {
    backCalls++;
    url = 'https://exchange.example.com/trade';
  }
}

class TestNavigationDelegate extends PlatformNavigationDelegate {
  TestNavigationDelegate(super.params) : super.implementation();
  PageEventCallback? finished;
  @override
  Future<void> setOnNavigationRequest(
      NavigationRequestCallback callback) async {}
  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async {
    finished = callback;
  }

  @override
  Future<void> setOnProgress(ProgressCallback callback) async {}
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async {}
}

class TestWebWidget extends PlatformWebViewWidget {
  TestWebWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => TextButton(
      onPressed: () => (params.controller as TestWebController)
          .channels['WalletNavigation']!
          .onMessageReceived(const JavaScriptMessage(message: 'wallet')),
      child: const Text('Wallet icon'));
}

void main() {
  late TestWebPlatform platform;
  setUp(() {
    platform = TestWebPlatform();
    WebViewPlatform.instance = platform;
  });

  Future<void> openTrading(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const TradingPage(
                                serviceUrl: 'https://exchange.example.com'))),
                    child: const Text('Local wallet'))))));
    await tester.tap(find.text('Local wallet'));
    await tester.pumpAndSettle();
    expect(find.text('Wallet icon'), findsOneWidget);
  }

  for (final page in ['trade', 'deposit', 'withdraw', 'account', 'security']) {
    testWidgets('wallet icon exits $page despite web history', (tester) async {
      await openTrading(tester);
      platform.controller.url = 'https://exchange.example.com/$page';
      await tester.tap(find.text('Wallet icon'));
      await tester.pumpAndSettle();
      expect(find.text('Local wallet'), findsOneWidget);
      expect(find.byType(TradingPage), findsNothing);
      expect(platform.controller.backCalls, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('system back preserves web history navigation', (tester) async {
    await openTrading(tester);
    platform.controller.url = 'https://exchange.example.com/deposit';
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(platform.controller.backCalls, 1);
    expect(find.byType(TradingPage), findsOneWidget);
    platform.controller.hasHistory = false;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Local wallet'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('wallet bridge rejects a non-trading URL', (tester) async {
    await openTrading(tester);
    platform.controller.url = 'https://other.example/account';
    await tester.tap(find.text('Wallet icon'));
    await tester.pumpAndSettle();
    expect(find.byType(TradingPage), findsOneWidget);
    expect(platform.controller.backCalls, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
