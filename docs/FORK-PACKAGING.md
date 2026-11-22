# Fork packaging / 扩展版打包

This path is separate from the upstream installer and tag workflow. It does not publish anything. / 此流程与上游安装器及标签工作流分开，不执行发布。

## 1. Windows x64 / Windows 安装包

On a disposable Windows user profile or VM, check out the exact release commit. Install PowerShell 7.2+, Python 3, .NET SDK **8.0.419** (the notice set matches runtime 8.0.25), and Inno Setup **6.4+**. The fork-only, manual workflow `fork-windows.yml` performs this check on Windows; it is intentionally not triggered on push/tag. Do not run the installer smoke test in a profile with a real Bridge or user data.

```powershell
./scripts/package-windows-fork.ps1 -Version 0.4.3-rc.2 `
  -OutputDirectory ./dist/windows-rc2 -VerifyInDisposableProfile
```

`AgentPager-Windows-Setup.exe` installs per user, adds a Start Menu shortcut and an Apps & Features uninstall entry. `AgentPager-Windows-Portable.zip` contains the same Bridge bytes. Setup does not launch the app unless selected, and silent Setup does not launch it. The installed and portable copies use the same Bridge runtime state; quit the old tray Bridge before switching. Uninstall removes only installer-owned files and shortcuts, not shared startup, hooks, pairing, or preferences. Disable startup/remove hooks inside Bridge before uninstall **only** if none of your other Bridge copies uses them. Windows builds are currently unsigned; checksums do not replace Authenticode.

在干净、可丢弃的 Windows 用户环境中运行，勿在日常使用的 Bridge 用户环境执行验证。安装器按当前用户安装，添加开始菜单快捷方式和系统卸载项；便携包的 Bridge 与安装器内的版本字节一致。安装器默认不启动程序，静默安装也不启动；切换版本前请退出旧托盘程序。卸载只移除安装器自有文件及快捷方式，不清理共享的自启动、钩子、配对或设置。两个 Windows 文件目前均未做 Authenticode 签名。

The command fetches four hash-pinned supplier notices; `-TermsDirectory` can point to the same exact source files prepared offline with `python3 scripts/package-fork-release.py windows-terms --out <new-directory>`. The native test checks registration, installed-vs-portable bytes, and uninstall ownership boundaries. Its receipt and logs are internal, not release assets. Do not edit or fabricate the receipt; it is a hash/commit binding from a trusted test run, not independently signed proof of execution. The smoke does not cover rendering or next-login behavior.

## 2. Stage separate assets locally / 本地平铺整理资产

Use the same clean commit on the assembly machine. Supply the **already signed** Android coexistence APK from that commit, the maintained certificate's SHA-256 digest, Android SDK `apksigner` and `aapt2`, and the verified Windows output directory. Use the SDK tools' actual executable files on Linux. No key or password is passed to the assembler. / 使用同一个干净的提交及已用长期签名证书签署的共存 APK；打包工具只接收公开证书的指纹，不接收签名密钥或密码。

```sh
python3 scripts/package-fork-release.py assemble \
  --version 0.4.3-rc.2 --windows dist/windows-rc2 \
  --apk /path/to/already-signed-coexistence.apk \
  --apksigner "$ANDROID_HOME/build-tools/35.0.0/apksigner" \
  --aapt2 "$ANDROID_HOME/build-tools/35.0.0/aapt2" \
  --android-cert-sha256 "$RELEASE_CERT_SHA256" --out dist/release-rc2
(cd dist/release-rc2 && sha256sum -c SHA256SUMS.txt)
```

The fresh output directory contains the standalone Setup, portable ZIP, one Android APK, one Chrome/Edge ZIP, exact Git source ZIP, and `SHA256SUMS.txt`. There is no wrapper archive, debug/unsigned APK, Firefox artifact, or macOS build. The receipt binds Windows inputs to the commit; the Android checks verify the signing certificate, fork app ID, non-debuggable status and version, not which commit built the APK. Keep the Android build provenance yourself. To test packaging contracts without performing an install or signing: `python3 -m unittest discover -s scripts/tests -v`.
