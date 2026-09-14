import 'activity.generated.dart';

final class AgentActivity {
  const AgentActivity(this.kind, this.state);
  final String kind, state;
  bool get running => state == 'running';
  factory AgentActivity.parse(Map<String, dynamic> value) {
    if (!activityKinds.contains(value['kind']) ||
        !activityStates.contains(value['state']) ||
        value.keys.any((key) => key != 'kind' && key != 'state')) {
      throw const FormatException();
    }
    return AgentActivity(value['kind'] as String, value['state'] as String);
  }
}
