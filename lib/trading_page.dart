import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'core/app_language.dart';

const tradingServiceUrl = String.fromEnvironment('CEX_URL');

Uri? tradingOrigin(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  final local = {'127.0.0.1', 'localhost', '10.0.2.2'}.contains(uri.host);
  final configured = Uri.tryParse(tradingServiceUrl);
  final production = uri.scheme == 'http' &&
      configured?.scheme == 'http' &&
      configured?.userInfo == '' &&
      configured?.origin == uri.origin;
  if (uri.scheme != 'https' &&
      !(uri.scheme == 'http' && (local || production))) {
    return null;
  }
  return uri.replace(path: '/');
}

bool isTradingNavigation(Uri origin, String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.origin == origin.origin &&
      const {'/', '/trade', '/deposit', '/withdraw', '/account', '/security'}
          .contains(uri.path);
}

class TradingPage extends StatefulWidget {
  const TradingPage({super.key, this.serviceUrl = tradingServiceUrl});
  final String serviceUrl;

  @override
  State<TradingPage> createState() => _TradingPageState();
}

class _TradingPageState extends State<TradingPage> {
  WebViewController? _web;
  Uri? _origin;
  String? _error;
  int _progress = 0;
  Timer? _timeout;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _origin = tradingOrigin(widget.serviceUrl);
    if (_origin == null) {
      _error = '交易服务尚未配置';
    } else if (kIsWeb ||
        !{TargetPlatform.android, TargetPlatform.iOS}
            .contains(defaultTargetPlatform)) {
      _error = '请在 Android 或 iOS 设备打开交易';
    } else {
      unawaited(_initialize());
    }
  }

  Future<void> _initialize() async {
    try {
      final controller = WebViewController();
      _web = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xff0c1017));
      await controller.addJavaScriptChannel('WalletNavigation',
          onMessageReceived: (message) async {
        if (!mounted || message.message != 'wallet') return;
        final current = await controller.currentUrl();
        if (!mounted ||
            current == null ||
            !isTradingNavigation(_origin!, current)) {
          return;
        }
        _returnToWallet();
      });
      await controller.setOnJavaScriptConfirmDialog((request) async {
        if (!mounted) return false;
        return await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                      title: Text(tr('确认操作')),
                      content: SingleChildScrollView(
                          child: SelectableText(request.message)),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(tr('取消'))),
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(tr('确认')))
                      ],
                    )) ??
            false;
      });
      await controller.addJavaScriptChannel('CexClipboard',
          onMessageReceived: (message) async {
        if (!mounted || message.message.length > 8192) return;
        try {
          final current = await controller.currentUrl();
          if (current == null || !isTradingNavigation(_origin!, current)) {
            return;
          }
          final data = jsonDecode(message.message) as Map<String, dynamic>;
          final text = data['text'] as String;
          final id = data['id'] as int;
          if (text.length > 4096 || id < 0) return;
          await Clipboard.setData(ClipboardData(text: text));
          if (mounted) {
            await controller.runJavaScript('window.cexCopyDone?.($id);');
          }
        } catch (_) {
          /* The web promise times out and keeps its manual copy fallback. */
        }
      });
      await controller.setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) =>
            isTradingNavigation(_origin!, request.url)
                ? NavigationDecision.navigate
                : NavigationDecision.prevent,
        onPageStarted: (_) {
          if (!mounted) return;
          setState(() {
            _error = null;
            _progress = 0;
          });
          _timeout?.cancel();
          _timeout = Timer(const Duration(seconds: 25), () => _fail());
        },
        onProgress: (value) {
          if (mounted) setState(() => _progress = value);
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == true) _fail();
        },
        onHttpError: (error) {
          final uri = error.request?.uri;
          if (uri != null && isTradingNavigation(_origin!, uri.toString())) {
            _fail();
          }
        },
        onPageFinished: (_) async {
          _timeout?.cancel();
          if (!mounted || _error != null) return;
          try {
            final code = jsonEncode(AppLanguage.instance.code);
            await controller.runJavaScript("""
(() => {
 const selector=document.getElementById('language');
 if(selector){selector.value=$code;selector.dispatchEvent(new Event('change'));}
 const wallet=document.getElementById('wallet-switch');
 if(wallet){wallet.hidden=false;wallet.onclick=()=>WalletNavigation.postMessage('wallet');}
 if(window.cexCopyDone)return;
 let next=0;const pending=new Map();
 window.cexCopyDone=id=>{const done=pending.get(id);if(done){pending.delete(id);done();}};
 const writeText=text=>new Promise((resolve,reject)=>{
   const id=++next;const timer=setTimeout(()=>{pending.delete(id);reject(new Error('Clipboard unavailable'));},5000);
   pending.set(id,()=>{clearTimeout(timer);resolve();});
   CexClipboard.postMessage(JSON.stringify({id,text:String(text)}));
 });
 Object.defineProperty(navigator,'clipboard',{value:{writeText},configurable:true});
})();
""");
          } catch (_) {/* Browser clipboard remains the fallback. */}
          if (mounted) setState(() => _progress = 100);
        },
      ));
      if (!mounted) return;
      setState(() {});
      await _load();
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    _timeout?.cancel();
    if (mounted) setState(() => _error = '无法连接交易服务，请检查连接后重试');
  }

  Future<void> _load() async {
    if (_web == null || _origin == null) return;
    setState(() {
      _error = null;
      _progress = 0;
    });
    try {
      await _web!.loadRequest(_origin!);
    } catch (_) {
      _fail();
    }
  }

  Future<void> _back() async {
    if (_leaving) return;
    final web = _web;
    if (web != null && _error == null && await web.canGoBack()) {
      if (mounted && !_leaving) await web.goBack();
      return;
    }
    _returnToWallet();
  }

  void _returnToWallet() {
    if (!mounted || _leaving) return;
    _timeout?.cancel();
    // An explicit wallet switch exits the Flutter route, not WebView history.
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: _leaving || _web == null || _error != null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        body: SafeArea(
            child: _error != null
                ? Center(
                    child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.cloud_off_outlined, size: 48),
                      const SizedBox(height: 16),
                      Text(tr(_error!), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      if (_web != null)
                        FilledButton(onPressed: _load, child: Text(tr('重试'))),
                      TextButton(
                          onPressed: _returnToWallet, child: Text(tr('返回钱包'))),
                    ]),
                  ))
                : Stack(children: [
                    if (_web != null) WebViewWidget(controller: _web!),
                    if (_progress < 100)
                      LinearProgressIndicator(
                          value: _progress == 0 ? null : _progress / 100),
                  ])),
      ));
}
