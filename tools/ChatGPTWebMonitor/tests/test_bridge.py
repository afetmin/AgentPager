"""Real loopback HTTP -> newline hook TCP integration tests (no chat content)."""
import http.client
import json
import os
import shutil
from pathlib import Path
import socket
import subprocess
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
DOTNET = os.environ.get('DOTNET') or shutil.which('dotnet') or str(Path(os.environ.get('TMPDIR', '.')) / 'agentpager-tools/dotnet-builds/dotnet')
DLL = ROOT / 'tools/ChatGPTWebMonitor/bin/Debug/net8.0/AgentPagerChatGPTWebBridge.dll'
TOKEN = 'apw_1119_8f6db7be5a2a45e2a82f4667240bc921'

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.server = socket.socket()
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(('127.0.0.1', 49361))
        self.server.listen()
        self.server.settimeout(.2)
        self.closed = False
        self.worker = threading.Thread(target=self.collect, daemon=True)
        self.worker.start()
        self.bridge = subprocess.Popen([DOTNET, str(DLL)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', 49363), timeout=.1): break
            except OSError: time.sleep(.05)
        else: self.fail('bridge failed to listen')

    def tearDown(self):
        self.bridge.terminate()
        self.bridge.communicate(timeout=5)
        self.closed = True
        self.worker.join(timeout=2)
        self.server.close()

    def collect(self):
        while not self.closed:
            try: client, _ = self.server.accept()
            except socket.timeout: continue
            with client:
                client.settimeout(3)
                data = b''
                while not data.endswith(b'\n'):
                    chunk = client.recv(65536)
                    if not chunk: break
                    data += chunk
                if data:
                    self.events.append(json.loads(data))
                    client.sendall(b'\n')

    def post(self, action, hash='a'*64, request='r1', origin='chrome-extension://'+'a'*32, token=TOKEN, **extra):
        conn = http.client.HTTPConnection('127.0.0.1', 49363, timeout=5)
        conn.request('POST', '/state', json.dumps(dict(action=action, conversationHash=hash, requestId=request, mode='Chat', **extra)),
                     {'Origin': origin, 'X-AgentPager-Token': token, 'Content-Type': 'application/json'})
        response = conn.getresponse()
        result = response.status
        response.read()
        conn.close()
        return result

    def test_no_prompt_starts_running_immediately_and_finish_matches(self):
        self.assertEqual(200, self.post('start'))
        self.assertIn('UserPromptSubmit', [e['hook_event_name'] for e in self.events])
        self.assertEqual(200, self.post('finish', request='unknown'))
        self.assertNotIn('Stop', [e['hook_event_name'] for e in self.events])
        self.assertEqual(200, self.post('finish'))
        self.assertEqual('Stop', self.events[-1]['hook_event_name'])

    def test_rekey_preserves_running_request_and_emits_identity_migration(self):
        self.assertEqual(200, self.post('start'))
        self.assertEqual(200, self.post('rekey', hash='b'*64, previousConversationHash='a'*64))
        self.assertEqual('SessionMetadata', self.events[-1]['hook_event_name'])
        self.assertEqual('agentpager-chatgpt-web-'+'a'*64, self.events[-1]['previous_session_id'])
        self.assertNotIn('Stop', [e['hook_event_name'] for e in self.events])
        self.assertEqual(200, self.post('finish', hash='a'*64))
        self.assertEqual('agentpager-chatgpt-web-'+'b'*64, self.events[-1]['session_id'])
        self.assertEqual('Stop', self.events[-1]['hook_event_name'])

    def test_prompt_is_ignored_status_only(self):
        self.assertEqual(200, self.post('start', prompt='DO_NOT_COLLECT_THIS'))
        self.assertNotIn('DO_NOT_COLLECT_THIS', json.dumps(self.events))

    def test_security_rejects_web_origin_bad_token_and_malformed_hash(self):
        self.assertEqual(403, self.post('start', origin='https://chatgpt.com'))
        self.assertEqual(403, self.post('start', token='wrong'))
        self.assertEqual(400, self.post('start', hash='A'*64))
        self.assertEqual(400, self.post('start', request=''))
        self.assertEqual([], self.events)

    def test_idle_metadata_never_publishes_activity(self):
        self.assertEqual(200, self.post('metadata', title='Read only'))
        self.assertEqual([], self.events)

    def test_heartbeat_recovers_bridge_restart_without_phantom_starting(self):
        self.assertEqual(200, self.post('heartbeat'))
        self.assertEqual(['UserPromptSubmit'], [e['hook_event_name'] for e in self.events])

if __name__ == '__main__': unittest.main(verbosity=2)
