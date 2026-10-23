import 'core/address.dart' show formatAmount;
import 'package:flutter/material.dart';
import 'core/app_language.dart';
import 'core/wallet_panels.dart';

class WalletPanelView extends StatelessWidget {
  const WalletPanelView({super.key, required this.panels, required this.kind});
  final WalletPanels panels;
  final String kind;

  String _time(DateTime value) {
    final date = value.toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${date.year}-${pad(date.month)}-${pad(date.day)} '
        '${pad(date.hour)}:${pad(date.minute)}:${pad(date.second)}';
  }

  String _blockTime(Map item) => item['time'] is int
      ? _time(DateTime.fromMillisecondsSinceEpoch((item['time'] as int) * 1000,
          isUtc: true))
      : '—';

  void _details(BuildContext context, Map<String, dynamic> item) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(tr(kind == 'utxo' ? '未花费输出' : '交易详情')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('${item['txid']}'),
              const SizedBox(height: 12),
              Text(tr('金额：{0}', [
                formatAmount(
                    BigInt.parse(
                        item[kind == 'utxo' ? 'value_atomic' : 'delta_atomic']
                            as String),
                    signed: kind != 'utxo')
              ])),
              if (item['vout'] != null) Text(tr('输出序号：{0}', [item['vout']])),
              if (kind == 'utxo') Text(tr('区块时间：{0}', [_blockTime(item)])),
              if (kind != 'utxo' && item['time'] != null)
                Text(_time(DateTime.fromMillisecondsSinceEpoch(
                    (item['time'] as int) * 1000))),
              Text(tr('确认数：{0}', [panels.confirmations(item)])),
              if (kind == 'normal') Text(tr('净变化包含此钱包的流入、流出和找零，不等同于交易总额。')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(tr('关闭'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([panels, AppLanguage.instance]),
        builder: (context, _) {
          final state = panels.states[kind]!;
          final data = state.data;
          final items = (data?['items'] as List?) ?? const [];
          final titles = {
            'balance': tr('已确认余额'),
            'utxo': tr('未花费输出'),
            'normal': tr('普通交易'),
            'mining': tr('挖矿奖励'),
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (kind == 'balance' || kind == 'utxo')
                Text(kind == 'utxo' ? tr('未花费输出（UTXO）') : titles[kind]!,
                    style: Theme.of(context).textTheme.titleMedium),
              if (kind == 'utxo') Text(tr('仅展示最新十条记录')),
              if (kind == 'mining') Text(tr('仅展示最近十条数据')),
              if (state.loading) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (state.error != null) ...[
                Text(state.error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                TextButton(
                  onPressed: state.loading ? null : () => panels.load(kind),
                  child: Text(tr('重试')),
                ),
              ],
              if (data == null && !state.loading && state.error == null)
                Text(tr('连接服务后查看钱包数据。')),
              if (state.updatedAt != null)
                Text(tr('更新于 {0}{1}', [_time(state.updatedAt!), '']),
                    style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              if (kind == 'balance') ...[
                SelectableText(
                  data == null
                      ? '—'
                      : formatAmount(
                          BigInt.parse(data['balance_atomic'] as String)),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const Text('Dragonchain'),
                const SizedBox(height: 16),
                if (data != null) ...[
                  const SizedBox(height: 8),
                  Text(tr('不含待确认交易；含尚未成熟的挖矿奖励。此数值不是可发送余额。')),
                ],
              ] else ...[
                if (data != null && items.isEmpty) Text(tr('暂无记录。')),
                for (final value in items)
                  Card(
                    child: ListTile(
                      leading: kind == 'utxo'
                          ? null
                          : Icon(
                              BigInt.parse(value['delta_atomic'] as String)
                                      .isNegative
                                  ? Icons.north_east
                                  : Icons.south_west,
                            ),
                      title: Text(formatAmount(
                        BigInt.parse(value[kind == 'utxo'
                            ? 'value_atomic'
                            : 'delta_atomic'] as String),
                        signed: kind != 'utxo',
                      )),
                      subtitle: Text(kind == 'utxo'
                          ? tr('{0} : {1}\n{2} 次确认{3}\n区块时间：{4}', [
                              _short(value['txid'] as String),
                              value['vout'],
                              panels.confirmations(value),
                              value['coinbase'] == 1 ? tr(' · 挖矿奖励') : '',
                              _blockTime(value),
                            ])
                          : tr('{0} · {1}\n{2} 次确认 · {3}', [
                              kind == 'mining' ? tr('挖矿奖励') : tr('普通交易'),
                              _short(value['txid'] as String),
                              panels.confirmations(value),
                              _time(DateTime.fromMillisecondsSinceEpoch(
                                  (value['time'] as int) * 1000,
                                  isUtc: true)),
                            ])),
                      isThreeLine: true,
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _details(
                          context, Map<String, dynamic>.from(value as Map)),
                    ),
                  ),
                if (kind == 'normal' && data?['next_cursor'] != null)
                  OutlinedButton(
                    onPressed: state.loading
                        ? null
                        : () => panels.load('normal', more: true),
                    child: Text(tr('加载更多')),
                  ),
              ],
            ],
          );
        },
      );
}

String _short(String value) => value.length <= 20
    ? value
    : '${value.substring(0, 10)}…${value.substring(value.length - 8)}';
