import 'core/app_language.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'core/address.dart';
import 'core/wallet_api.dart';
import 'core/wallet_controller.dart';
import 'core/key_vault.dart';
import 'key_page.dart';
import 'transfer_page.dart';
import 'trading_page.dart';
import 'watch_addresses_page.dart';
import 'address_name_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLanguage.instance.initialize();
  runApp(const DragonWalletApp());
}

class DragonWalletApp extends StatefulWidget {
  const DragonWalletApp({super.key, this.controller});
  final WalletController? controller;
  @override
  State<DragonWalletApp> createState() => _DragonWalletAppState();
}

class _DragonWalletAppState extends State<DragonWalletApp> {
  late final WalletController controller;
  @override
  void initState() {
    super.initState();
    controller = widget.controller ??
        WalletController(api: WalletApi(), store: PreferencesWalletStore());
    unawaited(controller.initialize());
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: AppLanguage.instance,
      builder: (context, _) => MaterialApp(
            locale: Locale(AppLanguage.instance.code),
            supportedLocales: const [Locale("en"), Locale("zh")],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            title: 'Dragon Wallet',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              useMaterial3: true,
              colorScheme:
                  ColorScheme.fromSeed(seedColor: const Color(0xffb44b29)),
              scaffoldBackgroundColor: const Color(0xfffaf8f4),
              inputDecorationTheme: const InputDecorationTheme(
                border: OutlineInputBorder(),
              ),
            ),
            home: WalletHome(controller: controller),
          ));
}

class WalletHome extends StatefulWidget {
  const WalletHome({super.key, required this.controller});
  final WalletController controller;
  @override
  State<WalletHome> createState() => _WalletHomeState();
}

class _WalletHomeState extends State<WalletHome> with WidgetsBindingObserver {
  int tab = 0;
  int _utxoLimit = 10;
  String? _utxoAddress;
  WalletController get wallet => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    wallet.setActive(true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    wallet.setActive(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(wallet.refreshKeys());
    }
  }

  @override
  void dispose() {
    wallet.setActive(false);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> configure() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ImportPage(controller: wallet)),
    );
    if (mounted) {
      setState(() => tab = 0);
    }
  }

  Future<void> manageWatchAddresses() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (listContext) => WatchAddressesPage(
        wallet: wallet,
        onAdd: () async {
          await Navigator.of(listContext).push(MaterialPageRoute<void>(
            builder: (_) => ImportPage(controller: wallet, newWatch: true),
          ));
        },
      ),
    ));
    if (mounted) setState(() => tab = 0);
  }

  Future<void> openTrading() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TradingPage()),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(tr('已切换回钱包'))));
  }

  Future<void> manageKeys() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => KeyPage(wallet: wallet),
    ));
    await wallet.refreshKeys();
    if (mounted) setState(() => tab = 0);
  }

  Future<void> copy(String value, String label) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr("{0}已复制", [label]))));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr("无法复制，请长按文本手动复制"))));
      }
    }
  }

  Future<void> transfer() async {
    await wallet.refreshKeys();
    if (!mounted) return;
    if (wallet.selectedKey == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr("此为观察钱包，请先导入对应私钥再转账"))));
      return;
    }
    if (!wallet.connected) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr("请先配置本地 Wallet API 连接"))));
      return;
    }
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => TransferPage(wallet: wallet)));
    await wallet.refreshKeys();
  }

  Future<void> renameCurrentAddress() async {
    final address = wallet.address!;
    final name = await askAddressName(context, wallet.nameFor(address),
        title: tr("修改钱包名称"));
    if (name == null || !mounted) return;
    try {
      await wallet.renameAddress(address, name);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr("名称保存失败，请重试"))));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: wallet,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            title: Image.asset(
              'assets/dragon.png',
              width: 40,
              height: 40,
              cacheWidth: 160,
              semanticLabel: 'Dragon Wallet',
            ),
            actions: [
              Tooltip(
                message: tr('切换到交易页面'),
                child: ActionChip(
                  avatar: const Icon(Icons.swap_horiz, size: 18),
                  label: Text(tr('主网')),
                  onPressed: openTrading,
                ),
              ),
              IconButton(
                onPressed: wallet.initializing ||
                        wallet.busy ||
                        !wallet.connected ||
                        wallet.address == null
                    ? null
                    : wallet.refresh,
                icon: const Icon(Icons.refresh),
                tooltip: tr("刷新"),
              ),
              if (KeyVault.supported)
                IconButton(
                    onPressed: wallet.initializing ? null : manageKeys,
                    icon: const Icon(Icons.key_outlined),
                    tooltip: tr("本地钱包与私钥")),
              IconButton(
                onPressed: wallet.initializing ? null : configure,
                icon: const Icon(Icons.settings_outlined),
                tooltip: tr("连接与钱包设置"),
              ),
              IconButton(
                onPressed: () => copy('https://t.me/dragonchaincn', 'Telegram'),
                icon: const Icon(Icons.telegram, size: 22),
                tooltip: tr('复制 Telegram 链接'),
              ),
            ],
          ),
          body: wallet.initializing
              ? const Center(child: CircularProgressIndicator())
              : wallet.address == null
                  ? welcome()
                  : Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.all(20),
                          children: [
                            if (wallet.busy) const LinearProgressIndicator(),
                            if (wallet.error != null) notice(wallet.error!),
                            if (!wallet.connected)
                              notice(
                                tr("收款钱包已保存在本机。连接服务后可查询余额与历史。"),
                                TextButton(
                                  onPressed: configure,
                                  child: Text(tr("连接服务")),
                                ),
                              ),
                            if (wallet.snapshot != null &&
                                !wallet.snapshot!.synced)
                              notice(
                                tr(
                                    "索引正在同步或节点暂不可用。下方为部分数据，不能代表完整余额。\n已索引 {0} / {1} 个区块",
                                    [
                                      wallet.snapshot!.height,
                                      wallet.snapshot!.nodeHeight ?? tr("未知")
                                    ]),
                              ),
                            if (tab == 0) ...overview(),
                            if (tab == 1) ...receive(),
                            if (tab == 2) ...history(),
                          ],
                        ),
                      ),
                    ),
          bottomNavigationBar: wallet.address == null
              ? null
              : NavigationBar(
                  selectedIndex: tab,
                  onDestinationSelected: (value) => setState(() => tab = value),
                  destinations: [
                    NavigationDestination(
                      icon: Icon(Icons.account_balance_wallet_outlined),
                      label: tr("资产"),
                    ),
                    NavigationDestination(
                        icon: Icon(Icons.qr_code), label: tr("收款")),
                    NavigationDestination(
                      icon: Icon(Icons.receipt_long_outlined),
                      label: tr("记录"),
                    ),
                  ],
                ),
        ),
      );

  Widget welcome() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.account_balance_wallet_outlined, size: 64),
                const SizedBox(height: 28),
                Text(
                  tr("你的钱包，\n一目了然。"),
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 16),
                Text(tr("导入 Dragonchain 主网钱包，查看余额、收款和交易记录。无需私钥或助记词。")),
                const SizedBox(height: 16),
                Text(tr("观察钱包不控制资产。请导入你自己持有私钥的钱包用于收款。")),
                if (wallet.error != null) notice(wallet.error!),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: configure,
                  icon: const Icon(Icons.add),
                  label: Text(tr("导入观察钱包")),
                ),
                if (KeyVault.supported) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                      onPressed: manageKeys,
                      icon: const Icon(Icons.key_outlined),
                      label: Text(tr("生成钱包 / 导入私钥"))),
                ],
                TextButton.icon(
                  onPressed: manageWatchAddresses,
                  icon: const Icon(Icons.list_alt),
                  label: Text(tr('观察钱包列表')),
                ),
              ],
            ),
          ),
        ),
      );

  Widget notice(String text, [Widget? action]) => Card(
        color: Theme.of(context).colorScheme.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(text), if (action != null) action],
          ),
        ),
      );

  List<Widget> overview() {
    final state = wallet.snapshot;
    return [
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(state != null && !state.synced
                  ? tr("已索引余额（同步中）")
                  : tr("已确认余额")),
              const SizedBox(height: 12),
              SelectableText(
                state == null ? '—' : formatAmount(state.balance),
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const Text('Dragonchain'),
              const SizedBox(height: 16),
              Text(
                tr("不含待确认交易；含尚未成熟的挖矿奖励。此数值不是可发送余额。"),
                style: TextStyle(fontSize: 12),
              ),
              if (wallet.updatedAt != null)
                Text(
                  tr("更新于 {0}{1}", [
                    _time(wallet.updatedAt!),
                    wallet.error == null ? '' : tr(" · 数据可能已过期")
                  ]),
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: () => setState(() => tab = 1),
                    icon: const Icon(Icons.south_west),
                    label: Text(tr("收款")),
                  ),
                  OutlinedButton.icon(
                    onPressed: wallet.selectedKey == null ? null : transfer,
                    icon: const Icon(Icons.north_east),
                    label: Text(tr("转账")),
                  ),
                ],
              ),
              if (wallet.selectedKey == null) ...[
                const SizedBox(height: 8),
                Text(tr('观察钱包仅支持查看余额、交易记录和收款，不能转账')),
              ],
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
            child: Text(
                wallet.selectedKey == null
                    ? tr('{0}(观察)', [wallet.nameFor(wallet.address!)])
                    : wallet.nameFor(wallet.address!),
                style: Theme.of(context).textTheme.titleLarge)),
        IconButton(
            onPressed: renameCurrentAddress,
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr("修改钱包名称"))
      ]),
      const SizedBox(height: 8),
      SelectableText(wallet.address!),
      Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: manageWatchAddresses,
                icon: const Icon(Icons.list_alt),
                label: Text(tr('观察钱包列表')),
              ),
            ),
          ),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => copy(wallet.address!, tr("钱包")),
                icon: const Icon(Icons.copy, size: 16),
                label: Text(tr("复制钱包")),
              ),
            ),
          ),
        ],
      ),
      const Divider(height: 32),
      Text(
        tr("未花费输出（UTXO） · {0}", [state?.data['utxo_count'] ?? '—']),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (state == null)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text(tr("连接服务后显示链上数据")),
        ),
      if (state != null && state.utxos.isEmpty)
        Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text(tr("当前索引中没有未花费输出")),
        ),
      if (state != null)
        for (final output in state.utxos
            .take(_utxoAddress == wallet.address ? _utxoLimit : 10))
          Card(
            child: ListTile(
              title: Text(
                formatAmount(BigInt.parse(output['value_atomic'] as String)),
              ),
              subtitle: Text(
                tr("{0} : {1}\n{2} 次确认{3}", [
                  _short(output['txid'] as String),
                  output['vout'],
                  output['confirmations'],
                  output['coinbase'] == 1 ? tr(" · 挖矿奖励") : ''
                ]),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => details(tr("未花费输出"), output),
            ),
          ),
      if (state != null &&
          (state.utxos.length >
                  (_utxoAddress == wallet.address ? _utxoLimit : 10) ||
              state.data['utxos_truncated'] == true))
        TextButton(
            onPressed: wallet.busy
                ? null
                : () async {
                    final currentAddress = wallet.address;
                    final limit =
                        _utxoAddress == currentAddress ? _utxoLimit : 10;
                    if (state.utxos.length <= limit) {
                      await wallet.loadMoreUtxos();
                    }
                    if (!mounted ||
                        currentAddress != wallet.address ||
                        wallet.error != null) {
                      return;
                    }
                    setState(() {
                      _utxoLimit =
                          (_utxoAddress == wallet.address ? _utxoLimit : 10) +
                              10;
                      _utxoAddress = wallet.address;
                    });
                  },
            child: Text(tr("再显示 10 个 UTXO"))),
    ];
  }

  List<Widget> receive() => [
        Text(tr("收款"), style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(tr("仅接收 Dragonchain 主网资产")),
        Text(wallet.nameFor(wallet.address!)),
        const SizedBox(height: 24),
        Center(
          child: Semantics(
            label: tr("收款钱包二维码"),
            image: true,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(16),
              child: QrImageView(data: wallet.address!, size: 240),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SelectableText(wallet.address!, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => copy(wallet.address!, tr("钱包")),
          icon: const Icon(Icons.copy),
          label: Text(tr("复制收款钱包")),
        ),
        const SizedBox(height: 16),
        Text(wallet.selectedKey == null
            ? tr("本机没有对应私钥，只能查看和收款。")
            : tr("本机保存了对应私钥，请妥善备份。")),
      ];

  List<Widget> history() {
    final state = wallet.snapshot;
    final transactions = state?.transactions
            .where((tx) => wallet.historyTypes
                .contains(tx['coinbase'] == 1 ? 'mining' : 'normal'))
            .toList() ??
        [];
    return [
      Text(tr("交易记录"), style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      Text(tr("仅显示已确认交易，金额为此钱包的净变化。")),
      Wrap(spacing: 8, children: [
        for (final type in {'normal': tr("普通交易"), 'mining': tr("挖矿奖励")}.entries)
          FilterChip(
              label: Text(type.value),
              selected: wallet.historyTypes.contains(type.key),
              onSelected: (selected) {
                final types = wallet.historyTypes.toSet();
                if (selected) {
                  types.add(type.key);
                } else {
                  types.remove(type.key);
                }
                unawaited(wallet.setHistoryTypes(types));
              }),
      ]),
      Text(tr("时间按设备本地时区显示")),
      const SizedBox(height: 16),
      if (state == null) Text(tr("连接服务后查看交易记录")),
      if (wallet.historyTypes.isEmpty) Text(tr("请勾选要显示的交易类型")),
      if (state != null &&
          transactions.isEmpty &&
          wallet.historyTypes.isNotEmpty &&
          !wallet.busy)
        Text(tr("当前筛选下暂无交易记录")),
      if (state != null)
        for (final tx in transactions)
          Card(
            child: ListTile(
              leading: Icon(
                BigInt.parse(tx['delta_atomic'] as String).isNegative
                    ? Icons.north_east
                    : Icons.south_west,
              ),
              title: Text(
                formatAmount(
                  BigInt.parse(tx['delta_atomic'] as String),
                  signed: true,
                ),
              ),
              subtitle: Text(
                tr("{0} · {1}\n{2} 次确认 · {3}", [
                  tx['coinbase'] == 1 ? tr("挖矿奖励") : tr("普通交易"),
                  _short(tx['txid'] as String),
                  tx['confirmations'],
                  _time(DateTime.fromMillisecondsSinceEpoch(
                      (tx['time'] as int) * 1000,
                      isUtc: true))
                ]),
              ),
              isThreeLine: true,
              onTap: () => details(tr("交易详情"), tx),
            ),
          ),
      if (state?.nextOffset != null)
        OutlinedButton(
          onPressed: wallet.busy ? null : () => wallet.refresh(more: true),
          child: Text(tr("加载更多")),
        ),
    ];
  }

  Future<void> details(
    String title,
    Map<String, dynamic> data,
  ) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 16),
                Text(tr("交易 ID")),
                SelectableText(data['txid'] as String),
                TextButton(
                  onPressed: () => copy(data['txid'] as String, tr("交易 ID")),
                  child: Text(tr("复制交易 ID")),
                ),
                Text(tr("区块高度：{0}", [data['height']])),
                Text(tr("确认数：{0}", [data['confirmations']])),
                if (data['time'] is int)
                  Text(tr("时间：{0}", [
                    _time(DateTime.fromMillisecondsSinceEpoch(
                        (data['time'] as int) * 1000,
                        isUtc: true))
                  ])),
                if (data.containsKey('vout'))
                  Text(tr("输出序号：{0}", [data['vout']])),
                Text(
                  tr("金额：{0}", [
                    formatAmount(
                        BigInt.parse((data['delta_atomic'] ??
                            data['value_atomic']) as String),
                        signed: data.containsKey('delta_atomic'))
                  ]),
                ),
                if (data.containsKey('delta_atomic'))
                  Text(tr("净变化包含此钱包的流入、流出和找零，不等同于交易总额。")),
              ],
            ),
          ),
        ),
      );
}

String _short(String value) => value.length <= 20
    ? value
    : '${value.substring(0, 10)}…${value.substring(value.length - 8)}';
String _time(DateTime date) {
  final local = date.toLocal();
  String pad(int value) => value.toString().padLeft(2, '0');
  final year = local.year == DateTime.now().year ? '' : '${local.year}-';
  return '$year${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}:${pad(local.second)}';
}

class ImportPage extends StatefulWidget {
  const ImportPage(
      {super.key, required this.controller, this.newWatch = false});
  final bool newWatch;
  final WalletController controller;
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _address, _endpoint, _name;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _address = TextEditingController(
        text: widget.newWatch ? '' : widget.controller.address);
    _endpoint = TextEditingController(text: widget.controller.endpoint);
    _name = TextEditingController(
        text: widget.newWatch || widget.controller.address == null
            ? widget.controller.suggestedName
            : widget.controller.nameFor(widget.controller.address!));
  }

  @override
  void dispose() {
    _address.dispose();
    _endpoint.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.configure(
        _address.text,
        _endpoint.text,
        WalletController.bundledToken,
        name: _name.text,
        refreshOnSwitch: false,
      );
      if (mounted) {
        Navigator.pop(context);
        unawaited(widget.controller.refresh());
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is FormatException ? error.message : tr("保存失败，请重试");
        });
      }
    }
  }

  Future<void> forget() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr("移除观察钱包？")),
        content: Text(tr("仅删除本机观察记录，不影响链上资产。")),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr("取消")),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr("移除")),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      await widget.controller.forget();
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = tr("移除失败，请重试"));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr("钱包名称与连接"))),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: AppLanguage.instance.code,
                    decoration: InputDecoration(
                        labelText: tr('语言'),
                        helperText: tr('语言切换后自动保存，无需填写观察钱包。')),
                    items: const [
                      DropdownMenuItem(value: 'en', child: Text('English')),
                      DropdownMenuItem(value: 'zh', child: Text('中文'))
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      try {
                        await AppLanguage.instance.select(value);
                        if (mounted) setState(() {});
                      } catch (_) {
                        if (mounted) setState(() => _error = tr('语言保存失败，请重试'));
                      }
                    },
                  ),
                  const SizedBox(height: 24),
                  Text(tr("导入主网公开钱包。这里不接收私钥或助记词。")),
                  const SizedBox(height: 8),
                  Text(tr('观察钱包仅支持查看余额、交易记录和收款，不能转账')),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _address,
                    decoration: InputDecoration(labelText: tr("当前钱包")),
                    maxLines: 3,
                    minLines: 1,
                    autocorrect: false,
                    enableSuggestions: false,
                    validator: (value) {
                      if (!widget.newWatch &&
                          (value ?? '').trim().isEmpty &&
                          widget.controller.address == null) {
                        return null;
                      }
                      try {
                        normalizeAddress(value ?? '');
                        return null;
                      } on FormatException catch (error) {
                        return error.message;
                      }
                    },
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _name,
                    maxLength: 32,
                    decoration: InputDecoration(labelText: tr("钱包名称")),
                    validator: (value) {
                      if (_address.text.trim().isEmpty &&
                          widget.controller.address == null) {
                        return null;
                      }
                      try {
                        WalletController.validateName(value ?? '');
                        return null;
                      } on FormatException catch (e) {
                        return e.message;
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    tr("余额查询服务（可稍后设置）"),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _endpoint,
                    decoration: InputDecoration(
                      labelText: tr("服务地址"),
                      hintText: 'https://wallet.example.com',
                    ),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return null;
                      }
                      try {
                        validateEndpoint(value);
                        return null;
                      } on FormatException catch (error) {
                        return error.message;
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : save,
                    child: Text(_saving ? tr("正在保存与连接…") : tr("保存设置")),
                  ),
                  if (!widget.newWatch && widget.controller.address != null)
                    TextButton(
                      onPressed: _saving ? null : forget,
                      child: Text(tr("移除观察钱包")),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
}
