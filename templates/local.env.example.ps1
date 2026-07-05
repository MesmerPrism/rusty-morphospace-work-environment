# Copy to local/local.env.ps1 and edit for your workstation.

$env:RUSTY_MORPHOSPACE_WORKSPACE = "<workspace-root>"
$env:RUSTY_MORPHOSPACE_REPOS = "<workspace-root>/repos"
$env:RUSTY_MORPHOSPACE_ARTIFACTS = "<workspace-root>/artifacts"

$env:RUSTY_XR_ANDROID_SDK_ROOT = "<android-sdk-root>"
$env:RUSTY_XR_ANDROID_NDK_ROOT = "<android-ndk-root>"
$env:RUSTY_XR_ANDROID_JDK_ROOT = "<jdk-root>"
$env:RUSTY_XR_OPENXR_LOADER_QUEST = "<openxr-loader-so>"

$env:RUSTY_QUEST_MAKEPAD_SOURCE_ROOT = "<workspace-root>/repos/makepad-morphospace"

# Optional convenience aliases for tools. Prefer explicit paths in evidence.
$env:ANDROID_SDK_ROOT = $env:RUSTY_XR_ANDROID_SDK_ROOT
$env:ANDROID_NDK_ROOT = $env:RUSTY_XR_ANDROID_NDK_ROOT
$env:JAVA_HOME = $env:RUSTY_XR_ANDROID_JDK_ROOT
