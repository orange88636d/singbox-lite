"""仅使用回环网络，验证两个核心优先走 SOCKS 上游且故障时不会直连。"""
import json
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def receive(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        data += chunk
    return data


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        data = self.request.recv(1024)
        self.request.sendall(b"direct:" + data)


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        sock = self.request
        sock.settimeout(5)
        version, count = receive(sock, 2)
        assert version == 5
        receive(sock, count)
        sock.sendall(b"\x05\x00")
        _, command, _, kind = receive(sock, 4)
        assert command == 1
        if kind == 1:
            receive(sock, 4)
        elif kind == 4:
            receive(sock, 16)
        else:
            receive(sock, receive(sock, 1)[0])
        receive(sock, 2)
        sock.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
        data = sock.recv(1024)
        sock.sendall(b"via-egress:" + data)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def start(handler):
    server = Server(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def exchange(port, target):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
        sock.sendall(b"\x05\x01\x00")
        assert receive(sock, 2) == b"\x05\x00"
        sock.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", target))
        reply = receive(sock, 4)
        if reply[1] != 0:
            return b"rejected"
        receive(sock, {1: 4, 4: 16}.get(reply[3], 0))
        receive(sock, 2)
        sock.sendall(b"hello")
        return sock.recv(1024)


def main():
    sb, xray, sb_config, xr_config = sys.argv[1:]
    direct, upstream = start(Echo), start(Socks)
    processes = []
    try:
        target = direct.server_address[1]
        upstream_port = upstream.server_address[1]
        with tempfile.TemporaryDirectory() as directory:
            for core, binary in (("singbox", sb), ("xray", xray)):
                port = free_port()
                if core == "singbox":
                    config = json.loads(Path(sb_config).read_text(encoding="utf-8"))
                    config['inbounds'] = [{"type": "socks", "tag": "entry", "listen": "127.0.0.1", "listen_port": port}]
                    outbound = next(o for o in config['outbounds'] if o['tag'] == 'managed-socks-egress')
                    outbound.update(server='127.0.0.1', server_port=upstream_port)
                    outbound.pop('username', None)
                    outbound.pop('password', None)
                    config['route']['rules'].append({"ip_cidr": ["127.0.0.0/8"], "action": "route", "outbound": "direct"})
                    args = [binary, "run", "-c"]
                else:
                    config = json.loads(Path(xr_config).read_text(encoding="utf-8"))
                    config['inbounds'] = [{"protocol": "socks", "tag": "entry", "listen": "127.0.0.1", "port": port, "settings": {"auth": "noauth", "udp": True}}]
                    outbound = next(o for o in config['outbounds'] if o['tag'] == 'managed-socks-egress')
                    outbound['settings']['servers'] = [{"address": "127.0.0.1", "port": upstream_port}]
                    config['routing']['rules'].append({"type": "field", "ip": ["127.0.0.0/8"], "outboundTag": "direct"})
                    args = [binary, "run", "-config"]
                # sing-box 按文件名排序合并；使用与生产服务完全一致的 config.json/relay.json。
                path = Path(directory) / ('config.json' if core == 'singbox' else 'xray.json')
                path.write_text(json.dumps(config))
                args += [str(path)]
                if core == 'singbox':
                    relay = Path(directory) / 'relay.json'
                    relay.write_text(json.dumps({'route': {'rules': [{'action': 'route', 'outbound': 'direct'}]}}))
                    args += ['-c', str(relay)]
                process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                processes.append((process, port, core))
                for _ in range(60):
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        if process.poll() is not None:
                            raise RuntimeError(f"{core} exited before listening")
                        time.sleep(0.1)
                reply = exchange(port, target)
                assert reply == b"via-egress:hello", (core, reply, config.get('route', config.get('routing')))
            upstream.shutdown()
            upstream.server_close()
            for _, port, core in processes:
                try:
                    reply = exchange(port, target)
                except (OSError, ConnectionError):
                    reply = b"closed"
                assert reply != b"direct:hello", f"{core} fell back to direct"
        print("Both cores route through SOCKS and fail closed when upstream stops.")
    finally:
        for process, _, _ in processes:
            process.terminate()
            process.wait(timeout=5)
        upstream.shutdown()
        upstream.server_close()
        direct.shutdown()
        direct.server_close()


if __name__ == "__main__":
    main()
