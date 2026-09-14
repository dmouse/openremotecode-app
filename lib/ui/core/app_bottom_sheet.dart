import 'package:flutter/material.dart';

/// Shared shell for modal bottom sheets: blocks dismissal while busy, and
/// keeps content above the keyboard and the bottom safe area.
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    required this.canPop,
    required this.child,
    this.topPadding = 24,
    this.bottomPadding = 24,
  });

  final bool canPop;
  final Widget child;
  final double topPadding;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          topPadding,
          24,
          bottomPadding + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: child,
      ),
    ),
  );
}
