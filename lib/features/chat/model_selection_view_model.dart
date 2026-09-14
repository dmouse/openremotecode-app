import 'package:flutter/foundation.dart';

import 'data/chat_repository.dart';
import 'domain/chat_models.dart';

/// Available/selected model and effort for the open chat, and the RPC to
/// list a project's models. Self-contained: whether selection is currently
/// allowed is decided by the owning [ConversationViewModel], which gates its
/// forwarding calls before reaching this object.
final class ModelSelectionViewModel extends ChangeNotifier {
  ModelSelectionViewModel(this.repository, this.connectorId);

  final ChatRepository repository;
  final String connectorId;

  List<ChatModelOption> availableModels = [];
  bool modelsLoading = false;
  String? modelsError;
  ChatModelOption? _selectedModel;
  String? _selectedEffort;
  ChatModelOption? get selectedModel => _selectedModel;
  String? get selectedEffort => _selectedEffort;

  bool get supportsModelSelection =>
      repository.chatSupports(connectorId, 'chat.prompt') &&
      repository.chatSupports(connectorId, 'chat.models') &&
      repository.chatSupports(connectorId, 'chat.prompt.model');

  /// Fetched lazily -- only ever called from the picker's open handler, never
  /// eagerly on chat load, so a connector's provider list isn't pulled until
  /// the user actually asks to change models.
  Future<void> loadModels(String projectId, {bool force = false}) async {
    if (modelsLoading) return;
    if (availableModels.isNotEmpty && !force) return;
    modelsLoading = true;
    modelsError = null;
    notifyListeners();
    try {
      final response = await repository.chatRequest(
        connectorId,
        'chat.models',
        {'projectId': projectId},
      );
      final models = response['models'];
      if (models is! List) throw const FormatException();
      availableModels = models
          .map((m) => ChatModelOption.parse(m as Map<String, dynamic>))
          .toList();
      _upgradeSelectedModel();
    } catch (_) {
      modelsError = 'Could not load models.';
    } finally {
      modelsLoading = false;
      notifyListeners();
    }
  }

  /// A model recovered from a chat snapshot carries ids alone -- see
  /// [applyRecovered]. Once the real list arrives, swap in the matching
  /// option so the chat reads with the model's display name and its effort
  /// levels become adjustable. A recovered effort the option does not offer is
  /// dropped, the same rule [select] applies to a user's own choice, so no
  /// selection can name a level its model denies.
  void _upgradeSelectedModel() {
    final selected = _selectedModel;
    if (selected == null) return;
    for (final option in availableModels) {
      if (option.providerId == selected.providerId &&
          option.modelId == selected.modelId) {
        _selectedModel = option;
        if (_selectedEffort case final effort?
            when !option.effortLevels.contains(effort)) {
          _selectedEffort = null;
        }
        return;
      }
    }
  }

  /// Recovers the model + effort a chat's last assistant reply actually used,
  /// so reopening a chat doesn't show an empty header just because this app
  /// session never picked one. Never overrides an already-set selection --
  /// whether from the user or an earlier call for this same chat -- and never
  /// recovers on a connector that doesn't support sending the choice back,
  /// so a plain send later can't unexpectedly fail as unsupported.
  void applyRecovered(dynamic modelJson) {
    if (_selectedModel != null || !supportsModelSelection) return;
    if (modelJson is! Map<String, dynamic>) return;
    final providerId = modelJson['providerID'];
    final modelId = modelJson['modelID'];
    final effort = modelJson['effort'];
    if (providerId is! String ||
        providerId.isEmpty ||
        modelId is! String ||
        modelId.isEmpty) {
      return;
    }
    ChatModelOption? cached;
    for (final option in availableModels) {
      if (option.providerId == providerId && option.modelId == modelId) {
        cached = option;
        break;
      }
    }
    _selectedModel =
        cached ??
        ChatModelOption(
          providerId: providerId,
          providerName: providerId,
          modelId: modelId,
          modelName: modelId,
        );
    _selectedEffort = effort is String && effort.isNotEmpty ? effort : null;
  }

  void select(ChatModelOption? model, [String? effort]) {
    _selectedModel = model;
    _selectedEffort =
        model != null && effort != null && model.effortLevels.contains(effort)
        ? effort
        : null;
    notifyListeners();
  }

  /// Clears the selection -- e.g. switching to a different chat, whose own
  /// last-used model (if any) is recovered separately from its own snapshot.
  void reset() {
    _selectedModel = null;
    _selectedEffort = null;
  }

  /// Clears the selection and the cached model list -- e.g. a trust loss,
  /// after which re-pairing may offer a different provider/model list.
  void resetAll() {
    reset();
    availableModels = [];
  }
}
