"""使用脚本实际生成的 HTTPUpgrade 入站，验证 Xray/sing-box 客户端真实转发。"""
import copy
import json
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from proxy_smoke import Echo, Socks, exchange, free_port, start


def launch(binary, config, kind, directory, name, port):
    path = directory / f'{name}.json'
    path.write_text(json.dumps(config), encoding='utf-8')
    log = open(directory / f'{name}.log', 'w', encoding='utf-8')
    args = [binary, 'run', '-c' if kind == 'singbox' else '-config', str(path)]
    process = subprocess.Popen(args, stdout=log, stderr=log)
    for _ in range(60):
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                return process, log
        except OSError:
            if process.poll() is not None:
                log.close()
                raise RuntimeError(f'{name} exited: {(directory / (name + ".log")).read_text(encoding="utf-8")}')
            time.sleep(0.1)
    process.terminate()
    process.wait(timeout=5)
    log.close()
    raise RuntimeError(f'{name} did not listen')


def main():
    sb, xray, generated = sys.argv[1:]
    nodes = json.loads(Path(generated).read_text(encoding='utf-8'))['inbounds']
    echo = start(Echo)
    upstream = start(Socks)
    processes = []
    temporary = tempfile.TemporaryDirectory()
    directory = Path(temporary.name)
    try:
        for protocol in ('vless', 'trojan'):
            node = copy.deepcopy(next(n for n in nodes if n['protocol'] == protocol and n.get('streamSettings', {}).get('network') == 'httpupgrade'))
            server_port = free_port()
            node['port'] = server_port
            path = node['streamSettings']['httpupgradeSettings']['path']
            credential = node['settings']['clients'][0]['id' if protocol == 'vless' else 'password']
            # 用回环 SOCKS 上游验证数据往返，避开新版 Freedom 对私网目标的默认限制。
            server = {'inbounds': [node], 'outbounds': [{'protocol': 'socks', 'tag': 'egress',
                       'settings': {'servers': [{'address': '127.0.0.1', 'port': upstream.server_address[1]}]}}]}
            processes.append(launch(xray, server, 'xray', directory, f'{protocol}-server', server_port))
            # 当前 Xray 客户端会加这个头；旧 sing-box 服务端在相同请求上返回 404。
            with socket.create_connection(('127.0.0.1', server_port), timeout=3) as sock:
                request = (f'GET {path} HTTP/1.1\r\nHost: test.example.com\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n'
                           'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n')
                sock.sendall(request.encode())
                assert sock.recv(4096).startswith(b'HTTP/1.1 101'), protocol
            for kind, binary in (('singbox', sb), ('xray', xray)):
                client_port = free_port()
                if kind == 'singbox':
                    outbound = {'type': protocol, 'tag': 'proxy', 'server': '127.0.0.1', 'server_port': server_port,
                                'transport': {'type': 'httpupgrade', 'path': path, 'host': 'test.example.com'},
                                'uuid' if protocol == 'vless' else 'password': credential}
                    client = {'inbounds': [{'type': 'socks', 'tag': 'entry', 'listen': '127.0.0.1', 'listen_port': client_port}], 'outbounds': [outbound]}
                else:
                    if protocol == 'vless':
                        settings = {'vnext': [{'address': '127.0.0.1', 'port': server_port, 'users': [{'id': credential, 'encryption': 'none'}]}]}
                    else:
                        settings = {'servers': [{'address': '127.0.0.1', 'port': server_port, 'password': credential}]}
                    outbound = {'protocol': protocol, 'tag': 'proxy', 'settings': settings,
                                'streamSettings': {'network': 'httpupgrade', 'security': 'none', 'httpupgradeSettings': {'path': path, 'host': 'test.example.com'}}}
                    client = {'inbounds': [{'protocol': 'socks', 'tag': 'entry', 'listen': '127.0.0.1', 'port': client_port, 'settings': {'auth': 'noauth'}}], 'outbounds': [outbound]}
                process, log = launch(binary, client, kind, directory, f'{protocol}-{kind}-client', client_port)
                try:
                    try:
                        assert exchange(client_port, echo.server_address[1]) == b'via-egress:hello', (protocol, kind)
                    except Exception:
                        for log_path in directory.glob('*.log'):
                            print(log_path.name, log_path.read_text(encoding='utf-8'), flush=True)
                        raise
                finally:
                    process.terminate()
                    process.wait(timeout=5)
                    log.close()
                print(f'{protocol} HTTPUpgrade: {kind} client forwarded successfully')
    finally:
        for process, log in processes:
            process.terminate()
            process.wait(timeout=5)
            log.close()
        echo.shutdown()
        echo.server_close()
        upstream.shutdown()
        upstream.server_close()
        temporary.cleanup()


if __name__ == '__main__':
    main()
