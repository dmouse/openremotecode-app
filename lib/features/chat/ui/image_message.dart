import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../domain/chat_models.dart';

/// A WhatsApp-style bounded preview thumbnail for an inline chat image.
/// Tapping it opens a full-screen, pinch-to-zoom view of the same bytes --
/// there is no higher-resolution original to fetch. See CHAT-IMAGES.md.
class ImageMessage extends StatelessWidget {
  const ImageMessage({super.key, required this.image});
  final ChatImage image;

  Uint8List? _decode() {
    try {
      return base64Decode(image.data);
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _decode();
    if (bytes == null) return const SizedBox.shrink();
    final width = image.width, height = image.height;
    final aspect = (width != null && height != null && width > 0 && height > 0)
        ? width / height
        : 1.0;
    return Semantics(
      label: 'Image. Double tap to view larger.',
      button: true,
      image: true,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _ImageViewer(bytes: bytes),
              fullscreenDialog: true,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
              child: AspectRatio(
                aspectRatio: aspect,
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.bytes});
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    body: Center(
      child: InteractiveViewer(
        maxScale: 5,
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      ),
    ),
  );
}
