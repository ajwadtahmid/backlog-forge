import 'package:material_ui/material_ui.dart';

/// Above this the phone's font size setting is "large" (Settings → Display →
/// Font size); layouts that only fit at normal sizes switch to a roomier form.
const kLargeTextScale = 1.3;

/// How much the user has scaled text, as a factor (1.0 = default).
double textScaleOf(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(14) / 14;

bool isLargeText(BuildContext context) => textScaleOf(context) > kLargeTextScale;
