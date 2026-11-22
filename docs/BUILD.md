# 构建与发版 / Build and release

Run at the source root unless noted. 在源码根目录运行（另有说明的除外）。本候选基线 / Candidate baseline: .NET SDK 8.0.419, JDK 17, Android SDK 36, Gradle wrapper, Python 3.

```sh
dotnet publish windows/src/AgentPager.Bridge/AgentPager.Bridge.csproj -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true -p:DebugType=none -o dist/windows
(cd android && ./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease :app:assembleDebugAndroidTest)
python3 scripts/package-browser.py --out dist/extensions
```

Windows publishes `dist/windows/AgentPagerBridge.exe`; Android outputs under `android/app/build/outputs/apk/`. The default Android version is `0.4.3-rc.1` (code `7`). For a public Android build, sign the unsigned release APK with your maintained release key, verify with `apksigner`, and choose a version code higher than previously published builds. Do not use the debug key for public production updates.

Windows 输出为 `dist/windows/AgentPagerBridge.exe`；Android 输出在 `android/app/build/outputs/apk/`。正式发布时使用长期密钥签署 Release APK，用 `apksigner` 验证，并确保版本号代码高于此前发版；不要用测试密钥做公开正式更新。

`package-browser.py` creates the shared Chrome/Edge package. It is loaded unpacked for local testing. Store publishing is separate; no store submission is performed. 本地通过开发者模式加载扩展；商店发布另行处理。

Keep each release's exact corresponding source, build scripts, upstream notices, and third-party terms next to its binaries. A production release should also run the platform tests with real hardware/accounts. 发布二进制时同时提供该版本对应源码、构建脚本和许可归属；真机及真实账号是独立的验收步骤。
