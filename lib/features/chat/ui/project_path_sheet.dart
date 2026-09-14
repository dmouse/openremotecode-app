import 'package:flutter/material.dart';

import '../../../ui/core/app_bottom_sheet.dart';
import '../../../ui/core/app_button.dart';

/// A bottom sheet for entering a folder path to open directly, for
/// connectors that allow it.
class ProjectPathSheet extends StatefulWidget {
  const ProjectPathSheet({super.key, required this.connectionName});
  final String connectionName;
  @override
  State<ProjectPathSheet> createState() => _ProjectPathSheetState();
}

class _ProjectPathSheetState extends State<ProjectPathSheet> {
  final input = TextEditingController();
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppBottomSheet(
    canPop: true,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Open project', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        TextField(
          controller: input,
          autofocus: true,
          maxLength: 4096,
          decoration: InputDecoration(
            labelText: 'Folder path on ${widget.connectionName}',
            counterText: '',
            helperText: 'Enter an existing folder authorized in the local Remote plugin.',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 16),
        AppButton.primary(
          label: 'Open project',
          onPressed: () => Navigator.pop(context, input.text),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
