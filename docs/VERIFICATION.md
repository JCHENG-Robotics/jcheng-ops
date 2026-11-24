# 验证记录：2026-11-24

范围：v0.1.0 的四层机器人防护与 Studio 看护，在真实 ArmPi Ultra 与操作员笔记本上
安装并验证。所有命令与输出片段见 [`../evidence/20261124/verification.txt`](../evidence/20261124/verification.txt)。

## 1. 环境

| 项 | 值 |
|---|---|
| 机器人 | Raspberry Pi 5，Debian 12 bookworm，systemd 252，`10.42.0.218` |
| 机器人 OS 状态 | 52 GB 根分区，86% 使用；8 GB 内存 + 5.2 GB swap |
| 网关 | 8765 只读（相机 + 遥测），8766 pose（运动），两者都绑定 `10.42.0.218` |
| 笔记本 | Ubuntu，systemd user manager 可用，`linger=no`（待操作员执行一次 sudo） |
| 后端 | `jcheng-manipulation` v1.0.0，`armpi-debug-studio/backend`，port 8000 |

## 2. 机器人侧

| 检查 | 命令 | 结果 |
|---|---|---|
| 硬件看门狗超时 | `systemctl show -p RuntimeWatchdogUSec` | `15s` |
| PID 1 持有看门狗 | `ls -l /proc/1/fd \| grep watchdog` | `9 -> /dev/watchdog0` |
| 巡检 timer | `systemctl is-active armpi-ops-health.timer` | `active` |
| 巡检结果 | `cat /run/armpi-ops/status.json` | `summary=ok`，`failures={8765:0,8766:0,sshd:0}`，`actions=[]`，`MemAvailable≈6.6 GB` |
| 8765 | `GET /health` | `status=ok`，`ros_ready/joints_ready/measured_ready/tf_ready/camera_ready/aux_camera_ready` 全 true |
| 8766 | `GET /health` | `status=ok`，`motion_enabled=true`，`motion_mode=pose`，`motion_state=idle`，`safety_stop=false`，`chassis_enabled=true` |
| 重启策略 | `systemctl show -p Restart` | `armpi-gateway-pose=always`（原 `no`），`start_node=on-failure` |
| OOM 保护 | `systemctl show -p OOMScoreAdjust` | `armpi-gateway-pose=-500`，`armpi-gateway=-500` |
| fstab | `cat /etc/fstab` | 4 条重复 `/swapfile` → 1 条；`findmnt --verify` 0 errors（2 个预期 warning）；已 `daemon-reload` |
| 巡检自检 | `armpi-ops-health --dry-run` | `summary=ok actions=none` |

## 3. 笔记本侧

| 检查 | 命令 | 结果 |
|---|---|---|
| 看护单元 | `systemctl --user is-enabled/is-active` | `enabled` / `active` |
| 配置 | `stat -c %a ~/.config/armpi-studio/studio.env` | `600` |
| 后端能力 | `GET /api/health` | `status=ok`，`mode=hardware`，`hardware_motion=true`，`motion_scope=pose`，`gripper_control=true` |
| 分支 A：健康失败 + 网关可达 | `studio_watchdog.sh --once --dry-run`（PORT=8999） | 日志：`gateway reachable; restarting the unhealthy backend` → `would start the backend on 127.0.0.1:8999` |
| 分支 B：健康失败 + 网关不可达 + 端口被占 | 同上（PORT=8998 被占，网关指向 9999） | 日志：`gateway unreachable and port 8998 is held; leaving the backend alone (robot down)` |
| linger | `loginctl show-user … -p Linger` | `no`（需要操作员执行 `sudo loginctl enable-linger`） |

## 4. 仓库自检

```text
$ python3 -m pytest -q tests
5 passed

$ bash -n robot/install-pi-ops.sh studio/*.sh scripts/*.sh
(no output)

$ python3 tools/verify_config_consistency.py   # in jcheng-manipulation, cross-check
CONFIG OK: 5 joints agree ... the constant correction agrees in 6 sources
```

## 5. 未验证

| 项 | 原因 | 风险 |
|---|---|---|
| 看门狗真实触发 | 装机当天没有复现卡死；没有做人为 stall（唯一测试机 + 厂商启动会动机械臂） | 触发路径只在设计上正确 |
| drop-ins 整机重启生效 | 重启会跑厂商启动序列，需要操作员在场 | OOMScoreAdjust 在下次 exec 生效，不影响当前运行 |
| 事故重放 | 4 GB Python 进程身份未知 | 无法确认巡检能及时记录到它 |
| 长时间稳定性 | 截至 2026-11-24 10:11，巡检只运行了数分钟 | 需要下一次实机使用观察 |
