import 'package:openremotecode/features/settings/data/settings_repository.dart';

final class MemorySettingsRepository implements SettingsRepository {
  MemorySettingsRepository({this.images = true, this.thinking = true});

  bool images;
  bool thinking;
  bool failImagesRead = false;
  bool failThinkingRead = false;
  bool failImagesWrite = false;
  bool failThinkingWrite = false;

  @override
  Future<bool> readShowImages() async {
    if (failImagesRead) throw StateError('image read failed');
    return images;
  }

  @override
  Future<bool> readShowThinkingMessages() async {
    if (failThinkingRead) throw StateError('thinking read failed');
    return thinking;
  }

  @override
  Future<void> writeShowImages(bool value) async {
    if (failImagesWrite) throw StateError('image write failed');
    images = value;
  }

  @override
  Future<void> writeShowThinkingMessages(bool value) async {
    if (failThinkingWrite) throw StateError('thinking write failed');
    thinking = value;
  }
}
