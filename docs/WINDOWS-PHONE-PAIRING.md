# Windows Bridge → Android pairing

## Upgrade and re-pair

Upgrade both the Windows Bridge and the Android app. On the Bridge connection page, scan the new QR code or copy its pairing text and paste it into the app. Existing Windows pairings do not migrate automatically; if the old entry keeps reconnecting, unpair it and add the new code. Treat the QR and copied text as credentials: do not post, screenshot for support, or share them. On the Windows firewall, allow the Bridge only on the intended private network; the phone listener uses TCP `49365`. Do not forward this port to the internet.

| Bridge and phone version | Behavior |
| --- | --- |
| New Windows Bridge + new Android app | Pair again with the version-2 QR. The app uses pinned WSS on TCP `49365`. |
| New Windows Bridge + old Android app | The old app rejects the new pairing format. The old cleartext phone endpoint cannot connect. |
| Old Windows Bridge + new Android app | A saved or explicitly entered version-1 pairing remains legacy cleartext. Upgrade the Bridge and replace that pairing to get encryption. The old Windows and macOS QR formats do not identify their platform. |
| Legacy macOS/upstream Bridge + new Android app | Version-1 compatibility is unchanged: cleartext status and signed controls. It is a separate pairing mode, never a fallback from version 2. |

The desktop QR and copy/paste carry the exact SHA-256 fingerprint of the Bridge's certificate and its existing 32-byte pairing key. The app verifies the fingerprint in the TLS handshake before sending the key as an authorization header. Windows authorizes the WebSocket upgrade before sending any snapshot. The app does not follow redirects or retry with cleartext after a TLS or authentication failure. Controls still use the signed version-1 message envelope and existing replay checks. The persistent Windows certificate identity is protected with current-user DPAPI. If the identity is replaced (including renewal after expiry), scan or paste a fresh code. If the Windows LAN address changes, use an updated code to change the address.

Windows no longer serves `/pairing` or a cleartext phone WebSocket on any interface. Local Hermes `/hermes-status` stays on `127.0.0.1:49362`; its port and existing authentication do not change.

## Verification and release gate

- `WindowsSettingsSmoke` exercises the production Kestrel listener over loopback on a Linux test host: missing/wrong/query-only auth, browser Origin, incorrect pin, cleartext rejection, authorized snapshots, signed control and replay rejection. The TLS identity restart test injects a test cipher; it does not execute Windows DPAPI.
- Android JVM tests cover pairing-version validation and preserving the pin on reconnect. Debug and instrumentation APK builds are not evidence that device instrumentation ran.
- Before publishing, run the updated Windows Bridge and Android app together on a private LAN. Verify a new QR and manual paste, a valid snapshot and signed control, reconnect after a Bridge restart, and failure of the old Windows pairing. This is also the native Schannel, DPAPI, Windows Firewall, and Android TLS/UI check.
- The existing `scripts/e2e-windows.ps1` release smoke still expects the removed `/pairing` endpoint and a cleartext socket. It needs a secure fixture-based update before its result can be used as a release check; do not re-enable the endpoint to make the script pass.
