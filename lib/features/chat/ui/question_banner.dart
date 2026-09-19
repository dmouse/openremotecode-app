import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';

/// A persistent, non-dismissible prompt for a pending question batch OpenCode is blocked
/// on, mirroring [PermissionBanner]: high-visibility and time-sensitive, and its actions
/// are replaced by an explanation once the connector is offline, since an unreachable
/// connector can't accept a reply anyway. Unlike a permission, a question has an
/// on-demand server-side fallback read (see ADR 0011), so every snapshot --
/// live-streamed or polled -- refreshes it; this banner therefore does not additionally
/// require the low-latency live stream itself to be up, or it would stay stuck showing
/// "no longer live" during ordinary polling.
///
/// OpenCode's `question` tool can ask several questions in one call, sharing one batch
/// id and answered together (see CHAT-QUESTIONS.md). This banner renders one question at
/// a time with Back/Next paging, mirroring OpenCode's own client -- "navigate between
/// them before submitting all answers." Nothing is sent to OpenCode until every question
/// has an answer staged; a single-question batch behaves exactly as before: tapping
/// Answer sends immediately, since staging its only question already completes it.
///
/// The question text and option labels are authored by the model. They are rendered as
/// plain [Text] -- never markup, never a link -- and the plugin caps and sanitizes them
/// before they reach the device.
class QuestionBanner extends StatefulWidget {
  const QuestionBanner({super.key, required this.model, this.onTypeOwnAnswer});
  final ConversationViewModel model;

  /// Raised after switching into free-text drafting, so the caller can focus the
  /// composer -- its `FocusNode` lives with the page's input row, not here.
  final VoidCallback? onTypeOwnAnswer;

  @override
  State<QuestionBanner> createState() => _QuestionBannerState();
}

class _QuestionBannerState extends State<QuestionBanner> {
  final _selected = <int>{};
  String? _batchId;
  int _pageIndex = 0;
  int? _selectedForPage;

  @override
  Widget build(BuildContext context) {
    final batch = widget.model.question;
    if (batch == null) return const SizedBox.shrink();
    // A new batch must never inherit a previous one's page or selection.
    if (_batchId != batch.id) {
      _batchId = batch.id;
      _pageIndex = 0;
      _selectedForPage = null;
    }
    if (_pageIndex >= batch.questions.length) {
      _pageIndex = batch.questions.length - 1;
    }
    // Free-text drafting always shows the page it targets, even if paging moved away.
    if (widget.model.answeringQuestionIndex case final index?) {
      _pageIndex = index;
    }
    // A page's checkboxes default to whatever was already staged for it (e.g. after
    // paging Back to revise an earlier answer), never a previous page's selection.
    if (_selectedForPage != _pageIndex) {
      _selectedForPage = _pageIndex;
      _selected
        ..clear()
        ..addAll(widget.model.stagedSelection(_pageIndex) ?? const <int>[]);
    }
    final question = batch.questions[_pageIndex];
    final multiPage = batch.questions.length > 1;
    final lastPage = _pageIndex == batch.questions.length - 1;
    final stale = !widget.model.online();
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.warningSurface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.warning),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.help_outline,
                  color: AppTheme.warning,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (question.header.isNotEmpty)
                        Text(
                          question.header,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppTheme.ink,
                          ),
                        ),
                      Text(
                        question.question,
                        style: const TextStyle(color: AppTheme.ink),
                        semanticsLabel: 'OpenCode asks: ${question.question}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (multiPage) ...[
              const SizedBox(height: 4),
              Text(
                'Question ${_pageIndex + 1} of ${batch.questions.length}',
                style: const TextStyle(color: AppTheme.muted, fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            if (stale)
              const Text(
                'Connector offline -- this question may already be answered or out of date.',
                style: TextStyle(color: AppTheme.muted),
              )
            else if (widget.model.answeringCustomQuestion) ...[
              const Text(
                'Type your answer in the message box below.',
                style: TextStyle(color: AppTheme.muted),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: widget.model.cancelQuestionCustomAnswer,
                    child: const Text('Back to options'),
                  ),
                ],
              ),
            ] else ...[
              for (final (index, option) in question.options.indexed)
                _Option(
                  key: ValueKey('question-option-$index'),
                  label: option.label,
                  description: option.description,
                  selected: _selected.contains(index),
                  multiple: question.multiple,
                  onTap: () => setState(() {
                    if (question.multiple) {
                      _selected.contains(index)
                          ? _selected.remove(index)
                          : _selected.add(index);
                    } else {
                      _selected
                        ..clear()
                        ..add(index);
                    }
                  }),
                ),
              if (question.custom)
                _CustomAnswerOption(
                  key: const ValueKey('question-option-custom'),
                  onTap: () {
                    widget.model.startQuestionCustomAnswer(_pageIndex);
                    widget.onTypeOwnAnswer?.call();
                  },
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (multiPage && _pageIndex > 0)
                    TextButton(
                      onPressed: () => setState(() => _pageIndex--),
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => unawaited(widget.model.rejectQuestion()),
                    child: Text(multiPage ? 'Skip all' : 'Skip'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () {
                            unawaited(
                              widget.model.answerQuestionAt(
                                _pageIndex,
                                _selected.toList(growable: false)..sort(),
                              ),
                            );
                            if (!lastPage) setState(() => _pageIndex++);
                          },
                    child: Text(lastPage ? 'Answer' : 'Next'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.label,
    required this.description,
    required this.selected,
    required this.multiple,
    required this.onTap,
  });
  final String label;
  final String? description;
  final bool selected, multiple;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      inMutuallyExclusiveGroup: !multiple,
      checked: selected,
      button: true,
      label: description == null ? label : '$label. $description',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  multiple
                      ? (selected
                            ? Icons.check_box
                            : Icons.check_box_outline_blank)
                      : (selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked),
                  size: 20,
                  color: selected ? AppTheme.warning : AppTheme.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (description case final text?)
                        Text(
                          text,
                          style: const TextStyle(color: AppTheme.muted),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The row that switches the banner into free-text drafting, mirroring OpenCode's own
/// TUI "type your own answer" entry: appended after the real options, and -- unlike
/// [_Option] -- not a toggle, since tapping it hands off to the composer immediately.
class _CustomAnswerOption extends StatelessWidget {
  const _CustomAnswerOption({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Type your own answer',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.edit_outlined, size: 20, color: AppTheme.muted),
                SizedBox(width: 8),
                Text(
                  'Type your own answer',
                  style: TextStyle(
                    color: AppTheme.ink,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
