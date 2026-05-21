# Keep generic signatures so Gson TypeToken<List<...>>() resolves at
# runtime inside flutter_local_notifications' internal serialization of
# pending notifications. Without these, R8 strips the type argument and
# the plugin crashes with "TypeToken must be created with a type
# argument" on first launch after a cold start.
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod
-keepattributes Annotation
-keepattributes *Annotation*

-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.TypeAdapter
-keep class * extends com.google.gson.TypeAdapterFactory
-keep class * extends com.google.gson.JsonSerializer
-keep class * extends com.google.gson.JsonDeserializer

# Gson: preserve fields it reads via reflection — without this, R8 may
# rename fields in serialized model classes and break round-trips.
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}
