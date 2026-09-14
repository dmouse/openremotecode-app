import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openremotecode/features/chat/ui/activity_row.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'activity artwork stays within text-sized bounds at text scale $scale',
      (tester) async {
        final font = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await font.load();
        const icons = [
          Icons.psychology_outlined,
          Icons.settings_outlined,
          Icons.arrow_forward,
          Icons.edit_outlined,
          Icons.note_add_outlined,
          Icons.search,
          Icons.folder_outlined,
          Icons.terminal,
          Icons.language,
          Icons.error_outline,
          Icons.check,
          Icons.account_tree_outlined,
        ];
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  for (final icon in icons)
                    RepaintBoundary(
                      key: ValueKey(icon),
                      child: ActivityRow(
                        icon: icon,
                        color: Colors.black,
                        title: const SizedBox.shrink(),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        for (final icon in icons) {
          expect(
            tester.getSize(find.byIcon(icon)),
            Size(12 * scale, 12 * scale),
          );
        }
        Future<Size> inkSize(IconData icon) async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(ValueKey(icon)),
          );
          final image = await boundary.toImage(pixelRatio: 4);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          var left = image.width, top = image.height, right = -1, bottom = -1;
          for (var y = 0; y < image.height; y++) {
            for (var x = 0; x < image.width; x++) {
              if (bytes.getUint8((y * image.width + x) * 4 + 3) < 128) continue;
              if (x < left) left = x;
              if (x > right) right = x;
              if (y < top) top = y;
              if (y > bottom) bottom = y;
            }
          }
          image.dispose();
          expect(right, greaterThanOrEqualTo(left));
          return Size((right - left + 1) / 4, (bottom - top + 1) / 4);
        }

        final sizes = await tester.runAsync(
          () async => [for (final icon in icons) await inkSize(icon)],
        );
        for (final size in sizes!) {
          // Natural font glyph insets are preserved instead of magnifying each
          // icon past the header's font size with a per-glyph transform.
          expect(
            size.longestSide,
            inInclusiveRange(8 * scale - 0.5, 12 * scale),
            reason: '$sizes',
          );
        }
      },
    );
  }
}
