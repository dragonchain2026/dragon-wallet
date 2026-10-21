import 'core/app_language.dart';
import 'package:flutter/material.dart';
import 'core/wallet_controller.dart';

Future<String?> askAddressName(BuildContext context, String initial,
        {String? title}) =>
    showDialog<String>(
        context: context,
        builder: (_) =>
            _NameDialog(initial: initial, title: title ?? tr("钱包名称")));

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial, required this.title});
  final String initial, title;
  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final controller = TextEditingController(text: widget.initial);
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void save() {
    try {
      Navigator.pop(context, WalletController.validateName(controller.text));
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 32,
            decoration:
                InputDecoration(labelText: tr("钱包名称"), errorText: error),
            onSubmitted: (_) => save()),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(tr("取消"))),
          FilledButton(onPressed: save, child: Text(tr("保存名称")))
        ],
      );
}
