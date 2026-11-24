import 'package:material_ui/material_ui.dart';

import '../../constants.dart';
import '../game_detail_widgets.dart';

/// Return type for [HltbDialog]. Carries the three nullable hour fields.
class HltbDialogResult {
  final double? essential, extended, completionist;
  const HltbDialogResult(this.essential, this.extended, this.completionist);
}

/// True when too little height is left for a normal dialog, typically a phone
/// held sideways with the keyboard open (about 130 dp above the keyboard).
bool isCompactDialog(BuildContext context) {
  final mq = MediaQuery.of(context);
  return mq.size.height - mq.viewInsets.bottom < 360;
}

/// One-row form for [isCompactDialog]: the fields on the left, Cancel and Save
/// on the right, no title. The title text moves into the field labels.
Widget _compactDialog(
  BuildContext context, {
  required Widget body,
  required VoidCallback onSave,
}) {
  return Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: body),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: FilledButton(onPressed: onSave, child: const Text('Save')),
          ),
        ],
      ),
    ),
  );
}

// ── Playtime dialog ───────────────────────────────────────────────────────────

class PlaytimeDialog extends StatefulWidget {
  const PlaytimeDialog({
    super.key,
    required this.initialHours,
    required this.isSteamGame,
  });
  final double initialHours;
  final bool isSteamGame;

  @override
  State<PlaytimeDialog> createState() => _PlaytimeDialogState();
}

class _PlaytimeDialogState extends State<PlaytimeDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialHours.toStringAsFixed(1));
    // Start with the whole value selected so typing replaces it instead of
    // appending to "0.0".
    _ctrl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _ctrl.text.length,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final hours = double.tryParse(_ctrl.text.trim());
    if (hours == null || !hours.isFinite || hours < 0) {
      setState(() => _error = 'Enter a valid number (e.g. 12.5)');
      return;
    }
    if (hours * 60 > AppConstants.kMaxPlaytimeMinutes) {
      setState(
        () => _error =
            'That is more than ${AppConstants.kMaxPlaytimeMinutes ~/ 60} hours',
      );
      return;
    }
    Navigator.pop(context, hours);
  }

  Widget _field({required String label}) => TextField(
    controller: _ctrl,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    autofocus: true,
    onChanged: (_) => setState(() => _error = null),
    decoration: InputDecoration(
      labelText: label,
      suffixText: 'h',
      border: const OutlineInputBorder(),
      isDense: true,
      errorText: _error,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (isCompactDialog(context)) {
      return _compactDialog(
        context,
        body: _field(label: 'Edit playtime (hours)'),
        onSave: _submit,
      );
    }
    return AlertDialog(
      scrollable: true,
      title: const Text('Edit Playtime'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            onChanged: (_) => setState(() => _error = null),
            decoration: InputDecoration(
              labelText: 'Hours played',
              suffixText: 'h',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          if (widget.isSteamGame) ...[
            const SizedBox(height: 8),
            Text(
              'Steam games will have this overwritten on next sync.',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

// ── HLTB hours dialog ─────────────────────────────────────────────────────────

class HltbDialog extends StatefulWidget {
  const HltbDialog({
    super.key,
    this.essential,
    this.extended,
    this.completionist,
  });
  final double? essential, extended, completionist;

  @override
  State<HltbDialog> createState() => _HltbDialogState();
}

class _HltbDialogState extends State<HltbDialog> {
  late final TextEditingController _ess, _ext, _cmp;

  @override
  void initState() {
    super.initState();
    _ess = TextEditingController(
      text: widget.essential?.toStringAsFixed(1) ?? '',
    );
    _ext = TextEditingController(
      text: widget.extended?.toStringAsFixed(1) ?? '',
    );
    _cmp = TextEditingController(
      text: widget.completionist?.toStringAsFixed(1) ?? '',
    );
  }

  @override
  void dispose() {
    _ess.dispose();
    _ext.dispose();
    _cmp.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(
    context,
    HltbDialogResult(
      double.tryParse(_ess.text.trim()),
      double.tryParse(_ext.text.trim()),
      double.tryParse(_cmp.text.trim()),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (isCompactDialog(context)) {
      return _compactDialog(
        context,
        onSave: _submit,
        body: Row(
          children: [
            Expanded(
              child: HoursField(controller: _ess, label: 'Essential'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HoursField(controller: _ext, label: 'Extended'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: HoursField(controller: _cmp, label: 'Completionist'),
            ),
          ],
        ),
      );
    }
    return AlertDialog(
      scrollable: true,
      title: const Text('Edit Time to Beat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Builder(
            builder: (context) => Text(
              'Leave a field blank to clear it.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 12),
          HoursField(controller: _ess, label: 'Essential'),
          const SizedBox(height: 10),
          HoursField(controller: _ext, label: 'Extended'),
          const SizedBox(height: 10),
          HoursField(controller: _cmp, label: 'Completionist'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}

// ── Notes dialog ──────────────────────────────────────────────────────────────

/// Shows the notes editing dialog and returns the saved text, or null if cancelled.
Future<String?> showNotesDialog(
  BuildContext context,
  String? currentNotes,
) async {
  final ctrl = TextEditingController(text: currentNotes ?? '');
  final saved = await showDialog<String?>(
    context: context,
    builder: (ctx) => isCompactDialog(ctx)
        ? _compactDialog(
            ctx,
            onSave: () => Navigator.pop(ctx, ctrl.text),
            body: TextField(
              controller: ctrl,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          )
        : AlertDialog(
            scrollable: true,
            title: const Text('Notes'),
            content: TextField(
              controller: ctrl,
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(
                hintText: 'Add personal notes…',
                border: OutlineInputBorder(),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('Save'),
              ),
            ],
          ),
  );
  ctrl.dispose();
  return saved;
}
