import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/interaction_auth_provider.dart';
import '../screens/interaction_auth_screen.dart';

Future<bool> ensureLoggedInForContent(
  BuildContext context, {
  required bool allowed,
  required String title,
  required String message,
}) async {
  if (allowed || context.read<InteractionAuthProvider>().isLoggedIn) {
    return true;
  }

  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return false;
  if (context.read<InteractionAuthProvider>().isLoggedIn) return true;

  final shouldLogin = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('稍后再说'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('去登录'),
        ),
      ],
    ),
  );
  if (shouldLogin != true || !context.mounted) return false;

  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => const InteractionAuthScreen()),
  );
  if (!context.mounted) return false;
  return context.read<InteractionAuthProvider>().isLoggedIn;
}
