import 'dart:async';
import 'package:flutter/material.dart';
import 'core/app_language.dart';
import 'core/wallet_controller.dart';
import 'address_name_dialog.dart';

class WatchAddressesPage extends StatefulWidget {
  const WatchAddressesPage(
      {super.key, required this.wallet, required this.onAdd});
  final WalletController wallet;
  final Future<void> Function() onAdd;

  @override
  State<WatchAddressesPage> createState() => _WatchAddressesPageState();
}

class _WatchAddressesPageState extends State<WatchAddressesPage> {
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => error = tr('操作失败，请重试'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(String address) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(tr('移除观察钱包？')),
              content: Text(tr('仅删除本机观察记录，不影响链上资产。')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr('取消'))),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr('移除'))),
              ],
            ));
    if (confirmed == true) await widget.wallet.removeWatchAddress(address);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.wallet,
        builder: (context, _) => Scaffold(
          appBar: AppBar(title: Text(tr('观察钱包列表'))),
          body: ListView(padding: const EdgeInsets.all(20), children: [
            Text(tr('观察钱包仅支持查看余额、交易记录和收款，不能转账')),
            const SizedBox(height: 16),
            FilledButton.icon(
                onPressed: busy ? null : () => run(widget.onAdd),
                icon: const Icon(Icons.add),
                label: Text(tr('添加观察钱包'))),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Text(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (widget.wallet.watchAddresses.isEmpty)
              Padding(
                  padding: const EdgeInsets.all(24), child: Text(tr('暂无观察钱包'))),
            for (final address in widget.wallet.watchAddresses)
              Card(
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.wallet.nameFor(address),
                              style: Theme.of(context).textTheme.titleMedium),
                          SelectableText(address),
                          if (widget.wallet.address == address)
                            Text(tr('当前观察钱包')),
                          Wrap(spacing: 8, children: [
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => run(() async {
                                          await widget.wallet.configure(
                                              address,
                                              widget.wallet.endpoint,
                                              widget.wallet.token,
                                              refreshOnSwitch: false);
                                          if (!context.mounted) return;
                                          Navigator.of(context).pop();
                                          unawaited(widget.wallet.refresh());
                                        }),
                                child: Text(tr('切换'))),
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => run(() async {
                                          final name = await askAddressName(
                                              context,
                                              widget.wallet.nameFor(address));
                                          if (name != null) {
                                            await widget.wallet
                                                .renameAddress(address, name);
                                          }
                                        }),
                                child: Text(tr('修改钱包名称'))),
                            TextButton(
                                onPressed: busy
                                    ? null
                                    : () => run(() => remove(address)),
                                child: Text(tr('移除'))),
                          ]),
                        ],
                      ))),
          ]),
        ),
      );
}
