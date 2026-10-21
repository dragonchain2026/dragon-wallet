import 'app_language.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'address.dart';
import 'key_vault.dart';
import 'wallet_api.dart';

abstract interface class WalletStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class PreferencesWalletStore implements WalletStore {
  PreferencesWalletStore({String key = 'dragon.watchProfile.v1'}) : _key = key;
  final _preferences = SharedPreferencesAsync();
  final String _key;
  @override
  Future<String?> read() => _preferences.getString(_key);
  @override
  Future<void> write(String value) => _preferences.setString(_key, value);
  @override
  Future<void> clear() => _preferences.remove(_key);
}

class WalletController extends ChangeNotifier {
  WalletController(
      {required this.api, required this.store, WalletStore? namesStore})
      : namesStore =
            namesStore ?? PreferencesWalletStore(key: 'dragon.addressNames.v1');
  final WalletApi api;
  final WalletStore store;
  final WalletStore namesStore;
  Map<String, String> _names = {};
  int _nextName = 1;
  Future<void>? _namesLoaded;
  Future<void> _nameChanges = Future.value();
  String nameFor(String address) => _names[address] ?? tr("钱包");
  String get suggestedName {
    var number = _nextName;
    while (_names.containsValue(tr("钱包{0}", [number]))) {
      number++;
    }
    return tr("钱包{0}", [number]);
  }

  static String validateName(String input) {
    final value = input.trim();
    if (value.isEmpty ||
        value.runes.length > 32 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
      throw FormatException(tr("请输入 1–32 个字符的钱包名称"));
    }
    return value;
  }

  Future<void> loadNames() => _namesLoaded ??= (() async {
        final saved = await namesStore.read();
        if (saved != null) {
          final data = jsonDecode(saved) as Map<String, dynamic>;
          _names = (data['names'] as Map<String, dynamic>).map((key, value) =>
              MapEntry(normalizeAddress(key), validateName(value as String)));
          _nextName = data['next'] as int;
          if (_nextName < 1) _nextName = 1;
        }
      })();
  Future<void> ensureNames(Iterable<String> addresses, {String? name}) {
    final list = addresses.map(normalizeAddress).toList();
    final supplied = name == null ? null : validateName(name);
    if (supplied == null && list.every(_names.containsKey)) {
      return Future.value();
    }
    final operation = _nameChanges.then((_) async {
      await loadNames();
      final updated = Map<String, String>.from(_names);
      var next = _nextName;
      for (final value in list) {
        if (!updated.containsKey(value)) {
          while (updated.containsValue(tr("钱包{0}", [next]))) {
            next++;
          }
          updated[value] = supplied ?? tr("钱包{0}", [next]);
          next++;
        } else if (supplied != null) {
          updated[value] = supplied;
        }
      }
      if (mapEquals(updated, _names)) return;
      await namesStore.write(jsonEncode({'names': updated, 'next': next}));
      _names = updated;
      _nextName = next;
      _notify();
    });
    _nameChanges = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> renameAddress(String address, String name) =>
      ensureNames([address], name: name);
  String? address;
  List<String> _savedAddresses = [];
  List<String> get watchAddresses => List.unmodifiable(_savedAddresses
      .where((value) => !localKeys.any((key) => key.owns(value))));
  static const defaultEndpoint = String.fromEnvironment('WALLET_API_URL');
  String endpoint = defaultEndpoint;
  // Deployment token is supplied at build time, never saved to preferences.
  static const bundledToken = String.fromEnvironment('WALLET_API_TOKEN');
  String token = bundledToken;
  WalletSnapshot? snapshot;
  String? error;
  DateTime? updatedAt;
  bool initializing = true;
  bool busy = false;
  bool _disposed = false;
  int _request = 0;
  StreamSubscription<void>? _changes;
  String? _streamKey;
  bool _active = true;
  bool _refreshPending = false;

  void setActive(bool active) {
    _active = active;
    _syncStream();
  }

  void _syncStream() {
    final key = !_disposed && _active && connected && address != null
        ? '$endpoint|$token|$address'
        : null;
    if (key == _streamKey) return;
    _changes?.cancel();
    _changes = null;
    _streamKey = key;
    if (key != null) {
      _changes = api.changes(endpoint, token, address!).listen((_) {
        if (_disposed || _streamKey != key) return;
        if (busy) {
          _refreshPending = true;
        } else {
          unawaited(refresh());
        }
      }, onError: (Object _) {});
    }
  }

  List<VaultKey> localKeys = [];
  VaultKey? get selectedKey {
    for (final key in localKeys) {
      if (key.owns(address)) return key;
    }
    return null;
  }

  String get addressLabel => selectedKey == null ? tr("观察钱包") : tr("我的钱包");
  Future<void> refreshKeys() async {
    if (!KeyVault.supported || _disposed) return;
    try {
      final keys = await KeyVault().list();
      await ensureNames(keys.map((key) => key.address));
      if (!_disposed) localKeys = keys;
      if (!_disposed && address != null) {
        for (final key in keys) {
          if (key.legacyAddress == address && key.address != address) {
            await configure(key.address, endpoint, token);
            break;
          }
        }
      }
    } catch (_) {
      if (!_disposed) localKeys = [];
    }
    _notify();
  }

  bool get connected => endpoint.isNotEmpty && token.isNotEmpty;

  Future<void> initialize() async {
    try {
      await loadNames();
      final saved = await store.read();
      if (_disposed) {
        return;
      }
      if (saved != null) {
        final config = jsonDecode(saved) as Map<String, dynamic>;
        _savedAddresses = ((config['watch_addresses'] as List?) ?? [])
            .map((value) => normalizeAddress(value as String))
            .toSet()
            .toList();
        final savedAddress = config['address'] as String?;
        address = savedAddress == null || savedAddress.trim().isEmpty
            ? null
            : normalizeAddress(savedAddress);
        if (address != null) await ensureNames([address!]);
        if (address != null && !_savedAddresses.contains(address)) {
          _savedAddresses.add(address!);
        }
        endpoint = (config['endpoint'] as String? ?? '').trim();
        const deployedEndpoint = defaultEndpoint;
        const legacyUrls = String.fromEnvironment('WALLET_API_LEGACY_URLS');
        if (endpoint.isEmpty ||
            (deployedEndpoint.isNotEmpty &&
                legacyUrls
                    .split(',')
                    .contains(endpoint.replaceFirst(RegExp(r'/$'), '')))) {
          endpoint = deployedEndpoint;
          await store.write(jsonEncode({
            'address': address,
            'endpoint': endpoint,
            'watch_addresses': _savedAddresses
          }));
        }
        if (endpoint.isNotEmpty) {
          validateEndpoint(endpoint);
        }
      }
    } catch (_) {
      address = null;
      _savedAddresses = [];
      endpoint = defaultEndpoint;
      error = tr("无法读取本地设置，请重新导入观察钱包");
    } finally {
      await refreshKeys();
      initializing = false;
      _notify();
      if (connected && address != null && snapshot == null) await refresh();
    }
  }

  Future<void> configure(
      String inputAddress, String inputEndpoint, String inputToken,
      {String? name, bool refreshOnSwitch = true}) async {
    final normalized =
        inputAddress.trim().isEmpty ? null : normalizeAddress(inputAddress);
    final switchingAddress = address != null && address != normalized;
    final server = inputEndpoint.trim().isEmpty
        ? defaultEndpoint
        : validateEndpoint(inputEndpoint).toString();
    final accessToken = inputToken.trim();
    if (accessToken.isNotEmpty &&
        !RegExp(r'^[\x21-\x7e]{32,}$').hasMatch(accessToken)) {
      throw FormatException(tr("访问令牌至少需要 32 个非空白 ASCII 字符"));
    }
    if (normalized != null) await ensureNames([normalized], name: name);
    final savedAddresses = [..._savedAddresses];
    if (normalized != null && !savedAddresses.contains(normalized)) {
      savedAddresses.add(normalized);
    }
    await store.write(jsonEncode({
      'address': normalized,
      'endpoint': server,
      'watch_addresses': savedAddresses
    }));
    if (_disposed) {
      return;
    }
    _request++;
    address = normalized;
    _savedAddresses = savedAddresses;
    endpoint = server;
    token = accessToken;
    snapshot = null;
    updatedAt = null;
    error = null;
    busy = false;
    _notify();
    if (refreshOnSwitch && switchingAddress && connected) await refresh();
  }

  Set<String> _historyTypes = {'normal'};
  Set<String> get historyTypes => Set.unmodifiable(_historyTypes);
  Future<void> setHistoryTypes(Set<String> types) async {
    if (types.any((type) => type != 'normal' && type != 'mining')) {
      throw ArgumentError('Invalid transaction type');
    }
    if (setEquals(types, _historyTypes)) return;
    _historyTypes = Set.of(types);
    _request++;
    busy = false;
    if (snapshot != null) {
      snapshot = WalletSnapshot({
        ...snapshot!.data,
        'transactions': <Map<String, dynamic>>[],
        'next_offset': null,
        'transaction_count': 0
      }, address!);
    }
    _notify();
  }

  Future<void> loadMoreUtxos() async {
    final previous = snapshot;
    if (_disposed ||
        busy ||
        previous == null ||
        previous.data['utxos_truncated'] != true ||
        !connected) {
      return;
    }
    final request = ++_request;
    final requestedAddress = address!;
    busy = true;
    error = null;
    _notify();
    try {
      final page = await api.snapshot(endpoint, token, requestedAddress,
          utxoOffset: previous.utxos.length,
          tip: previous.tipHash,
          types: _historyTypes);
      if (_disposed || request != _request) return;
      if (page.tipHash != previous.tipHash || page.utxos.isEmpty) {
        throw WalletApiException(tr('区块链已更新，请刷新后再加载历史'));
      }
      snapshot = WalletSnapshot({
        ...previous.data,
        'utxos': [...previous.utxos, ...page.utxos],
        'utxos_truncated': page.data['utxos_truncated'],
      }, requestedAddress);
    } catch (e) {
      if (!_disposed && request == _request) {
        error = e is WalletApiException ? e.message : tr('读取失败，请稍后重试');
      }
    } finally {
      if (!_disposed && request == _request) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> refresh({bool more = false}) async {
    if (_disposed || busy || address == null || !connected) {
      return;
    }
    final previous = snapshot;
    if (more && previous?.nextOffset == null) {
      return;
    }
    final request = ++_request;
    busy = true;
    error = null;
    _notify();
    try {
      final result = await api.snapshot(
        endpoint,
        token,
        address!,
        offset: more ? previous!.nextOffset! : 0,
        tip: more ? previous!.tipHash : null,
        types: _historyTypes,
      );
      if (_disposed || request != _request) {
        return;
      }
      snapshot = more
          ? WalletSnapshot({
              ...result.data,
              'transactions': [
                ...previous!.transactions,
                ...result.transactions,
              ],
            }, address!)
          : result;
      if (previous != null &&
          previous.tipHash == result.tipHash &&
          previous.utxos.length > result.utxos.length) {
        snapshot = WalletSnapshot({
          ...snapshot!.data,
          'utxos': previous.utxos,
          'utxos_truncated': previous.data['utxos_truncated']
        }, address!);
      }
      updatedAt = DateTime.now();
    } catch (exception) {
      if (_disposed || request != _request) {
        return;
      }
      error = exception is WalletApiException
          ? exception.message
          : tr("读取失败，请稍后重试");
    } finally {
      if (!_disposed && request == _request) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> forget() async {
    if (address != null) {
      await removeWatchAddress(address!);
      return;
    }
  }

  Future<void> removeWatchAddress(String value) async {
    final remaining = _savedAddresses.where((item) => item != value).toList();
    final removingCurrent = address == value;
    if (remaining.isEmpty && removingCurrent) {
      await store.clear();
    } else {
      await store.write(jsonEncode({
        'address': removingCurrent ? null : address,
        'endpoint': endpoint,
        'watch_addresses': remaining,
      }));
    }
    if (_disposed) {
      return;
    }
    _savedAddresses = remaining;
    if (!removingCurrent) {
      _notify();
      return;
    }
    _request++;
    address = null;
    token = bundledToken;
    snapshot = null;
    updatedAt = null;
    busy = false;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      _syncStream();
      notifyListeners();
      if (!busy && _refreshPending) {
        _refreshPending = false;
        scheduleMicrotask(() => refresh());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    _changes?.cancel();
    api.close();
    super.dispose();
  }
}
