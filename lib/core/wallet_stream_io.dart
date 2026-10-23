import 'dart:async';
import 'dart:convert';
import 'dart:io';

Stream<void> walletChanges(Uri uri, String token, String address) {
  WebSocket? socket;
  HttpClient? client;
  Timer? retry;
  StreamSubscription<dynamic>? subscription;
  var stopped = false;
  late StreamController<void> controller;
  Future<void> connect() async {
    if (stopped) return;
    try {
      final transport = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      client = transport;
      final ws = await WebSocket.connect(uri.toString(),
              headers: {
                'Authorization': 'Bearer $token',
                'X-Version': 'android/v1'
              },
              customClient: transport)
          .timeout(const Duration(seconds: 15));
      if (stopped) {
        await ws.close();
        return;
      }
      socket = ws;
      ws.pingInterval = const Duration(seconds: 25);
      ws.add(jsonEncode({
        'type': 'subscribe',
        'topics': ['address:$address']
      }));
      subscription = ws.listen((raw) {
        try {
          final event = jsonDecode(raw as String) as Map<String, dynamic>;
          if (event['type'] == 'ping') {
            ws.add(jsonEncode({'type': 'ping'}));
          } else if (event['type'] == 'subscribed' ||
              ((event['type'] == 'address.changed' ||
                      event['type'] == 'resync') &&
                  event['topic'] == 'address:$address')) {
            controller.add(null);
          }
        } catch (_) {
          ws.close();
        }
      }, onError: (Object _) {
        ws.close();
      }, onDone: () {
        socket = null;
        client?.close(force: true);
        client = null;
        if (!stopped) retry = Timer(const Duration(seconds: 5), connect);
      });
    } catch (_) {
      client?.close(force: true);
      client = null;
      if (!stopped) retry = Timer(const Duration(seconds: 5), connect);
    }
  }

  controller = StreamController<void>(
      onListen: connect,
      onCancel: () async {
        stopped = true;
        retry?.cancel();
        client?.close(force: true);
        await subscription?.cancel();
        await socket?.close();
      });
  return controller.stream;
}
