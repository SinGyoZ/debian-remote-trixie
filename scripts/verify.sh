#!/usr/bin/env bash
# ============================================================
# debian-remote-trixie — 一键验证脚本
# 在宿主机（Linux / WSL）上运行：bash scripts/verify.sh
#
# 前提：secrets/*.txt 已配置（至少 root_passwd）
# 本脚本会：
#   Phase A：临时注入用例容器 —— 验证密码注入防护、密码正确性
#   Phase B：正式 compose 容器 —— PID1/systemd/健康/自愈/优雅停止/持久化/中文
# Phase A 结束后自动清理，不影响 Phase B 的正式部署。
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
FAILED_ITEMS=()

ok()  { echo "  [通过] $1"; PASS=$((PASS + 1)); }
bad() { echo "  [失败] $1"; FAIL=$((FAIL + 1)); FAILED_ITEMS+=("$1"); }
info(){ echo "  ---- $1"; }
summary() {
    echo ""
    echo "============================================================"
    echo "验证完成：通过 $PASS 项，失败 $FAIL 项"
    if [ "$FAIL" -gt 0 ]; then
        echo "失败项："
        for item in "${FAILED_ITEMS[@]}"; do echo "  - $item"; done
        echo "容器保持运行状态，可手动排查：docker exec -it trixie-desktop bash"
        exit 1
    else
        echo "全部通过。剩余手动项：用 RDP 客户端连接并确认中文显示与 fcitx5 输入。"
        exit 0
    fi
}

# 前置检查：secrets
if [ ! -s secrets/root_passwd.txt ]; then
    echo "错误：secrets/root_passwd.txt 不存在或为空"
    echo "请先：cp secrets/root_passwd.txt.example secrets/root_passwd.txt 并写入密码"
    exit 1
fi

echo "============================================================"
echo "Phase A：安全验证（临时容器，用完即删）"
echo "============================================================"

VERIFY_CONTAINER=trixie-verify
IMG=debian-remote-trixie:v0.1.1
INJECT_PW='P@ss;w0rd`$(touch /tmp/pwned)#'
# 清理历史残留
docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true

info "构建镜像（如本地已有则复用缓存；APT_MIRROR 环境变量可传入构建加速源）"
docker build ${APT_MIRROR:+--build-arg APT_MIRROR="$APT_MIRROR"} \
    -t "$IMG" . >/dev/null 2>&1 || {
    bad "镜像构建失败，请手动执行 docker build 查看日志"; summary; exit 1; }

info "启动注入用例容器（密码含 shell 元字符，验证不发生命令注入）"
docker run -d -t --name "$VERIFY_CONTAINER" \
    --stop-signal SIGRTMIN+3 \
    --security-opt seccomp=unconfined \
    --cap-add SYS_ADMIN \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock --tmpfs /sys/fs/cgroup:rw \
    -e ROOT_PASSWD="$INJECT_PW" \
    "$IMG" >/dev/null

# 等待 container-init 执行 + xrdp 就绪
sleep 12

# A1：容器仍在运行（未触发拒绝启动 —— 提供了密码）
if [ "$(docker inspect -f '{{.State.Running}}' "$VERIFY_CONTAINER" 2>/dev/null)" = "true" ]; then
    ok "A1 注入用例容器正常运行（配置引擎接受特殊字符密码）"
else
    bad "A1 注入用例容器异常退出"
    docker logs "$VERIFY_CONTAINER" 2>/dev/null | tail -n 20
fi

# A2：注入的命令没有被执行（/tmp/pwned 不存在）
if docker exec "$VERIFY_CONTAINER" test ! -e /tmp/pwned; then
    ok "A2 命令注入防护：密码中的 \$(touch ...) 未被执行"
else
    bad "A2 存在命令注入：/tmp/pwned 被创建！"
fi

# A3：密码被正确设置（用 crypt 校验 shadow hash）
A3_RESULT=$(python3 - "$INJECT_PW" <<'PYEOF' 2>/dev/null
import subprocess, sys
pw = sys.argv[1]
shadow = subprocess.run(
    ["docker", "exec", "trixie-verify", "cat", "/etc/shadow"],
    capture_output=True, text=True).stdout
for line in shadow.splitlines():
    if line.startswith("root:"):
        hash_ = line.split(":")[1]
        if hash_.startswith(("$y$", "$6$", "$5$")):
            try:
                import crypt
                if crypt.crypt(pw, hash_) == hash_:
                    print("OK")
                else:
                    print("MISMATCH")
            except Exception:
                print("NO-CRYPT-MODULE")  # 宿主 python 无 crypt 模块，降级为结构校验
                sys.exit(0)
        elif hash_ in ("*", "!"):
            print("LOCKED")
        else:
            print("UNEXPECTED-HASH")
        sys.exit(0)
print("NO-ROOT-LINE")
PYEOF
)
case "$A3_RESULT" in
    OK)           ok "A3 密码经 crypt 校验一致（含特殊字符密码设置成功）" ;;
    MISMATCH)     bad "A3 密码校验不一致" ;;
    LOCKED)       bad "A3 root 被锁定（密码未设置成功）" ;;
    NO-CRYPT-MODULE) echo "  [跳过] A3 宿主 python3 缺 crypt 模块，降级为 hash 结构检查"
                   if docker exec "$VERIFY_CONTAINER" sh -c "cut -d: -f2 /etc/shadow | head -n1 | grep -qE '^\\\$y\\\$'"; then
                       ok "A3-降级 root 密码 hash 已写入（yescrypt）"
                   else
                       bad "A3-降级 root 密码 hash 未写入"
                   fi ;;
    *)             bad "A3 密码校验异常：$A3_RESULT" ;;
esac

# A4：拒绝启动规则 —— 无密码容器必须关机退出
# 注意：容器删除走 SIGRTMIN+3 优雅关机（systemd 可能需要数秒），
# rm 需要重试兜底，否则同名 run 会静默失败、误查 A1 旧容器
docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
sleep 3
docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true
if docker ps -a --format '{{.Names}}' | grep -q "^${VERIFY_CONTAINER}$"; then
    bad "A4 旧容器清理失败，跳过本项（请手动 docker rm -f $VERIFY_CONTAINER）"
else
    info "验证 D7：无密码时拒绝启动（轮询等待退出，最多 45 秒）"
    if ! docker run -d -t --name "$VERIFY_CONTAINER" \
        --security-opt seccomp=unconfined --cap-add SYS_ADMIN \
        --tmpfs /tmp --tmpfs /run --tmpfs /run/lock --tmpfs /sys/fs/cgroup:rw \
        "$IMG" >/dev/null 2>&1; then
        bad "A4 测试容器启动失败（docker run 错误）"
    else
        A4_ID="$(docker inspect -f '{{.Id}}' "$VERIFY_CONTAINER" 2>/dev/null | cut -c1-12)"
        A4_STARTED="$(docker inspect -f '{{.StartedAt}}' "$VERIFY_CONTAINER" 2>/dev/null)"
        # 轮询等待退出（systemd boot 时长随负载波动，不依赖固定 sleep）
        A4_WAIT=0
        while [ "$(docker inspect -f '{{.State.Running}}' "$VERIFY_CONTAINER" 2>/dev/null)" = "true" ]; do
            sleep 3
            A4_WAIT=$((A4_WAIT + 3))
            if [ "$A4_WAIT" -ge 45 ]; then break; fi
        done
        # 再等 3 秒，确保关机输出完全落盘
        sleep 3
        A4_EXITCODE="$(docker inspect -f '{{.State.ExitCode}}' "$VERIFY_CONTAINER" 2>/dev/null)"
        A4_STATUS="$(docker inspect -f '{{.State.Status}}' "$VERIFY_CONTAINER" 2>/dev/null)"
        echo "  ---- A4 取证：id=$A4_ID started=$A4_STARTED waited=${A4_WAIT}s status=$A4_STATUS exit=$A4_EXITCODE"
        if [ "$A4_STATUS" = "exited" ]; then
            # -a：systemd 控制台输出含 ANSI 转义，防止 grep 误判二进制
            docker logs "$VERIFY_CONTAINER" > /tmp/a4-debug.log 2>&1
            if grep -qa "未提供任何密码" /tmp/a4-debug.log; then
                ok "A4 无密码容器被拒绝启动并给出明确日志（exit $A4_EXITCODE，日志已存 /tmp/a4-debug.log）"
            else
                bad "A4 容器退出了但缺少拒绝启动日志（日志 $(wc -c < /tmp/a4-debug.log) 字节，已存 /tmp/a4-debug.log）"
                grep -a 'container-init' /tmp/a4-debug.log | head -4
            fi
        else
            bad "A4 无密码容器未按预期退出（状态：$A4_STATUS）——弱口令防护失效"
        fi
    fi
fi
docker rm -f "$VERIFY_CONTAINER" >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo "Phase B：正式部署验证（docker compose）"
echo "============================================================"

info "启动正式容器（镜像已由 Phase A 构建，直接使用）"
docker compose down >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1 || {
    bad "docker compose up 失败"; summary; exit 1; }

info "等待 systemd 初始化与 xrdp 就绪（最多 90 秒）"
WAITED=0
until docker exec trixie-desktop systemctl is-active xrdp.service >/dev/null 2>&1; do
    sleep 5; WAITED=$((WAITED + 5))
    if [ "$WAITED" -ge 90 ]; then break; fi
done

# B1：PID 1 为 systemd
PID1="$(docker exec trixie-desktop sh -c 'readlink /proc/1/exe' 2>/dev/null)"
if echo "$PID1" | grep -q systemd; then
    ok "B1 PID 1 = systemd（$PID1）"
else
    bad "B1 PID 1 不是 systemd：$PID1"
fi

# B2：systemd 整体状态（degraded 可接受：被 mask/无关 unit 失败不阻断）
RUN_STATE="$(docker exec trixie-desktop systemctl is-system-running 2>/dev/null || true)"
if [ "$RUN_STATE" = "running" ] || [ "$RUN_STATE" = "degraded" ]; then
    ok "B2 systemd 状态：$RUN_STATE"
else
    bad "B2 systemd 状态异常：$RUN_STATE"
    docker exec trixie-desktop systemctl --failed --no-pager 2>/dev/null
fi

# B3：xrdp active
if [ "$(docker exec trixie-desktop systemctl is-active xrdp.service 2>/dev/null)" = "active" ]; then
    ok "B3 xrdp.service active"
else
    bad "B3 xrdp.service 未运行"
fi

# B4：3389 端口在容器内监听
if docker exec trixie-desktop bash -c 'exec 3<>/dev/tcp/127.0.0.1/3389' 2>/dev/null; then
    ok "B4 容器内 3389 端口监听正常"
else
    bad "B4 容器内 3389 端口未监听"
fi

# B5：宿主侧端口可达（compose 映射）
if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/3389' 2>/dev/null; then
    ok "B5 宿主侧 127.0.0.1:3389 可达"
else
    bad "B5 宿主侧 3389 不可达（端口映射问题）"
fi

# B6：container-init 完成态
if [ "$(docker exec trixie-desktop systemctl is-active container-init.service 2>/dev/null)" = "active" ]; then
    ok "B6 container-init.service 已执行（oneshot RemainAfterExit）"
else
    bad "B6 container-init.service 异常"
    docker exec trixie-desktop journalctl -u container-init.service --no-pager 2>/dev/null | tail -n 10
fi

# B7：密码文件不残留
if docker exec trixie-desktop test ! -e /run/container-secrets/root_passwd \
   && docker exec trixie-desktop test ! -e /run/container-init.env; then
    ok "B7 密码/env 临时文件已清理（不残留）"
else
    bad "B7 密码临时文件残留"
fi

# B8：xrdp 崩溃自愈
info "kill xrdp 验证自动拉起"
docker exec trixie-desktop sh -c 'pkill -9 -x xrdp' 2>/dev/null
sleep 8
if [ "$(docker exec trixie-desktop systemctl is-active xrdp.service 2>/dev/null)" = "active" ]; then
    ok "B8 xrdp 被 kill 后 systemd 自动拉起"
else
    bad "B8 xrdp 未自动恢复"
fi

# B9：/home 卷持久化
docker exec trixie-desktop sh -c 'echo persist-test > /home/.verify-mark' 2>/dev/null
info "重建容器（compose down → up）验证数据持久化"
docker compose down >/dev/null 2>&1
docker compose up -d >/dev/null 2>&1
WAITED=0
until docker exec trixie-desktop systemctl is-active xrdp.service >/dev/null 2>&1; do
    sleep 5; WAITED=$((WAITED + 5)); [ "$WAITED" -ge 90 ] && break
done
if docker exec trixie-desktop sh -c 'test "$(cat /home/.verify-mark)" = persist-test' 2>/dev/null; then
    ok "B9 /home 卷持久化：容器重建后数据保留"
    docker exec trixie-desktop rm -f /home/.verify-mark
else
    bad "B9 /home 数据在容器重建后丢失"
fi

# B10：优雅停止计时（SIGRTMIN+3 → systemd 关机序列）
info "验证优雅停止"
T0=$(date +%s)
docker compose stop -t 30 >/dev/null 2>&1
T1=$(date +%s)
ELAPSED=$((T1 - T0))
if [ "$ELAPSED" -le 20 ]; then
    ok "B10 优雅停止耗时 ${ELAPSED}s（≤20s，systemd 关机序列生效）"
else
    bad "B10 停止耗时 ${ELAPSED}s，疑似未走 systemd 关机流程"
fi

# B11：健康检查转 healthy
docker compose up -d >/dev/null 2>&1
info "等待 HEALTHCHECK 转绿（start-period 60s）"
WAITED=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' trixie-desktop 2>/dev/null)" = "healthy" ]; do
    sleep 10; WAITED=$((WAITED + 10)); [ "$WAITED" -ge 150 ] && break
done
if [ "$(docker inspect -f '{{.State.Health.Status}}' trixie-desktop 2>/dev/null)" = "healthy" ]; then
    ok "B11 HEALTHCHECK = healthy"
else
    bad "B11 健康检查未转绿"
    docker inspect -f '{{json .State.Health}}' trixie-desktop 2>/dev/null | head -c 500; echo ""
fi

# B12：中文环境（自动化部分；中文输入需手动 RDP 确认，见 README）
if docker exec trixie-desktop locale 2>/dev/null | grep -q 'zh_CN.UTF-8'; then
    ok "B12-1 locale 默认 zh_CN.UTF-8"
else
    bad "B12-1 locale 异常"
fi
if docker exec trixie-desktop fc-list 2>/dev/null | grep -qi 'noto sans cjk\|wenquanyi'; then
    ok "B12-2 CJK 字体已安装（Noto CJK / 文泉驿）"
else
    bad "B12-2 CJK 字体缺失"
fi
if docker exec trixie-desktop test -e /etc/xdg/autostart/fcitx5-autostart.desktop; then
    ok "B12-3 fcitx5 随会话自启动（/etc/xdg/autostart/fcitx5-autostart.desktop）"
else
    bad "B12-3 fcitx5 自启动条目缺失"
fi
if docker exec trixie-desktop sh -c '. /etc/profile.d/im-config.sh && test "$GTK_IM_MODULE" = fcitx'; then
    ok "B12-4 输入法环境变量就绪（GTK_IM_MODULE=fcitx）"
else
    bad "B12-4 输入法环境变量未生效"
fi

echo ""
echo "============================================================"
summary
