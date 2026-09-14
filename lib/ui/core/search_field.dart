import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Compact list-filter search field. Uses the same metrics on every screen that
/// filters a list (projects, chats) so the control does not change size between
/// adjacent screens. A clear action appears once the field holds text.
class SearchField extends StatelessWidget {
  const SearchField({
    super.key,
    required this.controller,
    required this.hintText,
  });

  final TextEditingController controller;
  final String hintText;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(color: AppTheme.ink),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: Theme.of(context).textTheme.bodyMedium,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        prefixIcon: const Icon(Icons.search, size: 20),
        suffixIcon: value.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                onPressed: controller.clear,
                icon: const Icon(Icons.close, size: 20),
              ),
      ),
    ),
  );
}
