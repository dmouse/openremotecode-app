import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/domain/chat_models.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              '../packages/protocol/test/fixtures/chat-questions-v1.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  test('the shared fixture parses into the client model', () {
    final question = ChatQuestion.parse(
      fixture['question'] as Map<String, dynamic>,
    );
    expect(question.id, fixture['question']['id']);
    expect(question.questions, hasLength(1));
    final prompt = question.questions.first;
    expect(prompt.question, fixture['question']['questions'][0]['question']);
    expect(prompt.multiple, isFalse);
    expect(prompt.options, hasLength(2));
    expect(prompt.options.first.label, 'Online backfill');
    expect(prompt.options.first.description, isNotNull);
    expect(prompt.custom, isTrue);

    final multiple = ChatQuestion.parse(
      fixture['multipleChoice'] as Map<String, dynamic>,
    );
    final multiplePrompt = multiple.questions.single;
    expect(multiplePrompt.multiple, isTrue);
    expect(multiplePrompt.options.first.description, isNull);
    expect(multiplePrompt.custom, isFalse);
  });

  test('a batch answers several questions in order under one id', () {
    final batch = ChatQuestion.parse(fixture['batch'] as Map<String, dynamic>);
    expect(batch.questions, hasLength(2));
    expect(batch.questions[0].header, 'Migration safety');
    expect(batch.questions[1].header, 'Targets');
    expect(batch.questions[1].custom, isFalse);
  });

  test('a body the contract forbids is rejected rather than rendered', () {
    // Mirrors the TypeScript assertions on the same fixture: anything that is not what
    // OpenCode prepared for display must not reach the UI.
    for (final entry
        in (fixture['rejected'] as Map<String, dynamic>).entries) {
      expect(
        () => ChatQuestion.parse(entry.value as Map<String, dynamic>),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test('agent-authored text is bounded on the client too', () {
    final base = fixture['question'] as Map<String, dynamic>;
    final prompt = (base['questions'] as List).single as Map<String, dynamic>;
    Map<String, dynamic> withPrompt(Map<String, dynamic> override) => {
      ...base,
      'questions': [
        {...prompt, ...override},
      ],
    };
    for (final override in [
      {'question': 'x' * 2001},
      {'header': 'x' * 65},
      {
        'options': [
          {'label': 'x' * 81},
        ],
      },
      {
        'options': [
          {'label': 'ok', 'description': 'x' * 257},
        ],
      },
      {'options': <dynamic>[]},
    ]) {
      expect(
        () => ChatQuestion.parse(withPrompt(override)),
        throwsFormatException,
        reason: '$override',
      );
    }
    expect(
      ChatQuestion.parse(
        withPrompt({'question': 'x' * 2000}),
      ).questions.single.question.length,
      2000,
    );
  });

  test('a snapshot without a pending question yields null', () {
    expect(parseQuestion({'question': null}), isNull);
    expect(parseQuestion(<String, dynamic>{}), isNull);
    expect(
      parseQuestion({'question': fixture['question']}),
      isA<ChatQuestion>(),
    );
  });
}
