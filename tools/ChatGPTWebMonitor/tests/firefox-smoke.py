#!/usr/bin/env python3
"""Install the packaged Firefox extension temporarily and exercise its actual popup/background."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from uuid import uuid4


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    for name in ('firefox', 'driver', 'xpi'):
        cli.add_argument(f'--{name}', required=True, type=Path)
    options = cli.parse_args()
    reference = 'agentpager-chatgpt-web@agentpager.invalid'
    browser_id = str(uuid4())
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    base = f'http://127.0.0.1:{port}'

    def call(path, data=None, method=None):
        payload = json.dumps(data).encode() if data is not None else None
        req = Request(base + path, payload, {'Content-Type': 'application/json'}, method=method)
        try:
            with urlopen(req, timeout=45) as response:
                return json.load(response)['value']
        except HTTPError as error:
            detail = json.load(error).get('value', {})
            raise RuntimeError(f"WebDriver {path}: {detail.get('message', error.reason)}") from error

    env = dict(os.environ, MOZ_HEADLESS='1')
    with subprocess.Popen([str(options.driver.resolve()), '--port', str(port), '--allow-system-access'], env=env,
                          stdout=subprocess.DEVNULL) as driver:
        session = None
        try:
            for _ in range(80):
                try:
                    call('/status')
                    break
                except URLError:
                    if driver.poll() is not None:
                        raise RuntimeError('geckodriver stopped')
                    time.sleep(.1)
            session = '/session/' + call('/session', {'capabilities': {'alwaysMatch': {
                'browserName': 'firefox', 'moz:firefoxOptions': {
                    'binary': str(options.firefox.resolve()), 'args': ['-headless'],
                    'prefs': {'extensions.webextensions.uuids': json.dumps({reference: browser_id})}}}}})['sessionId']
            addon = call(session + '/moz/addon/install', {'path': str(options.xpi.resolve()), 'temporary': True})
            assert addon == reference, addon
            # Only the throwaway test browser grants privileged navigation to the add-on page.
            call(session + '/moz/context', {'context': 'chrome'})
            call(session + '/execute/sync', {'script': """
              const tab = Services.wm.getMostRecentWindow('navigator:browser').gBrowser;
              tab.selectedBrowser.loadURI(Services.io.newURI(arguments[0]), {
                triggeringPrincipal: Services.scriptSecurityManager.getSystemPrincipal()
              });
            """, 'args': [f'moz-extension://{browser_id}/popup.html']})
            call(session + '/moz/context', {'context': 'content'})
            status = ''
            for _ in range(60):
                status = call(session + '/execute/sync', {'script': "return document.getElementById('status')?.textContent", 'args': []})
                if status and status.startswith('已连接'):
                    print('PASS Firefox temporary XPI → extension popup → background → local Bridge')
                    break
                time.sleep(.15)
            else:
                detail = call(session + '/execute/sync', {'script': "return document.getElementById('details')?.textContent", 'args': []})
                raise RuntimeError(f'Extension not connected: {status} / {detail}')
        finally:
            if session:
                call(session, method='DELETE')
            driver.terminate()


if __name__ == '__main__':
    main()
