import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/core/app_button.dart';
import '../../../ui/core/inline_notice.dart';
import '../verify_email_view_model.dart';

class VerifyEmailForm extends StatefulWidget {
  const VerifyEmailForm({
    super.key,
    required this.viewModel,
    required this.onSignIn,
  });

  final VerifyEmailViewModel viewModel;

  /// Abandons verification and goes to sign-in. It is one action rather than a
  /// bare cancel, because someone who arrived here by registering an address they
  /// already own must land on the sign-in form, not back on the registration one.
  final VoidCallback onSignIn;

  @override
  State<VerifyEmailForm> createState() => _VerifyEmailFormState();
}

class _VerifyEmailFormState extends State<VerifyEmailForm> {
  final _formKey = GlobalKey<FormState>();
  final _code = TextEditingController();
  Timer? _cooldownTimer;
  // Starts on the clock: a code was just sent to get the user here.
  Duration _cooldown = VerifyEmailViewModel.resendCooldown;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _code.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = VerifyEmailViewModel.resendCooldown);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _cooldown -= const Duration(seconds: 1));
      if (_cooldown <= Duration.zero) timer.cancel();
    });
  }

  Future<void> _submit() async {
    if (widget.viewModel.isBusy) return;
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final verified = await widget.viewModel.submit(_code.text);
    if (!verified && mounted) _code.clear();
  }

  Future<void> _resend() async {
    if (widget.viewModel.isBusy) return;
    final sent = await widget.viewModel.resend();
    if (!mounted) return;
    _code.clear();
    if (sent) _startCooldown();
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _cooldown > Duration.zero;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            enabled: !widget.viewModel.isBusy,
            controller: _code,
            validator: widget.viewModel.validateCode,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 28, letterSpacing: 10),
            textAlign: TextAlign.center,
            onFieldSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Verification code',
              counterText: '',
            ),
          ),
          const SizedBox(height: 24),
          AppButton.primary(
            onPressed: _submit,
            label: 'Verify and continue',
            icon: Icons.arrow_forward_rounded,
            iconAlignment: IconAlignment.end,
            isLoading: widget.viewModel.isBusy,
            loadingLabel: 'Verifying',
          ),
          if (widget.viewModel.error case final error?) ...[
            const SizedBox(height: 16),
            InlineNotice(message: error, isError: true),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: widget.viewModel.isBusy || waiting ? null : _resend,
            child: Text(
              waiting
                  ? 'Send a new code in ${_cooldown.inSeconds}s'
                  : 'Send a new code',
            ),
          ),
          // Someone who already had an account lands here too, because
          // registration cannot reveal that the address was taken. This is the
          // way out of that dead end, and it discloses nothing either way.
          TextButton(
            onPressed: widget.viewModel.isBusy ? null : widget.onSignIn,
            child: const Text('Already have an account? Sign in'),
          ),
        ],
      ),
    );
  }
}
