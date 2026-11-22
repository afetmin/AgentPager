"""Static WPF contract checks; runtime filesystem behavior is exercised by Program.cs."""
from pathlib import Path
import re
import unittest
import xml.etree.ElementTree as ET

BRIDGE = Path(__file__).resolve().parents[2] / "src" / "AgentPager.Bridge"
X = "{http://schemas.microsoft.com/winfx/2006/xaml}"
W = "{http://schemas.microsoft.com/winfx/2006/xaml/presentation}"


class SettingsUiContract(unittest.TestCase):
    def setUp(self):
        self.root = ET.parse(BRIDGE / "MainWindow.xaml").getroot()
        self.code = (BRIDGE / "MainWindow.xaml.cs").read_text()

    def test_window_visibly_identifies_r42_binary(self):
        self.assertIn("r4.3-rc.1", self.root.get("Title", ""))
        self.assertTrue(any("r4.3-rc.1" in node.get("Text", "") for node in self.root.iter(W + "TextBlock")))

    def test_desktop_status_script_upgrade_is_visible_and_runs_on_startup(self):
        runtime = (BRIDGE / "BridgeRuntime.cs").read_text()
        self.assertIn("_hermesSetup.UpgradeInstalled();", runtime)
        self.assertIn("_hermesSetup.UpdateStatus", runtime)
        self.assertIn("HermesPluginUpdateText.Text = state.HermesPluginUpdateStatus;", self.code)
        tab = self.root.find(f".//{W}TabItem[@Header='HERMES']")
        assert tab is not None
        self.assertIsNotNone(tab.find(f".//{W}TextBlock[@{X}Name='HermesPluginUpdateText']"))
        labels = "\n".join(node.get("Text", "") for node in tab.iter())
        for phrase in ("已安装", "自动更新", "自定义", "禁用", "NAS"):
            self.assertIn(phrase, labels)

    def test_one_startup_toggle_is_in_visible_settings_tab(self):
        toggles = self.root.findall(f".//{W}CheckBox[@{X}Name='StartupCheckBox']")
        self.assertEqual(len(toggles), 1)
        tabs = self.root.findall(f".//{W}TabItem[@Header='设置']")
        self.assertEqual(len(tabs), 1)
        self.assertIn(toggles[0], list(tabs[0].iter()))
        self.assertIn("StartupRegistration.ReadStatus()", self.code)
        self.assertNotIn("StartupCheckBox.IsChecked = _runtime.Settings.LaunchAtLogin", self.code)

    def test_normal_launch_never_repairs_startup_without_explicit_settings_click(self):
        program = (BRIDGE / "Program.cs").read_text()
        self.assertRegex(program, r"(?s)if \(!created\)\s*\{.*?SingleInstanceSignal\.Send\(\);.*?return 0;\s*\}\s*var app = new App")
        launch = program.split("var background", 1)[1].split("internal static class HookClient", 1)[0]
        self.assertNotIn("RepairExistingPath", launch)
        self.assertNotIn("SetEnabled", launch)
        toggle = self.root.find(f".//{W}CheckBox[@{X}Name='StartupCheckBox']")
        assert toggle is not None
        self.assertEqual(toggle.get("Click"), "StartupCheckBox_Changed")
        self.assertNotIn("Checked", toggle.attrib)
        self.assertNotIn("Unchecked", toggle.attrib)
        self.assertIn("_runtime.SetLaunchAtLogin(StartupCheckBox.IsChecked == true)", self.method("StartupCheckBox_Changed"))

    def test_all_hermes_controls_belong_to_hermes_tab_not_general_settings(self):
        hermes_tab = self.root.find(f".//{W}TabItem[@Header='HERMES']")
        settings_tab = self.root.find(f".//{W}TabItem[@Header='设置']")
        self.assertIsNotNone(hermes_tab)
        self.assertIsNotNone(settings_tab)
        assert hermes_tab is not None and settings_tab is not None
        hermes_controls = [node for node in self.root.iter() if "Hermes" in node.get(X + "Name", "")]
        self.assertGreaterEqual(len(hermes_controls), 12)
        names = [node.get(X + "Name") for node in hermes_controls]
        self.assertEqual(len(names), len(set(names)), "Hermes controls must have unique names")
        for node in hermes_controls:
            self.assertIn(node, list(hermes_tab.iter()), node.get(X + "Name"))
        self.assertFalse(any("Hermes" in str(value) for node in settings_tab.iter() for value in node.attrib.values()))

    def test_account_login_is_primary_and_token_compatibility_is_collapsed(self):
        tab = self.root.find(f".//{W}TabItem[@Header='HERMES']")
        assert tab is not None
        self.assertIsNotNone(tab.find(f".//{W}TextBox[@{X}Name='HermesUsernameBox']"))
        password = tab.find(f".//{W}PasswordBox[@{X}Name='HermesPasswordBox']")
        self.assertIsNotNone(password)
        assert password is not None
        self.assertNotIn("Password", password.attrib)
        advanced = tab.find(f".//{W}Expander[@Header='高级：访问令牌（可选）']")
        self.assertIsNotNone(advanced)
        assert advanced is not None
        self.assertEqual(advanced.get("IsExpanded"), "False")
        for name in ("HermesAccessTokenBox", "HermesAnonymousCheckBox", "ClearHermesTokenCheckBox", "SaveHermesSourceButton"):
            self.assertTrue(any(node.get(X + "Name") == name for node in advanced.iter()), name)
        self.assertIsNotNone(advanced.find(f".//{W}PasswordBox[@{X}Name='HermesAccessTokenBox']"))
        for name, handler, caption in (("LoginHermesButton", "LoginHermes_Click", "登录"), ("LogoutHermesButton", "LogoutHermes_Click", "退出")):
            button = tab.find(f".//{W}Button[@{X}Name='{name}']")
            self.assertIsNotNone(button)
            assert button is not None
            self.assertEqual(button.get("Content"), caption)
            self.assertEqual(button.get("Click"), handler)
            self.assertNotIn(button, list(advanced.iter()))
        labels = "\n".join(node.get("Text", "") for node in tab.iter())
        for text in ("用量统计", "PC 会话状态", "Hermes 服务账号", "不是模型供应商 API Key", "HTTP", "不会加密", "NAS"):
            self.assertIn(text, labels)
        self.assertLess(labels.index("用量统计"), labels.index("PC 会话状态"))
        for name in ("HermesAuthStateText", "HermesAuthFeedbackText", "NativeHermesStatusText", "HermesStatusText"):
            self.assertIsNotNone(tab.find(f".//{W}TextBlock[@{X}Name='{name}']"))

    def method(self, name):
        match = re.search(r"\b" + re.escape(name) + r"\([^)]*\)\s*\{", self.code)
        self.assertIsNotNone(match, name + " must be implemented")
        assert match is not None
        start = match.end()
        depth = 1
        for index in range(start, len(self.code)):
            if self.code[index] == "{":
                depth += 1
            elif self.code[index] == "}":
                depth -= 1
                if depth == 0:
                    return self.code[start:index]
        self.fail(name + " has an unterminated method body")

    def test_account_handlers_clear_secrets_and_share_pending_guard(self):
        login = self.method("LoginHermes_Click")
        self.assertIn("if (_changingHermesConnection) return;", login)
        self.assertRegex(login, r"var password = HermesPasswordBox.Password;\s*HermesPasswordBox.Clear\(\);")
        self.assertIn("_runtime.LoginHermesAsync(url, profile, username, password, cancellation.Token)", login)
        self.assertIn("SetHermesConnectionPending(true)", login)
        self.assertIn("finally", login)
        self.assertIn('password = "";', login)
        self.assertIn("SetHermesConnectionPending(false)", login)
        self.assertIn("catch (Exception)", login)
        self.assertNotIn("result.Error", login)
        self.assertNotRegex(self.code, r"Hermes(?:Password|AccessToken)Box\.Password\s*=(?!=)")
        logout = self.method("LogoutHermes_Click")
        self.assertIn("_runtime.LogoutHermes(out _)", logout)
        self.assertIn("if (_changingHermesConnection) return;", logout)
        self.assertIn("catch (Exception)", logout)
        self.assertIn("_hermesLogoutNeedsRetry = !ok;", logout)
        self.assertIn("_hermesLogoutNeedsRetry = true;", logout)
        self.assertIn("_hermesLogoutNeedsRetry", self.method("RefreshHermesAuthState"))
        manual = self.method("SaveHermesSource_Click")
        self.assertIn("if (_changingHermesConnection) return;", manual)
        self.assertRegex(manual, r"var token = HermesAccessTokenBox.Password;\s*HermesAccessTokenBox.Clear\(\);")
        self.assertIn("catch (Exception)", manual)
        self.assertNotIn("result.error", manual)
        refresh = self.method("RefreshSettings")
        self.assertIn("if (forceHermes || !_hermesSettingsDisplayed)", refresh)
        self.assertNotIn("HermesPasswordBox", refresh)
        self.assertNotIn("HermesAccessTokenBox.Password", refresh)
        state = self.method("RefreshHermesAuthState")
        self.assertIn("_runtime.HermesSignedInUsername", state)
        self.assertIn("LoginHermesButton.IsEnabled = !_changingHermesConnection", state)
        for control in ("HermesServiceUrlBox", "HermesProfileBox", "HermesUsernameBox", "HermesPasswordBox", "HermesAdvancedTokenExpander"):
            self.assertIn(control + ".IsEnabled = !_changingHermesConnection", state)
        closing = self.method("OnClosing")
        self.assertIn("_hermesLoginCancellation?.Cancel()", closing)
        self.assertIn("HermesPasswordBox.Clear()", closing)

    def test_hermes_transport_refusal_is_actionable_before_login_or_token_save(self):
        login = self.method("LoginHermes_Click")
        manual = self.method("SaveHermesSource_Click")
        self.assertLess(login.index("HermesCredentialTransport.RequireSecure"), login.index("_runtime.LoginHermesAsync"))
        self.assertLess(manual.index("HermesCredentialTransport.RequireSecure"), manual.index("_runtime.TrySetHermesSource"))
        for method in (login, manual):
            self.assertIn("HermesCredentialTransport.HttpsRequiredMessage", method)
        self.assertIn("_runtime.HermesUsageStatus", self.method("RefreshSettings"))

    def test_legacy_web_startup_cleanup_is_explicit_and_scan_is_throttled(self):
        tab = self.root.find(f".//{W}TabItem[@Header='设置']")
        assert tab is not None
        warning = tab.find(f".//{W}TextBlock[@{X}Name='LegacyStartupWarningText']")
        self.assertIsNotNone(warning)
        button = tab.find(f".//{W}Button[@{X}Name='DisableLegacyWebStartupButton']")
        self.assertIsNotNone(button)
        assert button is not None
        self.assertEqual(button.get("Content"), "停用旧网页监控自启动")
        self.assertEqual(button.get("Click"), "DisableLegacyWebStartup_Click")
        scan = self.method("RefreshLegacyWebStartup")
        self.assertIn("StartupRegistration.LegacyWebStartupEntries()", scan)
        self.assertIn("TimeSpan.FromSeconds(30)", scan)
        self.assertIn("!force", scan)
        self.assertNotIn("DisableLegacyWebStartup()", scan)
        handler = self.method("DisableLegacyWebStartup_Click")
        self.assertIn("StartupRegistration.DisableLegacyWebStartup()", handler)
        self.assertIn("result.Message", handler)
        self.assertIn("RefreshLegacyWebStartup(force: true)", handler)
        self.assertIn("RefreshLegacyWebStartup();", self.method("RefreshSettings"))
        self.assertRegex(self.code, r"Activated \+=.*RefreshLegacyWebStartup\(force: true\)")

    def test_edit_browse_apply_reset_open_are_wired(self):
        self.assertIsNotNone(self.root.find(f".//{W}TextBox[@{X}Name='LogDirectoryTextBox']"))
        for handler in ("BrowseLogs_Click", "ApplyLogs_Click", "ResetLogs_Click", "OpenLogs_Click"):
            self.assertTrue(self.root.findall(f".//{W}Button[@Click='{handler}']"), handler)
            self.assertIn(handler + "(", self.code)
        self.assertIn("_runtime.ActiveLogDirectory", self.code)
        self.assertIn("_runtime.LogDirectoryError", self.code)
        self.assertIn("_runtime.TrySetLogDirectory", self.code)
        self.assertNotIn('ProcessStartInfo("explorer.exe", AgentPagerPaths.LogsDirectory)', self.code)

    def test_footer_shows_same_active_log_path_as_open_button(self):
        self.assertIsNotNone(self.root.find(f".//{W}TextBlock[@{X}Name='FooterLogDirectoryText']"))
        self.assertIn('FooterLogDirectoryText.Text = "日志目录：" + activeLogDirectory;', self.code)
        self.assertIn('var activeLogDirectory = _runtime.ActiveLogDirectory;', self.code)
        self.assertIn('var path = _runtime.ActiveLogDirectory;', self.code)
        self.assertNotIn('个任务 · 数据目录 {AgentPagerPaths.DataRoot}', self.code)


if __name__ == "__main__":
    unittest.main()
