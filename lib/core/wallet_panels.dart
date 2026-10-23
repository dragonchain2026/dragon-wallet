import 'package:flutter/foundation.dart';
import 'app_language.dart';
import 'wallet_api.dart';

class WalletPanelState {
  Map<String, dynamic>? data;
  String? error;
  bool loading = false;
  DateTime? updatedAt;
  int serial = 0;
  bool queued = false;
}

// One coordinator, four independent request lifecycles. Credentials remain in
// Dart; each native view observes only its own display state.
class WalletPanels extends ChangeNotifier {
  WalletPanels(this.api);
  final WalletApi api;
  final states = {for (final kind in kinds) kind: WalletPanelState()};
  static const kinds = ['balance', 'utxo', 'normal', 'mining', 'height'];
  String endpoint = '', token = '', address = '';
  bool _disposed = false;
  int _epoch = 0;
  Object confirmations(Map item) {
    final height = states['height']!.data?['height'] as int?;
    final recordHeight = item['height'];
    if (height == null || recordHeight is! int) return '—';
    final count = (height - recordHeight).clamp(0, height);
    return count > 100 ? '>100' : count;
  }

  bool get loading => states.values.any((s) => s.loading);

  void configure(String newEndpoint, String newToken, String? newAddress) {
    if (endpoint == newEndpoint &&
        token == newToken &&
        address == (newAddress ?? '')) {
      return;
    }
    _epoch++;
    endpoint = newEndpoint;
    token = newToken;
    address = newAddress ?? '';
    for (final kind in kinds) {
      states[kind] = WalletPanelState();
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() => Future.wait(kinds.map((k) => load(k))).then((_) {});

  Future<void> load(String kind, {bool more = false}) async {
    if (_disposed || address.isEmpty || endpoint.isEmpty || token.isEmpty) {
      return;
    }
    final state = states[kind];
    if (state == null || (more && kind != 'normal')) return;
    if (state.loading) {
      if (!more) state.queued = true;
      return;
    }
    final cursor = more ? (state.data?['next_cursor'] as String?) : null;
    if (more && cursor == null) return;
    final epoch = _epoch, serial = ++state.serial;
    state.loading = true;
    state.error = null;
    notifyListeners();
    bool current() => !_disposed && epoch == _epoch && serial == state.serial;
    try {
      final data =
          await api.panel(endpoint, token, address, kind, cursor: cursor);
      if (!current()) return;
      // A full refresh requested during pagination wins over the old page.
      if (more && state.queued) return;
      state.data = more
          ? {
              ...data,
              'items': [
                ...state.data!['items'] as List,
                ...data['items'] as List
              ]
            }
          : data;
      state.updatedAt = DateTime.now();
    } catch (error) {
      if (!current()) return;
      if (error is WalletPageExpired && more) {
        state.queued = true;
      } else {
        state.error =
            error is WalletApiException ? error.message : tr('读取失败，请稍后重试');
      }
    } finally {
      if (current()) {
        state.loading = false;
        notifyListeners();
        if (state.queued) {
          state.queued = false;
          await load(kind);
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    super.dispose();
  }
}
