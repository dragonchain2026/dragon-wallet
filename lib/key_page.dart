import 'core/app_language.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/key_vault.dart';
import 'core/wallet_controller.dart';
import 'address_name_dialog.dart';
import 'secret_dialogs.dart';

class KeyPage extends StatefulWidget {
  const KeyPage({super.key, required this.wallet, this.vault});
  final WalletController wallet;
  final KeyVault? vault;
  @override
  State<KeyPage> createState() => _KeyPageState();
}

class _KeyPageState extends State<KeyPage> {
  late final KeyVault vault = widget.vault ?? KeyVault();
  List<VaultKey> keys = [];
  bool busy = true;
  String? message;
  final listHeading = GlobalKey();

  void showCreatedKey(VaultKey key) {
    if (!mounted) return;
    setState(() {
      keys = [key, ...keys.where((item) => item.id != key.id)];
    });
  }

  Future<void> revealKeys() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final target = listHeading.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(target,
          duration: const Duration(milliseconds: 250), alignment: 0);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(run(() async {
      await vault.secure(true);
      keys = await vault.list();
      await widget.wallet.ensureNames(keys.map((key) => key.address));
    }));
  }

  @override
  void dispose() {
    unawaited(vault.secure(false).catchError((Object _) {}));
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } on PlatformException catch (error) {
      if (mounted) {
        message = error.code == 'cancelled'
            ? tr("操作已取消，可继续操作或返回钱包。")
            : tr(error.message ?? tr("本地密钥操作失败"));
      }
    } catch (_) {
      if (mounted) message = tr("本地密钥操作失败，请重试");
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String text, String label) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(title),
                content: Text(text),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr("取消"))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(label)),
                ],
              )) ??
      false;

  Future<void> generate({bool mnemonic = false}) async {
    final name = await askAddressName(context, widget.wallet.suggestedName,
        title: tr("新建钱包名称"));
    if (name == null || !mounted) return;
    var created = false;
    await run(() async {
      final key =
          mnemonic ? await vault.generateMnemonic() : await vault.generate();
      showCreatedKey(key);
      created = true;
      await widget.wallet.renameAddress(key.address, name);
      message = mnemonic
          ? tr("钱包已生成，24 个英文助记词已加密保存在本机。请查看助记词并备份，再使用此钱包收款。")
          : tr("WIF 钱包已生成并加密保存在本机。请查看 WIF 私钥并备份，再使用此钱包收款。");
    });
    if (created) await revealKeys();
  }

  Future<void> importKey({bool mnemonic = false}) async {
    final name = await askAddressName(context, widget.wallet.suggestedName,
        title: tr("导入钱包名称"));
    if (name == null || !mounted) return;
    String? text = await showDialog<String>(
        context: context,
        builder: (_) => SecretImportDialog(mnemonic: mnemonic));
    if (text == null || !mounted) return;
    var imported = false;
    await run(() async {
      final key = mnemonic
          ? await vault.importMnemonic(text!)
          : await vault.importWif(text!);
      showCreatedKey(key);
      imported = true;
      await widget.wallet.renameAddress(key.address, name);
      message = tr("导入成功，已恢复钱包并加密保存在本机。");
    });
    text = null;
    if (imported) await revealKeys();
  }

  Future<void> viewSecret(VaultKey key) async {
    String? secret;
    await run(() async {
      secret = await vault.viewSecret(key);
    });
    if (!mounted || secret == null) return;
    // Do not reveal a completed authentication result after the app is hidden.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached) {
      return;
    }
    await showDialog<void>(
        context: context,
        builder: (_) => SecretViewDialog(
            secret: secret!,
            mnemonic: key.mnemonicBackup,
            copy: vault.copySecret));
    secret = null;
  }

  Future<void> rename(VaultKey key) async {
    final name = await askAddressName(
        context, widget.wallet.nameFor(key.address),
        title: tr("修改钱包名称"));
    if (name == null || !mounted) return;
    await run(() async {
      await widget.wallet.renameAddress(key.address, name);
    });
  }

  Future<void> deleteKey(VaultKey key) async {
    if (!await confirm(
        tr("删除本地私钥？"),
        tr("请确认你已保存可恢复此钱包的助记词或 WIF 私钥备份。删除后本机的私钥及助记词一并移除；链上资产不受影响。"),
        tr("已备份，删除"))) {
      return;
    }
    await run(() async {
      await vault.delete(key);
      if (mounted) {
        setState(() => keys = keys.where((item) => item.id != key.id).toList());
      }
      message = tr("已删除本地私钥。");
    });
  }

  Future<void> select(VaultKey key) async {
    var saved = false;
    await run(() async {
      await widget.wallet.configure(
          key.address, widget.wallet.endpoint, widget.wallet.token,
          refreshOnSwitch: false);
      saved = true;
    });
    if (!mounted || !saved) return;
    // Let PopScope observe the end of the operation before leaving this route.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.pop(context);
    unawaited(widget.wallet.refresh());
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !busy,
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr("本地钱包与私钥")),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).maybePop(),
                child: Text(tr("返回钱包")),
              ),
            ],
          ),
          body: Center(
              child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(padding: const EdgeInsets.all(24), children: [
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr("使用与备份提示"),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                children: [
                  Text(tr(
                      "可新建或导入 WIF 密钥、助记词钱包，并按对应格式查看和复制备份。钱包统一以 dragon1q 开头。私钥和助记词由 Android Keystore 加密保护。")),
                  const SizedBox(height: 12),
                  Text(tr(
                      "需要启用系统锁屏 PIN 或密码。卸载应用、清除数据或移除系统锁屏可能导致本地私钥无法恢复，请及时备份。")),
                  TextButton(
                      onPressed: busy ? null : () => run(vault.lockSettings),
                      child: Text(tr("打开系统安全设置"))),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                  onPressed: busy ? null : () => generate(),
                  icon: const Icon(Icons.add),
                  label: Text(tr("生成 WIF 钱包"))),
              FilledButton.icon(
                  onPressed: busy ? null : () => generate(mnemonic: true),
                  icon: const Icon(Icons.add),
                  label: Text(tr("生成助记词钱包"))),
              OutlinedButton.icon(
                  onPressed: busy ? null : () => importKey(),
                  icon: const Icon(Icons.key),
                  label: Text(tr("导入 WIF 私钥"))),
              OutlinedButton.icon(
                  onPressed: busy ? null : () => importKey(mnemonic: true),
                  icon: const Icon(Icons.restore),
                  label: Text(tr("导入助记词"))),
              if (busy)
                const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator()),
              if (message != null)
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(message!, key: const Key('key-message'))),
              const SizedBox(height: 16),
              Text(tr("本地密钥 · {0}", [keys.length]),
                  key: listHeading,
                  style: Theme.of(context).textTheme.titleLarge),
              if (keys.isEmpty && !busy)
                Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(tr("尚未生成或导入私钥。"))),
              for (final key in keys)
                Card(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${widget.wallet.nameFor(key.address)}(${key.mnemonicBackup ? tr("助记词") : 'wif'})',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              SelectableText(key.address),
                              const SizedBox(height: 12),
                              Wrap(spacing: 8, children: [
                                FilledButton(
                                    onPressed: busy ? null : () => select(key),
                                    child: Text(tr("切换"))),
                                TextButton(
                                    onPressed: busy ? null : () => rename(key),
                                    child: Text(tr("修改"))),
                                TextButton(
                                    onPressed:
                                        busy ? null : () => viewSecret(key),
                                    child: Text(key.mnemonicBackup
                                        ? tr("助记词")
                                        : tr("私钥"))),
                                TextButton(
                                    onPressed:
                                        busy ? null : () => deleteKey(key),
                                    child: Text(tr("删除"))),
                              ]),
                            ]))),
            ]),
          )),
        ),
      );
}
