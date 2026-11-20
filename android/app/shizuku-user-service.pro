# Shizuku creates this UserService by class name in a process of its own, so
# neither the class nor its AIDL stub may be renamed or stripped.
-keep class com.azx8788.opencode.mini.shizuku.CommandService { *; }
-keep interface com.azx8788.opencode.mini.shizuku.IShizukuCommandService { *; }
# The service is looked up through the manifest-declared provider; keep the
# entry point the SDK reflects on.
-keep class rikka.shizuku.ShizukuProvider { *; }
