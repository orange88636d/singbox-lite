#!/bin/bash
# 用真实核心校验配置，所有写入限制在 mktemp 目录；服务与 cloudflared 使用测试替身。
# SB_TEST_BIN=/path/sing-box XRAY_TEST_BIN=/path/xray YQ_TEST_BIN=/path/yq bash tests/network_features.sh
set -eo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_sb="${SB_TEST_BIN:?set SB_TEST_BIN}"
test_xray="${XRAY_TEST_BIN:?set XRAY_TEST_BIN}"
test_yq="${YQ_TEST_BIN:?set YQ_TEST_BIN}"
test_python="${PYTHON_TEST_BIN:-python3}"
export SINGBOXLITE_LIBRARY_ONLY=1
source "$repo/singbox.sh"
SINGBOX_DIR=$(mktemp -d)
trap 'rm -rf -- "$SINGBOX_DIR"' EXIT
CONFIG_FILE="$SINGBOX_DIR/config.json"
RELAY_CONFIG_FILE="$SINGBOX_DIR/relay.json"
METADATA_FILE="$SINGBOX_DIR/metadata.json"
ARGO_METADATA_FILE="$SINGBOX_DIR/argo_metadata.json"
CLASH_YAML_FILE="$SINGBOX_DIR/clash.yaml"
FEATURE_XRAY_CONFIG="$SINGBOX_DIR/xray.json"
FEATURE_XRAY_METADATA="$SINGBOX_DIR/xray-meta.json"
FEATURE_XRAY_BIN="$test_xray"
SINGBOX_BIN="$test_sb"
YQ_BINARY="$test_yq"
SCRIPT_DIR="$repo"
export SINGBOXLITE_LOCK_HELD=1
_manage_service() {
    printf '%s\n' singbox >> "$SINGBOX_DIR/restarts"
    if [ -f "$SINGBOX_DIR/fail-restart" ]; then rm "$SINGBOX_DIR/fail-restart"; return 1; fi
    return 0
}
_feature_xray() {
    case "$1" in
        _validate_xray_config) "$test_xray" run -test -config "$FEATURE_XRAY_CONFIG" >/dev/null ;;
        _manage_xray_service) printf '%s\n' xray >> "$SINGBOX_DIR/restarts" ;;
        _init_xray_config|_create_xray_service) return 0 ;;
        *) return 1 ;;
    esac
}
cat > "$CONFIG_FILE" <<'JSON'
{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"domain":["example.com"],"action":"route","outbound":"direct"}],"final":"direct"}}
JSON
echo '{"inbounds":[],"outbounds":[],"route":{"rules":[]}}' > "$RELAY_CONFIG_FILE"
echo '{"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"type":"field","domain":["example.com"],"outboundTag":"direct"}]}}' > "$FEATURE_XRAY_CONFIG"
echo '{}' > "$METADATA_FILE"; echo '{}' > "$ARGO_METADATA_FILE"; echo '{}' > "$FEATURE_XRAY_METADATA"
printf 'proxies: []\nproxy-groups:\n  - name: 节点选择\n    type: select\n    proxies: []\n' > "$CLASH_YAML_FILE"

_valid_domain sub.example.com
for domain in 'https://example.com' 'bad..example.com' '-bad.example.com' '127.0.0.1' 'bad.example.com/x'; do
    if _valid_domain "$domain"; then echo "accepted invalid domain: $domain"; exit 1; fi
done
_feature_transaction _set_bound_domain test.example.com
[ "$(_get_client_address)" = test.example.com ]

cp "$CONFIG_FILE" "$SINGBOX_DIR/original-sb"
cp "$FEATURE_XRAY_CONFIG" "$SINGBOX_DIR/original-xray"
out=$(_socks_outbound '[::1]' 1080 'user:@' 'password"\\中文')
_feature_transaction _apply_socks_egress "$out"
jq -e '.route.rules[0].outbound == "managed-socks-egress" and .outbounds[-1].server == "::1"' "$CONFIG_FILE" >/dev/null
jq -e '.routing.rules[0].outboundTag == "managed-socks-egress" and .outbounds[-1].settings.servers[0].users[0].user == "user:@"' "$FEATURE_XRAY_CONFIG" >/dev/null
_feature_transaction _apply_socks_egress "$out"
[ "$(jq '.outbounds|length' "$CONFIG_FILE")" = 2 ]
_feature_transaction _apply_socks_egress null
diff <(jq -S . "$CONFIG_FILE") <(jq -S . "$SINGBOX_DIR/original-sb")
diff <(jq -S . "$FEATURE_XRAY_CONFIG") <(jq -S . "$SINGBOX_DIR/original-xray")
cp "$CONFIG_FILE" "$SINGBOX_DIR/original-sb"
cp "$FEATURE_XRAY_CONFIG" "$SINGBOX_DIR/original-xray"
bad_change() { _apply_socks_egress "$out"; return 1; }
if _feature_transaction bad_change; then echo 'expected rollback failure status'; exit 1; fi
cmp "$CONFIG_FILE" "$SINGBOX_DIR/original-sb"
cmp "$FEATURE_XRAY_CONFIG" "$SINGBOX_DIR/original-xray"
invalid_config() { _atomic_modify_json "$CONFIG_FILE" '.inbounds += [{type:"nonexistent"}]'; }
if _feature_transaction invalid_config; then echo 'invalid core config accepted'; exit 1; fi
cmp "$CONFIG_FILE" "$SINGBOX_DIR/original-sb"
touch "$SINGBOX_DIR/fail-restart"
if _feature_transaction _apply_socks_egress "$out"; then echo 'failed restart committed'; exit 1; fi
cmp "$CONFIG_FILE" "$SINGBOX_DIR/original-sb"
cmp "$FEATURE_XRAY_CONFIG" "$SINGBOX_DIR/original-xray"

uuid=11111111-1111-4111-8111-111111111111
check_uri() {
    local outbound
    outbound=$(printf '%s\n' "$1" | bash "$repo/parser.sh" subscription)
    if [ "$(jq -r '.transport.type // ""' <<< "$outbound")" = httpupgrade ]; then
        jq -e '.tls.alpn == ["http/1.1"]' <<< "$outbound" >/dev/null
    fi
    jq -n --argjson o "$outbound" '{outbounds:[$o]}' > "$SINGBOX_DIR/check.json"
    "$SINGBOX_BIN" check -c "$SINGBOX_DIR/check.json"
}
check_uri "vless://$uuid@example.com:443?security=tls&type=grpc&sni=example.com&serviceName=hello"
check_uri 'trojan://p%40ss@example.com:443?type=httpupgrade&security=tls&path=%2Ftest'
check_uri 'socks5://u%40ser:p%3Ass@[::1]:1080'
check_uri 'hy2://password@example.com:443?sni=example.com&obfs=salamander&obfs-password=hello'
check_uri 'ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@example.com:443'
for uri in "vless://$uuid@example.com:443?type=xhttp&security=tls" 'trojan://pass@example.com:443?plugin=bad' 'socks://example.com:99999'; do
    if printf '%s\n' "$uri" | bash "$repo/parser.sh" subscription >/dev/null; then echo 'invalid URI accepted'; exit 1; fi
done

# 模拟两种 Argo 新传输，直接使用创建函数的产物并交给真实核心。
_install_cloudflared() { :; }
_check_port_conflict() { return 1; }
_enable_argo_watchdog() { :; }
_start_argo_tunnel() { echo test.trycloudflare.com; }
_stop_argo_tunnel() { :; }
_feature_transaction _create_argo_node vless httpupgrade <<< $'18001\n/test\n1\nTest-upgrade'
jq -e '.inbounds[0].streamSettings.network == "httpupgrade" and .inbounds[0].listen == "127.0.0.1"' "$FEATURE_XRAY_CONFIG" >/dev/null
jq -e '.[] | .core == "xray" and (.share_link|contains("type=httpupgrade") and contains("alpn=http%2F1.1"))' "$ARGO_METADATA_FILE" >/dev/null
_feature_transaction _create_argo_node trojan httpupgrade <<< $'18004\n/trojan\ntest-password\n1\nTest-trojan-upgrade'
_feature_transaction _create_argo_node trojan ws <<< $'18002\n/ws\n\n1\nTest-ws'
_feature_transaction _create_argo_node vless xhttp <<< $'18003\n/xhttp\n1\nTest-xhttp'
jq -e 'any(.inbounds[]; .streamSettings.xhttpSettings.mode == "packet-up" and .listen == "127.0.0.1")' "$FEATURE_XRAY_CONFIG" >/dev/null
tag=argo-trojan-ws-18002
_feature_transaction _bind_argo_domain "$tag" fixed.example.com
"$YQ_BINARY" eval -o=json '.proxies[0]' "$CLASH_YAML_FILE" | jq -e '.server == "fixed.example.com" and .sni == "fixed.example.com" and .["ws-opts"].headers.Host == "fixed.example.com"' >/dev/null
jq -e --arg t "$tag" '.[$t].share_link|contains("fixed.example.com")' "$ARGO_METADATA_FILE" >/dev/null
_atomic_modify_json "$FEATURE_XRAY_CONFIG" '.inbounds += [(.inbounds[0] | .tag="xray-domain-test" | .port=19000)]'
_atomic_modify_json "$FEATURE_XRAY_METADATA" '.test={name:"Domain test",share_link:"vless://11111111-1111-4111-8111-111111111111@[::1]:443?type=xhttp"} | .["xray-domain-test"]=.test | del(.test)'
_feature_transaction _bind_xray_domain xray-domain-test node.example.com
jq -e '.["xray-domain-test"].share_link | contains("@node.example.com:443?")' "$FEATURE_XRAY_METADATA" >/dev/null

# 旧 sing-box HTTPUpgrade 节点自动迁移，保持原有端口、凭据、路径和域名。
_atomic_modify_json "$CONFIG_FILE" '.inbounds += [{type:"trojan",tag:"argo-trojan-httpupgrade-18005",listen:"127.0.0.1",listen_port:18005,users:[{password:"old-credential"}],transport:{type:"httpupgrade",path:"/old-path"}}]'
_atomic_modify_json "$ARGO_METADATA_FILE" '.["argo-trojan-httpupgrade-18005"]={name:"Old upgrade",protocol:"trojan-httpupgrade",core:"singbox",type:"fixed",token:"test-token",local_port:18005,password:"old-credential",path:"/old-path",domain:"old.example.com"}'
cp "$CONFIG_FILE" "$SINGBOX_DIR/pre-migration-sb"
cp "$FEATURE_XRAY_CONFIG" "$SINGBOX_DIR/pre-migration-xray"
cp "$ARGO_METADATA_FILE" "$SINGBOX_DIR/pre-migration-meta"
touch "$SINGBOX_DIR/fail-restart"
if _repair_argo_httpupgrade; then echo 'failed migration restart committed'; exit 1; fi
cmp "$CONFIG_FILE" "$SINGBOX_DIR/pre-migration-sb"
cmp "$FEATURE_XRAY_CONFIG" "$SINGBOX_DIR/pre-migration-xray"
cmp "$ARGO_METADATA_FILE" "$SINGBOX_DIR/pre-migration-meta"
_repair_argo_httpupgrade
jq -e 'any(.inbounds[]; .tag == "argo-trojan-httpupgrade-18005") | not' "$CONFIG_FILE" >/dev/null
jq -e 'any(.inbounds[]; .tag == "argo-trojan-httpupgrade-18005" and .port == 18005 and .settings.clients[0].password == "old-credential" and .streamSettings.httpupgradeSettings.path == "/old-path")' "$FEATURE_XRAY_CONFIG" >/dev/null
jq -e '.["argo-trojan-httpupgrade-18005"] | .core == "xray" and .domain == "old.example.com" and .token == "test-token"' "$ARGO_METADATA_FILE" >/dev/null
_repair_argo_httpupgrade
[ "$(jq '[.inbounds[] | select(.tag == "argo-trojan-httpupgrade-18005")] | length' "$FEATURE_XRAY_CONFIG")" = 1 ]
"$test_python" "$repo/tests/httpupgrade_smoke.py" "$test_sb" "$test_xray" "$FEATURE_XRAY_CONFIG"

# 订阅下载替身：仍执行真实解析、逐节点核心检查与状态写入。
curl() {
    local output
    while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then output="$2"; break; fi; shift; done
    cp "$SINGBOX_DIR/feed" "$output"
}
printf 'socks://upstream.example.com:1080#出口\nvless://%s@example.com:443?type=grpc&security=tls&serviceName=test#Grpc\nunsupported://bad\n' "$uuid" > "$SINGBOX_DIR/feed"
_subscription_fetch test Test https://subscription.example.com
[ "$(jq '.test.nodes|length' "$SINGBOX_DIR/subscriptions.json")" = 2 ]
base64 < "$SINGBOX_DIR/feed" > "$SINGBOX_DIR/feed64"
mv "$SINGBOX_DIR/feed64" "$SINGBOX_DIR/feed"
_subscription_fetch test Test https://subscription.example.com
[ "$(jq '.test.nodes|length' "$SINGBOX_DIR/subscriptions.json")" = 2 ]
cp "$SINGBOX_DIR/subscriptions.json" "$SINGBOX_DIR/good-subscriptions"
echo invalid > "$SINGBOX_DIR/feed"
if _subscription_fetch test Test https://subscription.example.com; then echo 'invalid subscription accepted'; exit 1; fi
cmp "$SINGBOX_DIR/subscriptions.json" "$SINGBOX_DIR/good-subscriptions"
cat > "$SINGBOX_DIR/feed" <<'YAML'
proxies:
  - {name: Socks, type: socks5, server: example.com, port: 1080}
  - name: Vless
    type: vless
    server: example.com
    port: 443
    uuid: 11111111-1111-4111-8111-111111111111
    tls: true
    network: grpc
    grpc-opts: {grpc-service-name: hello}
  - name: Upgrade
    type: trojan
    server: example.com
    port: 443
    password: test-password
    network: httpupgrade
    http-upgrade-opts: {path: /upgrade, host: example.com}
YAML
_subscription_fetch yaml TestYaml https://subscription.example.com
[ "$(jq '.yaml.nodes|length' "$SINGBOX_DIR/subscriptions.json")" = 3 ]
jq -e '.yaml.nodes[] | select(.name == "Upgrade") | .outbound.tls.alpn == ["http/1.1"]' "$SINGBOX_DIR/subscriptions.json" >/dev/null
_subscription_export_locked
base64 -d "$SINGBOX_DIR/subscription-export/base64.txt" > "$SINGBOX_DIR/decoded"
cmp "$SINGBOX_DIR/decoded" "$SINGBOX_DIR/subscription-export/links.txt"
_subscription_http_write_server
"$test_python" -m py_compile "$SINGBOX_DIR/subscription_server.py"
"$test_python" "$repo/tests/subscription_http.py" "$SINGBOX_DIR"
_feature_transaction _apply_socks_egress "$out"
(
    # 验证真实 Xray 管理器在已有统一出口时初始化另一个新配置。
    source "$repo/xray_manager.sh"
    XRAY_DIR="$SINGBOX_DIR/fresh-xray"
    mkdir -p "$XRAY_DIR"
    XRAY_CONFIG="$XRAY_DIR/config.json"
    XRAY_METADATA="$XRAY_DIR/metadata.json"
    XRAY_BIN="$test_xray"
    _init_xray_config
    jq -e '.routing.rules[0].outboundTag == "managed-socks-egress"' "$XRAY_CONFIG" >/dev/null
    _validate_xray_config
)
"$test_python" "$repo/tests/proxy_smoke.py" "$SINGBOX_BIN" "$test_xray" "$CONFIG_FILE" "$FEATURE_XRAY_CONFIG"
echo 'All network feature tests passed.'
