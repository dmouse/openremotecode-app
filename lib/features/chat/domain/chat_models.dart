import '../../../platform/remote_api.dart';
import 'activity.dart';

final class RemoteProject {
  const RemoteProject(this.id, this.name, this.path);
  final String id, name, path;
  factory RemoteProject.parse(Map<String, dynamic> value) => RemoteProject(
    requiredString(value, 'id', max: 128),
    requiredString(value, 'name', max: 256),
    requiredString(value, 'path', max: 4096),
  );
}

final class RemoteChat {
  const RemoteChat(this.id, this.title, this.updatedAt, {this.parentId});
  final String id, title;
  final DateTime updatedAt;
  final String? parentId;
  factory RemoteChat.parse(Map<String, dynamic> value) {
    final time = value['updatedAt'];
    final title = value['title'];
    if (time is! int ||
        time < 0 ||
        time > 8640000000000000 ||
        title is! String ||
        title.length > 512) {
      throw const FormatException();
    }
    return RemoteChat(
      requiredString(value, 'id', max: 128),
      title.isEmpty ? 'Untitled chat' : title,
      DateTime.fromMillisecondsSinceEpoch(time),
      parentId: value['parentId'] == null
          ? null
          : requiredString(value, 'parentId', max: 128),
    );
  }
}

final class ChatModelOption {
  const ChatModelOption({
    required this.providerId,
    required this.providerName,
    required this.modelId,
    required this.modelName,
    this.effortLevels = const [],
  });
  final String providerId, providerName, modelId, modelName;
  // Ids as OpenCode itself names them (its "variant" concept) -- not a fixed
  // set. OpenAI ships up to six; other providers fewer; a user's own config
  // can name variants arbitrarily. Never assume a particular set here.
  final List<String> effortLevels;

  factory ChatModelOption.parse(Map<String, dynamic> value) => ChatModelOption(
    providerId: requiredString(value, 'providerID', max: 128),
    providerName: requiredString(value, 'providerName', max: 256),
    modelId: requiredString(value, 'modelID', max: 128),
    modelName: requiredString(value, 'modelName', max: 256),
    effortLevels: value.containsKey('effortLevels')
        ? _parseEffortLevels(value['effortLevels'])
        : const [],
  );
}

List<String> _parseEffortLevels(dynamic value) {
  if (value is! List || value.isEmpty || value.length > 10) {
    throw const FormatException();
  }
  final levels = value.map((item) {
    if (item is! String || item.isEmpty || item.length > 128) {
      throw const FormatException();
    }
    return item;
  }).toList();
  if (levels.toSet().length != levels.length) throw const FormatException();
  return List.unmodifiable(levels);
}

final class ChatMessage {
  const ChatMessage(
    this.id,
    this.role,
    this.text,
    this.truncated, {
    this.parts,
    this.incomplete = false,
    this.mode,
  });
  final String id, role, text;
  final bool truncated;
  final bool incomplete;
  final List<ChatMessagePart>? parts;
  // The agent this message was generated under, when it was build/plan --
  // null for a custom agent name or when unknown.
  final String? mode;
  factory ChatMessage.parse(Map<String, dynamic> value) {
    final role = value['role'];
    final text = value['text'];
    if (!['user', 'assistant'].contains(role) ||
        text is! String ||
        text.length > 48000 ||
        value['truncated'] is! bool ||
        (value.containsKey('incomplete') && value['incomplete'] is! bool) ||
        (value.containsKey('mode') &&
            !['build', 'plan'].contains(value['mode']))) {
      throw const FormatException();
    }
    final parts = value.containsKey('parts')
        ? parseItems(value, 'parts', 100, ChatMessagePart.parse)
        : null;
    // Tool/subtask/reasoning parts stay assistant-only; a user message may
    // only carry its own authored text and image attachments as structured
    // parts (mirrors the protocol's chat.ts message refinement).
    if (parts != null &&
        (!(role == 'assistant' ||
                parts.every((part) => part.type == 'text' || part.isImage)) ||
            parts.map((part) => part.id).toSet().length != parts.length ||
            parts.fold(
                  0,
                  (length, part) =>
                      length +
                      part.text.length +
                      (part.tool?.shell?.command.length ?? 0) +
                      (part.tool?.shell?.output.length ?? 0) +
                      (part.image?.data.length ?? 0),
                ) >
                48000 ||
            (parts.any((part) => part.tool?.shell?.truncated == true) &&
                value['truncated'] != true) ||
            parts
                    .where((part) => !part.isReasoning && !part.isImage)
                    .map((part) => part.text)
                    .join() !=
                text)) {
      throw const FormatException();
    }
    return ChatMessage(
      requiredString(value, 'id', max: 128),
      role as String,
      text,
      value['truncated'] as bool,
      parts: parts == null ? null : List.unmodifiable(parts),
      incomplete: value['incomplete'] == true,
      mode: value['mode'] as String?,
    );
  }
}

final class ChatMessagePart {
  const ChatMessagePart(
    this.id,
    this.type,
    this.text, {
    this.start,
    this.end,
    this.task,
    this.tool,
    this.activity,
    this.image,
  });

  final String id, type, text;
  final int? start, end;
  final ChatSubtask? task;
  final ChatTool? tool;
  final AgentActivity? activity;
  final ChatImage? image;
  bool get isReasoning => type == 'reasoning';
  bool get isImage => type == 'image';
  int? get durationMs => start != null && end != null ? end! - start! : null;

  factory ChatMessagePart.parse(Map<String, dynamic> value) {
    final type = value['type'];
    final text = value['text'];
    if (!['text', 'reasoning', 'subtask', 'tool', 'image'].contains(type) ||
        text is! String ||
        text.length > 48000 ||
        (type == 'image' && text.isNotEmpty) ||
        value.keys.any(
          (key) => ![
            'id',
            'type',
            'text',
            if (type == 'reasoning') 'time',
            if (type == 'subtask') 'task',
            if (type == 'tool') 'tool',
            if (type == 'image') 'image',
            if (type != 'text' && type != 'image') 'activity',
          ].contains(key),
        )) {
      throw const FormatException();
    }
    int? start, end;
    if (value.containsKey('time')) {
      final time = value['time'];
      if (time is! Map<String, dynamic>) throw const FormatException();
      final from = time['start'];
      final to = time['end'];
      bool timestamp(dynamic value) =>
          value is int && value >= 0 && value <= 9007199254740991;
      if (!timestamp(from) ||
          (time.containsKey('end') && (!timestamp(to) || to < from)) ||
          time.keys.any((key) => key != 'start' && key != 'end')) {
        throw const FormatException();
      }
      start = from as int;
      end = to as int?;
    }
    return ChatMessagePart(
      requiredString(value, 'id', max: 128),
      type as String,
      text,
      start: start,
      end: end,
      task: type == 'subtask'
          ? ChatSubtask.parse(requiredMap(value, 'task'))
          : null,
      tool: type == 'tool' ? ChatTool.parse(requiredMap(value, 'tool')) : null,
      activity: value.containsKey('activity')
          ? AgentActivity.parse(requiredMap(value, 'activity'))
          : null,
      image: type == 'image'
          ? ChatImage.parse(requiredMap(value, 'image'))
          : null,
    );
  }
}

final class ChatImage {
  const ChatImage(this.mime, this.data, {this.width, this.height});
  final String mime, data;
  final int? width, height;
  static final _base64 = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  factory ChatImage.parse(Map<String, dynamic> value) {
    final mime = value['mime'];
    final data = value['data'];
    final width = value['width'];
    final height = value['height'];
    bool validDimension(dynamic value) =>
        value is int && value > 0 && value <= 8192;
    if (mime != 'image/jpeg' ||
        data is! String ||
        data.isEmpty ||
        data.length > 34000 ||
        data.length % 4 != 0 ||
        !_base64.hasMatch(data) ||
        (value.containsKey('width') && !validDimension(width)) ||
        (value.containsKey('height') && !validDimension(height)) ||
        value.keys.any(
          (key) => !['mime', 'data', 'width', 'height'].contains(key),
        )) {
      throw const FormatException();
    }
    return ChatImage(mime, data, width: width as int?, height: height as int?);
  }
}

// Shared with ChatPermission: a permission request maps through the same
// presentation taxonomy a tool call does, not a parallel one.
const _chatOperations = [
  'read',
  'edit',
  'write',
  'search',
  'list',
  'execute',
  'fetch',
  'tool',
  'question',
];

final class ChatTool {
  const ChatTool({
    required this.operation,
    required this.status,
    this.description,
    this.durationMs,
    this.shell,
  });
  final String operation, status;
  final String? description;
  final int? durationMs;
  final ChatShell? shell;

  factory ChatTool.parse(Map<String, dynamic> value) {
    final duration = value['durationMs'];
    if (!_chatOperations.contains(value['operation']) ||
        ![
          'pending',
          'running',
          'completed',
          'error',
          'unknown',
        ].contains(value['status']) ||
        value.keys.any(
          (key) => ![
            'operation',
            'status',
            'description',
            'durationMs',
            'shell',
          ].contains(key),
        ) ||
        (value.containsKey('shell') && value['operation'] != 'execute') ||
        (value.containsKey('durationMs') &&
            (duration is! int ||
                duration < 0 ||
                duration > 9007199254740991))) {
      throw const FormatException();
    }
    return ChatTool(
      operation: value['operation'] as String,
      status: value['status'] as String,
      description: value.containsKey('description')
          ? requiredString(value, 'description', max: 256)
          : null,
      durationMs: duration as int?,
      shell: value.containsKey('shell')
          ? ChatShell.parse(requiredMap(value, 'shell'))
          : null,
    );
  }
}

final class ChatShell {
  const ChatShell({
    required this.command,
    required this.output,
    required this.truncated,
  });
  final String command, output;
  final bool truncated;

  factory ChatShell.parse(Map<String, dynamic> value) {
    final command = value['command'];
    final output = value['output'];
    if (command is! String ||
        command.length > 8000 ||
        output is! String ||
        output.length > 32000 ||
        value['truncated'] is! bool ||
        value.keys.any(
          (key) => !['command', 'output', 'truncated'].contains(key),
        )) {
      throw const FormatException();
    }
    return ChatShell(
      command: command,
      output: output,
      truncated: value['truncated'] as bool,
    );
  }
}

final class ChatSubtask {
  const ChatSubtask({
    required this.title,
    required this.agent,
    required this.status,
    required this.background,
    this.sessionId,
    this.toolCalls,
    this.statsComplete,
    this.durationMs,
  });
  final String title, agent, status;
  final bool background;
  final String? sessionId;
  final int? toolCalls, durationMs;
  final bool? statsComplete;
  String get label =>
      '${agent[0].toUpperCase()}${agent.substring(1)} Task${background ? ' (background)' : ''} — $title';

  /// Work still in flight: the subtask has neither finished nor failed, so
  /// the chat is waiting on it even when its own session reports idle.
  bool get active => ['pending', 'running', 'retry'].contains(status);

  factory ChatSubtask.parse(Map<String, dynamic> value) {
    if (value.keys.any(
          (key) => ![
            'title',
            'agent',
            'status',
            'background',
            'sessionId',
            'stats',
          ].contains(key),
        ) ||
        ![
          'pending',
          'running',
          'retry',
          'completed',
          'error',
          'unknown',
        ].contains(value['status']) ||
        value['background'] is! bool) {
      throw const FormatException();
    }
    int? toolCalls, durationMs;
    bool? complete;
    if (value.containsKey('stats')) {
      final stats = requiredMap(value, 'stats');
      final count = stats['toolCalls'];
      final duration = stats['durationMs'];
      if (count is! int ||
          count < 0 ||
          count > 5000 ||
          stats['complete'] is! bool ||
          (stats.containsKey('durationMs') &&
              (duration is! int ||
                  duration < 0 ||
                  duration > 9007199254740991)) ||
          stats.keys.any(
            (key) => !['toolCalls', 'complete', 'durationMs'].contains(key),
          )) {
        throw const FormatException();
      }
      toolCalls = count;
      complete = stats['complete'] as bool;
      durationMs = duration as int?;
    }
    return ChatSubtask(
      title: requiredString(value, 'title', max: 512),
      agent: requiredString(value, 'agent', max: 64),
      status: value['status'] as String,
      background: value['background'] as bool,
      sessionId: value.containsKey('sessionId')
          ? requiredString(value, 'sessionId', max: 128)
          : null,
      toolCalls: toolCalls,
      statsComplete: complete,
      durationMs: durationMs,
    );
  }
}

/// The user's answer to a pending permission request, mirroring OpenCode's
/// own choices. [always] is a persistent grant the user makes explicitly for
/// one request. [wire] is the value the protocol carries. See
/// CHAT-PERMISSIONS.md.
enum PermissionDecision {
  reject('reject'),
  once('once'),
  always('always');

  const PermissionDecision(this.wire);
  final String wire;
}

/// A pending permission request. Only what OpenCode itself prepared for
/// display crosses the wire -- never raw native metadata. See
/// CHAT-PERMISSIONS.md.
final class ChatPermission {
  const ChatPermission({
    required this.id,
    required this.operation,
    required this.description,
    this.pattern,
  });
  final String id, operation, description;
  final String? pattern;

  factory ChatPermission.parse(Map<String, dynamic> value) {
    final description = value['description'];
    final pattern = value['pattern'];
    if (!_chatOperations.contains(value['operation']) ||
        description is! String ||
        description.isEmpty ||
        description.length > 256 ||
        (value.containsKey('pattern') &&
            (pattern is! String || pattern.isEmpty || pattern.length > 256)) ||
        value.keys.any(
          (key) => !['id', 'operation', 'description', 'pattern'].contains(key),
        )) {
      throw const FormatException();
    }
    return ChatPermission(
      id: requiredString(value, 'id', max: 128),
      operation: value['operation'] as String,
      description: description,
      pattern: pattern as String?,
    );
  }
}

/// One choice OpenCode prepared for a pending question. The label and description are
/// authored by the model, so they are bounded and sanitized before they reach here; the
/// app renders them as plain text and never as markup. See ADR 0011.
final class ChatQuestionOption {
  const ChatQuestionOption({required this.label, this.description});
  final String label;
  final String? description;

  factory ChatQuestionOption.parse(Map<String, dynamic> value) {
    final label = value['label'];
    final description = value['description'];
    if (label is! String ||
        label.isEmpty ||
        label.length > 80 ||
        (value.containsKey('description') &&
            (description is! String || description.length > 256)) ||
        value.keys.any((key) => !['label', 'description'].contains(key))) {
      throw const FormatException();
    }
    return ChatQuestionOption(
      label: label,
      description: description as String?,
    );
  }
}

/// One question within a pending batch. The answer is a set of indices into [options],
/// or -- only when [custom] allows it -- free text the user typed, mirroring OpenCode's
/// own TUI "type your own answer" affordance. See ADR 0011.
final class ChatQuestionPrompt {
  const ChatQuestionPrompt({
    required this.header,
    required this.question,
    required this.options,
    required this.multiple,
    required this.custom,
  });
  final String header, question;
  final List<ChatQuestionOption> options;
  final bool multiple, custom;

  factory ChatQuestionPrompt.parse(Map<String, dynamic> value) {
    final header = value['header'];
    final question = value['question'];
    final options = value['options'];
    if (header is! String ||
        header.length > 64 ||
        question is! String ||
        question.isEmpty ||
        question.length > 2000 ||
        value['multiple'] is! bool ||
        value['custom'] is! bool ||
        options is! List ||
        options.isEmpty ||
        options.length > 32 ||
        value.keys.any(
          (key) =>
              [
                'header',
                'question',
                'options',
                'multiple',
                'custom',
              ].contains(key) ==
              false,
        )) {
      throw const FormatException();
    }
    return ChatQuestionPrompt(
      header: header,
      question: question,
      options: options
          .map(
            (option) =>
                ChatQuestionOption.parse(option as Map<String, dynamic>),
          )
          .toList(growable: false),
      multiple: value['multiple'] as bool,
      custom: value['custom'] as bool,
    );
  }
}

/// A batch of one or more questions OpenCode is blocked on, all sharing one [id] and
/// answered together: OpenCode's own `question` tool can ask several at once, and its
/// reply endpoint has no per-question form, so a batch is always answered or rejected as
/// a whole. See ADR 0011 and CHAT-QUESTIONS.md.
final class ChatQuestion {
  const ChatQuestion({required this.id, required this.questions});
  final String id;
  final List<ChatQuestionPrompt> questions;

  factory ChatQuestion.parse(Map<String, dynamic> value) {
    final questions = value['questions'];
    if (questions is! List ||
        questions.isEmpty ||
        questions.length > 8 ||
        value.keys.any((key) => !['id', 'questions'].contains(key))) {
      throw const FormatException();
    }
    return ChatQuestion(
      id: requiredString(value, 'id', max: 128),
      questions: questions
          .map(
            (prompt) =>
                ChatQuestionPrompt.parse(prompt as Map<String, dynamic>),
          )
          .toList(growable: false),
    );
  }
}

/// One entry of OpenCode's own task list for the session, as the agent's
/// task-list tool last wrote it. Read-only: this app never adds, reorders,
/// completes, or clears a task -- the agent owns its list. See CHAT-TODOS.md.
final class ChatTodo {
  const ChatTodo({
    required this.id,
    required this.content,
    required this.status,
  });
  final String id, content, status;
  bool get done => status == 'completed';
  bool get running => status == 'in_progress';
  bool get cancelled => status == 'cancelled';

  /// The state in words. Never rely on an icon or color alone to carry it.
  String get label => switch (status) {
    'completed' => 'Done',
    'in_progress' => 'In progress',
    'cancelled' => 'Cancelled',
    _ => 'To do',
  };

  factory ChatTodo.parse(Map<String, dynamic> value) {
    final content = value['content'];
    if (content is! String ||
        content.isEmpty ||
        content.length > 256 ||
        ![
          'pending',
          'in_progress',
          'completed',
          'cancelled',
        ].contains(value['status']) ||
        value.keys.any((key) => !['id', 'content', 'status'].contains(key))) {
      throw const FormatException();
    }
    return ChatTodo(
      id: requiredString(value, 'id', max: 128),
      content: content,
      status: value['status'] as String,
    );
  }
}

/// The session's task list, or `null` when this client did not opt in (or the
/// connector does not offer one). An opted-in snapshot always carries a list,
/// empty when the session has no tasks.
List<ChatTodo>? parseTodos(Map<String, dynamic> value) {
  if (!value.containsKey('todos')) return null;
  final todos = parseItems(value, 'todos', 100, ChatTodo.parse);
  if (todos.map((todo) => todo.id).toSet().length != todos.length) {
    throw const FormatException();
  }
  return List.unmodifiable(todos);
}

List<T> parseItems<T>(
  Map<String, dynamic> value,
  String key,
  int limit,
  T Function(Map<String, dynamic>) parse,
) {
  final items = value[key];
  if (items is! List || items.length > limit) throw const FormatException();
  return items.map((item) => parse(item as Map<String, dynamic>)).toList();
}

String? pageCursor(Map<String, dynamic> value) =>
    value['cursor'] == null ? null : requiredString(value, 'cursor', max: 128);

ChatPermission? parsePermission(Map<String, dynamic> value) =>
    value['permission'] == null
    ? null
    : ChatPermission.parse(requiredMap(value, 'permission'));

ChatQuestion? parseQuestion(Map<String, dynamic> value) =>
    value['question'] == null
    ? null
    : ChatQuestion.parse(requiredMap(value, 'question'));
