#!/bin/bash
# 域名、统一 SOCKS 出口、Argo 传输与订阅。由主脚本加载，共享状态锁。
FEATURE_XRAY_CONFIG="${FEATURE_XRAY_CONFIG:-/usr/local/etc/xray/config.json}"
FEATURE_XRAY_METADATA="${FEATURE_XRAY_METADATA:-/usr/local/etc/xray/metadata.json}"
FEATURE_XRAY_BIN="${FEATURE_XRAY_BIN:-/usr/local/bin/xray}"

_valid_domain() {
    local domain="${1%.}" label
    [[ ${#domain} -le 253 && "$domain" == *.* && "$domain" != *[!a-zA-Z0-9.-]* ]] || return 1
    local labels=()
    IFS=. read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" != -* && "$label" != *- ]] || return 1
    done
    [[ "$domain" != *..* && ! "$domain" =~ ^[0-9.]+$ ]]
}

_get_client_address() {
    local domain
    domain=$(jq -r '.domain // empty' "${SINGBOX_DIR}/domain.json" 2>/dev/null)
    if _valid_domain "$domain"; then printf '%s\n' "$domain"; else _get_public_ip; fi
}

_feature_xray() (
    local script="${SCRIPT_DIR}/xray_manager.sh"
    [ -f "$script" ] || script="${SINGBOX_DIR}/xray_manager.sh"
    if [ ! -f "$script" ]; then
        _download_bash_script_atomic "${GITHUB_RAW_BASE}/xray_manager.sh" "$script" xray_manager.sh || return 1
    fi
    export SINGBOXLITE_LIBRARY_ONLY=1
    source "$script" || return 1
    "$@"
)

# 为跨核心改动建立独立事务；已有中转规则不被覆盖。失败或信号会恢复所有文件。
_feature_transaction() { _with_state_lock _feature_transaction_locked "$@"; }
_feature_transaction_locked() (
    local tx committed=0 changed_sb=0 changed_xray=0 feature_new_argo_port=""
    local files=("$CONFIG_FILE" "$RELAY_CONFIG_FILE" "$METADATA_FILE" "$ARGO_METADATA_FILE" "$CLASH_YAML_FILE"
        "${SINGBOX_DIR}/domain.json" "${SINGBOX_DIR}/egress.json" "${SINGBOX_DIR}/subscriptions.json"
        "$FEATURE_XRAY_CONFIG" "$FEATURE_XRAY_METADATA")
    local i file
    tx=$(mktemp -d "${SINGBOX_DIR}/.network-tx.XXXXXX") || return 1
    for i in "${!files[@]}"; do
        file=${files[$i]}
        _main_create_tx_snapshot_file "$tx" "$i" "$file" || { rm -rf -- "$tx"; return 1; }
    done
    trap 'rc=$?; trap - EXIT INT TERM; if [ "$committed" != 1 ]; then
        [ -z "$feature_new_argo_port" ] || _stop_argo_tunnel "$feature_new_argo_port"
        failed=0
        cmp -s "$CONFIG_FILE" "$tx/0" || { [ ! -f "$CONFIG_FILE" ] && [ ! -f "$tx/0" ]; } || changed_sb=1
        cmp -s "$RELAY_CONFIG_FILE" "$tx/1" || { [ ! -f "$RELAY_CONFIG_FILE" ] && [ ! -f "$tx/1" ]; } || changed_sb=1
        cmp -s "$FEATURE_XRAY_CONFIG" "$tx/8" || { [ ! -f "$FEATURE_XRAY_CONFIG" ] && [ ! -f "$tx/8" ]; } || changed_xray=1
        for i in "${!files[@]}"; do _main_create_tx_restore_file "$tx" "$i" "${files[$i]}" || failed=1; done
        if [ "$changed_sb" = 1 ]; then
            [ -f "$tx/0.present" ] && action=restart || action=stop
            _manage_service "$action" >/dev/null 2>&1 || failed=1
        fi
        if [ "$changed_xray" = 1 ]; then
            [ -f "$tx/8.present" ] && action=restart || action=stop
            _feature_xray _manage_xray_service "$action" >/dev/null 2>&1 || failed=1
        fi
        if [ "$failed" = 0 ]; then rm -rf -- "$tx"; _error "操作失败，已恢复原配置。";
        else _error "回滚不完整，请检查服务。恢复快照: $tx"; fi
        [ "$rc" != 0 ] || rc=1
    else rm -rf -- "$tx"; fi; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@" || return 1
    if [ -f "$CONFIG_FILE" ] && { [ ! -f "$tx/0" ] || ! cmp -s "$CONFIG_FILE" "$tx/0"; }; then changed_sb=1; fi
    if [ -f "$RELAY_CONFIG_FILE" ] && { [ ! -f "$tx/1" ] || ! cmp -s "$RELAY_CONFIG_FILE" "$tx/1"; }; then changed_sb=1; fi
    if [ -f "$FEATURE_XRAY_CONFIG" ] && { [ ! -f "$tx/8" ] || ! cmp -s "$FEATURE_XRAY_CONFIG" "$tx/8"; }; then changed_xray=1; fi
    if [ "$changed_sb" = 1 ]; then _check_combined_config_files && _manage_service restart || return 1; fi
    if [ "$changed_xray" = 1 ]; then
        _feature_xray _validate_xray_config && _feature_xray _manage_xray_service restart || return 1
    fi
    committed=1
)

_set_bound_domain() {
    local domain="$1"
    _valid_domain "$domain" || { _error "请输入有效域名，不包含协议、路径或端口。"; return 1; }
    [ -f "${SINGBOX_DIR}/domain.json" ] || printf '{}\n' > "${SINGBOX_DIR}/domain.json"
    _atomic_modify_json "${SINGBOX_DIR}/domain.json" '.domain = $domain' --arg domain "${domain,,}"
}

_bind_main_node_domain() {
    local tag="$1" domain="$2" node meta proxy
    _valid_domain "$domain" || return 1
    node=$(jq -cS --arg t "$tag" '.inbounds[] | select(.tag == $t)' "$CONFIG_FILE") || return 1
    meta=$(jq -cS --arg t "$tag" '.[$t] // {}' "$METADATA_FILE") || return 1
    proxy=$(_find_proxy_name "$(jq -r .listen_port <<< "$node")" "$(jq -r .type <<< "$node")" "$tag")
    _modify_node_apply "$tag" "$node" "$meta" "$proxy" address "$domain"
}

_bind_xray_domain() {
    local tag="$1" domain="$2" meta name port link
    _valid_domain "$domain" || return 1
    meta=$(jq -c --arg t "$tag" '.[$t]' "$FEATURE_XRAY_METADATA") || return 1
    name=$(jq -r .name <<< "$meta"); link=$(jq -r '.share_link // empty' <<< "$meta")
    port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .port' "$FEATURE_XRAY_CONFIG")
    [[ "$link" == *@* && -n "$port" ]] || { _error "节点缺少可更新的分享链接。"; return 1; }
    _atomic_modify_json "$FEATURE_XRAY_METADATA" '.[$t].share_link |= sub("@(?:\\[[^]]+\\]|[^/:?#]+):"; "@" + $domain + ":") | .[$t].clientServer=$domain' \
        --arg t "$tag" --arg domain "$domain" || return 1
    export BIND_NAME="$name" BIND_PORT="$port" BIND_DOMAIN="$domain"
    if [ -f "$CLASH_YAML_FILE" ]; then
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(BIND_NAME) and (.port | tostring) == strenv(BIND_PORT)) | .server) = strenv(BIND_DOMAIN)' || return 1
    fi
}

_binding_menu() {
    local choice domain tag nodes=() node
    echo "1) 设置新节点默认连接域名   2) 绑定已有 sing-box 节点"
    echo "3) 绑定/更换 Argo 固定隧道域名   4) 清除默认域名   5) 绑定已有 Xray 节点   0) 返回"
    read -r -p "请选择: " choice
    [ "$choice" != 0 ] || return 0
    if [ "$choice" = 4 ]; then
        _with_state_lock rm -f -- "${SINGBOX_DIR}/domain.json"
        server_ip=""; return
    fi
    read -r -p "请输入已配置 DNS 的域名: " domain
    domain="${domain%.}"
    _valid_domain "$domain" || { _error "域名格式无效。"; return 1; }
    case "$choice" in
        1) _feature_transaction _set_bound_domain "$domain" && { server_ip="$domain"; _success "默认连接域名已保存；DNS 需指向本机。"; } ;;
        2)
            while IFS= read -r node; do
                tag=$(jq -r .tag <<< "$node"); nodes+=("$tag"); echo "${#nodes[@]}) $tag"
            done < <(_list_main_primary_inbounds)
            read -r -p "节点编号: " choice
            [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#nodes[@]}" ] || return 1
            _bind_main_node_domain "${nodes[$((choice - 1))]}" "$domain" && _success "连接域名已同步到链接和 YAML。TLS 证书/SNI 可在修改节点菜单设置。"
            ;;
        3)
            _select_argo_tag || return 1
            tag="$SELECTED_ARGO_TAG"
            [ "$(jq -r --arg t "$tag" '.[$t].type' "$ARGO_METADATA_FILE")" = fixed ] || {
                _error "临时隧道不能绑定自定义域名，请创建 Token 固定隧道。"; return 1;
            }
            _info "请在 Cloudflare 为此 Tunnel 设置 Public Hostname=${domain}，Service=http://localhost:$(jq -r --arg t "$tag" '.[$t].local_port' "$ARGO_METADATA_FILE")"
            _feature_transaction _bind_argo_domain "$tag" "$domain"
            ;;
        5)
            while IFS= read -r tag; do nodes+=("$tag"); echo "${#nodes[@]}) $tag"; done < <(jq -r '.inbounds[] | select((.tag | startswith("argo-")) | not) | .tag' "$FEATURE_XRAY_CONFIG")
            read -r -p "节点编号: " choice
            [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#nodes[@]}" ] || return 1
            _feature_transaction _bind_xray_domain "${nodes[$((choice - 1))]}" "$domain" && _success "Xray 连接域名已同步；证书/SNI 保持原值。"
            ;;
        *) return 1 ;;
    esac
}

_bind_argo_domain() {
    _atomic_modify_json "$ARGO_METADATA_FILE" '.[$tag].domain = $domain' --arg tag "$1" --arg domain "$2" || return 1
    _argo_refresh_artifacts "$1"
}

_socks_outbound() {
    local host="$1" port="$2" username="${3:-}" password="${4:-}"
    [[ -n "$host" && "$host" != *[[:space:]/@?#]* && "$host" != *"://"* ]] || return 1
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] || return 1
    [ -z "$username" ] && [ -n "$password" ] && return 1
    jq -n --arg s "${host#[}" --arg p "$port" --arg u "$username" --arg pw "$password" '
        {type:"socks",tag:"managed-socks-egress",server:($s|rtrimstr("]")),server_port:($p|tonumber),version:"5"}
        + if $u != "" then {username:$u,password:$pw} else {} end'
}

_apply_socks_egress() {
    local outbound="$1" file="${SINGBOX_DIR}/egress.json" xout
    if [ "$outbound" != null ]; then
        jq -e '.type == "socks" and .tag == "managed-socks-egress" and (.server|type == "string") and (.server_port|type == "number")' <<< "$outbound" >/dev/null || return 1
    fi
    [ -f "$file" ] || printf '{}\n' > "$file"
    _atomic_modify_json "$file" '.outbound = $out' --argjson out "$outbound" || return 1
    if [ -f "$CONFIG_FILE" ]; then
        _atomic_modify_json "$CONFIG_FILE" '
            .outbounds = ((.outbounds // [] | map(select(.tag != "managed-socks-egress"))) + if $out == null then [] else [$out] end)
            | .route.rules = ((if $out == null then [] else [{action:"route",outbound:"managed-socks-egress"}] end)
                + ((.route.rules // []) | map(select(.outbound != "managed-socks-egress"))))' --argjson out "$outbound" || return 1
    fi
    if [ -f "$FEATURE_XRAY_CONFIG" ]; then
        xout=$(jq -n --argjson o "$outbound" 'if $o == null then null else
            {tag:"managed-socks-egress",protocol:"socks",settings:{servers:[
                {address:$o.server,port:$o.server_port} + if ($o.username // "") != "" then {users:[{user:$o.username,pass:$o.password}]} else {} end]}} end') || return 1
        _atomic_modify_json "$FEATURE_XRAY_CONFIG" '
            .outbounds = ((.outbounds // [] | map(select(.tag != "managed-socks-egress"))) + if $out == null then [] else [$out] end)
            | .routing.rules = ((if $out == null then [] else [{type:"field",network:"tcp,udp",outboundTag:"managed-socks-egress"}] end)
                + ((.routing.rules // []) | map(select(.outboundTag != "managed-socks-egress"))))' --argjson out "$xout" || return 1
    fi
}

_egress_menu() {
    local choice host port username password outbound
    echo "1) 设置统一 SOCKS5 出口   2) 关闭统一出口   3) 查看状态   0) 返回"
    _info "覆盖 sing-box/Xray 的代理流量及用户态中转；优先于原分流。上游不可达时不回退直连。"
    _info "UDP 需要上游支持 SOCKS5 UDP ASSOCIATE；系统流量与 nftables 转发不经过核心。"
    read -r -p "请选择: " choice
    case "$choice" in
        1)
            read -r -p "SOCKS5 地址 (IP/域名): " host
            read -r -p "端口: " port
            read -r -p "用户名 (无认证留空): " username
            password=""
            if [ -n "$username" ]; then read -r -s -p "密码: " password; echo; fi
            outbound=$(_socks_outbound "$host" "$port" "$username" "$password") || { _error "出口参数无效。"; return 1; }
            _feature_transaction _apply_socks_egress "$outbound" && _success "统一出口已启用。"
            ;;
        2) _feature_transaction _apply_socks_egress null && _success "已恢复原有分流。" ;;
        3) jq '{enabled:(.outbound != null),server:.outbound.server,port:.outbound.server_port,authenticated:((.outbound.username // "") != "")}' "${SINGBOX_DIR}/egress.json" 2>/dev/null || echo "未启用" ;;
        0) return 0 ;;
    esac
}

_select_argo_tag() {
    local entry tags=() choice
    while IFS= read -r entry; do
        tags+=("$(jq -r .key <<< "$entry")")
        printf '%s) %s\n' "${#tags[@]}" "$(jq -r '.value.name' <<< "$entry")"
    done < <(jq -c 'to_entries[]' "$ARGO_METADATA_FILE")
    [ "${#tags[@]}" -gt 0 ] || { _warn "没有 Argo 节点。"; return 1; }
    read -r -p "节点编号 (0 返回): " choice
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#tags[@]}" ] || return 1
    SELECTED_ARGO_TAG="${tags[$((choice - 1))]}"
}

_argo_refresh_artifacts() {
    local tag="$1" meta protocol transport domain name credential path link proxy
    meta=$(jq -c --arg t "$tag" '.[$t]' "$ARGO_METADATA_FILE") || return 1
    protocol=$(jq -r .protocol <<< "$meta"); transport="${protocol#*-}"; protocol="${protocol%%-*}"
    domain=$(jq -r .domain <<< "$meta"); name=$(jq -r .name <<< "$meta")
    path=$(jq -r '.path // "/"' <<< "$meta")
    credential=$(jq -r '.uuid // .password' <<< "$meta")
    link="${protocol}://$(_url_encode "$credential")@${domain}:443?security=tls&encryption=none&type=${transport}&sni=${domain}&host=${domain}"
    if [ "$transport" = ws ]; then path=$(_ws_path_with_early_data "$path"); fi
    link+="&path=$(_url_encode "$path")"
    [ "$transport" != xhttp ] || link+="&mode=packet-up"
    link+="#$(_url_encode "$name")"
    _atomic_modify_json "$ARGO_METADATA_FILE" '.[$t].share_link = $link' --arg t "$tag" --arg link "$link" || return 1
    if [ "$transport" = xhttp ]; then return 0; fi
    proxy=$(jq -n --arg n "$name" --arg s "$domain" --arg p "$protocol" --arg net "$transport" \
        --arg cred "$credential" --arg path "$(jq -r .path <<< "$meta")" --argjson ed "$WS_EARLY_DATA_SIZE" --arg edh "$WS_EARLY_DATA_HEADER" '
        {name:$n,type:$p,server:$s,port:443,tls:true,udp:true,"skip-cert-verify":false,network:$net}
        + (if $p == "vless" then {uuid:$cred,servername:$s} else {password:$cred,sni:$s} end)
        + (if $net == "ws" then {"ws-opts":{path:$path,headers:{Host:$s},"max-early-data":$ed,"early-data-header-name":$edh}}
           else {"http-upgrade-opts":{path:$path,host:$s}} end)') || return 1
    # HTTPUpgrade 客户端生态差异较大，只输出 URI，不写不受支持的 Mihomo network。
    [ "$transport" = ws ] || return 0
    export ARGO_NAME="$name" ARGO_PROXY="$proxy"
    if "$YQ_BINARY" eval '.proxies[] | select(.name == strenv(ARGO_NAME)) | .name' "$CLASH_YAML_FILE" 2>/dev/null | grep -Fxq "$name"; then
        _atomic_modify_yaml "$CLASH_YAML_FILE" '(.proxies[] | select(.name == strenv(ARGO_NAME))) = (strenv(ARGO_PROXY) | from_json)'
    else _add_node_to_yaml "$proxy"; fi
}

_create_argo_node() {
    local protocol="$1" transport="${2:-ws}" core=singbox port path credential custom_password mode token="" domain="" name tag inbound meta
    case "$protocol:$transport" in vless:ws|trojan:ws|vless:httpupgrade|trojan:httpupgrade) ;; vless:xhttp|trojan:xhttp) core=xray ;; *) return 1 ;; esac
    [ "$core" != xray ] || [ -x "$FEATURE_XRAY_BIN" ] || { _error "XHTTP 需要先安装 Xray 核心。"; return 1; }
    _install_cloudflared || return 1
    read -r -p "Argo 本地端口 (回车随机): " port
    [ -n "$port" ] || port=$(( $(od -An -tu2 -N2 /dev/urandom | tr -d ' ') % 40000 + 20000 ))
    [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] && [ "$port" -le 65535 ] || { _error "端口应在 1024-65535 之间。"; return 1; }
    [ "$port" -ge 1024 ] || return 1
    _check_port_conflict "$port" tcp && return 1
    read -r -p "传输路径 (回车随机): " path
    path="${path:-/$(openssl rand -hex 8)}"; [[ "$path" == /* ]] || path="/$path"
    credential=$(openssl rand -hex 16)
    [ "$protocol" != vless ] || credential=$("$SINGBOX_BIN" generate uuid)
    if [ "$protocol" = trojan ]; then
        read -r -s -p "Trojan 密码 (回车随机生成): " custom_password; echo
        credential=${custom_password:-$credential}
    fi
    [ -n "$credential" ] || return 1
    read -r -p "隧道模式 [1 临时 / 2 固定] (默认 1): " mode; mode=${mode:-1}
    case "$mode" in
        1) mode=temp ;;
        2)
            mode=fixed
            read -r -s -p "Tunnel Token (或完整安装命令): " token; echo
            token=$(grep -oE 'ey[A-Za-z0-9_.=-]{20,}' <<< "$token" | head -1)
            [ -n "$token" ] || { _error "未识别到有效 Token。"; return 1; }
            read -r -p "绑定域名: " domain
            _valid_domain "$domain" || { _error "域名格式无效。"; return 1; }
            _info "Cloudflare Public Hostname: $domain -> http://localhost:$port"
            ;;
        *) return 1 ;;
    esac
    read -r -p "节点名称 (回车默认): " name
    name=${name:-Argo-${protocol}-${transport}-${port}}
    export PROXY_NAME="$name"
    if "$YQ_BINARY" eval '.proxies[] | select(.name == strenv(PROXY_NAME)) | .name' "$CLASH_YAML_FILE" 2>/dev/null | grep -Fxq "$name" ||
        jq -e --arg n "$name" 'any(.[]; .name == $n)' "$ARGO_METADATA_FILE" >/dev/null 2>&1; then _error "节点名称已存在。"; return 1; fi
    tag="argo-${protocol}-${transport}-${port}"
    if [ "$core" = singbox ]; then
        inbound=$(jq -n --arg t "$tag" --arg p "$protocol" --arg net "$transport" --argjson port "$port" --arg c "$credential" --arg path "$path" \
            --argjson ed "$WS_EARLY_DATA_SIZE" --arg edh "$WS_EARLY_DATA_HEADER" '
            {type:$p,tag:$t,listen:"127.0.0.1",listen_port:$port,users:[if $p == "vless" then {uuid:$c,flow:""} else {password:$c} end],transport:{type:$net,path:$path}}
            | if $net == "ws" then .transport += {max_early_data:$ed,early_data_header_name:$edh} else . end') || return 1
        _atomic_modify_json "$CONFIG_FILE" '.inbounds += [$in]' --argjson in "$inbound" || return 1
        _check_combined_config_files && _manage_service restart || return 1
    else
        _feature_xray _init_xray_config && _feature_xray _create_xray_service || return 1
        inbound=$(jq -n --arg t "$tag" --arg p "$protocol" --argjson port "$port" --arg c "$credential" --arg path "$path" '
            {tag:$t,listen:"127.0.0.1",port:$port,protocol:$p,
             settings:({clients:[if $p == "vless" then {id:$c} else {password:$c} end]} + if $p == "vless" then {decryption:"none"} else {} end),
             streamSettings:{network:"xhttp",security:"none",xhttpSettings:{path:$path,mode:"packet-up"}}}') || return 1
        _atomic_modify_json "$FEATURE_XRAY_CONFIG" '.inbounds += [$in]' --argjson in "$inbound" || return 1
        # 后安装的核心也继承既有统一出口。
        if [ -f "${SINGBOX_DIR}/egress.json" ]; then _apply_socks_egress "$(jq -c '.outbound' "${SINGBOX_DIR}/egress.json")" || return 1; fi
        _feature_xray _validate_xray_config && _feature_xray _manage_xray_service restart || return 1
    fi
    feature_new_argo_port="$port"
    if [ "$mode" = fixed ]; then _start_argo_tunnel "$port" "${protocol}-${transport}" "$token" || return 1
    else domain=$(_start_argo_tunnel "$port" "${protocol}-${transport}") || return 1; [ -n "$domain" ] || return 1; fi
    meta=$(jq -n --arg t "$tag" --arg p "${protocol}-${transport}" --argjson port "$port" --arg c "$credential" --arg proto "$protocol" \
        --arg path "$path" --arg n "$name" --arg d "$domain" --arg mode "$mode" --arg token "$token" --arg core "$core" '
        {($t): ({name:$n,protocol:$p,local_port:$port,path:$path,domain:$d,type:$mode,token:$token,core:$core}
            + (if $proto == "vless" then {uuid:$c} else {password:$c} end))}') || return 1
    [ -f "$ARGO_METADATA_FILE" ] || printf '{}\n' > "$ARGO_METADATA_FILE"
    _atomic_modify_json "$ARGO_METADATA_FILE" '. + $meta' --argjson meta "$meta" || return 1
    _argo_refresh_artifacts "$tag" && _enable_argo_watchdog || return 1
    _success "Argo ${protocol} + ${transport} 已创建。"
    jq -r --arg t "$tag" '.[$t].share_link' "$ARGO_METADATA_FILE"
}

_add_argo_node() { _feature_transaction _create_argo_node "$@"; }

_sync_argo_ws_artifacts() {
    local tag
    export WS_ED="$WS_EARLY_DATA_SIZE" WS_EDH="$WS_EARLY_DATA_HEADER"
    _atomic_modify_json "$CONFIG_FILE" '
        (.inbounds[] | select((.tag | startswith("argo-")) and .transport.type == "ws") | .transport)
        += {max_early_data:(env.WS_ED|tonumber),early_data_header_name:env.WS_EDH}' || return 1
    while IFS= read -r tag; do _argo_refresh_artifacts "$tag" || return 1; done < <(jq -r 'to_entries[] | select(.value.protocol == "vless-ws" or .value.protocol == "trojan-ws") | .key' "$ARGO_METADATA_FILE")
}

_sync_argo_early_data() {
    [ -f "$CONFIG_FILE" ] && [ -f "$ARGO_METADATA_FILE" ] || return 0
    _feature_transaction _sync_argo_ws_artifacts
}

_restart_one_argo() {
    local tag="$1" meta port protocol token type domain
    meta=$(jq -ce --arg t "$tag" '.[$t] // empty' "$ARGO_METADATA_FILE") || return 1
    port=$(jq -r .local_port <<< "$meta"); protocol=$(jq -r .protocol <<< "$meta")
    token=$(jq -r '.token // ""' <<< "$meta"); type=$(jq -r .type <<< "$meta")
    _stop_argo_tunnel "$port"
    if [ "$type" = fixed ]; then
        _start_argo_tunnel "$port" "$protocol" "$token" || return 1
        _argo_refresh_artifacts "$tag"
    else
        domain=$(_start_argo_tunnel "$port" "$protocol") || return 1
        [ -n "$domain" ] || return 1
        _feature_transaction _bind_argo_domain "$tag" "$domain"
    fi
}

_restart_argo_tunnel_menu() {
    local choice tag failed=0
    read -r -p "重启全部隧道请输入 a；选择单个节点请回车: " choice
    if [ "$choice" = a ]; then
        while IFS= read -r tag; do _with_state_lock _restart_one_argo "$tag" || failed=1; done < <(jq -r 'keys[]' "$ARGO_METADATA_FILE")
    else
        _select_argo_tag || return 1
        _with_state_lock _restart_one_argo "$SELECTED_ARGO_TAG" || failed=1
    fi
    [ "$failed" = 0 ] && _success "隧道已重启，订阅和 YAML 已同步。" || { _error "部分隧道重启失败，请检查日志。"; return 1; }
}

_argo_keepalive() { _with_state_lock _argo_keepalive_locked; }

_remove_argo_config() {
    local tag="$1" core name
    core=$(jq -r --arg t "$tag" '.[$t].core // "singbox"' "$ARGO_METADATA_FILE")
    name=$(jq -r --arg t "$tag" '.[$t].name' "$ARGO_METADATA_FILE")
    if [ "$core" = xray ]; then
        _atomic_modify_json "$FEATURE_XRAY_CONFIG" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag" || return 1
    else
        _atomic_modify_json "$CONFIG_FILE" 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$tag" || return 1
    fi
    _atomic_modify_json "$ARGO_METADATA_FILE" 'del(.[$tag])' --arg tag "$tag" || return 1
    _remove_node_from_yaml "$name"
}

_delete_argo_node() {
    local port tag
    _select_argo_tag || return 1
    tag="$SELECTED_ARGO_TAG"
    port=$(jq -r --arg t "$tag" '.[$t].local_port' "$ARGO_METADATA_FILE")
    _feature_transaction _remove_argo_config "$tag" || return 1
    _stop_argo_tunnel "$port"
    [ "$(jq length "$ARGO_METADATA_FILE")" != 0 ] || _disable_argo_watchdog
    _success "Argo 节点已删除。"
}

_remove_all_argo_config() {
    local tag
    while IFS= read -r tag; do _remove_argo_config "$tag" || return 1; done < <(jq -r 'keys[]' "$ARGO_METADATA_FILE")
}

_uninstall_argo() {
    local confirm
    read -r -p "删除所有 Argo 节点和 cloudflared？(y/N): " confirm
    [[ "$confirm" == y || "$confirm" == Y ]] || return 0
    if [ -f "$ARGO_METADATA_FILE" ]; then _feature_transaction _remove_all_argo_config || return 1; fi
    _stop_all_argo_tunnels
    _disable_argo_watchdog
    rm -f -- "$CLOUDFLARED_BIN" "$ARGO_METADATA_FILE"
    _success "Argo 已卸载。"
}

_subscription_parser_path() {
    local path="${SCRIPT_DIR}/parser.sh"
    [ -f "$path" ] || path="${SINGBOX_DIR}/parser.sh"
    if [ ! -f "$path" ]; then _download_bash_script_atomic "${GITHUB_RAW_BASE}/parser.sh" "$path" parser.sh || return 1; fi
    printf '%s\n' "$path"
}

# 将 Mihomo 的常见节点转换为最小 outbound，不执行 YAML 标签，不导入规则/脚本。
_subscription_clash_nodes() {
    "$YQ_BINARY" eval -o=json '.proxies' "$1" | jq -c '
        if type != "array" then error("缺少 proxies 数组") else . end | .[] |
        . as $p | (.type // "") as $t |
        select(["socks5","http","ss","vless","trojan","hysteria2","anytls"] | index($t)) |
        select((.plugin // "") == "" and (.smux.enabled // false) == false and (.encryption // "none") == "none") |
        select((.network // "tcp") as $n | ["tcp","ws","grpc","httpupgrade"] | index($n)) |
        {name:($p.name // $p.server),outbound:({tag:"proxy",type:({socks5:"socks",ss:"shadowsocks"}[$t] // $t),server:$p.server,server_port:$p.port}
        + (if $t == "socks5" or $t == "http" then {username:($p.username // ""),password:($p.password // "")}
           elif $t == "ss" then {method:$p.cipher,password:$p.password}
           elif $t == "vless" then {uuid:$p.uuid,flow:($p.flow // "")} else {password:$p.password} end)
        + (if ($p.tls // false) or (["trojan","hysteria2","anytls"]|index($t)) then
            {tls:({enabled:true,server_name:($p.servername // $p.sni // $p.server),insecure:($p["skip-cert-verify"] // false)}
            + if $p["reality-opts"] then {reality:{enabled:true,public_key:$p["reality-opts"]["public-key"],short_id:($p["reality-opts"]["short-id"] // "")},utls:{enabled:true,fingerprint:($p["client-fingerprint"] // "chrome")}} else {} end)} else {} end)
        + (if $p.network == "ws" then {transport:{type:"ws",path:($p["ws-opts"].path // "/"),headers:($p["ws-opts"].headers // {})}}
           elif $p.network == "grpc" then {transport:{type:"grpc",service_name:($p["grpc-opts"]["grpc-service-name"] // "")}}
           elif $p.network == "httpupgrade" then {transport:{type:"httpupgrade",path:($p["http-upgrade-opts"].path // "/"),host:($p["http-upgrade-opts"].host // $p.server)}} else {} end)
        + (if $t == "hysteria2" and $p.obfs then {obfs:{type:$p.obfs,password:$p["obfs-password"]}} else {} end)),share_link:""}'
}

_subscription_fetch() (
    local id="$1" name="$2" url="$3" work parser content line outbound name_node count=0 skipped=0 total=0
    local state="${SINGBOX_DIR}/subscriptions.json"
    [[ "$url" == https://* || "$url" == http://* ]] && [[ "$url" != *[[:space:]]* ]] || { _error "订阅 URL 必须是 HTTP(S)。"; return 1; }
    parser=$(_subscription_parser_path) || return 1
    work=$(mktemp -d "${SINGBOX_DIR}/.subscription.XXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    # 限制下载、重定向协议、时限与体积，保留系统 CA 校验；错误日志不回显私密 URL。
    if ! curl --proto '=http,https' --proto-redir '=http,https' --connect-timeout 10 --max-time 30 \
        --max-filesize 4194304 -L -fsS -A 'singbox-lite/29' "$url" -o "$work/raw" 2>"$work/download-error"; then
        _error "订阅下载失败（网络、HTTP 状态、证书或 4MiB 限制）；旧订阅已保留。"; return 1
    fi
    [ "$(wc -c < "$work/raw")" -le 4194304 ] || return 1
    tr -d '\r' < "$work/raw" > "$work/body"
    if ! grep -qE '^[a-zA-Z0-9+.-]+://' "$work/body" && ! grep -qE '^proxies:' "$work/body"; then
        content=$(tr -d '[:space:]' < "$work/body")
        content="${content//-/+}"; content="${content//_/\/}"
        case $((${#content} % 4)) in 2) content+='==' ;; 3) content+='=' ;; esac
        if ! printf '%s' "$content" | base64 -d > "$work/decoded" 2>/dev/null; then _error "订阅既不是链接列表、Base64，也不是 Clash YAML。"; return 1; fi
        tr -d '\r' < "$work/decoded" > "$work/body"
    fi
    : > "$work/nodes"
    if grep -qE '^proxies:' "$work/body"; then
        _subscription_clash_nodes "$work/body" > "$work/candidates" 2>/dev/null || { _error "Clash 订阅格式无效。"; return 1; }
        total=$("$YQ_BINARY" eval '.proxies | length' "$work/body")
    else
        : > "$work/candidates"
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -n "$line" && "$line" != \#* ]] || continue
            total=$((total + 1)); [ "$total" -le 500 ] || { _error "单订阅最多支持 500 个节点。"; return 1; }
            if outbound=$(printf '%s\n' "$line" | bash "$parser" subscription 2>/dev/null); then
                name_node="${line#*#}"; [ "$name_node" != "$line" ] || name_node="节点-$total"
                name_node=$(_url_decode "$name_node")
                jq -nc --arg n "$name_node" --arg l "$line" --argjson o "$outbound" '{name:$n,share_link:$l,outbound:$o}' >> "$work/candidates" || return 1
            fi
        done < "$work/body"
    fi
    [[ "$total" =~ ^[0-9]+$ ]] && [ "$total" -le 500 ] || return 1
    # 每个节点用当前核心单独验证；远程传来的配置仅包含重建的白名单字段。
    while IFS= read -r line; do
        outbound=$(jq -c .outbound <<< "$line") || continue
        jq -n --argjson o "$outbound" '{outbounds:[$o],route:{default_domain_resolver:"subscription-dns"},dns:{servers:[{type:"local",tag:"subscription-dns"}]}}' > "$work/check.json" || return 1
        if "$SINGBOX_BIN" check -c "$work/check.json" > "$work/check.log" 2>&1; then
            printf '%s\n' "$line" >> "$work/nodes"; count=$((count + 1))
        fi
    done < "$work/candidates"
    [ "$count" -gt 0 ] || { _error "没有当前 sing-box 支持的有效节点；旧订阅已保留。"; return 1; }
    jq -s 'unique_by(.outbound)' "$work/nodes" > "$work/nodes.json" || return 1
    [ -f "$state" ] || printf '{}\n' > "$state"
    _atomic_modify_json "$state" '.[$id]={name:$name,url:$url,nodes:$nodes[0],updated_at:$time}' \
        --arg id "$id" --arg name "$name" --arg url "$url" --arg time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --slurpfile nodes "$work/nodes.json" || return 1
    skipped=$((total - count))
    _success "订阅已保存：有效 $count，跳过 $skipped（不支持或配置无效）；相同节点已去重。"
)

_subscription_select() {
    local entry ids=() choice
    while IFS= read -r entry; do
        ids+=("$(jq -r .key <<< "$entry")")
        printf '%s) %s\n' "${#ids[@]}" "$(jq -r '.value | "\(.name) (\(.nodes|length) 节点)"' <<< "$entry")"
    done < <(jq -c 'to_entries[]' "${SINGBOX_DIR}/subscriptions.json" 2>/dev/null)
    [ "${#ids[@]}" -gt 0 ] || { _warn "尚未添加订阅。"; return 1; }
    read -r -p "订阅编号 (0 返回): " choice
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -le "${#ids[@]}" ] || return 1
    SELECTED_SUBSCRIPTION_ID="${ids[$((choice - 1))]}"
}

_subscription_export_locked() (
    local root="${SINGBOX_DIR}/subscription-export" work file
    work=$(mktemp -d "${SINGBOX_DIR}/.export.XXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    : > "$work/links.txt"
    for file in "$METADATA_FILE" "$ARGO_METADATA_FILE" /usr/local/etc/xray/metadata.json "${SINGBOX_DIR}/relay_links.json"; do
        [ -f "$file" ] || continue
        jq -r '.. | objects | (.share_link? // .link? // empty) | select(type == "string" and length > 0)' "$file" >> "$work/links.txt" || return 1
    done
    sort -u "$work/links.txt" -o "$work/links.txt" || return 1
    [ -s "$work/links.txt" ] || { _warn "没有可导出的分享链接。"; return 1; }
    base64 < "$work/links.txt" | tr -d '\n' > "$work/base64.txt" || return 1
    [ ! -s "$CLASH_YAML_FILE" ] || cp "$CLASH_YAML_FILE" "$work/clash.yaml" || return 1
    mkdir -p "$root" || return 1
    for file in "$work"/*; do chmod 600 "$file" && mv -f "$file" "$root/${file##*/}" || return 1; done
    _success "已导出 links.txt、base64.txt、clash.yaml 到 $root。XHTTP/HTTPUpgrade 使用链接订阅。"
)

_subscription_menu() {
    local choice name url id node outbound index state="${SINGBOX_DIR}/subscriptions.json"
    while true; do
        echo "1) 添加订阅 URL   2) 更新订阅   3) 删除订阅"
        echo "4) 从订阅节点创建中转   5) 导出本机订阅文件   6) 本机订阅 HTTP 服务"
        echo "7) 使用订阅中的 SOCKS5 作为统一出口   0) 返回"
        read -r -p "请选择: " choice
        case "$choice" in
            1)
                read -r -p "订阅名称: " name
                read -r -s -p "订阅 URL: " url; echo
                id=$(openssl rand -hex 8)
                _with_state_lock _subscription_fetch "$id" "${name:-订阅-$id}" "$url"
                ;;
            2|3|4|7)
                _subscription_select || continue
                id="$SELECTED_SUBSCRIPTION_ID"
                case "$choice" in
                    2)
                        name=$(jq -r --arg id "$id" '.[$id].name' "$state"); url=$(jq -r --arg id "$id" '.[$id].url' "$state")
                        _with_state_lock _subscription_fetch "$id" "$name" "$url" ;;
                    3) _atomic_modify_json "$state" 'del(.[$id])' --arg id "$id" ;;
                    4|7)
                        jq -r --arg id "$id" '.[$id].nodes | to_entries[] | "\(.key+1)) \(.value.name) [\(.value.outbound.type)]"' "$state"
                        read -r -p "节点编号: " index
                        [[ "$index" =~ ^[1-9][0-9]*$ ]] && [ "$index" -le "$(jq --arg id "$id" '.[$id].nodes|length' "$state")" ] || continue
                        outbound=$(jq -c --arg id "$id" --argjson i "$((index - 1))" '.[$id].nodes[$i].outbound' "$state")
                        if [ "$choice" = 7 ]; then
                            [ "$(jq -r .type <<< "$outbound")" = socks ] || { _error "请选择 SOCKS5 节点。"; continue; }
                            outbound=$(jq '.tag="managed-socks-egress"' <<< "$outbound")
                            _feature_transaction _apply_socks_egress "$outbound"
                        else _advanced_features subscription-node 3<<< "$outbound"; fi
                        ;;
                esac
                ;;
            5) _with_state_lock _subscription_export_locked ;;
            6) _subscription_http_menu ;;
            0) return 0 ;;
            *) _error "无效选项。" ;;
        esac
    done
}

_subscription_http_write_server() {
    # 实时读取元数据，避免节点修改、删除或临时隧道改域名后继续分发旧凭据。
    local tmp
    tmp=$(mktemp "${SINGBOX_DIR}/.subscription-server.XXXXXX") || return 1
    cat > "$tmp" <<'PY'
import base64
import fcntl
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

root = Path(sys.argv[1])
settings = json.loads((root / 'subscription-http.json').read_text())

class Handler(BaseHTTPRequestHandler):
    timeout = 5

    def log_message(self, *_):
        pass  # URL 中有订阅凭据，不记录请求路径。

    def do_GET(self):
        parts = self.path.split('?', 1)[0].split('/')
        if len(parts) != 3 or not hmac.compare_digest(parts[1], settings['token']) or parts[2] not in ('links', 'base64', 'clash'):
            self.send_error(404)
            return
        try:
            with open(root / '.singboxlite.lock', 'a') as lock:
                deadline = time.monotonic() + 3
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            raise TimeoutError()
                        time.sleep(0.05)
                if parts[2] == 'clash':
                    data = (root / 'clash.yaml').read_bytes()
                else:
                    links = set()
                    def collect(value):
                        if isinstance(value, dict):
                            link = value.get('share_link', value.get('link'))
                            if isinstance(link, str) and link:
                                links.add(link)
                            for item in value.values():
                                collect(item)
                        elif isinstance(value, list):
                            for item in value:
                                collect(item)
                    for path in (root / 'metadata.json', root / 'argo_metadata.json', root / 'relay_links.json', Path('/usr/local/etc/xray/metadata.json')):
                        if path.is_file():
                            collect(json.loads(path.read_text()))
                    data = ('\n'.join(sorted(links)) + '\n').encode() if links else b''
                    if parts[2] == 'base64':
                        data = base64.b64encode(data)
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (OSError, ValueError, TimeoutError):
            self.send_error(503)

server = HTTPServer((settings['listen'], settings['port']), Handler)
server.timeout = 5
server.serve_forever()
PY
    chmod 600 "$tmp" && mv -f "$tmp" "${SINGBOX_DIR}/subscription_server.py"
}

_subscription_http_start() {
    local settings="${SINGBOX_DIR}/subscription-http.json" pid="${RUNTIME_DIR}/subscription.pid" python_bin
    [ -f "$settings" ] && [ "$(jq -r '.enabled' "$settings")" = true ] || return 0
    python_bin=$(command -v python3) || { _error "缺少 python3。"; return 1; }
    mkdir -p "$RUNTIME_DIR" || return 1
    chmod 700 "$RUNTIME_DIR"
    case "$INIT_SYSTEM" in
        systemd)
            cat > /etc/systemd/system/singbox-subscription.service <<EOF
[Unit]
Description=singbox-lite subscription
After=network.target
[Service]
ExecStart=$python_bin ${SINGBOX_DIR}/subscription_server.py ${SINGBOX_DIR}
Restart=on-failure
RestartSec=3
UMask=0077
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload && systemctl enable --now singbox-subscription 8>&- 9>&- || return 1
            systemctl is-active --quiet singbox-subscription
            ;;
        openrc)
            cat > /etc/init.d/singbox-subscription <<EOF
#!/sbin/openrc-run
name="singbox-subscription"
command="$python_bin"
command_args="${SINGBOX_DIR}/subscription_server.py ${SINGBOX_DIR}"
supervisor="supervise-daemon"
pidfile="$pid"
respawn_delay=3
depend() { need net; }
EOF
            chmod 755 /etc/init.d/singbox-subscription
            rc-update add singbox-subscription default && rc-service singbox-subscription start 8>&- 9>&-
            ;;
        *)
            if _is_pid_file_running_cmd "$pid" subscription_server.py; then return 0; fi
            nohup "$python_bin" "${SINGBOX_DIR}/subscription_server.py" "$SINGBOX_DIR" \
                > /dev/null 2>&1 8>&- 9>&- 219>&- &
            printf '%s\n' "$!" > "$pid"
            sleep 1
            _is_pid_file_running_cmd "$pid" subscription_server.py
            ;;
    esac
}

_subscription_http_stop() {
    local pid="${RUNTIME_DIR}/subscription.pid" cron
    case "$INIT_SYSTEM" in
        systemd) systemctl disable --now singbox-subscription >/dev/null 2>&1 || true ;;
        openrc) rc-service singbox-subscription stop >/dev/null 2>&1 || true; rc-update del singbox-subscription default >/dev/null 2>&1 || true ;;
    esac
    if _is_pid_file_running_cmd "$pid" subscription_server.py; then
        local old_pid attempt
        old_pid=$(cat "$pid")
        kill "$old_pid" || return 1
        for ((attempt=0; attempt<30; attempt++)); do
            _is_pid_running_cmd "$old_pid" subscription_server.py || break
            sleep 0.1
        done
        _is_pid_running_cmd "$old_pid" subscription_server.py && { _error "旧订阅进程尚未退出。"; return 1; }
    fi
    rm -f "$pid" /etc/systemd/system/singbox-subscription.service /etc/init.d/singbox-subscription
    if command -v crontab >/dev/null 2>&1; then
        cron=$(crontab -l 2>/dev/null | grep -v '# subscription-watchdog' || true)
        printf '%s\n' "$cron" | crontab - || return 1
    fi
    [ "$INIT_SYSTEM" != systemd ] || systemctl daemon-reload
    if [ -f "${SINGBOX_DIR}/subscription-http.json" ]; then
        _atomic_modify_json "${SINGBOX_DIR}/subscription-http.json" '.enabled=false' || return 1
    fi
}

_subscription_http_configure() (
    local listen="$1" port="$2" base="$3" token tmp settings="${SINGBOX_DIR}/subscription-http.json"
    local backup committed=0 old_enabled=false
    backup=$(mktemp -d "${SINGBOX_DIR}/.http-config.XXXXXX") || return 1
    if [ -f "$settings" ]; then
        cp -p "$settings" "$backup/settings" || return 1
        old_enabled=$(jq -r '.enabled // false' "$settings")
    fi
    if [ -f "${SINGBOX_DIR}/subscription_server.py" ]; then cp -p "${SINGBOX_DIR}/subscription_server.py" "$backup/server" || return 1; fi
    crontab -l > "$backup/cron" 2>/dev/null || true
    trap 'rc=$?; trap - EXIT INT TERM; if [ "$committed" != 1 ]; then
        _subscription_http_stop >/dev/null 2>&1 || true
        if [ -f "$backup/settings" ]; then cp -p "$backup/settings" "$settings"; else rm -f "$settings"; fi
        if [ -f "$backup/server" ]; then cp -p "$backup/server" "${SINGBOX_DIR}/subscription_server.py"; fi
        if [ "$old_enabled" = true ]; then
            _subscription_http_start >/dev/null 2>&1 || _error "恢复旧订阅服务失败，请检查监听端口。"
            [ "$INIT_SYSTEM" != direct ] || crontab "$backup/cron"
        fi
        [ "$rc" != 0 ] || rc=1
    fi; rm -rf -- "$backup"; exit "$rc"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _subscription_http_stop || return 1
    _check_port_conflict "$port" tcp && return 1
    token=$(openssl rand -hex 24) || return 1
    tmp=$(mktemp "${settings}.tmp.XXXXXX") || return 1
    jq -n --arg l "$listen" --argjson p "$port" --arg b "$base" --arg t "$token" \
        '{enabled:true,listen:$l,port:$p,base:$b,token:$t}' > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$settings" || { rm -f "$tmp"; return 1; }
    _subscription_http_write_server && _subscription_http_start || { _subscription_http_stop; _error "订阅服务启动失败。"; return 1; }
    if [ "$INIT_SYSTEM" = direct ]; then
        _ensure_argo_cron || { _subscription_http_stop; return 1; }
        local cron
        cron=$(crontab -l 2>/dev/null | grep -v '# subscription-watchdog' || true)
        { printf '%s\n' "$cron"; printf '* * * * * /bin/bash "%s" subscription-keepalive >/dev/null 2>&1 # subscription-watchdog\n' "$SELF_SCRIPT_PATH"; } | crontab - || { _subscription_http_stop; return 1; }
    fi
    committed=1
)

_subscription_http_menu() {
    local choice listen port base token tmp settings="${SINGBOX_DIR}/subscription-http.json"
    echo "1) 开启/重新配置   2) 查看订阅 URL   3) 停止并禁用   0) 返回"
    read -r -p "请选择: " choice
    case "$choice" in
        1)
            command -v python3 >/dev/null 2>&1 || _pkg_install python3 || return 1
            read -r -p "监听 IP (默认 127.0.0.1，可通过 HTTPS 反向代理发布；公网填 0.0.0.0): " listen
            listen=${listen:-127.0.0.1}
            case "$listen" in 127.0.0.1|0.0.0.0) ;; *) _error "仅支持 127.0.0.1 或 0.0.0.0。"; return 1 ;; esac
            read -r -p "HTTP 端口 (默认 18080): " port; port=${port:-18080}
            [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || return 1
            read -r -p "客户端访问基址 (例如 https://sub.example.com，留空使用本机 HTTP 地址): " base
            if [ -n "$base" ]; then
                [[ "$base" == https://* ]] && _valid_domain "${base#https://}" || { _error "基址需为 https://域名（无路径）。"; return 1; }
            else
                base="http://127.0.0.1:$port"
                if [ "$listen" = 0.0.0.0 ]; then
                    local ip; ip=$(_get_public_ip); [[ "$ip" != *:* ]] || ip="[$ip]"
                    base="http://${ip}:$port"
                fi
            fi
            _with_state_lock _subscription_http_configure "$listen" "$port" "$base" || return 1
            _success "订阅服务已启动；HTTPS 域名需反向代理到 http://127.0.0.1:$port。"
            ;;
        2) ;;
        3) _with_state_lock _subscription_http_stop; return ;;
        *) return ;;
    esac
    if [ -f "$settings" ]; then
        jq -r 'if .enabled then "Base64: \(.base)/\(.token)/base64\n链接列表: \(.base)/\(.token)/links\nClash: \(.base)/\(.token)/clash" else "订阅服务未启用" end' "$settings"
    fi
}
