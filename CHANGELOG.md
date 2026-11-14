# 更新记录

## [未发布] — 部署配置修正

- compose：新增 `apparmor=unconfined`——Debian/Ubuntu 宿主的 AppArmor 默认配置
  拒绝容器内挂载 cgroup，缺失时 systemd 启动即退出（日志报
  `Failed to mount cgroup ... Permission denied`）；无 AppArmor 的宿主为空操作
- compose：默认镜像改为 Docker Hub 官方地址（`singyoku/debian-remote-trixie`），
  `docker compose up -d` 直接拉取，不再要求本地构建；本地开发构建见 README
- 修正 cgroup v1 宿主指引：初版把 volumes 语法写在 tmpfs 段注释里，
  照抄会报 `invalid tmpfs option`；正确做法是 volumes 段 rw 绑定挂载
- README：新增宿主要求与 `Failed to mount cgroup` 排障条目

## v0.1.0 - 2026-11-14

初版发布。

- 系统层：Debian 13 (Trixie) + systemd 作为 PID 1，容器行为等同一台小主机
  - xrdp 由 systemd 托管，崩溃自动拉起（Restart=on-failure）
  - `docker stop` 触发 systemd 完整关机序列，数据优雅落盘
  - 无关服务（getty / apt-daily / hugepages 等）以 mask 方式收敛，可审计
  - 服务日志经 journald 转发 console，`docker logs` 直接可读
- 桌面：XFCE + xrdp（Xorg 后端），标准 RDP 客户端直连
  - 内置中文环境：zh_CN.UTF-8 locale、Noto CJK + 文泉驿字体
  - 内置 fcitx5 + 拼音输入法，随会话自启动
  - 已知限制：无音频重定向（Debian 源暂无 pulseaudio-module-xrdp，Ubuntu 独有包；待上游收录后引入）
- 配置引擎（全新设计，替代原 ignition C 程序）：
  - 声明式幂等：配置项"存在则应用"，改 secrets/环境变量后重启即生效
  - 密码经 stdin 管道喂给 chpasswd，全程不经 shell 拼接，无注入面
  - 密码来源优先 docker secrets（`docker inspect` 不可见），环境变量兜底
  - 拒绝启动规则：未提供任何密码时容器直接关机退出，绝不回退默认弱口令
  - 输入校验：用户名白名单字符集，密码字节级禁控制字符（含换行）
- 安全：默认镜像无任何第三方 apt 源；root 密码不落 journal
- 兼容性：entrypoint 预挂 cgroup v2——在纯 cgroup v2 内核（WSL2 等）上
  systemd 若尝试挂 cgroup v1 层级会被内核拒绝并直接退出，预挂后直接进入 unified 模式
- 可靠性：xrdp.service 追加 drop-in（Restart=on-failure），崩溃自动拉起；
  fcitx5 追加 XDG autostart 条目，随会话自启动
- 交付：docker-compose 一键部署、HEALTHCHECK 健康检查、
  scripts/verify.sh 一键验证（19 项）、CI tag 触发 Docker Hub 发布、
  APT_MIRROR 构建加速参数（仅构建期生效）
- 验证：WSL2（内核 6.18，纯 cgroup v2）+ Docker 29 实测 19/19 全绿，
  含命令注入防护、拒绝启动规则、数据持久化、优雅关机、xrdp 自愈、中文环境

### 与上游项目的差异

本项目基于 [Riyangarma33/Debian-Remote-Docker](https://github.com/Riyangarma33/Debian-Remote-Docker)
重构，主要变更：

| 上游 | 本项目 |
| --- | --- |
| Debian 12 (bookworm) | Debian 13 (trixie) |
| C 程序 ignition 作为 PID 1（service + tail 保活） | systemd 作为 PID 1 |
| 首次配置一次性标记（/ignited） | 声明式幂等配置，每次启动同步 |
| 16 份复制粘贴 Dockerfile | 1 份 Dockerfile |
| shell 拼接命令（存在缓冲区溢出与命令注入） | stdin 管道 + 字节级校验 |
| 明文密码进 systemd unit 环境 | secrets 文件 0600，用后即删 |
| 未设密码回退 root:root | 无密码拒绝启动 |
| 第三方源安装 nala | 无第三方源 |
| 无 LICENSE | MIT 双版权 |
