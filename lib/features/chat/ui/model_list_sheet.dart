import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../../../ui/core/inline_notice.dart';
import '../../../ui/core/search_field.dart';
import '../conversation_view_model.dart';
import '../domain/chat_models.dart';

/// The model list, reached from the model banner's title: one searchable
/// sheet of names. Effort is not repeated here -- the banner's slider owns
/// it. [source] is the composer key at the time the sheet was opened, so
/// entries disable themselves if the open chat changes while it's up.
class ModelListSheet extends StatelessWidget {
  const ModelListSheet({
    super.key,
    required this.model,
    required this.source,
    required this.search,
    required this.onSelected,
  });

  final ConversationViewModel model;
  final String? source;
  final TextEditingController search;
  final ValueChanged<ChatModelOption> onSelected;

  @override
  Widget build(BuildContext context) => SizedBox(
    // A tall, list-style sheet -- like the tools list -- rather than a
    // compact popup, since a connector can report many models.
    height: MediaQuery.of(context).size.height * 0.85,
    child: ListenableBuilder(
      listenable: Listenable.merge([model, search]),
      builder: (context, _) {
        final models0 = model.models;
        if (models0.modelsLoading && models0.availableModels.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (models0.modelsError != null && models0.availableModels.isEmpty) {
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: InlineNotice(message: models0.modelsError!, isError: true),
            ),
          );
        }
        final query = search.text.trim().toLowerCase();
        final models = query.isEmpty
            ? models0.availableModels
            : models0.availableModels
                  .where(
                    (option) => '${option.modelName} ${option.providerName}'
                        .toLowerCase()
                        .contains(query),
                  )
                  .toList();
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Column(
              children: [
                if (models0.availableModels.isNotEmpty)
                  SearchField(controller: search, hintText: 'Search models'),
                Expanded(
                  child: models.isEmpty
                      ? Center(
                          child: Text(
                            models0.availableModels.isEmpty
                                ? 'No models available.'
                                : 'No models match "$query".',
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: [
                            for (final option in models)
                              _ModelNameTile(
                                option: option,
                                selected:
                                    models0.selectedModel?.providerId ==
                                        option.providerId &&
                                    models0.selectedModel?.modelId ==
                                        option.modelId,
                                enabled:
                                    model.canChangeModel &&
                                    model.composerKey == source,
                                onTap: () => onSelected(option),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// One model in the list: its name and provider. Choosing one keeps the
/// effort already in force where the new model offers it, and the banner's
/// slider takes over from there.
class _ModelNameTile extends StatelessWidget {
  const _ModelNameTile({
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  final ChatModelOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    enabled: enabled,
    selected: selected,
    selectedColor: AppTheme.ink,
    title: Text(
      option.modelName,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontSize: 14, fontWeight: FontWeight.w500),
    ),
    subtitle: Text(
      option.providerName,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: AppTheme.muted),
    ),
    trailing: selected
        ? const Icon(Icons.check, color: AppTheme.ink, size: 20)
        : null,
    onTap: enabled ? onTap : null,
  );
}
