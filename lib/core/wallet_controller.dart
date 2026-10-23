import 'app_language.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'address.dart';
import 'key_vault.dart';
import 'wallet_api.dart';
import 'wallet_panels.dart';

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
  late final WalletPanels panels = WalletPanels(api)
    ..addListener(_panelsChanged);
  Map<String, dynamic>? _lastBalance, _lastOutputs, _lastHistory;
  void _panelsChanged() {
    busy = panels.loading;
    final balance = panels.states['balance']!;
    error = balance.error;
    updatedAt = balance.updatedAt;
    final data = balance.data;
    final outputData = panels.states['utxo']!.data;
    final historyData = panels.states[_historyType]!.data;
    if (data != null &&
        address != null &&
        (data != _lastBalance ||
            outputData != _lastOutputs ||
            historyData != _lastHistory)) {
      _lastBalance = data;
      _lastOutputs = outputData;
      _lastHistory = historyData;
      // Compatibility view for native consumers; requests and native panels keep
      // independent page states and never wait for this aggregate.
      final outputs = panels.states['utxo']!.data?['items'] as List? ?? [];
      final history =
          panels.states[_historyType]!.data?['items'] as List? ?? [];
      snapshot = WalletSnapshot({
        ...data,
        'tip': data['index'],
        'utxos': outputs,
        'transactions': history,
        'utxos_truncated': data['utxo_count'] > outputs.length,
        'next_offset': null
      }, address!);
    }
    _notify();
  }

  WalletSnapshot? snapshot;
  String? error;
  DateTime? updatedAt;
  bool initializing = true;
  bool busy = false;
  bool _disposed = false;
  static const refreshOptions = [10, 30, 60, 1800, 0];
  int _refreshSeconds = 60;
  int get refreshSeconds => _refreshSeconds;

  Future<void> setRefreshSeconds(int seconds) async {
    if (!refreshOptions.contains(seconds)) {
      throw ArgumentError('Invalid refresh interval');
    }
    await store.write(jsonEncode({
      'address': address,
      'endpoint': endpoint,
      'watch_addresses': _savedAddresses,
      'refresh_seconds': seconds,
    }));
    if (_disposed) return;
    _refreshSeconds = seconds;
    _notify();
  }

  Timer? _refreshTimer;
  String? _timerKey;
  bool _active = true;
  bool _refreshPending = false;

  void setActive(bool active) {
    final resumed = active && !_active;
    _active = active;
    if (!active) _refreshPending = false;
    _syncRefreshTimer();
    if (resumed) unawaited(refresh());
  }

  void _syncRefreshTimer() {
    final key = !_disposed &&
            _active &&
            connected &&
            address != null &&
            _refreshSeconds > 0
        ? '$endpoint|$token|$address|$_refreshSeconds'
        : null;
    if (key == _timerKey) return;
    _refreshTimer?.cancel();
    _timerKey = key;
    if (key != null) {
      _refreshTimer = Timer.periodic(Duration(seconds: _refreshSeconds), (_) {
        unawaited(refresh());
      });
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
        final interval = config['refresh_seconds'];
        _refreshSeconds = interval is int && refreshOptions.contains(interval)
            ? interval
            : 60;
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
            'watch_addresses': _savedAddresses,
            'refresh_seconds': _refreshSeconds,
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
      'watch_addresses': savedAddresses,
      'refresh_seconds': _refreshSeconds,
    }));
    if (_disposed) {
      return;
    }
    _refreshPending = false;
    address = normalized;
    _savedAddresses = savedAddresses;
    endpoint = server;
    token = accessToken;
    snapshot = null;
    panels.configure(endpoint, token, address);
    updatedAt = null;
    error = null;
    busy = false;
    _notify();
    if (refreshOnSwitch && switchingAddress && connected) await refresh();
  }

  String _historyType = 'normal';
  String get historyType => _historyType;
  Future<void> setHistoryType(String type) async {
    if (type != 'normal' && type != 'mining') {
      throw ArgumentError('Invalid transaction type');
    }
    if (type == _historyType) return;
    _historyType = type;
    // Both history types already refresh independently; switching only changes
    // the visible list and preserves cached data and in-flight requests.
    _notify();
  }

  Future<void> refresh({bool more = false}) async {
    if (_disposed || !_active || address == null || !connected) return;
    panels.configure(endpoint, token, address);
    if (more) {
      await panels.load('normal', more: true);
    } else {
      await panels.refresh();
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
    await store.write(jsonEncode({
      'address': removingCurrent ? null : address,
      'endpoint': endpoint,
      'watch_addresses': remaining,
      'refresh_seconds': _refreshSeconds,
    }));
    if (_disposed) {
      return;
    }
    _savedAddresses = remaining;
    if (!removingCurrent) {
      _notify();
      return;
    }
    address = null;
    token = bundledToken;
    snapshot = null;
    panels.configure(endpoint, token, address);
    updatedAt = null;
    busy = false;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      _syncRefreshTimer();
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
    panels.dispose();
    _refreshTimer?.cancel();
    api.close();
    super.dispose();
  }
}
