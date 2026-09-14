import 'package:flutter/material.dart';

import '../../../ui/core/app_bottom_sheet.dart';
import '../../../ui/core/app_button.dart';
import '../../../ui/core/inline_notice.dart';
import '../data/connections_repository.dart';
import '../pairing_view_model.dart';

class PairingSheet extends StatefulWidget {
  const PairingSheet({super.key, required this.repository});
  final ConnectionsRepository repository;

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet> {
  late final _viewModel = PairingViewModel(widget.repository);
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await _viewModel.checkCode(_code.text);
    if (mounted && _viewModel.review != null) _code.clear();
  }

  Future<void> _confirm() async {
    final connection = await _viewModel.confirm();
    if (mounted && connection != null) Navigator.of(context).pop(connection);
  }

  @override
  void dispose() {
    _code.dispose();
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _viewModel,
    builder: (context, _) {
      final review = _viewModel.review;
      return AppBottomSheet(
        canPop: !_viewModel.isWorking,
        topPadding: 24,
        bottomPadding: 16,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                review == null ? 'Add connection' : 'Check the safety code',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              if (review == null) ...[
                const Text(
                  'Enter or paste the short pairing code shown in OpenCode on your computer.',
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _code,
                  autofocus: true,
                  enabled: !_viewModel.isWorking,
                  validator: _viewModel.validateCode,
                  onChanged: (_) => _viewModel.clearError(),
                  textCapitalization: TextCapitalization.characters,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _connect(),
                  decoration: const InputDecoration(
                    labelText: 'Pairing code',
                    hintText: 'ABCD-EFGH',
                  ),
                ),
              ] else ...[
                const Text(
                  'Compare every group with the safety code shown in OpenCode. Confirm only if they all match.',
                ),
                const SizedBox(height: 24),
                Semantics(
                  label: 'Pairing safety code',
                  child: SelectableText(
                    review.safetyCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _viewModel.isWorking ? null : _viewModel.reject,
                  child: const Text('Codes do not match'),
                ),
              ],
              if (_viewModel.error case final error?) ...[
                const SizedBox(height: 16),
                InlineNotice(message: error, isError: true),
              ],
              const SizedBox(height: 24),
              AppButton.primary(
                onPressed: review == null ? _connect : _confirm,
                label: review == null ? 'Connect' : 'Codes match — confirm',
                isLoading: _viewModel.isWorking,
                loadingLabel: 'Connecting',
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _viewModel.isWorking
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    },
  );
}
