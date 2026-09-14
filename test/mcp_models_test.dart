import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/domain/mcp_models.dart';

import 'support/mcp_fakes.dart';

void main() {
  test('shared project MCP fixture parses all statuses and both requests', () {
    final fixture = mcpFixture;
    final snapshot = McpSnapshot.parse(fixture['snapshotResponse']);
    final update = McpSnapshot.parse(fixture['update'], subscription: true);
    expect(snapshot.projectId, mcpProject);
    expect(snapshot.servers.map((s) => s.status), McpStatus.values);
    expect(
      update.servers.map((s) => s.name),
      snapshot.servers.map((s) => s.name),
    );
    expect(update.revision, 1);
    expect(McpSnapshot.request(mcpProject), fixture['snapshotRequest']);
    expect(
      McpSnapshot.request(mcpProject, subscriptionId: update.subscriptionId),
      fixture['subscribeRequest'],
    );
    expect(() => snapshot.servers.clear(), throwsUnsupportedError);
  });

  test(
    'ready empty and unavailable empty are distinct; limits count UTF16',
    () {
      final base = Map<String, dynamic>.from(
        mcpFixture['snapshotResponse'] as Map,
      );
      expect(McpSnapshot.parse({...base, 'servers': []}).available, isTrue);
      expect(
        McpSnapshot.parse({...base, 'state': 'unavailable', 'servers': []})
            .available,
        isFalse,
      );
      for (final name in ['x' * 128, '\u{1f600}' * 64]) {
        expect(
          McpSnapshot.parse({
            ...base,
            'servers': [
              {'name': name, 'status': 'connected'},
            ],
          }).servers.single.name,
          name,
        );
      }
      expect(
        McpSnapshot.parse({
          ...base,
          'servers': List.generate(
            100,
            (i) => {'name': 'server-$i', 'status': 'connected'},
          ),
        }).servers.length,
        100,
      );
    },
  );

  final snapshot = Map<String, dynamic>.from(
    mcpFixture['snapshotResponse'] as Map,
  );
  final update = Map<String, dynamic>.from(mcpFixture['update'] as Map);
  final invalid = <Object?>[
    null,
    [],
    {...snapshot, 'extra': true},
    {...snapshot}..remove('state'),
    {...snapshot, 'version': 2},
    {...snapshot, 'version': 1.0},
    {...snapshot, 'projectId': 'not-uuid'},
    {...snapshot, 'state': 'unknown'},
    {...snapshot, 'state': 'unavailable'},
    {...snapshot, 'servers': {}},
    {
      ...snapshot,
      'servers': List.generate(
        101,
        (i) => {'name': 's$i', 'status': 'connected'},
      ),
    },
    {
      ...snapshot,
      'servers': [
        {'name': 'same', 'status': 'connected'},
        {'name': 'same', 'status': 'failed'},
      ],
    },
    for (final row in [
      null,
      {},
      {'name': 'server'},
      {'status': 'connected'},
      {'name': 'server', 'status': 'connected', 'url': 'private'},
      {'name': 'server', 'status': 'unknown'},
      {'name': 1, 'status': 'connected'},
      for (final name in [
        '',
        'x' * 129,
        '\u{1f600}' * 65,
        for (final code in [
          0,
          10,
          31,
          127,
          128,
          159,
          0x61c,
          0x200e,
          0x200f,
          0x202a,
          0x202e,
          0x2066,
          0x2069,
        ])
          'a${String.fromCharCode(code)}b',
      ])
        {'name': name, 'status': 'connected'},
    ])
      {
        ...snapshot,
        'servers': [row],
      },
  ];
  for (var i = 0; i < invalid.length; i++) {
    test('reject hostile snapshot $i', () {
      expect(() => McpSnapshot.parse(invalid[i]), throwsFormatException);
    });
  }
  for (final revision in [-1, 1.0, '1', null, 9007199254740992]) {
    test('reject unsafe revision $revision', () {
      expect(
        () => McpSnapshot.parse({
          ...update,
          'revision': revision,
        }, subscription: true),
        throwsFormatException,
      );
    });
  }
  test('strict topic shapes cannot substitute snapshots and subscriptions', () {
    expect(() => McpSnapshot.parse(update), throwsFormatException);
    expect(
      () => McpSnapshot.parse(snapshot, subscription: true),
      throwsFormatException,
    );
    expect(
      () => McpSnapshot.parse({
        ...update,
        'subscriptionId': 'bad',
      }, subscription: true),
      throwsFormatException,
    );
    expect(() => McpSnapshot.request('bad'), throwsFormatException);
    expect(
      () => McpSnapshot.request(mcpProject, subscriptionId: 'bad'),
      throwsFormatException,
    );
    for (final revision in [0, 9007199254740991]) {
      expect(
        McpSnapshot.parse({
          ...update,
          'revision': revision,
        }, subscription: true).revision,
        revision,
      );
    }
  });
}
