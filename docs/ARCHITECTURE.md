# 架构与失败模型

## 1. 失败分类

运维对象是一台“能 ping 通但用户态完蛋”的机器人。按可观测性分三类：

| 类别 | 症状 | 能被谁发现 | 恢复方式 |
|---|---|---|---|
| 进程崩溃 | systemd 显示 `failed`/`inactive`，端口关闭 | systemd | `Restart=` 策略 |
| 服务挂死 | 端口在听、连接被接受、但没有响应 | 应用层探测（本仓库） | 重启对应单元 |
| 内存耗尽 | OOM killer 介入，随后出现级联故障 | 内核日志 + 内存阈值 | 预防（OOM 保护）+ 事后记录 |
| 用户态整体停滞 | ping/TCP 正常，sshd 无 banner，所有用户态服务无响应 | 本机看门狗（已无法由自己发现） | 硬件看门狗重启 |

2026-11-24 的事故是第 3 类触发第 2 类，最后演变成第 4 类。

## 2. 机器人侧

```text
armpi-ops-health.timer (30 s)
        │
        ▼
armpi-ops-health (oneshot, root)
        ├── 8765 /health ──┐
        ├── 8766 /health ──┤ 连续失败 3 次
        ├── sshd banner ───┤
        └── /proc/meminfo ─┘
        │
        ├── 另一网关 motion_state ∈ {idle, disabled}
        │        ├── 是 → systemctl restart <unit>
        │        └── 否 → 跳过，只记日志
        └── 两个网关都失联 → 第 3 次失败时都重启
```

判定细节：

- **探针地址**：两个网关都绑定显式地址（`ARMPI_GATEWAY_BIND`、
  `ARMPI_GATEWAY_POSE_BIND`，当前 `10.42.0.218`），不是 `0.0.0.0`，所以
  `127.0.0.1` 会被拒绝。巡检先读 `/etc/armpi-gateway/*.env`，再退回默认值，
  最后才试 loopback。
- **令牌**：网关在容器里读 `/home/ubuntu/shared/...`，宿主机对应
  `/home/pi/docker/tmp/...`；两个路径都会尝试，`ARMPI_OPS_TOKEN_FILE` 可覆盖。
- **失败计数**：按单元分别计数，连续 3 次（≈90 s）才动手；一次慢循环
  （相机快照、SD 卡抖动）不会触发重启。成功一次即清零。
- **sshd 探测**：连 `127.0.0.1:22`，3 s 内必须收到 `SSH-2.0`。事故中 TCP
  可以建连但永远没有 banner，所以只检查端口是否在听没有意义。
- **运动保护**：网关重启不会发运动命令，但运动中失去读取端不可接受。只要另一个
  网关报告非 idle 状态就跳过；两个都失联时运动状态不可知，第 3 次失败才一起重启。
- **内存**：`MemAvailable < 400 MB` 时把 top 3 常驻进程写进 journal 和
  `status.json`；`SwapFree < 200 MB` 也会记录。巡检本身 `OOMScoreAdjust=-500`，
  不会先于被监控对象被杀。

状态文件：

- `/run/armpi-ops/state.json` — 失败计数与上一次摘要（重启后清零）
- `/run/armpi-ops/status.json` — 最近一次循环的完整结果（给人和脚本读）

## 3. 硬件看门狗

`/etc/systemd/system.conf.d/10-runtime-watchdog.conf`：

```ini
[Manager]
RuntimeWatchdogSec=15
```

- BCM2835 的硬件超时固定 15 s，`SETTIMEOUT` 不支持，systemd 会按 7.5 s 喂狗。
- 只有 PID 1 完全停止调度 15 s 才会触发，正常负载（含相机 + 视觉 + DDS）不会
  接近这个阈值。
- 触发后整板重启，**厂商启动序列会移动机械臂**。这是本仓库唯一的自动“大动作”，
  已在 README 与 RUNBOOK 中标注。

## 4. 重启策略与 OOM 保护

| 单元 | Restart | OOMScoreAdjust | 理由 |
|---|---|---|---|
| `armpi-gateway` (8765) | `always`（原有） | -500 | 相机与遥测的唯一读取端 |
| `armpi-gateway-pose` (8766) | `always`（**新增**，原 `no`） | -500 | 崩溃后不需要操作员到场 |
| `start_node` | `on-failure`（**新增**，原 `no`） | -300 | 厂商栈失败后不再永久停摆 |
| `ssh` | `on-failure`（原有） | -800 | 唯一的远程入口 |

OOMScoreAdjust 在进程下一次 exec 时生效，因此安装后不重启单元也能保证
“下次启动生效”，本次没有为此重启 8765 或 sshd。

## 5. 笔记本侧 Studio 看护

```text
每 30 s ── GET /api/health
   ├── 成功 → 计数清零
   └── 连续 2 次失败
        ├── 机器人网关可达 → 杀掉本机 app.main:create_app 进程，等端口释放后重启
        ├── 网关不可达 + 8000 被占 → 只记日志（5 分钟一次），不杀
        └── 网关不可达 + 8000 空闲 → 起一个后端（UI 先用着，机器人回来后自动恢复能力）
```

`start_studio.sh` 的顺序也被修正：token、网关健康、venv 全部通过后才处理
8000 端口。旧顺序在 2026-11-24 把健康后端杀掉、再因为 SSH 失败退出，是那次
“Studio 也一起挂了”的直接原因。

安装脚本生成的 `studio.env` 是只读配置：后端指向 `jcheng-studio`，网关用
可达的 8765，`ARMPI_HARDWARE_MOTION=0`。看护单元只负责保活，不启用运动；
需要运动的会话由操作员手动启动。

## 6. 配置面

| 变量 | 作用 | 默认 |
|---|---|---|
| `ARMPI_OPS_TOKEN_FILE` | 巡检读取的网关令牌 | 两个已知路径依次尝试 |
| `ARMPI_OPS_BIND` | 网关未配置时的探测地址 | `10.42.0.218` |
| `ARMPI_STUDIO_ENV` | Studio 看护的环境文件 | `~/.config/armpi-studio/studio.env` |
| `ARMPI_STUDIO_BACKEND_DIR` | 后端 checkout | 同级 `jcheng-studio/backend` |
| `ARMPI_STUDIO_INTERVAL` / `_FAIL_THRESHOLD` | 看护周期与阈值 | 30 s / 2 |
| `ARMPI_STUDIO_LOG_DIR` | 看护日志 | `~/.local/state/armpi-studio` |

## 7. 明确不做

- 不拥有设备：不打开 `/dev/video*`、串口、总线，只读已有服务的 HTTP 接口。
- 不发布运动命令，不参与安全校验、租约或仲裁。
- 不监控 ROS 图内部；MoveIt、控制器、相机驱动由各自的 service 与网关反映。
- 不替代急停。
