# SharedPreferences 2.5 uses JNI method descriptors from generated Dart code.
# @Keep on the registrar alone does not preserve parameter type names:
# R8 renamed kotlin.coroutines.Continuation, breaking getString/setString lookup.
-keep,includedescriptorclasses class io.flutter.plugins.sharedpreferences.** { *; }
-keep,includedescriptorclasses interface kotlin.coroutines.Continuation { *; }
# jni/src/kotlin.dart also looks up these runtime types and members by name.
-keep class kotlin.coroutines.intrinsics.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$* { *; }
-keep class kotlin.Unit { *; }
