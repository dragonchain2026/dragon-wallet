import 'package:flutter/material.dart';
import 'core/app_language.dart';
import 'core/address.dart';
import 'core/wallet_controller.dart';

class PendingBalance extends StatefulWidget {
  const PendingBalance({super.key, required this.wallet});
  final WalletController wallet;
  @override
  State<PendingBalance> createState() => _PendingBalanceState();
}

class _PendingBalanceState extends State<PendingBalance> {
  BigInt? amount;
  BigInt? immature;
  BigInt? transfers;
  bool busy = false;
  bool failed = false;
  Future<void> load() async {
    if (busy) return;
    final wallet = widget.wallet;
    setState(() {
      busy = true;
      failed = false;
      amount = null;
      immature = null;
      transfers = null;
    });
    try {
      if (!wallet.connected) throw StateError('offline');
      final data = await wallet.api.transfer(wallet.endpoint, wallet.token,
          'pending', {'address': wallet.address});
      if (data['network'] != 'mainnet' ||
          data['address'] != wallet.address ||
          data['scope'] != 'mempool_net_change') {
        throw const FormatException();
      }
      final transferValue = BigInt.parse(data['pending_atomic'] as String);
      final rewardValue = BigInt.parse(data['immature_atomic'] as String);
      final value = BigInt.parse(data['total_pending_atomic'] as String);
      if (rewardValue.isNegative || value != transferValue + rewardValue) {
        throw const FormatException();
      }
      if (mounted) {
        setState(() {
          amount = value;
          immature = rewardValue;
          transfers = transferValue;
        });
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text(tr('未确认余额'), style: const TextStyle(fontSize: 13)),
        onExpansionChanged: (expanded) {
          if (expanded) load();
        },
        children: [
          Row(children: [
            Expanded(
                child: Text(
                    busy
                        ? tr('查询中…')
                        : failed
                            ? tr('暂时无法查询')
                            : amount == null
                                ? '—'
                                : '${formatAmount(amount!)} Dragonchain',
                    style: const TextStyle(fontSize: 14))),
            IconButton(
                onPressed: busy ? null : load,
                tooltip: tr('刷新'),
                icon: const Icon(Icons.refresh, size: 18)),
          ]),
          if (amount != null) ...[
            Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('未成熟挖矿奖励：{0}', [formatAmount(immature!)]),
                    style: const TextStyle(fontSize: 12))),
            Align(
                alignment: Alignment.centerLeft,
                child: Text(tr('未确认转账净额：{0}', [formatAmount(transfers!)]),
                    style: const TextStyle(fontSize: 12))),
          ],
          Align(
              alignment: Alignment.centerLeft,
              child: Text(tr('合计包含未成熟挖矿奖励与未确认转账净额。挖矿奖励已计入上方链上余额，请勿重复相加。'),
                  style: const TextStyle(fontSize: 12))),
        ],
      );
}
