# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Dart/Flutter SQLite (drift)
-keep class com.tekartik.sqflite.** { *; }

# flutter_secure_storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# Keep native crash info readable in stack traces
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Play Core split-install classes are only used for Play Feature Delivery /
# deferred components, which this app does not use, and the artifact has
# been pulled from Maven — silence R8's missing-class errors for it.
-dontwarn com.google.android.play.core.**
