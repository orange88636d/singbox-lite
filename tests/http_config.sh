#!/bin/bash
# 只替换进程/初始化系统操作，校验订阅服务配置失败后的凭据和状态恢复。
set -eo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export SINGBOXLITE_LIBRARY_ONLY=1
source "$repo/singbox.sh"
SINGBOX_DIR=$(mktemp -d)
trap 'rm -rf -- "$SINGBOX_DIR"' EXIT
export SINGBOXLITE_LOCK_HELD=1
INIT_SYSTEM=systemd
_check_port_conflict() { return 1; }
crontab() { :; }
_subscription_http_start() {
    [ "$(jq -r .port "$SINGBOX_DIR/subscription-http.json")" != 18081 ]
}
_subscription_http_stop() {
    if [ -f "$SINGBOX_DIR/subscription-http.json" ]; then
        _atomic_modify_json "$SINGBOX_DIR/subscription-http.json" '.enabled=false'
    fi
    return 0
}
_subscription_http_configure 127.0.0.1 18080 https://sub.example.com
cp "$SINGBOX_DIR/subscription-http.json" "$SINGBOX_DIR/good"
if _subscription_http_configure 127.0.0.1 18081 https://new.example.com; then
    echo 'Failed service reconfiguration unexpectedly succeeded.'; exit 1
fi
cmp "$SINGBOX_DIR/good" "$SINGBOX_DIR/subscription-http.json"
echo 'HTTP service reconfiguration rollback passed.'
