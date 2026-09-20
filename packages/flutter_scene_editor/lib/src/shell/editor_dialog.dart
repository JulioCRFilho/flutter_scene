/// In-window modal dialogs for the editor shell.
///
/// With the windowing feature enabled, showDialog hosts dialogs in their own
/// OS window. On the stable revision the editor distributions build against,
/// that window never receives its content size (it opens 0x0) while still
/// blocking the app modally, and its widget tree mounts outside the shell's
/// theme scope, so forui controls throw on mount. Pushing the DialogRoute
/// directly keeps every editor dialog a classic modal inside the main
/// window. All shell dialogs go through this helper, never showDialog.
library;

import 'package:material_ui/material_ui.dart';

/// Shows [builder]'s widget as a modal dialog inside the current window.
///
/// A drop-in for showDialog that never hosts the dialog in a separate OS
/// window. Returns the value passed to `Navigator.pop`, like showDialog.
Future<T?> showEditorDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    DialogRoute<T>(
      context: context,
      builder: builder,
      barrierColor: Colors.black54,
      barrierDismissible: barrierDismissible,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

/// Prompts for the spatial grid cell size (world units) for mesh splitting.
Future<double?> promptSplitGridCellSize(BuildContext context) {
  final textCtrl = TextEditingController(text: '10.0');
  return showEditorDialog<double>(
    context,
    builder: (context) => AlertDialog(
      title: const Text('Split Mesh by Grid'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Divides the mesh into spatial cells of the specified size. '
            'Each cell with geometry becomes an independent twin node.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: textCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Cell size (world units)',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (value) {
              final parsed = double.tryParse(value);
              if (parsed != null && parsed > 0) {
                Navigator.of(context).pop(parsed);
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final parsed = double.tryParse(textCtrl.text);
            if (parsed != null && parsed > 0) {
              Navigator.of(context).pop(parsed);
            }
          },
          child: const Text('Split'),
        ),
      ],
    ),
  );
}

