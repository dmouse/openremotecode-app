import '../../platform/remote_api.dart';
import 'data/chat_repository.dart';
import 'domain/chat_models.dart';

/// The authorized-project list and path-entry availability for a connector.
///
/// Both operations that touch this state (a full refresh, and resolving a
/// typed path to a project) are cross-domain: on success they also reset the
/// chat list and move to the chats page, so `ChatViewModel` orchestrates them
/// under its own request/generation cycle rather than this object owning one
/// -- these fetch primitives just do the RPC and parsing.
final class ProjectsViewModel {
  ProjectsViewModel(this.repository, this.connectorId);

  final ChatRepository repository;
  final String connectorId;

  List<RemoteProject> projects = [];
  bool pathEntry = false;

  Future<void> fetchList() async {
    final response = await repository.chatRequest(
      connectorId,
      'project.list',
      const {},
    );
    projects = parseItems(response, 'projects', 100, RemoteProject.parse);
    pathEntry = response['pathEntry'] == true;
  }

  Future<RemoteProject> resolvePath(String input) async {
    if (input.trim().isEmpty || input.length > 4096) {
      throw ChatFailure.denied;
    }
    final response = await repository.chatRequest(connectorId, 'project.open', {
      'path': input.trim(),
    });
    return RemoteProject.parse(requiredMap(response, 'project'));
  }
}
