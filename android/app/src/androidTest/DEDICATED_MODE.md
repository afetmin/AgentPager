# Dedicated / immersive mode regression tests

These tests drive the real `MainActivity` through Android accessibility, inspect
system-bar visibility and `FLAG_KEEP_SCREEN_ON`, and check saved preferences. They
cover a disabled cold start, default-enabled behavior, exit/re-entry in the same
activity, focus restoration, and both choices surviving a fresh activity launch.
The original dedicated-mode preference and pairing credentials are restored.

Use an unlocked Android phone/tablet emulator or test device with system bars.
No desktop server is required. The platform-only instrumentation runner does not
require adding AndroidX/JUnit test dependencies to the app.

From `android/`, with Java and Android SDK configured:

```sh
bash ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest
adb install -r -g app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w \
  com.agentgrid.mobile.test/com.agentgrid.mobile.DedicatedModeRegressionTest
```

`-g` grants camera permission so an initial pairing-screen permission dialog
cannot obscure the settings during asynchronous pairing. Run on a test device;
the command grants the app's runtime permissions.

Expected runner summary: `Tests run: 2, Failures: 0`. Use this explicit runner,
not `connectedDebugAndroidTest`, which uses the app's pre-existing default runner.
