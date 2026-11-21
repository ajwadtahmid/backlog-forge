import 'package:material_ui/material_ui.dart';

extension PlatformContext on BuildContext {
  bool get isMobileOS {
    final p = Theme.of(this).platform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }
}
