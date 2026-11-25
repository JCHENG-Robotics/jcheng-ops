# 运维手册

所有操作都只重启进程或修改 systemd 配置，**不发运动命令**。唯一的例外是硬件
看门狗触发整板重启：厂商启动序列会让机械臂动作。

## 1. 安装

### 1.1 机器人

```bash
scp robot/* pi@10.42.0.218:/tmp/armpi-ops/
ssh pi@10.42.0.218 sudo bash /tmp/armpi-ops/install-pi-ops.sh
```

安装器做的事：

| 动作 | 结果 |
|---|---|
| `/usr/local/sbin/armpi-ops-health` | 巡检程序（0755） |
| `armpi-ops-health.service/.timer` | 30 s 周期，`enable --now` |
| `armpi-gateway-pose.service.d/restart.conf` | `Restart=always`、`RestartSec=5`、`OOMScoreAdjust=-500` |
| `armpi-gateway.service.d/oom.conf` | `OOMScoreAdjust=-500` |
| `start_node.service.d/restart.conf` | `Restart=on-failure`、`RestartSec=15`、`OOMScoreAdjust=-300` |
| `ssh.service.d/oom.conf` | `OOMScoreAdjust=-800` |
| `system.conf.d/10-runtime-watchdog.conf` | `RuntimeWatchdogSec=15` + `systemctl daemon-reexec` |

`--no-watchdog` 跳过最后一项（其余照装）。

### 1.2 笔记本

```bash
studio/install-studio-watchdog.sh
sudo loginctl enable-linger "$USER"
```

安装器写入 `~/.config/armpi-studio/studio.env`（0600），包含网关 token、pose
模式、`DB_PATH`（启动时展开日期）和后端目录。token 来源依次为
`ARMPI_GATEWAY_TOKEN` → 正在运行的后端环境 → SSH 读取机器人。

## 2. 日常验证

```bash
# 机器人
systemctl show -p RuntimeWatchdogUSec                 # 15s
sudo ls -l /proc/1/fd | grep watchdog                 # PID 1 -> /dev/watchdog0
systemctl list-timers armpi-ops-health.timer
cat /run/armpi-ops/status.json                        # summary/gateways/actions
sudo journalctl -u armpi-ops-health.service -n 20

# 笔记本
systemctl --user status armpi-studio-watchdog
tail -5 ~/.local/state/armpi-studio/watchdog.log
```

`status.json` 里 `summary=ok`、`actions=[]`、两个网关都是 `idle/disabled` 即正常。
`--dry-run` 只探测、不重启，可随时手跑。

## 3. 事故处置：SSH 不通时先分类

| 观测 | 判据 | 处理 |
|---|---|---|
| 网卡 `NO-CARRIER` / 无 10.42.0.0/24 路由 | 笔记本侧链路问题 | 重新插线、检查 NM；不要重启机器人 |
| ping 不通，但网卡有载波 | 机器人未启动或网络未起 | 等 ~90 s 启动链；仍不行则断电 |
| ping 通，TCP 22 可建连，**无 SSH banner** | 用户态卡死 | 等看门狗（15 s 内应重启）；没有看门狗则断电 |
| SSH 通，8765 无响应 / 8766 refused | 单元挂了 | `sudo systemctl restart armpi-gateway[-pose]`；巡检也会自动处理 |
| SSH 通，`/health` 报 `ros_ready=false` | 厂商栈未就绪 | 查 `start_node`、容器、DDS 绑定地址 |

IPv6 链路本地 SSH（`ssh -6 pi@fe80::…%<if>`）与 IPv4 走同一个 sshd；如果两者都
没有 banner，就是用户态问题，不是链路问题。

容器重建、镜像扁平化这类变更**不属于本仓职责**（见 `ROADMAP.md` 的 Out of
scope：重启厂商容器会移动机械臂，必须有人在现场）。步骤、运行参数和回滚见
`JCHENG-Robotics/jcheng-system` 的 `deploy/armpi-ultra/README.md`。

## 4. 令牌与地址（最容易踩的坑）

- 网关绑定显式地址：`/etc/armpi-gateway/gateway.env` 的 `ARMPI_GATEWAY_BIND`、
  `pose.env` 的 `ARMPI_GATEWAY_POSE_BIND`，当前都是 `10.42.0.218`。**不是
  `0.0.0.0`**，所以 `curl 127.0.0.1:8765` 会被拒绝。
- 令牌在容器里是 `/home/ubuntu/shared/armpi_gateway_deploy/token`，宿主机对应
  `/home/pi/docker/tmp/armpi_gateway_deploy/token`（0600，pi:pi）。
- SSH 一定要带 `-o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_armpi`，否则 agent 里
  的时钟同步 key（forced command）可能被先选中。
- 8765 与 8766 是两个实例：8765 持有相机，8766 负责运动。不要起第二个 8766。

## 5. 调参与关闭

| 需求 | 做法 |
|---|---|
| 巡检更灵敏 | 改 `armpi-ops-health.timer` 的 `OnUnitActiveSec`，或代码里的 `FAIL_THRESHOLD` |
| 临时不重启任何东西 | `sudo systemctl stop armpi-ops-health.timer` |
| perception 运行时保持 8766 停止 | `sudo touch /run/armpi-ops/hold-pose`，再 `sudo systemctl stop armpi-gateway-pose`；巡检不会重启它。结束后 `sudo rm /run/armpi-ops/hold-pose`、`sudo systemctl start armpi-gateway-pose` |
| 关闭看门狗 | `sudo bash robot/install-pi-ops.sh --no-watchdog` |
| 关闭 Studio 看护 | `systemctl --user disable --now armpi-studio-watchdog` |

## 6. 回滚

```bash
# 机器人：只关硬件看门狗
sudo rm /etc/systemd/system.conf.d/10-runtime-watchdog.conf
sudo systemctl daemon-reexec

# 机器人：全部
sudo systemctl disable --now armpi-ops-health.timer
sudo rm /etc/systemd/system/armpi-ops-health.{service,timer} /usr/local/sbin/armpi-ops-health
sudo rm -r /etc/systemd/system/armpi-gateway-pose.service.d \
           /etc/systemd/system/armpi-gateway.service.d \
           /etc/systemd/system/start_node.service.d \
           /etc/systemd/system/ssh.service.d
sudo systemctl daemon-reload

# 笔记本
systemctl --user disable --now armpi-studio-watchdog
rm ~/.config/systemd/user/armpi-studio-watchdog.service
```

fstab 的备份在机器人 `/etc/fstab.bak-20261124`。

## 7. 已知未验证项

- 看门狗没有在真实卡死中触发过。
- drop-ins 安装后没有做整机重启验证（厂商启动会动机械臂，需要操作员在场）。
- 4 GB `python3` 的身份未知；内存压力日志会在下一次复现时给出名字。
