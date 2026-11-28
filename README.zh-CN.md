# jcheng-ops

**简体中文** | [English](README.md)

JCHENG Robotics 的机器人运维仓库：无人值守健康巡检、硬件看门狗、服务自愈、
操作员笔记本上的 Studio 看护，以及对应的事故手册。

遗留目标：**ArmPi Ultra**（Raspberry Pi 5 + 厂商 ROS 2 Humble 栈）和操作员笔记本
上的 ArmPi Debug Studio。平台已于 2026-11-28 **冻结**（ADR-0007）；这些探针保留为
参考部署，不再安装到新主机。

> 状态：**已部署** — v0.1.0（2026-11-24）。机器人侧的四层防护（15 s 硬件看门狗、
> 30 s 健康巡检、重启策略、OOM 保护）已安装并逐项验证；笔记本侧 Studio 看护已
> 安装并跑通“重启/拒绝重启”两条分支。
> **看门狗尚未在真实卡死中自动触发过**——装机当天没有复现事故，所以这里是
> “按设计可用”，不是“已经救过一次场”。
> 本文为英文主文档的中文对照；如有歧义，以英文版为准。

本仓库**不发送任何运动命令**，不拥有相机/串口/总线设备，也不替代急停。

---

## 1. 为什么存在

2026-11-24 09:20，机器人发生一次 OOM：内核杀掉了一个约 4 GB 的 `python3`
（12.4 GB 虚拟内存）。随后 sshd 触发 `MaxStartups` 限流、`armpi-vision` 起不来、
8765 网关 socket 只接受连接不应答，系统进入半死状态，**只能断电**。

最麻烦的是它骗过了所有只看网络的监控：

| 检查 | 事故中的表现 | 结论 |
|---|---|---|
| `ping <ROBOT_LINK_IP>` | 0.16 ms 正常 | 网线和 Pi 内核都活着 |
| TCP 22 | 可以建立连接 | 端口在听 |
| SSH banner | 永不返回（IPv4、IPv6 链路本地都一样） | sshd 用户态卡死 |
| `8765 /health` | 接受 SYN、永不应答 | 网关进程挂死 |
| `8766` | `Connection refused` | pose 网关没在跑 |

所以本仓库的第一原则是：**探应用层，不探网络层**；第二原则是：
**在机器人不可达时，绝不把笔记本上的 Studio 弄停**。

完整时间线与证据：[`docs/INCIDENT-2026-11-24.md`](docs/INCIDENT-2026-11-24.md)。

## 2. 分层

| 层 | 位置 | 触发条件 | 动作 | 已验证 |
|---|---|---|---|---|
| 硬件看门狗 | 机器人 PID 1 | systemd 停止喂 `/dev/watchdog0` | 整板重启 | 已装载（`RuntimeWatchdogUSec=15s`，PID 1 持有 fd） |
| 健康巡检 | 机器人 `armpi-ops-health.timer` | 每 30 s；同一探针连续失败 3 次 | 重启对应 systemd 服务 | 实机运行，`status.json` 全绿 |
| 重启策略 | 机器人 systemd drop-ins | 进程崩溃/退出 | `armpi-gateway-pose` 始终拉起，`start_node` 失败拉起 | `systemctl show` 已确认 |
| OOM 保护 | 机器人 systemd drop-ins | 内核选择牺牲者 | sshd/网关/start_node 更难被杀 | `OOMScoreAdjust` 已设置（进程重启后完全生效） |
| Studio 看护 | 笔记本 systemd user 服务 | `/api/health` 连续失败 2 次 | 重启后端；网关不可达时拒绝 | 两条分支均 dry-run 实测 |

安全约束（全部已实现）：

- 健康巡检重启网关前，必须由**另一个网关**报告 `motion_state` 为 `idle`/`disabled`；
  运动中只记日志，不重启。
- 两个网关都失联时，第三次连续失败才允许重启（此时运动状态已不可知）。
- Studio 看护在机器人网关不可达时**不杀**占用 8000 端口的后端，只每 5 分钟记一次日志。
- 所有动作只重启进程，不发运动命令。

## 3. 安装

机器人（机器人账户有 NOPASSWD sudo；安装器幂等）：

```bash
scp robot/* <ROBOT_USER>@<ROBOT_LINK_IP>:/tmp/armpi-ops/
ssh <ROBOT_USER>@<ROBOT_LINK_IP> sudo bash /tmp/armpi-ops/install-pi-ops.sh
# 只装巡检/自启/OOM 保护、不装硬件看门狗：
ssh <ROBOT_USER>@<ROBOT_LINK_IP> sudo bash /tmp/armpi-ops/install-pi-ops.sh --no-watchdog
```

笔记本（Studio 看护）：

```bash
studio/install-studio-watchdog.sh
sudo loginctl enable-linger "$USER"   # 一次；否则注销/重启后看护停止
```

`install-studio-watchdog.sh` 会读取网关 token（依次尝试 `ARMPI_GATEWAY_TOKEN`、
正在运行的后端环境、SSH 读取机器人上的 token 文件），写入
`~/.config/armpi-studio/studio.env`（0600）。后端目录默认是同级的
`jcheng-studio/backend` checkout，可用 `ARMPI_STUDIO_BACKEND_DIR` 覆盖。
生成的配置是**只读**的：指向可达的 8765 网关，并关闭
`ARMPI_HARDWARE_MOTION`，看护单元永不启用运动。

## 4. 验证

```bash
# 机器人
systemctl show -p RuntimeWatchdogUSec            # 15s
sudo ls -l /proc/1/fd | grep watchdog            # PID 1 持有 /dev/watchdog0
systemctl list-timers armpi-ops-health.timer
cat /run/armpi-ops/status.json
sudo journalctl -u armpi-ops-health.service -n 20
sudo /usr/local/sbin/armpi-ops-health --dry-run  # 只探测，不重启

# 笔记本
systemctl --user status armpi-studio-watchdog
tail -f ~/.local/state/armpi-studio/watchdog.log
```

仓库自检（CI 同款，不接触机器人）：

```bash
bash scripts/check_repo_gate.sh
```

完整验证记录：[docs/VERIFICATION.md](docs/VERIFICATION.md)；结论与未验证项见
[ACCEPTANCE.md](ACCEPTANCE.md)。

## 5. 边界与非承诺

- **不是急停**，不读取编码器/力矩/人员接近，不能阻止运动。
- **看门狗重启会执行厂商启动序列，机械臂会上电动作**。无人值守时请清空工作区。
- 15 s 是 BCM2835 看门狗芯片的固定超时（`SETTIMEOUT` 不支持），不是可调参数。
- 不限制单进程内存。事故中的 4 GB `python3` 不是启动栈的一部分，身份仍未确定；
  巡检会在 `MemAvailable < 400 MB` 时记录 top 3 常驻进程，供下一次定位。
- 健康巡检只覆盖 8765/8766 与 sshd，不覆盖 ROS 图内部（MoveIt、控制器、相机驱动）。
- Studio 看护依赖 `linger`；不开启时只在当前登录会话内有效。

## 6. 目录

```text
capability.yaml  组织准入清单：layer ops、无硬件访问、motion_authority: none
robot/    机器人侧：健康巡检（Python，仅标准库）、service/timer、安装器
studio/   笔记本侧：Studio 后端看护、systemd user 单元、安装器
docs/     事故记录、架构、运维手册、验证记录
evidence/ 事故当时的 journal 摘录与验证输出（已脱敏）
tests/    巡检决策逻辑的单元测试（不接触机器人）
scripts/  CI 同款仓库门禁
```

## 7. 证据

- [`docs/INCIDENT-2026-11-24.md`](docs/INCIDENT-2026-11-24.md) — 时间线、根因、
  贡献因素
- [`docs/VERIFICATION.md`](docs/VERIFICATION.md) — 2026-11-24 的实机验证记录
- [`evidence/20261124/`](evidence/20261124/README.md) — journal 摘录与命令输出
- [`ACCEPTANCE.md`](ACCEPTANCE.md) — 验收结论与未验证项

## 8. 许可

**pending。** 本仓库与 JCHENG-Robotics 其他仓库一致，暂不附带 `LICENSE`；
审查状态见 [`LICENSE-REVIEW.md`](LICENSE-REVIEW.md)。代码只依赖 Python 标准库、
bash、systemd 与 curl。
