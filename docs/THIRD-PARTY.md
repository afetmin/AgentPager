# 第三方许可 / Third-party terms

AgentPager 的原始 GNU GPL v3 和归属见 `LICENSE` 与 `NOTICE.md`。字体按所附 `LICENSES/` 中的 SIL OFL 条款分发。/ See `LICENSE` and `NOTICE.md` for the upstream GPL v3 and attribution, and `LICENSES/` for the font terms.

- **Windows:** The portable bundle incorporates .NET 8.0.25 runtime/host, WPF/Windows Desktop and ASP.NET Core, QRCoder 1.8.0, System.Drawing.Common and Microsoft.Win32.SystemEvents 6.0.0, and Windows SDK interop dependencies. `THIRD-PARTY/` in the Windows ZIP includes the relevant NuGet package notices, runtime MIT texts and additional supplier notices. The Windows SDK terms are included as provided by the SDK package's license URL; separate supplier terms are not replaced by the application license.
- **Android:** See `Android/*-dependencies.txt` for the resolved runtime dependency lists including AndroidX/Compose/CameraX, Kotlin/Kotlinx, OkHttp/Okio, ZXing and their support dependencies. The Apache 2.0 text and libyuv notices are alongside these lists. License resources already in the APK are preserved. OkHttp includes its public suffix notice and Android fonts keep their own OFL notices.
- **Chrome / Edge:** The unpacked extension includes the upstream GPL v3 text and attribution. Its readable JS, manifest and assets are also in the corresponding source ZIP.

Sources of runtime notices: NuGet metadata and license files for the versions above; `dotnet/aspnetcore` and `dotnet/wpf` at `v8.0.25`; Microsoft's Windows SDK package license URL and `microsoft/CsWinRT` license; Apache Software Foundation Apache-2.0 text and libyuv upstream `LICENSE`/`PATENTS`.
