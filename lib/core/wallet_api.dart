import 'app_language.dart';
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'address.dart';
import 'wallet_stream.dart';

Uri validateEndpoint(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw FormatException(tr("请输入服务根地址，例如 https://wallet.example.com"));
  }
  const localHosts = ['localhost', '127.0.0.1', '::1', '10.0.2.2'];
  const configuredUrl = String.fromEnvironment('WALLET_API_URL');
  final configured = Uri.tryParse(configuredUrl);
  final deployedServer = uri.scheme == 'http' &&
      configured?.scheme == 'http' &&
      configured?.userInfo == '' &&
      configured?.origin == uri.origin;
  if (uri.scheme != 'https' &&
      !(uri.scheme == 'http' &&
          (localHosts.contains(uri.host) || deployedServer))) {
    throw FormatException(tr("远程服务必须使用 HTTPS"));
  }
  return uri.replace(path: '');
}

class WalletApiException implements Exception {
  const WalletApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WalletPageExpired implements Exception {
  const WalletPageExpired();
}

class WalletSnapshot {
  WalletSnapshot(Map<String, dynamic> json, String expectedAddress)
      : data = json {
    if (json['network'] != 'mainnet' ||
        json['address'] != expectedAddress ||
        json['balance_scope'] != 'confirmed_chain_only' ||
        json['mempool_included'] != false ||
        json['tip'] is! Map ||
        json['transactions'] is! List ||
        json['utxos'] is! List) {
      throw FormatException(tr("服务响应不符合主网观察钱包协议"));
    }
    balance = BigInt.parse(json['balance_atomic'] as String);
    if (balance.isNegative) {
      throw FormatException(tr("无效余额"));
    }
    if ((nextOffset ?? 0) < 0 ||
        json['utxo_count'] is! int ||
        (json['utxo_count'] as int) < 0 ||
        json['utxos_truncated'] is! bool) {
      throw FormatException(tr("无效的索引状态"));
    }
    for (final tx in transactions) {
      BigInt.parse(tx['delta_atomic'] as String);
      if ((tx['confirmations'] as int) < 1 ||
          (tx['txid'] as String).isEmpty ||
          (tx['time'] as int) < 0 ||
          (tx['time'] as int) > 253402300799) {
        throw FormatException(tr("无效的交易记录"));
      }
    }
    for (final utxo in utxos) {
      if (BigInt.parse(utxo['value_atomic'] as String).isNegative ||
          (utxo['confirmations'] as int) < 1 ||
          (utxo['txid'] as String).isEmpty ||
          (utxo['vout'] as int) < 0) {
        throw FormatException(tr("无效的未花费输出"));
      }
    }
  }
  final Map<String, dynamic> data;
  late final BigInt balance;
  String? get tipHash => (data['tip'] as Map)['hash'] as String?;
  int? get nextOffset => data['next_offset'] as int?;
  List<Map<String, dynamic>> get transactions =>
      (data['transactions'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get utxos =>
      (data['utxos'] as List).cast<Map<String, dynamic>>();
}

class WalletApi {
  WalletApi(
      {http.Client? client,
      Stream<void> Function(Uri, String, String)? streamFactory})
      : _client = client ?? http.Client(),
        _streamFactory = streamFactory ?? walletChanges;
  final Stream<void> Function(Uri, String, String) _streamFactory;
  final http.Client _client;
  Future<Map<String, dynamic>> transfer(String endpoint, String token,
      String action, Map<String, dynamic> body) async {
    try {
      final request = http.Request('POST',
          validateEndpoint(endpoint).replace(path: '/w/v1/transfers/$action'))
        ..followRedirects = false;
      request.headers.addAll({
        'Authorization': 'Bearer $token',
        'X-Version': 'android/v1',
        'Content-Type': 'application/json'
      });
      request.body = jsonEncode(body);
      final response =
          await _client.send(request).timeout(const Duration(minutes: 10));
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(minutes: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) {
          throw WalletApiException(tr("服务响应过大"));
        }
      }
      if (response.statusCode != 200) {
        throw WalletApiException(switch (response.statusCode) {
          401 => tr("访问令牌无效，请修改连接设置"),
          409 => action == 'prepare'
              ? tr("转账暂不可用，请稍后重试")
              : tr("输入已不可用，请核对交易是否已发送；不要重复创建转账"),
          422 => tr("节点未接受交易，请核对手续费与输入状态"),
          400 => tr("转账参数无效"),
          _ => tr("转账服务暂不可用（{0}）", [response.statusCode]),
        });
      }
      return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on TimeoutException {
      throw WalletApiException(tr("连接超时；若已签名，请重试同一笔交易"));
    } on http.ClientException {
      throw WalletApiException(tr("无法连接服务；若已签名，请重试同一笔交易"));
    } on FormatException {
      throw WalletApiException(tr("服务数据格式无效"));
    }
  }

  Future<Map<String, dynamic>> panel(
      String endpoint, String token, String address, String kind,
      {String? cursor}) async {
    if (!{'height', 'balance', 'utxo', 'normal', 'mining'}.contains(kind)) {
      throw ArgumentError('Invalid wallet page');
    }
    final normalized = normalizeAddress(address);
    final uri = validateEndpoint(endpoint).replace(
      path:
          '/w/v1/${kind == 'height' ? 'index/height' : kind == 'normal' || kind == 'mining' ? 'transfers' : kind}',
      queryParameters: {
        if (kind != 'height') 'address': normalized,
        if (kind == 'normal' || kind == 'mining') 'type': kind,
        if (cursor != null) 'cursor': cursor
      },
    );
    try {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers.addAll(
          {'Authorization': 'Bearer $token', 'X-Version': 'android/v1'});
      final response =
          await _client.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        if (response.statusCode == 409) throw const WalletPageExpired();
        throw WalletApiException(switch (response.statusCode) {
          401 => tr('访问令牌无效，请修改连接设置'),
          429 => tr('请求过于频繁，请稍后重试'),
          _ => tr('服务暂不可用（{0}）', [response.statusCode]),
        });
      }
      final bytes = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw WalletApiException(tr('服务响应过大'));
        }
      }
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (kind == 'height') {
        if (data['network'] != 'mainnet' ||
            data['height'] is! int ||
            data['height'] < 0 ||
            data['data_time'] is! int) {
          throw const FormatException('Invalid height');
        }
        return data;
      }
      if (data['network'] != 'mainnet' ||
          data['address'] != normalized ||
          data['index'] is! Map ||
          data['data_time'] is! int) {
        throw const FormatException('Invalid wallet page');
      }
      if (kind == 'balance') {
        if (BigInt.parse(data['balance_atomic'] as String).isNegative ||
            data['utxo_count'] is! int ||
            data['utxo_count'] < 0) {
          throw const FormatException('Invalid balance');
        }
      } else {
        final items = (data['items'] as List).cast<Map<String, dynamic>>();
        if (kind != 'normal' && items.length > 10) {
          throw const FormatException('Invalid page length');
        }
        for (final item in items) {
          if (item['txid'] is! String ||
              (item['txid'] as String).isEmpty ||
              item['height'] is! int ||
              item['height'] < 0 ||
              item['confirmations'] is! int ||
              item['confirmations'] < 1) {
            throw const FormatException('Invalid record');
          }
          final value = BigInt.parse(
              item[kind == 'utxo' ? 'value_atomic' : 'delta_atomic'] as String);
          if (kind == 'utxo' &&
              (value.isNegative || item['vout'] is! int || item['vout'] < 0)) {
            throw const FormatException('Invalid output');
          }
          if (kind != 'utxo' &&
              (item['time'] is! int ||
                  item['time'] < 0 ||
                  item['time'] > 253402300799)) {
            throw const FormatException('Invalid time');
          }
        }
        if (kind == 'normal' &&
            data['next_cursor'] != null &&
            data['next_cursor'] is! String) {
          throw const FormatException('Invalid cursor');
        }
      }
      return data;
    } on TimeoutException {
      throw WalletApiException(tr('连接超时，请检查网络后重试'));
    } on http.ClientException {
      throw WalletApiException(tr('无法连接服务，请检查网络和服务地址'));
    } on FormatException {
      throw WalletApiException(tr('服务返回的数据格式不正确'));
    } on TypeError {
      throw WalletApiException(tr('服务返回的数据不完整'));
    }
  }

  Future<WalletSnapshot> snapshot(
    String endpoint,
    String token,
    String address, {
    String historyType = 'normal',
    int offset = 0,
    int utxoOffset = 0,
    String? tip,
  }) async {
    final normalized = normalizeAddress(address);
    final uri = validateEndpoint(endpoint).replace(
      pathSegments: ['w', 'v1', 'addresses', normalized, 'snapshot'],
      queryParameters: {
        'ready': 'true',
        'history_type': historyType,
        'utxo_limit': '10',
        'limit': historyType == 'mining' ? '10' : '50',
        'offset': '$offset',
        if (utxoOffset > 0) 'utxo_offset': '$utxoOffset',
        if (tip != null) 'tip': tip,
      },
    );
    try {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['Authorization'] = 'Bearer $token';
      request.headers['X-Version'] = 'android/v1';
      final response =
          await _client.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        if (response.statusCode == 409) throw const WalletPageExpired();
        throw WalletApiException(switch (response.statusCode) {
          401 => tr("访问令牌无效，请修改连接设置"),
          429 => tr("请求过于频繁，请稍后重试"),
          _ => tr("服务暂不可用（{0}）", [response.statusCode]),
        });
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw WalletApiException(tr("服务响应过大"));
        }
      }
      return WalletSnapshot(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        normalized,
      );
    } on TimeoutException {
      throw WalletApiException(tr("连接超时，请检查网络后重试"));
    } on http.ClientException {
      throw WalletApiException(tr("无法连接服务，请检查网络和服务地址"));
    } on FormatException {
      throw WalletApiException(tr("服务返回的数据格式不正确"));
    } on TypeError {
      throw WalletApiException(tr("服务返回的数据不完整"));
    }
  }

  Stream<void> changes(String endpoint, String token, String address) {
    final base = validateEndpoint(endpoint);
    return _streamFactory(
        base.replace(
            scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/w/v1/ws'),
        token,
        address);
  }

  void close() => _client.close();
}
