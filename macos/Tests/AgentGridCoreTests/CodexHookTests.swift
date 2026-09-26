import Foundation
import Testing
@testable import AgentGridCore

@Test("Hook 安装保留用户已有配置")
func hookInstallerPreservesExistingHooks() throws {
    let existing = Data(
        """
        {
          "custom": true,
          "hooks": {
            "SessionStart": [
              {
                "matcher": "startup",
                "hooks": [
                  {"type": "command", "command": "/tmp/custom-hook", "timeout": 5}
                ]
              }
            ]
          }
        }
        """.utf8
    )

    let mutation = try CodexHookInstaller.install(
        existingData: existing,
        command: "/Applications/AgentPager Bridge.app/Contents/MacOS/AgentPagerHooks"
    )
    let installedContents = try #require(mutation.contents)
    let root = try #require(
        JSONSerialization.jsonObject(with: installedContents) as? [String: Any]
    )
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks["SessionStart"] as? [[String: Any]])

    #expect(root["custom"] as? Bool == true)
    #expect(groups.count == 2)
    #expect(CodexHookInstaller.isInstalled(data: mutation.contents))
}

@Test("Hook 卸载只删除 AgentPager 管理项")
func hookUninstallOnlyRemovesManagedGroups() throws {
    let installed = try CodexHookInstaller.install(
        existingData: Data(
            """
            {
              "hooks": {
                "Stop": [
                  {"hooks": [{"type": "command", "command": "/tmp/custom"}]}
                ]
              }
            }
            """.utf8
        ),
        command: "/tmp/AgentPagerHooks"
    )

    let uninstalled = try CodexHookInstaller.uninstall(existingData: installed.contents)
    let uninstalledContents = try #require(uninstalled.contents)
    let root = try #require(
        JSONSerialization.jsonObject(with: uninstalledContents) as? [String: Any]
    )
    let hooks = try #require(root["hooks"] as? [String: Any])
    let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
    #expect(stopGroups.count == 1)
    #expect(!CodexHookInstaller.isInstalled(data: uninstalled.contents))
}

@Test("品牌迁移后仍识别并替换旧版 AgentGrid Hook")
func hookInstallerMigratesLegacyManagedGroups() throws {
    let legacy = Data(
        """
        {
          "hooks": {
            "SessionStart": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "'/Applications/AgentGrid Bridge.app/Contents/MacOS/AgentGridHooks'",
                    "statusMessage": "Managed by AgentGrid"
                  }
                ]
              }
            ]
          }
        }
        """.utf8
    )

    let mutation = try CodexHookInstaller.install(
        existingData: legacy,
        command: "/Applications/AgentPager Bridge.app/Contents/MacOS/AgentPagerHooks"
    )
    let installed = try #require(mutation.contents)
    let root = try #require(
        JSONSerialization.jsonObject(with: installed) as? [String: Any]
    )
    let hooks = try #require(root["hooks"] as? [String: Any])
    let groups = try #require(hooks["SessionStart"] as? [[String: Any]])
    let commands = groups.flatMap { group in
        (group["hooks"] as? [[String: Any]] ?? []).compactMap {
            $0["command"] as? String
        }
    }

    #expect(groups.count == 1)
    #expect(commands.count == 1)
    #expect(commands[0].contains("AgentPagerHooks"))
    #expect(!commands[0].contains("AgentGridHooks"))
    #expect(CodexHookInstaller.isInstalled(data: installed))
}

@Test("Codex 权限响应格式符合当前 PermissionRequest 规范")
func codexPermissionOutputShape() throws {
    let data = try CodexHookOutput.permission(.allow)
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let hookSpecificOutput = try #require(
        object["hookSpecificOutput"] as? [String: Any]
    )
    let decision = try #require(
        hookSpecificOutput["decision"] as? [String: Any]
    )

    #expect(object["continue"] == nil)
    #expect(hookSpecificOutput["hookEventName"] as? String == "PermissionRequest")
    #expect(decision["behavior"] as? String == "allow")
}
