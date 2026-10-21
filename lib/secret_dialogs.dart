import 'core/app_language.dart';
import 'package:flutter/material.dart';

class SecretImportDialog extends StatefulWidget {
  const SecretImportDialog({super.key, required this.mnemonic});
  final bool mnemonic;
  @override
  State<SecretImportDialog> createState() => _SecretImportDialogState();
}

class _SecretImportDialogState extends State<SecretImportDialog>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      input.clear();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    input.clear();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.mnemonic ? tr("导入助记词") : tr("导入 WIF 私钥")),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.mnemonic
              ? tr(
                  "粘贴 12、15、18、21 或 24 个英文助记词，以空格分隔，不使用附加口令。其他钱包的相同助记词可能生成不同钱包。")
              : tr("粘贴 Dragonchain 主网 Falcon-512 WIF 私钥。支持节点钱包导出的 WIF。")),
          const SizedBox(height: 16),
          TextField(
              controller: input,
              obscureText: true,
              maxLength: widget.mnemonic ? 512 : 1800,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              autofillHints: const [],
              decoration: InputDecoration(
                  labelText: widget.mnemonic ? tr("英文助记词") : tr("WIF 私钥"),
                  errorText: error)),
        ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(tr("取消"))),
          FilledButton(
              onPressed: () {
                final text = input.text.trim();
                if (text.isEmpty) {
                  setState(() => error =
                      widget.mnemonic ? tr("请粘贴助记词") : tr("请粘贴 WIF 私钥"));
                  return;
                }
                Navigator.pop(context, text);
              },
              child: Text(tr("导入钱包"))),
        ],
      );
}

class SecretViewDialog extends StatefulWidget {
  const SecretViewDialog(
      {super.key,
      required this.secret,
      required this.mnemonic,
      required this.copy});
  final String secret;
  final bool mnemonic;
  final Future<void> Function(String) copy;
  @override
  State<SecretViewDialog> createState() => _SecretViewDialogState();
}

class _SecretViewDialogState extends State<SecretViewDialog>
    with WidgetsBindingObserver {
  bool hidden = false;
  bool copying = false;
  String? status;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!hidden &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden)) {
      setState(() => hidden = true);
      if (ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> copy() async {
    setState(() {
      copying = true;
      status = null;
    });
    try {
      await widget.copy(widget.secret);
      if (mounted) setState(() => status = tr("已复制到剪贴板"));
    } catch (_) {
      if (mounted) setState(() => status = tr("复制失败，请重试"));
    } finally {
      if (mounted) setState(() => copying = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.mnemonic ? tr("查看助记词") : tr("查看私钥")),
        content: SizedBox(
            width: 480,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(tr("请妥善保管，勿向他人透露。持有此内容即可控制该钱包资产。")),
              const SizedBox(height: 16),
              Flexible(
                  child: SingleChildScrollView(
                      child: Text(hidden ? '' : widget.secret,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 14)))),
              if (status != null)
                Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(status!)),
            ])),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(tr("关闭"))),
          FilledButton.icon(
              onPressed: copying || hidden ? null : copy,
              icon: const Icon(Icons.copy),
              label: Text(tr("复制到剪贴板"))),
        ],
      );
}
