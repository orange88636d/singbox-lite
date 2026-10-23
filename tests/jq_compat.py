"""验证实际 Argo 元数据表达式，兼容 jq 1.6 与新版；参数是待测 jq 路径。"""
import json
import re
import subprocess
import sys
from pathlib import Path

source = (Path(__file__).resolve().parent.parent / 'network_features.sh').read_text(encoding='utf-8')
match = re.search(r"meta=\$\(jq -n.*?--arg core \"\$core\" '\n(.*?)'\) \|\| return 1", source, re.S)
assert match, 'Argo metadata builder not found; update this regression test'
expression = match.group(1)
for binary in sys.argv[1:]:
    version = subprocess.check_output([binary, '--version'], text=True).strip()
    for protocol in ('vless', 'trojan'):
        for transport in ('ws', 'httpupgrade', 'xhttp'):
            for mode in ('temp', 'fixed'):
                tag = f'argo-{protocol}-{transport}-35869'
                fixture = {
                    't': tag, 'p': f'{protocol}-{transport}', 'c': 'test:@"\\credential',
                    'proto': protocol, 'path': '/test path', 'n': '测试 "节点"',
                    'd': 'test.example.com', 'mode': mode, 'token': '' if mode == 'temp' else 'test-token',
                    'core': 'xray' if transport in ('xhttp', 'httpupgrade') else 'singbox',
                }
                args = [binary, '-n']
                for key, value in fixture.items():
                    args += ['--arg', key, value]
                args += ['--argjson', 'port', '35869', expression]
                result = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', check=True)
                node = json.loads(result.stdout)[tag]
                credential_key = 'uuid' if protocol == 'vless' else 'password'
                assert node[credential_key] == fixture['c']
                assert ('password' if protocol == 'vless' else 'uuid') not in node
                assert node['name'] == fixture['n'] and node['token'] == fixture['token']
                assert node['local_port'] == 35869 and node['core'] == fixture['core']
    print(f'{version}: 12 Argo metadata cases passed')
