import 'package:flutter/material.dart';

import '../../../ui/core/app_bottom_sheet.dart';
import '../../../ui/core/app_button.dart';
import '../../../ui/core/inline_notice.dart';
import '../server_settings_view_model.dart';

class ServerSettingsSheet extends StatefulWidget {
  const ServerSettingsSheet({super.key, required this.viewModel});

  final ServerSettingsViewModel viewModel;

  @override
  State<ServerSettingsSheet> createState() => _ServerSettingsSheetState();
}

class _ServerSettingsSheetState extends State<ServerSettingsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _address;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(
      text: widget.viewModel.endpoint?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final saved = await widget.viewModel.save(_address.text);
    if (!mounted || !saved) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.viewModel,
    builder: (context, _) {
      final saving = widget.viewModel.isSaving;
      return AppBottomSheet(
        canPop: !saving,
        topPadding: 12,
        bottomPadding: 24,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Your server. Your space.',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(widget.viewModel.addressInstructions),
              const SizedBox(height: 24),
              TextFormField(
                controller: _address,
                autofocus: true,
                enabled: !saving,
                validator: widget.viewModel.validateServer,
                onChanged: (_) => widget.viewModel.clearSaveError(),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onFieldSubmitted: (_) => _save(),
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'https://remote.example.com',
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Only use a server you trust. Changing servers clears the '
                'email and password entered on this screen.',
              ),
              if (widget.viewModel.saveError case final error?) ...[
                const SizedBox(height: 16),
                InlineNotice(message: error, isError: true),
              ],
              const SizedBox(height: 24),
              AppButton.primary(
                onPressed: _save,
                label: 'Save server',
                isLoading: saving,
                loadingLabel: 'Saving server',
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
