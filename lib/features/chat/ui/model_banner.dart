import 'package:flutter/material.dart';

import '../../../ui/core/app_theme.dart';
import '../conversation_view_model.dart';

/// OpenCode's built-in variant ids get a friendly label; a custom id (from a
/// user's own config) falls back to a capitalized display of the raw id,
/// since effort ids are not a fixed set -- see ChatModelOption.effortLevels.
String effortLabel(String effort) => switch (effort) {
  'none' => 'None',
  'minimal' => 'Minimal',
  'low' => 'Low',
  'medium' => 'Medium',
  'high' => 'High',
  'xhigh' => 'Extra high',
  'max' => 'Max',
  _ when effort.isNotEmpty =>
    '${effort[0].toUpperCase()}${effort.substring(1)}',
  _ => effort,
};

/// The label for one slider stop. The leftmost stop leaves effort unset: no
/// effort travels with the prompt and the model's own default applies, so the
/// slider can always be returned to "not chosen".
String _stopLabel(String? stop) => stop == null ? 'Default' : effortLabel(stop);

/// The model banner: the sheet the composer's sparkles button raises from the
/// bottom edge, naming the model in force and laying that model's effort
/// levels out on one slider.
///
/// It comes up over the composer like the Build/Plan picker -- covering the
/// input and Send rather than floating above them -- so the only thing asking
/// for attention is the choice at hand. A drag commits when it ends (the
/// banner tracks the thumb itself until then), so sweeping across six levels
/// settles the selection once rather than six times. Every stop keeps its text
/// label on the slider's value semantics and in the banner's own title, so the
/// control never reads as thumb position alone.
class ModelBanner extends StatefulWidget {
  const ModelBanner({
    super.key,
    required this.model,
    required this.source,
    required this.onChangeModel,
  });

  final ConversationViewModel model;

  /// The composer this banner was raised for. A banner left open over a chat
  /// the composer has since left cannot change that chat's model.
  final String? source;

  /// Opens the full model list, closing this banner on the way.
  final VoidCallback onChangeModel;

  @override
  State<ModelBanner> createState() => _ModelBannerState();
}

class _ModelBannerState extends State<ModelBanner> {
  /// Where the thumb sits mid-drag, before the drag settles on a level.
  double? _thumb;

  ConversationViewModel get model => widget.model;

  /// The slider's stops: the unset default, then the levels the connector
  /// reported, in its own order -- lowest to highest for every provider seen
  /// so far, which is what makes one axis the right control for them.
  List<String?> get _stops => [
    null,
    ...?model.models.selectedModel?.effortLevels,
  ];

  int _committedStop(List<String?> stops) {
    final effort = model.models.selectedEffort;
    if (effort == null) return 0;
    final index = stops.indexOf(effort);
    return index < 0 ? 0 : index;
  }

  String? _stopAt(List<String?> stops, double value) =>
      stops[value.round().clamp(0, stops.length - 1)];

  void _commit(List<String?> stops, double value) {
    setState(() => _thumb = null);
    model.selectModel(model.models.selectedModel, _stopAt(stops, value));
  }

  @override
  Widget build(BuildContext context) {
    final stops = _stops;
    final enabled =
        model.canChangeModel &&
        model.models.supportsModelSelection &&
        model.composerKey == widget.source;
    // The title mirrors what is actually in force, and previews the dragged
    // level only while a drag is in flight.
    final shown = _thumb == null
        ? model.models.selectedEffort
        : _stopAt(stops, _thumb!);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _title(context, enabled: enabled, effort: shown),
            if (!model.models.supportsModelSelection)
              _note(
                context,
                'Restart OpenCode with the updated Remote plugin to choose a model.',
              )
            else if (model.models.selectedModel == null)
              _note(
                context,
                'OpenCode picks the model. Tap the name to choose one.',
              )
            // A model that reports no levels has nothing to say about them:
            // the banner is then its title alone, not a line of apology.
            else if (stops.length > 1)
              _slider(stops, enabled: enabled),
          ],
        ),
      ),
    );
  }

  /// The banner's one line of text and its way through to the model list: the
  /// model's name, the effort in force beside it, and a chevron -- the whole
  /// line is the tap target.
  Widget _title(
    BuildContext context, {
    required bool enabled,
    required String? effort,
  }) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: MergeSemantics(
        child: Semantics(
          hint: enabled ? 'Change model' : null,
          child: InkWell(
            key: const ValueKey('model-banner-title'),
            borderRadius: BorderRadius.circular(14),
            onTap: enabled ? widget.onChangeModel : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        model.models.selectedModel?.modelName ??
                            'Default model',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.ink,
                        ),
                      ),
                    ),
                    if (effort != null) ...[
                      const SizedBox(width: 6),
                      // Both halves flex: at large text sizes the pair has to
                      // give way rather than run off the sheet.
                      Flexible(
                        child: Text(
                          effortLabel(effort),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium?.copyWith(
                            color: AppTheme.muted,
                          ),
                        ),
                      ),
                    ],
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: enabled ? AppTheme.muted : AppTheme.border,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The effort levels as one pill: a dot per level inside an outlined track,
  /// filled up to the chosen one. Brand lime fills the track and dark ink
  /// carries the thumb and dots, never the reverse -- pale green never has to
  /// hold a shape against white.
  Widget _slider(List<String?> stops, {required bool enabled}) => Container(
    height: 56,
    decoration: BoxDecoration(
      color: AppTheme.inputSurface,
      borderRadius: BorderRadius.circular(28),
      // The same hairline the composer's input carries, so the pill reads as
      // part of that family rather than as a frame drawn around a control.
      border: Border.all(color: AppTheme.softBorder, width: 0.5),
    ),
    child: MergeSemantics(
      child: Semantics(
        label: 'Effort',
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 36,
            trackShape: const RoundedRectSliderTrackShape(),
            activeTrackColor: AppTheme.lime,
            inactiveTrackColor: AppTheme.neutralSurface,
            disabledActiveTrackColor: AppTheme.neutralSurface,
            disabledInactiveTrackColor: AppTheme.neutralSurface,
            // Matching the thumb radius keeps the track's ends exactly a
            // thumb's width from the pill's, so the thumb comes to rest flush
            // inside the track at either extreme.
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: 16,
              disabledThumbRadius: 16,
              elevation: 0,
              pressedElevation: 0,
            ),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            thumbColor: AppTheme.ink,
            disabledThumbColor: AppTheme.border,
            overlayColor: AppTheme.ink.withValues(alpha: 0.08),
            tickMarkShape: const RoundSliderTickMarkShape(tickMarkRadius: 3),
            activeTickMarkColor: AppTheme.ink.withValues(alpha: 0.3),
            inactiveTickMarkColor: AppTheme.muted.withValues(alpha: 0.35),
            disabledActiveTickMarkColor: AppTheme.muted.withValues(alpha: 0.2),
            disabledInactiveTickMarkColor: AppTheme.muted.withValues(
              alpha: 0.2,
            ),
            showValueIndicator: ShowValueIndicator.never,
          ),
          child: Slider(
            value: (_thumb ?? _committedStop(stops).toDouble()).clamp(
              0,
              (stops.length - 1).toDouble(),
            ),
            max: (stops.length - 1).toDouble(),
            divisions: stops.length - 1,
            semanticFormatterCallback: (value) =>
                _stopLabel(_stopAt(stops, value)),
            onChanged: enabled
                ? (value) => setState(() => _thumb = value)
                : null,
            onChangeEnd: enabled ? (value) => _commit(stops, value) : null,
          ),
        ),
      ),
    ),
  );

  Widget _note(BuildContext context, String message) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: AppTheme.muted),
    ),
  );
}
