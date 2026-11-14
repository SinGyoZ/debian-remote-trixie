# ============================================================
# debian-remote-trixie
# Debian 13 (Trixie) + systemd + XRDP 远程桌面容器
#
# 基于 Riyangarma33/Debian-Remote-Docker 重构，感谢原作者：
# https://github.com/Riyangarma33/Debian-Remote-Docker
#
# 构建：docker build -t debian-remote-trixie:v0.1.0 .
# 运行：见 docker-compose.yml（必须使用 compose 中的
#       cgroup / seccomp / STOPSIGNAL 参数，否则 systemd 无法作为 PID 1 运行）
# ============================================================
FROM debian:trixie-slim

# 构建加速（可选）：仅影响构建期 apt 源，镜像成品内始终恢复官方源。
# 用法：docker build --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn -t ...
ARG APT_MIRROR=""

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=zh_CN.UTF-8

# 构建期源替换（幂等，支持 deb822 格式）
RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|deb.debian.org|$APT_MIRROR|g" \
            /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list 2>/dev/null || true; \
    fi

# ---- 1. locale：默认中文环境，en_US 兜底 ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        apt-utils ca-certificates locales && \
    printf 'zh_CN.UTF-8 UTF-8\nen_US.UTF-8 UTF-8\n' >> /etc/locale.gen && \
    locale-gen && \
    update-locale LANG=zh_CN.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# ---- 2. systemd 作为 PID 1 ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv sudo dbus && \
    rm -rf /var/lib/apt/lists/*

# 容器环境收敛：mask（ln -s /dev/null）无关服务，可审计、可逆。
# 相比原实验版 rm -f 硬删，mask 不破坏包完整性。
RUN for u in systemd-remount-fs.service \
             systemd-machine-id-commit.service \
             dev-hugepages.mount dev-mqueue.mount \
             getty.target console-getty.service \
             apt-daily.service apt-daily.timer \
             apt-daily-upgrade.service apt-daily-upgrade.timer; do \
        ln -sf /dev/null "/etc/systemd/system/$u"; \
    done && \
    ln -sf /lib/systemd/system/multi-user.target /etc/systemd/system/default.target && \
    : > /etc/machine-id && \
    # 服务日志转发 console → docker logs 直接可读（systemd 容器标准实践）
    mkdir -p /etc/systemd/journald.conf.d && \
    printf '[Journal]\nForwardToConsole=yes\n' \
        > /etc/systemd/journald.conf.d/container-forward.conf

# ---- 3. XFCE 桌面 + xrdp + 中文支持 ----
# 说明：
#   xorgxrdp  : xrdp 的 Xorg 后端，缺它必黑屏（--no-install-recommends 会漏）
#   fcitx5 系列 : 中文输入法；字体用 Noto CJK + 文泉驿微米黑
#   注：音频重定向（pulseaudio-module-xrdp）是 Ubuntu 独有包，
#       Debian 未收录；待上游收录后再引入，v0.1.0 不含音频
RUN apt-get update && apt-get install -y --no-install-recommends \
        xfce4 xfce4-terminal xfce4-datetime-plugin dbus-x11 \
        xrdp xorgxrdp \
        fonts-noto-cjk fonts-wqy-microhei \
        fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 && \
    usermod -aG ssl-cert xrdp && \
    rm -rf /var/lib/apt/lists/*

# ---- 4. 配置引擎与运行时（结构化 rootfs） ----
COPY rootfs/ /

RUN chmod 755 /usr/local/bin/docker-entrypoint /usr/local/sbin/container-init && \
    chmod 644 /etc/systemd/system/container-init.service \
              /etc/systemd/system/xrdp.service.d/restart.conf \
              /etc/profile.d/im-config.sh \
              /etc/xdg/autostart/fcitx5-autostart.desktop && \
    mkdir -p /etc/systemd/system/multi-user.target.wants && \
    ln -sf /etc/systemd/system/container-init.service \
           /etc/systemd/system/multi-user.target.wants/container-init.service && \
    ln -sf /lib/systemd/system/xrdp.service \
           /etc/systemd/system/multi-user.target.wants/xrdp.service && \
    # 恢复官方 apt 源（构建期镜像加速参数不残留进成品镜像）
    if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|$APT_MIRROR|deb.debian.org|g" \
            /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list 2>/dev/null || true; \
    fi

VOLUME /home
EXPOSE 3389

# docker stop → systemd 完整关机序列（数据优雅落盘）
STOPSIGNAL SIGRTMIN+3

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD systemctl is-active xrdp.service >/dev/null 2>&1 \
        && bash -c 'exec 3<>/dev/tcp/127.0.0.1/3389' \
        || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint"]
CMD ["/sbin/init"]
