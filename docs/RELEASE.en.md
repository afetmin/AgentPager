# AgentPager Extension: Hermes Desktop and ChatGPT Web monitoring

[简体中文](RELEASE.zh-CN.md) · Upstream: [`afetmin/AgentPager`](https://github.com/afetmin/AgentPager)

Modified from upstream `2651fd4a9fee61553ad3b59f52692e00385a5487` (November 22, 2026). **Not an official upstream release.** The added desktop features target Windows x64 only; upstream macOS source is unchanged. See `LICENSE`, `NOTICE.md`, `LICENSES/`, and `THIRD-PARTY/` for the terms and attributions.

## Changes

- **Codex quota:** Windows Bridge now selects the latest Codex quota by the timestamp of the event inside the rollout log, not by file modification time. The 5h and 7d values stay together from one snapshot. Quota still comes from local Codex logs, not from a live query to your subscription account.
- Detects resumed Codex conversations and read-only Hermes Desktop conversation/subagent status; native analytics require no NAS statistics plugin. The Android dedicated-mode button immediately changes to Enter Dedicated Mode after exit, with no restart required. QR and manual pairing instructions refer to the computer, not only Mac.
- **Why ChatGPT Web:** No reliable per-conversation activity signal has been verified for the native ChatGPT desktop app in this project, so it is not monitored. The optional browser extension uses ChatGPT's per-conversation sidebar spinner and associated page controls. It sends a title, a hashed conversation identifier, and limited status metadata to the local Windows Bridge. It does not send message bodies, prompts, cookies, or request contents. Closing a tab or switching chats does not imply completion. Layout updates, a collapsed sidebar, or background throttling can affect detection.

## Install and test

1. **Windows x64:** Choose `AgentPager-Windows-Setup.exe` (recommended; Windows uninstall entry) or `AgentPager-Windows-Portable.zip` (extract and run). Quit the old tray Bridge first. The installer removes only its own files and shortcuts; shared pairing, preferences, hooks and startup settings are retained. Windows packages are not Authenticode-signed.
2. **Android 8.0+:** Install `AgentPager-Android.apk` alongside upstream if desired. Upgrade both Windows and Android, then **pair again** with the new QR code or text. Allow TCP `49365` only on the intended private LAN, do not forward it to the Internet, and do not share the pairing code. See [pairing and compatibility](WINDOWS-PHONE-PAIRING.md).
3. **Chrome / Edge:** Both use `AgentPager-ChatGPT-Web-Chrome-Edge.zip`. Extract it, open `chrome://extensions` or `edge://extensions`, enable Developer mode, and choose **Load unpacked**. Select the directory containing `manifest.json`. This is a local test package, not a store listing. Firefox and Safari packages are not distributed with this candidate.
4. Enable Web Monitor in Bridge, refresh ChatGPT and expand the sidebar. For Hermes analytics, passwords and tokens require trusted HTTPS on non-loopback URLs. Update an existing insecure URL and sign in again. Explicit anonymous HTTP and local loopback HTTP remain available.
5. Resume a previously missed Codex conversation and check running and completed states. After a Bridge refresh, compare the dashboard's 5h/7d **remaining** percentages with Codex for the same windows. With no new quota event, the displayed values are the most recent local snapshot, not a live server query.

## Distribution

`AgentPager-Source.zip` contains corresponding source; `SHA256SUMS.txt` verifies the downloads. See the [fork packaging instructions](FORK-PACKAGING.md).
