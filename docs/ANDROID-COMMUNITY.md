# Android 共存构建 / Android side-by-side build

使用 `-PagentpagerCommunity=true` 构建 **AgentPager 扩展版**：包名 `io.github.ealin1994.agentpager`，可与原版 `com.agentgrid.mobile` 并存。首次运行单独配对；不读取或覆盖原版数据。此选项不改变 Windows Bridge、扩展或上游 Android 默认包名。

Build the community APK with `-PagentpagerCommunity=true`. It uses a separate application ID and pairing, leaving the upstream APK and its app data intact. Omitting the property preserves the upstream application ID.

```sh
cd android
AGENTPAGER_VERSION_NAME=0.4.3-rc.2 AGENTPAGER_VERSION_CODE=2 ./gradlew \
  -PagentpagerCommunity=true :app:testDebugUnitTest :app:assembleRelease
```

分发前使用社区版专用签名执行 `zipalign`、`apksigner sign` 和 `apksigner verify`；以后更新复用同一个签名并递增版本号。私钥不随源码或 APK 交付。/ Align and sign with the dedicated community key, verify before distribution, and retain that signing identity across updates. Do not distribute the key with the source or APK.
