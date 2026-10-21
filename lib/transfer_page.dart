import 'core/app_language.dart';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/address.dart';
import 'core/key_vault.dart';
import 'core/wallet_api.dart';
import 'core/wallet_controller.dart';
import 'scan_transfer_page.dart';

BigInt parseTransferAmount(String input) {
  final text = input.trim();
  if (!RegExp(r'^(0|[1-9][0-9]{0,7})(\.[0-9]{1,8})?$').hasMatch(text)) {
    throw FormatException(tr("请输入金额，最多 8 位小数"));
  }
  final parts = text.split('.');
  final value = BigInt.parse(parts[0]) * BigInt.from(100000000) +
      BigInt.parse((parts.length == 2 ? parts[1] : '').padRight(8, '0'));
  if (value < BigInt.from(546) || value > BigInt.from(2100000000000000)) {
    throw FormatException(tr("金额须在 0.00000546 至 21000000 之间"));
  }
  return value;
}

class TransferPage extends StatefulWidget {
  const TransferPage({super.key, required this.wallet, this.pendingStore});
  final WalletController wallet;
  final WalletStore? pendingStore;
  @override
  State<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends State<TransferPage> {
  final recipient = TextEditingController();
  final amount = TextEditingController();
  final rate = TextEditingController();
  late final WalletStore pendingStore =
      widget.pendingStore ?? _PendingStore(address);
  late final String address = widget.wallet.address!;
  late final String endpoint = widget.wallet.endpoint;
  late final String token = widget.wallet.token;
  Map<String, dynamic>? funds, signed;
  String? error;
  bool busy = true, sent = false, loaded = false;
  bool previewing = false;
  bool sendAll = false, quoting = false;
  bool sending = false;
  int quoteRequest = 0;
  bool scanning = false;

  bool get canTransfer =>
      widget.wallet.address == address && widget.wallet.selectedKey != null;

  void requireTransferKey() {
    if (!canTransfer) {
      throw FormatException(tr('观察钱包仅支持查看余额、交易记录和收款，不能转账'));
    }
  }

  Future<void> scanRecipient() async {
    if (busy || scanning || signed != null) return;
    setState(() => scanning = true);
    try {
      final result = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ScanTransferPage()),
      );
      if (!mounted || result == null) return;
      final destination = normalizeAddress(result);
      setState(() {
        recipient.text = destination;
        error = null;
      });
      if (sendAll) await fillMaximum();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(tr('已识别收款钱包，请核对钱包和金额后预览转账'))));
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  String limitedAmountNotice(String value) => tr(
      '可用 UTXO 超过 10000 个，单笔最多支持 10000 个输入。本次仅转出选中输出，扣除手续费后可转账 {0} Dragonchain；剩余余额需分次转出。',
      [value]);

  Future<void> fillMaximum() async {
    final request = ++quoteRequest;
    if (!sendAll || funds == null) return;
    setState(() {
      quoting = true;
      error = null;
      amount.clear();
    });
    try {
      final key = widget.wallet.selectedKey;
      if (key == null) throw FormatException(tr('当前钱包没有本地私钥'));
      final plan = (await KeyVault.channel
          .invokeMapMethod<String, dynamic>('quoteTransfer', {
        'id': key.id,
        'sender': address,
        'recipient': recipient.text.trim().isEmpty
            ? address
            : normalizeAddress(recipient.text),
        'amount_atomic': '546',
        'fee_rate': int.tryParse(rate.text) ?? 0,
        'utxos': funds!['utxos'],
        'send_all': true,
        'truncated': funds!['truncated'] == true,
      }))!;
      if (mounted && request == quoteRequest && sendAll) {
        setState(() => amount.text =
            formatAmount(BigInt.parse(plan['amount_atomic'] as String)));
      }
    } catch (e) {
      if (mounted && request == quoteRequest) {
        setState(() => error = e is PlatformException
            ? tr(e.message ?? tr('操作失败，请重试'))
            : e is FormatException
                ? e.message
                : tr('操作失败，请重试'));
      }
    } finally {
      if (mounted && request == quoteRequest) setState(() => quoting = false);
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    recipient.dispose();
    amount.dispose();
    rate.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => error = e is WalletApiException
            ? e.message
            : e is PlatformException
                ? (tr(e.message ?? tr("本地签名失败")))
                : e is FormatException
                    ? e.message
                    : tr("操作失败，请重试"));
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          sending = false;
        });
      }
    }
  }

  Future<void> load() => run(() async {
        requireTransferKey();
        final saved = await pendingStore.read();
        if (!mounted) return;
        if (saved != null) {
          signed = jsonDecode(saved) as Map<String, dynamic>;
          sent = signed!['broadcast_accepted'] == true;
        }
        loaded = true;
        if (signed != null) return;
        final result = await widget.wallet.api
            .transfer(endpoint, token, 'prepare', {'address': address});
        if (result['network'] != 'mainnet' ||
            result['address'] != address ||
            result['utxos'] is! List) {
          throw FormatException(tr("可用余额数据无效"));
        }
        if (mounted) {
          funds = result;
          rate.text = '${result['fee_rate']}';
          if (sendAll) await fillMaximum();
        }
      });

  Future<void> prepare() => run(() async {
        requireTransferKey();
        final destination = normalizeAddress(recipient.text);
        final value =
            sendAll ? BigInt.from(546) : parseTransferAmount(amount.text);
        final feeRate = int.tryParse(rate.text);
        if (feeRate == null || feeRate < 1 || feeRate > 1000) {
          throw FormatException(tr("手续费率须为 1–1000 最小单位/虚拟字节"));
        }
        // Refresh outpoints immediately before building the transaction.
        final fresh = await widget.wallet.api
            .transfer(endpoint, token, 'prepare', {'address': address});
        if (!mounted) return;
        if (fresh['network'] != 'mainnet' || fresh['address'] != address) {
          throw FormatException(tr("钱包不匹配"));
        }
        final key = widget.wallet.selectedKey;
        if (key == null || !key.owns(address)) {
          throw FormatException(tr("当前钱包没有本地私钥"));
        }
        final plan = (await KeyVault.channel
            .invokeMapMethod<String, dynamic>('prepareTransfer', {
          'id': key.id,
          'sender': address,
          'recipient': destination,
          'amount_atomic': value.toString(),
          'fee_rate': feeRate,
          'utxos': fresh['utxos'],
          'send_all': sendAll,
          'truncated': fresh['truncated'] == true,
        }))!;
        if (!mounted) return;
        funds = fresh;
        if (sendAll) {
          amount.text =
              formatAmount(BigInt.parse(plan['amount_atomic'] as String));
        }
        setState(() => previewing = true);
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: Text(tr("确认主网转账")),
                  content: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(tr("收款钱包")),
                        SelectableText(plan['recipient'] as String),
                        const SizedBox(height: 16),
                        Text(tr("金额：{0}", [
                          formatAmount(
                              BigInt.parse(plan['amount_atomic'] as String))
                        ])),
                        Text(tr("手续费：{0}", [
                          formatAmount(
                              BigInt.parse(plan['fee_atomic'] as String))
                        ])),
                        Text(tr("总支出：{0}", [
                          formatAmount(
                              BigInt.parse(plan['amount_atomic'] as String) +
                                  BigInt.parse(plan['fee_atomic'] as String))
                        ])),
                        Text(tr("找零回本钱包：{0}", [
                          formatAmount(
                              BigInt.parse(plan['change_atomic'] as String))
                        ])),
                        const SizedBox(height: 16),
                        if (sendAll && fresh['truncated'] == true) ...[
                          Text(limitedAmountNotice(formatAmount(
                              BigInt.parse(plan['amount_atomic'] as String)))),
                          const SizedBox(height: 16),
                        ],
                        Text(tr("确认后验证锁屏，在本机签名并发送。")),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: Text(tr("取消"))),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: Text(tr("确认并发送")))
                  ],
                ));
        if (!mounted) return;
        setState(() => previewing = false);
        if (confirmed != true) return;
        requireTransferKey();
        setState(() => sending = true);
        final result = (await KeyVault.channel.invokeMapMethod<String, dynamic>(
            'signTransfer', {'ticket': plan['ticket']}))!;
        // Persist signed bytes before any broadcast. A retry must never create a new signature/txid.
        signed = Map<String, dynamic>.from(result);
        await pendingStore.write(jsonEncode(signed));
        await broadcast();
      });

  Future<void> broadcast() async {
    requireTransferKey();
    if (mounted) setState(() => sending = true);
    await pendingStore.write(jsonEncode(signed));
    final response = await widget.wallet.api
        .transfer(endpoint, token, 'broadcast', {'hex': signed!['hex']});
    if (response['txid'] != signed!['txid']) {
      throw FormatException(tr("返回交易 ID 不匹配，请核对链上记录"));
    }
    signed!['broadcast_accepted'] = true;
    sent = true;
    await pendingStore.write(jsonEncode(signed));
  }

  Future<void> clear() async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(tr("结束此笔转账记录？")),
              content: Text(sent
                  ? tr("交易已提交给节点，等待区块确认。请勿重复向同一收款人支付。")
                  : tr("发送结果尚未确认。请先通过交易 ID 核对节点或链上记录，确认不会重复付款。删除本地记录不会撤销交易。")),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr("保留记录"))),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr("已核对，结束记录")))
              ],
            ));
    if (confirmed == true && mounted) {
      await run(() async {
        await pendingStore.clear();
        if (mounted) Navigator.pop(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !sending,
      child: Scaffold(
        appBar: AppBar(title: Text(tr("转账")), actions: [
          TextButton(
              onPressed: sending ? null : () => Navigator.pop(context),
              child: Text(tr("返回钱包")))
        ]),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          Text(tr("Dragonchain 主网 · 本地签名")),
          const SizedBox(height: 8),
          Text(tr("付款钱包：{0}", [address])),
          Text(tr("钱包名称：{0}", [widget.wallet.nameFor(address)])),
          if (busy && !previewing) const LinearProgressIndicator(),
          if (error != null)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (!canTransfer) ...[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(tr('返回钱包')),
            ),
          ] else if (signed != null) ...[
            const SizedBox(height: 24),
            Text(sent ? tr("已提交，等待链上确认") : tr("已签名，发送结果待确认"),
                style: Theme.of(context).textTheme.titleLarge),
            Text(tr("收款钱包：{0}", [signed!['recipient']])),
            Text(tr("金额：{0}", [
              formatAmount(BigInt.parse(signed!['amount_atomic'] as String))
            ])),
            Text(tr("手续费：{0}",
                [formatAmount(BigInt.parse(signed!['fee_atomic'] as String))])),
            const SizedBox(height: 16),
            Text(tr("交易 ID")),
            SelectableText(signed!['txid'] as String),
            if (!sent)
              FilledButton(
                  onPressed: busy ? null : () => run(broadcast),
                  child: Text(tr("重试发送同一笔交易"))),
            TextButton(
                onPressed: busy ? null : clear, child: Text(tr("结束此笔转账记录"))),
          ] else ...[
            const SizedBox(height: 24),
            if (funds != null)
              Text(tr("可用余额：{0}", [
                formatAmount(BigInt.parse(funds!['available_atomic'] as String))
              ])),
            Text(tr("仅使用已确认且成熟的输出；手续费另计。单笔最多 10000 个输入。")),
            if (funds?['truncated'] == true)
              Text(tr("输出超过 10000 个，当前可用余额仅包含本次加载的输出。")),
            const SizedBox(height: 24),
            TextField(
                controller: recipient,
                enabled: !busy,
                onChanged: (_) {
                  if (sendAll) unawaited(fillMaximum());
                },
                decoration: InputDecoration(
                  labelText: tr("主网收款钱包"),
                  suffixIcon: IconButton(
                    onPressed: busy || scanning ? null : scanRecipient,
                    icon: const Icon(Icons.qr_code_scanner),
                    tooltip: tr('扫码转账'),
                  ),
                ),
                autocorrect: false),
            const SizedBox(height: 16),
            TextField(
                controller: amount,
                enabled: !busy && !sendAll,
                decoration: InputDecoration(labelText: tr("转账金额")),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true)),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('全部转出')),
              subtitle: Text(funds?['truncated'] == true
                  ? tr('单笔最多转出 10000 个输入对应的金额，自动扣除手续费。')
                  : tr('自动扣除手续费，仅转出已确认且成熟的可用余额。')),
              value: sendAll,
              onChanged: busy || quoting || funds == null
                  ? null
                  : (value) {
                      setState(() {
                        sendAll = value == true;
                        error = null;
                      });
                      if (sendAll) {
                        unawaited(fillMaximum());
                      } else {
                        quoteRequest++;
                      }
                    },
            ),
            if (sendAll &&
                funds?['truncated'] == true &&
                !quoting &&
                amount.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(limitedAmountNotice(amount.text)),
              ),
            const SizedBox(height: 16),
            TextField(
                controller: rate,
                enabled: !busy,
                onChanged: (_) {
                  if (sendAll) unawaited(fillMaximum());
                },
                decoration: InputDecoration(
                    labelText: tr("手续费率（最小单位/虚拟字节）"),
                    helperText: tr("1 Dragonchain = 100000000 最小单位")),
                keyboardType: TextInputType.number),
            const SizedBox(height: 24),
            FilledButton(
                onPressed: busy ||
                        quoting ||
                        !loaded ||
                        funds == null ||
                        (sendAll && amount.text.isEmpty)
                    ? null
                    : prepare,
                child: Text(tr("预览转账"))),
            TextButton(
                onPressed: busy ? null : load, child: Text(tr("刷新可用余额"))),
          ],
        ]),
      ));
}

class _PendingStore implements WalletStore {
  _PendingStore(String address) : key = 'dragon.pendingTransfer.v1.$address';
  final String key;
  final preferences = SharedPreferencesAsync();
  @override
  Future<String?> read() => preferences.getString(key);
  @override
  Future<void> write(String value) => preferences.setString(key, value);
  @override
  Future<void> clear() => preferences.remove(key);
}
