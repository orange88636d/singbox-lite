"""验证生成的订阅服务鉴权、端点限制和实时刷新；Windows 下只替换 POSIX 锁。"""
import base64
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

root = Path(sys.argv[1])
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
token = 'test-token-0123456789'
(root / 'subscription-http.json').write_text(json.dumps({'listen': '127.0.0.1', 'port': port, 'token': token}))
server = root / 'subscription_server.py'
if os.name == 'nt':
    # 真实网络/HTTP/文件读取照常执行；Linux 的 flock 在 Windows 不可用。
    launch = "import runpy,sys,types; sys.modules['fcntl']=types.SimpleNamespace(LOCK_SH=1,LOCK_NB=2,flock=lambda *_:None); p=sys.argv.pop(1); runpy.run_path(p,run_name='__main__')"
    args = [sys.executable, '-c', launch, str(server), str(root)]
else:
    args = [sys.executable, str(server), str(root)]
process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
base = f'http://127.0.0.1:{port}'


def request(path):
    try:
        with urllib.request.urlopen(base + path, timeout=5) as response:
            assert response.headers['Cache-Control'] == 'no-store'
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, b''


metadata = root / 'metadata.json'
original = metadata.read_bytes()
try:
    for _ in range(60):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                break
        except OSError:
            assert process.poll() is None, 'subscription server exited'
            time.sleep(0.1)
    for path in ('/', '/wrong/links', f'/{token}/metadata.json', f'/{token}/../metadata.json'):
        assert request(path)[0] == 404, path
    metadata.write_text(json.dumps({'node': {'share_link': 'vless://old-link'}}))
    assert b'vless://old-link' in request(f'/{token}/links')[1]
    metadata.write_text(json.dumps({'node': {'share_link': 'vless://new-link'}}))
    links = request(f'/{token}/links')[1]
    assert b'vless://new-link' in links and b'vless://old-link' not in links
    assert base64.b64decode(request(f'/{token}/base64')[1]) == links
    assert request(f'/{token}/clash')[1] == (root / 'clash.yaml').read_bytes()
    print('Subscription HTTP authentication, restricted endpoints and live refresh passed.')
finally:
    metadata.write_bytes(original)
    process.terminate()
    process.wait(timeout=5)
