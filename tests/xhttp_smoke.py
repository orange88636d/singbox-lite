"""验证脚本生成的 VLESS/Trojan XHTTP packet-up 入站可以实际转发。"""
import copy
import json
import sys
import tempfile
from pathlib import Path

from httpupgrade_smoke import launch
from proxy_smoke import Echo, Socks, exchange, free_port, start


def main():
    binary, generated = sys.argv[1:]
    nodes = json.loads(Path(generated).read_text(encoding='utf-8'))['inbounds']
    echo, upstream = start(Echo), start(Socks)
    temporary = tempfile.TemporaryDirectory()
    directory = Path(temporary.name)
    processes = []
    try:
        for protocol in ('vless', 'trojan'):
            node = copy.deepcopy(next(n for n in nodes if n['protocol'] == protocol and n.get('streamSettings', {}).get('network') == 'xhttp'))
            node['port'] = server_port = free_port()
            transport = node['streamSettings']['xhttpSettings']
            assert transport['mode'] == 'packet-up'
            credential = node['settings']['clients'][0]['id' if protocol == 'vless' else 'password']
            server = {'inbounds': [node], 'outbounds': [{'protocol': 'socks', 'tag': 'egress',
                      'settings': {'servers': [{'address': '127.0.0.1', 'port': upstream.server_address[1]}]}}]}
            processes.append(launch(binary, server, 'xray', directory, f'{protocol}-server', server_port))
            if protocol == 'vless':
                settings = {'vnext': [{'address': '127.0.0.1', 'port': server_port, 'users': [{'id': credential, 'encryption': 'none'}]}]}
            else:
                settings = {'servers': [{'address': '127.0.0.1', 'port': server_port, 'password': credential}]}
            client_port = free_port()
            client = {'inbounds': [{'protocol': 'socks', 'listen': '127.0.0.1', 'port': client_port, 'settings': {'auth': 'noauth'}}],
                      'outbounds': [{'protocol': protocol, 'settings': settings,
                                    'streamSettings': {'network': 'xhttp', 'security': 'none', 'xhttpSettings': transport}}]}
            processes.append(launch(binary, client, 'xray', directory, f'{protocol}-client', client_port))
            assert exchange(client_port, echo.server_address[1]) == b'via-egress:hello', protocol
            print(f'{protocol} XHTTP packet-up: actual forwarding passed')
    except Exception:
        for log_path in directory.glob('*.log'):
            print(log_path.name, log_path.read_text(encoding='utf-8'), flush=True)
        raise
    finally:
        for process, log in reversed(processes):
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
