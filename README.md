# debian-remote-trixie

Debian 13 (Trixie) + **systemd** + XRDP 远程桌面容器。一个容器，就是一台干净的 Linux 小主机：标准 RDP 协议接入，Windows 自带的"远程桌面连接"即可直连，桌面数据独立持久化。

基于 [Riyangarma33/Debian-Remote-Docker](https://github.com/Riyangarma33/Debian-Remote-Docker) 重构，感谢原作者。

## 项目特点

- **Debian 13 (Trixie)**：当前 Debian stable，长期支持
- **systemd 作为 PID 1**：容器内 `systemctl` 完整可用；xrdp 崩溃自动拉起；`docker stop` 走完整关机序列，数据优雅落盘
- **声明式配置引擎**：密码/用户/时区以 compose 声明为准，改完重启即生效——没有"首次配置"概念，容器重建不丢用户数据
- **安全基线**：
  - 无密码 = 拒绝启动，绝不回退默认弱口令
  - 密码优先走 docker secrets（`docker inspect` 不可见），全程不经 shell 拼接，无命令注入面
  - 密码临时文件 0600 且用后即删，不进任何日志
  - 无任何第三方 apt 源
- **开箱中文**：zh_CN.UTF-8 locale、Noto CJK + 文泉驿字体、fcitx5 拼音输入法随会话自启动
- **可观测**：服务日志经 journald 转发 console，`docker logs` 直接可读；内置 HEALTHCHECK
- **单镜像单 tag**：每个 git tag 对应一个镜像版本（`v0.1.1`），版本可追溯

> 已知限制：当前版本不含音频重定向——Debian 官方源暂无 `pulseaudio-module-xrdp`（Ubuntu 独有包），待上游收录后引入。

## 快速开始

> **宿主要求**：KVM / 独立服务器等完整虚拟化环境——OpenVZ、LXC 等共享内核型
> VPS 无法运行任何 systemd 容器（平台硬限制，`systemd-detect-virt` 输出 `kvm`
> 即满足）；Docker 20.10+；cgroup v2（Debian 11+ / Ubuntu 20.04+ 默认即满足）。

### 1. 配置密码（必做）

```bash
cp secrets/root_passwd.txt.example secrets/root_passwd.txt
cp secrets/new_user_passwd.txt.example secrets/new_user_passwd.txt
# 然后编辑这两个文件，各写入一行密码（不要加引号）：
echo '你的强密码'   > secrets/root_passwd.txt
echo '用户密码'     > secrets/new_user_passwd.txt
```

> `secrets/*.txt` 已被 `.gitignore` 排除，不会被提交。
> 未配置任何密码时容器会拒绝启动——这是故意的。

### 2. 配置用户与环境

```bash
cp .env.example .env
# 编辑 .env：设置 NEW_USER（桌面用户名）、TZ 等
```

### 3. 启动

```bash
docker compose up -d
```

首次启动从 Docker Hub 拉取官方镜像；本地改代码构建见「构建」章节。

### 4. 连接远程桌面

Windows：打开「远程桌面连接」（mstsc），输入 `<主机IP>:3389`，用 `.env` 里的 `NEW_USER` + `secrets/new_user_passwd.txt` 里的密码登录。

中文输入：登录后按 `Ctrl+Space` 唤出 fcitx5 拼音。

### 5. 验证部署（可选）

```bash
bash scripts/verify.sh
```

15 项自动化检查：PID 1、systemd 状态、xrdp 自愈、注入防护、拒绝启动规则、数据持久化、优雅停止、健康检查、中文环境等。

## 配置项说明

| 配置 | 位置 | 说明 |
| --- | --- | --- |
| root 密码 | `secrets/root_passwd.txt` | 每次启动按此文件同步；留空则不动已有密码 |
| 用户密码 | `secrets/new_user_passwd.txt` | 同上；配合 `NEW_USER` 使用 |
| `TZ` | `.env` | 时区，如 `Asia/Shanghai` |
| `NEW_USER` | `.env` | 桌面用户名（小写字母开头，可用数字/`_`/`-`） |
| `NEW_USER_SUDO` | `.env` | `yes` = 加入 sudo 组 |
| `DIS_ROOT` | `.env` | `yes` = 锁定 root（必须同时设置 `NEW_USER`） |
| `GUEST_ACC` | `.env` | `yes` = 启用弱口令 guest 账户（不建议） |

也支持环境变量传密码（`ROOT_PASSWD` / `NEW_USER_PASSWD`），但推荐 secrets 文件方式。

## 网络与安全

compose 默认把 3389 监听在 `0.0.0.0`（所有网卡）。**公网部署时请注意：**

- RDP 端口会被持续扫描爆破，务必使用强密码（建议 16 位以上随机串）
- 建议叠加防护，任选其一：
  - 防火墙限制来源 IP：`ufw allow from <你的IP> to any port 3389`
  - 或改绑本机回环 + SSH 隧道：compose 里 `"3389:3389"` 改 `"127.0.0.1:3389:3389"`，连接时 `ssh -L 3389:127.0.0.1:3389 user@host`
- xrdp 使用自签证书建立 TLS，客户端首次连接的证书告警属正常现象；可挂载正式证书替换 `/etc/xrdp/cert.pem` 与 `/etc/xrdp/key.pem`

## 为什么需要那些奇怪的运行参数

systemd 想在容器里当好 PID 1，需要宿主放开一些权限，这些已全部封装在 compose 中：

| 参数 | 作用 |
| --- | --- |
| `stop_signal: SIGRTMIN+3` | `docker stop` 触发 systemd 关机流程（等同 `systemctl poweroff`） |
| `tty: true` | 让 `/dev/console` 落到 pty，服务日志才能进入 `docker logs`（含首配错误信息） |
| `security_opt: seccomp=unconfined` | 解除默认 seccomp 对 mount/namespace 调用的限制 |
| `security_opt: apparmor=unconfined` | Debian/Ubuntu 宿主的 AppArmor 默认配置拒绝容器内挂载 cgroup，必须解除；无 AppArmor 的环境为空操作 |
| `cap_add: SYS_ADMIN` | systemd 管理 cgroup 与挂载所需的最小特权 |
| `tmpfs: /run /tmp /run/lock` | systemd 运行时目录（内存盘，重启即净） |
| `tmpfs: /sys/fs/cgroup:rw` | cgroup v2 挂载点。cgroup v1 老宿主：删掉本行，改在 volumes 里 rw 绑定（见 compose 注释） |

任何 systemd 容器（不只本镜像）都需要这套参数，照抄 compose 即可。

## 常见问题

**容器反复重启，日志报 `Failed to mount cgroup ... Permission denied` / `Failed to mount cgroup v1 hierarchy`**

systemd 拿不到 cgroup 挂载权限，按序排查：

1. **没用 compose 启动**：裸 `docker run` 缺 cap/seccomp/tmpfs 那组参数，照抄仓库的 compose 即可
2. **宿主启用了 AppArmor**（Debian/Ubuntu 标准安装默认如此）：必须带 `apparmor=unconfined`——v0.1.0 发布初版的 compose 漏了这项，`git pull` 最新版即可
3. **VPS 是 OpenVZ/LXC 共享内核型**：虚拟化层直接拒绝挂载，systemd 容器无解，只能换 KVM 型 VPS

**连接后黑屏 / 一闪退回登录页**
多为会话启动失败。看日志：`docker logs trixie-desktop`，关注 `xrdp-sesman` 与 `xfce4-session` 的输出。确认用 `NEW_USER`（而非 root）登录。

**忘了密码**
直接改 `secrets/*.txt` 里的值，`docker compose up -d`（先 `down`）重启即生效。

**改密码没生效**
配置引擎每次启动都同步密码，请确认容器完整重启过：`docker compose down && docker compose up -d`。

**中文输入法不生效**
确认在桌面会话中按 `Ctrl+Space`；某些程序首次启动早于 fcitx5，重开该程序即可。终端输入法仅图形界面应用有效（xfceterm 支持）。

**数据存在哪**
用户家目录在 named volume `trixie-home` 里。彻底删除数据：`docker compose down -v`。

## 构建

```bash
docker build -t debian-remote-trixie:v0.1.1 .
```

## 发布（维护者）

CI 由 git tag 触发（`.github/workflows/publish.yml`）：push `v*` 标签 → 构建并推送
Docker Hub（镜像 tag 与 git tag 同名，如 `singyoku/debian-remote-trixie:v0.1.1`）。

需要配置的 Repository Secrets：`DOCKERHUB_USERNAME`（Docker Hub ID，如 `singyoku`）、
`DOCKERHUB_TOKEN`（Docker Hub → Account Settings → Security → Access Token，Read & Write 权限）。

## 更新记录

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可

MIT License，双版权（原作者 Riyangarma33 + SinGyoZ），详见 [LICENSE](LICENSE)。
