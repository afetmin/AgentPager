"""Source wiring checks; runtime HTTP/reducer tests run separately in .NET."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[3]
BRIDGE = ROOT / 'windows/src/AgentPager.Bridge'

class IntegratedWebUiTests(unittest.TestCase):
    def test_visible_monitor_control_and_diagnostics_are_wired(self):
        root = ET.parse(BRIDGE / 'MainWindow.xaml').getroot()
        ns = '{http://schemas.microsoft.com/winfx/2006/xaml}'
        names = {element.attrib.get(ns + 'Name'): element for element in root.iter()}
        source = (BRIDGE / 'MainWindow.xaml.cs').read_text()
        for name in ('WebMonitorCheckBox', 'WebStatusText', 'WebHeartbeatText', 'WebDetectionText', 'WebTabsText', 'WebErrorText', 'WebSummaryText'):
            self.assertIn(name, names)
            self.assertIn(name, source)
        checkbox = names['WebMonitorCheckBox']
        self.assertEqual(checkbox.attrib['Checked'], 'WebMonitorCheckBox_Changed')
        self.assertEqual(checkbox.attrib['Unchecked'], 'WebMonitorCheckBox_Changed')
        self.assertIn('_runtime.SetWebMonitorEnabled(', source)

    def test_existing_tray_exposes_monitor_status_and_toggle(self):
        source = (BRIDGE / 'TrayController.cs').read_text()
        self.assertEqual(source.count('_icon = new()'), 1)
        self.assertIn('_webStatus.Text', source)
        self.assertIn('_webToggle.Checked', source)
        self.assertIn('_runtime.SetWebMonitorEnabled(', source)

    def test_single_process_and_persisted_web_setting(self):
        runtime = (BRIDGE / 'BridgeRuntime.cs').read_text()
        project = (BRIDGE / 'AgentPager.Bridge.csproj').read_text()
        self.assertIn('ChatGPTWebStatusTracker.cs', project)
        self.assertIn('_webMonitor.StartAsync(token)', runtime)
        self.assertIn('Settings.WebMonitoringEnabled = web.Enabled', runtime)
        self.assertNotIn('AgentPagerChatGPTWebBridge.exe', runtime)
        self.assertNotIn('Process.Start', runtime)
        self.assertIn('await _webMonitor.DisposeAsync()', runtime)
        self.assertGreaterEqual(runtime.count('ClearActiveWebTasks()'), 3,
                                'startup and disabling must clear even legacy/restored web statuses')

if __name__ == '__main__':
    unittest.main()
