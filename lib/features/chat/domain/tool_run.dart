import 'chat_models.dart';

/// A maximal run of strictly consecutive tool-call parts within one message,
/// condensed into a single summary row in the conversation view. Every part
/// has a non-null [ChatMessagePart.tool]; order is preserved from the source
/// message.
final class ToolRun {
  const ToolRun(this.parts);
  final List<ChatMessagePart> parts;

  bool get failed => parts.any((part) => part.tool!.status == 'error');
  bool get running => parts.any((part) => part.tool!.status == 'running');

  /// A natural-language tally by operation, e.g. "Ran 3 commands, used a
  /// tool". Unknown/MCP/other tools fall under "tool" already at the source
  /// (see `ChatTool.operation`), so every value here is one of the eight
  /// known operations.
  String get summary {
    final counts = <String, int>{};
    for (final part in parts) {
      final operation = part.tool!.operation;
      counts[operation] = (counts[operation] ?? 0) + 1;
    }
    final joined = _operationOrder
        .where(counts.containsKey)
        .map((operation) => _phrase(operation, counts[operation]!))
        .join(', ');
    return joined.isEmpty
        ? joined
        : joined[0].toUpperCase() + joined.substring(1);
  }
}

const _operationOrder = [
  'execute',
  'edit',
  'write',
  'read',
  'search',
  'list',
  'fetch',
  'tool',
];

// Lowercase: only the first clause of a joined summary is capitalized.
String _phrase(String operation, int count) => switch (operation) {
  'execute' => 'ran ${count == 1 ? 'a command' : '$count commands'}',
  'edit' => 'edited ${count == 1 ? 'a file' : '$count files'}',
  'write' => 'created ${count == 1 ? 'a file' : '$count files'}',
  'read' => 'read ${count == 1 ? 'a file' : '$count files'}',
  'search' => count == 1 ? 'searched once' : 'searched $count times',
  'list' => count == 1 ? 'listed once' : 'listed $count times',
  'fetch' => 'fetched ${count == 1 ? 'a URL' : '$count URLs'}',
  _ => 'used ${count == 1 ? 'a tool' : '$count tools'}',
};

/// Splits [parts] into a display plan: a `ChatMessagePart` renders exactly as
/// it does today; a [ToolRun] replaces a run of [minLength] or more
/// consecutive tool-call parts. Text, reasoning, subtask and image parts
/// always break a run and are never absorbed into one.
List<Object> condenseToolRuns(
  Iterable<ChatMessagePart> parts, {
  int minLength = 2,
}) {
  final plan = <Object>[];
  var run = <ChatMessagePart>[];
  void flush() {
    if (run.isEmpty) return;
    if (run.length >= minLength) {
      plan.add(ToolRun(List.unmodifiable(run)));
    } else {
      plan.addAll(run);
    }
    run = <ChatMessagePart>[];
  }

  for (final part in parts) {
    if (part.tool != null) {
      run.add(part);
    } else {
      flush();
      plan.add(part);
    }
  }
  flush();
  return plan;
}

/// The ids of shell-bearing tool parts that would be absorbed into a
/// condensed [ToolRun] (a run of [minLength] or more consecutive tool
/// parts), without building the full [condenseToolRuns] plan. For a call
/// site that only needs this yes/no membership check -- e.g. deciding which
/// shell rows can still be expanded inline -- this skips allocating a
/// `List<Object>` plan and a `ToolRun` per run, which matters when it runs
/// over every retained message (including off-screen ones) on every
/// rebuild, not just the messages actually on screen.
Set<String> condensedShellPartIds(
  Iterable<ChatMessagePart> parts, {
  int minLength = 2,
}) {
  final ids = <String>{};
  final run = <ChatMessagePart>[];
  void flush() {
    if (run.length >= minLength) {
      for (final part in run) {
        if (part.tool!.shell != null) ids.add(part.id);
      }
    }
    run.clear();
  }

  for (final part in parts) {
    if (part.tool != null) {
      run.add(part);
    } else {
      flush();
    }
  }
  flush();
  return ids;
}

/// True when [message] contributes nothing but tool-call parts -- eligible
/// to merge with adjacent such messages into one cross-message [ToolRun].
/// OpenCode commonly emits one tool call per assistant turn -- each its own
/// message, with the tool as its only meaningful part once ignored/blank
/// reasoning is filtered out server-side -- rather than batching several
/// tool calls into a single message's parts array, so condensing has to
/// span these message boundaries to have any real effect.
bool isPureToolMessage(ChatMessage message) =>
    message.role == 'assistant' &&
    !message.truncated &&
    (message.parts?.isNotEmpty ?? false) &&
    message.parts!.every((part) => part.tool != null);

/// Messages that would render something -- drops empty projected records
/// (including synthetic shell-only user messages) so they never introduce a
/// phantom gap or break a run of activity rows. Shared between the message
/// list's own rendering and [findToolRun]'s live re-derivation so both agree
/// on which messages are adjacent.
List<ChatMessage> visibleMessages(Iterable<ChatMessage> messages) => messages
    .where(
      (message) =>
          message.truncated ||
          (message.parts == null
              ? message.text.trim().isNotEmpty
              : message.parts!.any(
                  (part) => part.type != 'text' || part.text.trim().isNotEmpty,
                )),
    )
    .toList();

/// Index ranges (inclusive, oldest-first) of maximal runs of two or more
/// consecutive [isPureToolMessage] messages in [messages].
List<(int, int)> pureToolMessageRuns(List<ChatMessage> messages) {
  final runs = <(int, int)>[];
  var i = 0;
  while (i < messages.length) {
    if (!isPureToolMessage(messages[i])) {
      i++;
      continue;
    }
    var end = i;
    while (end + 1 < messages.length && isPureToolMessage(messages[end + 1])) {
      end++;
    }
    if (end > i) runs.add((i, end));
    i = end + 1;
  }
  return runs;
}

/// Finds the run led by [leadingPartId], anchored at message [anchorId],
/// re-deriving it fresh from [messages] (oldest-first) so a sheet built from
/// this stays live rather than a frozen snapshot taken at tap-time. Mirrors
/// the exact grouping the conversation view uses to merge adjacent
/// pure-tool messages, falling back to plain per-message condensing when
/// there's no cross-message run to merge.
ToolRun? findToolRun(
  List<ChatMessage> messages,
  String anchorId,
  String leadingPartId,
) {
  final index = messages.indexWhere((m) => m.id == anchorId);
  if (index < 0) return null;
  for (final (start, end) in pureToolMessageRuns(messages)) {
    if (start != index) continue;
    final merged = <ChatMessagePart>[
      for (var j = start; j <= end; j++) ...messages[j].parts!,
    ];
    for (final item in condenseToolRuns(merged)) {
      if (item is ToolRun && item.parts.first.id == leadingPartId) return item;
    }
    return null;
  }
  final parts = messages[index].parts;
  if (parts == null) return null;
  for (final item in condenseToolRuns(parts)) {
    if (item is ToolRun && item.parts.first.id == leadingPartId) return item;
  }
  return null;
}
