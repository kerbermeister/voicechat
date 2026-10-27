import 'package:flutter/material.dart';
import 'app_motion.dart';

void showTransientNotice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..removeCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 13)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        showCloseIcon: false,
      ),
      snackBarAnimationStyle: appAnimationStyle(context),
    );
}
