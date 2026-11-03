# CN_IP

**[中文](#中文)** | [English](#english)

---

## 中文

中国大陆 IPv4 地址段列表（`CN.txt`），以及一个基于 ipset + iptables 的入站防火墙脚本，可以一键做到「只允许中国 IP 访问」或「屏蔽中国 IP」。

列表由 MaxMind GeoLite2 国家数据库生成，已合并为最小 CIDR 集合，一行一个网段，约 8000 条。

### 获取列表

```
https://raw.githubusercontent.com/du5/CN_IP/main/CN.txt
```

格式示例：

```
1.0.1.0/24
1.0.2.0/23
1.0.8.0/21
```

没有注释和空行，可以直接喂给 ipset、nftables、路由器规则或任何接受 CIDR 列表的工具。

### 防火墙脚本 `cn-firewall.sh`

适用于 Debian / Ubuntu，需要 root。脚本会自动安装依赖、导入列表、配置开机恢复，并写入每小时自动更新的定时任务。

#### 安装

```bash
git clone https://github.com/du5/CN_IP.git /root/CN_IP
cd /root/CN_IP
./cn-firewall.sh setup
```

`setup` 每台机器只需执行一次，它会安装 `ipset`、`iptables`、`netfilter-persistent`、`ipset-persistent` 和 `cron`。

#### 两种模式

| 命令 | 效果 | INPUT 默认策略 |
|---|---|---|
| `./cn-firewall.sh accept` | 只允许中国 IP 新建入站连接，其余全部丢弃 | DROP |
| `./cn-firewall.sh block` | 丢弃来自中国 IP 的入站连接，其余全部放行 | ACCEPT |

直接运行另一个命令即可切换模式，切换过程中始终有一条规则生效，不会出现空窗。

`accept` 模式下始终放行：本机回环、已建立的连接、以及 SSH 端口的 TCP 连接。SSH 端口默认从 `sshd -T` 读取，读取失败则使用 22。

#### 环境变量

| 变量 | 说明 | 默认值 |
|---|---|---|
| `SSH_PORTS` | `accept` 模式下无条件放行的 TCP 端口，空格分隔 | 从 `sshd -T` 读取，否则 `22` |
| `LIST_URL` | 列表下载地址 | `https://git.affcm.com/CN_IP/CN.txt` |

示例：

```bash
SSH_PORTS="22 2222" ./cn-firewall.sh accept
```

#### 运行后发生了什么

- 列表下载到临时文件，校验格式后与上次应用的版本比较哈希。列表没变且防火墙已处于目标模式时，脚本直接退出，不做任何修改。
- 新列表先导入临时 ipset，核对条数后用 `ipset swap` 原子替换正式集合 `cn_ipv4_list`，正在引用该集合的规则不受影响。
- 每种模式只占用一条自己的链（`CN_IPV4_ACCEPT` 或 `CN_IPV4_BLOCK`），挂在 `INPUT` 第一条。规则没有变化时不会重建链。
- 规则和集合通过 `netfilter-persistent` 保存，重启后自动恢复。
- 写入 crontab：每小时整点以当前模式重新执行一次，日志追加到 `/var/log/cn-firewall.log`。

#### 停用

脚本没有卸载命令，手动执行以下步骤即可（以 `accept` 模式为例，`block` 模式把链名换成 `CN_IPV4_BLOCK`）：

```bash
crontab -l | grep -v cn-firewall.sh | crontab -
iptables -P INPUT ACCEPT
iptables -D INPUT -j CN_IPV4_ACCEPT
iptables -F CN_IPV4_ACCEPT && iptables -X CN_IPV4_ACCEPT
ipset destroy cn_ipv4_list
netfilter-persistent save
```

#### 注意事项

- **先在测试机上验证。** `accept` 模式会把 `INPUT` 默认策略改为 DROP，如果你的 SSH 端口没有被正确识别，会把自己锁在外面。首次执行时保持当前 SSH 会话不要断开，另开一个会话确认能登录后再关闭。
- **只处理 IPv4。** 脚本不会修改 `ip6tables`。如果服务器有公网 IPv6 地址，`accept` 模式对 IPv6 入站没有任何限制。
- 列表来自 GeoIP 数据库，存在少量误判是正常的。

### 自行生成列表

需要 Go 1.26 或更高版本。

```bash
go run .
```

程序会下载 `GeoLite2-Country.mmdb`，遍历其中的所有网段，把国家码为 `CN` 的网段合并后写入 `CN.txt`，整个过程大约一秒。数据库文件会保留在本地，超过 6 小时未更新时自动重新下载；删除该文件也可以强制刷新。

国家判定优先使用 `country.iso_code`，为空时回退到 `registered_country.iso_code`。

### 数据来源

数据库来自 [du5/geoip](https://github.com/du5/geoip) 分发的 MaxMind GeoLite2 国家库。

This product includes GeoLite2 data created by MaxMind, available from <https://www.maxmind.com>.

---

## English

[中文](#中文) | **English**

A list of IPv4 CIDR blocks for mainland China (`CN.txt`), plus an ipset + iptables firewall script that lets a server either **allow only Chinese IPs** or **block Chinese IPs** with one command.

The list is generated from the MaxMind GeoLite2 Country database and aggregated into a minimal set of CIDRs, one per line, about 8,000 entries.

### Get the list

```
https://raw.githubusercontent.com/du5/CN_IP/main/CN.txt
```

Sample:

```
1.0.1.0/24
1.0.2.0/23
1.0.8.0/21
```

No comments or blank lines, so it can be fed directly to ipset, nftables, router rules, or anything else that accepts a CIDR list.

### Firewall script `cn-firewall.sh`

For Debian / Ubuntu, must run as root. The script installs its dependencies, loads the list, sets up boot persistence, and installs an hourly cron job that keeps the list current.

#### Install

```bash
git clone https://github.com/du5/CN_IP.git /root/CN_IP
cd /root/CN_IP
./cn-firewall.sh setup
```

`setup` only needs to run once per machine. It installs `ipset`, `iptables`, `netfilter-persistent`, `ipset-persistent`, and `cron`.

#### Two modes

| Command | Effect | INPUT default policy |
|---|---|---|
| `./cn-firewall.sh accept` | Only Chinese IPs may open new inbound connections; everything else is dropped | DROP |
| `./cn-firewall.sh block` | Inbound connections from Chinese IPs are dropped; everything else is accepted | ACCEPT |

To switch modes, just run the other command. One rule set is always active during the switch, so there is no window where the firewall is open or closed unexpectedly.

In `accept` mode, loopback, established connections, and TCP to the SSH ports are always allowed. SSH ports are read from `sshd -T`, falling back to 22.

#### Environment variables

| Variable | Description | Default |
|---|---|---|
| `SSH_PORTS` | TCP ports always allowed in `accept` mode, space-separated | From `sshd -T`, else `22` |
| `LIST_URL` | Where to download the list from | `https://git.affcm.com/CN_IP/CN.txt` |

Example:

```bash
SSH_PORTS="22 2222" ./cn-firewall.sh accept
```

#### What a run does

- Downloads the list to a temporary file, validates the format, and compares its hash with the last applied version. If nothing changed and the firewall is already in the requested mode, the script exits without touching anything.
- Loads the new list into a temporary ipset, verifies the entry count, then atomically replaces the live set `cn_ipv4_list` with `ipset swap`. Rules referencing the set are unaffected.
- Each mode owns a single chain (`CN_IPV4_ACCEPT` or `CN_IPV4_BLOCK`) hooked at position 1 of `INPUT`. The chain is not rebuilt unless its rules changed.
- Rules and sets are saved through `netfilter-persistent` and restored at boot.
- Installs a crontab entry that re-runs the current mode every hour, logging to `/var/log/cn-firewall.log`.

#### Uninstall

There is no uninstall command. Run these steps by hand (shown for `accept` mode; for `block` mode use `CN_IPV4_BLOCK` as the chain name):

```bash
crontab -l | grep -v cn-firewall.sh | crontab -
iptables -P INPUT ACCEPT
iptables -D INPUT -j CN_IPV4_ACCEPT
iptables -F CN_IPV4_ACCEPT && iptables -X CN_IPV4_ACCEPT
ipset destroy cn_ipv4_list
netfilter-persistent save
```

#### Caveats

- **Test on a non-production machine first.** `accept` mode sets the `INPUT` default policy to DROP. If your SSH port is not detected correctly you will lock yourself out. Keep your current SSH session open the first time you run it, and confirm you can log in from a second session before closing the first.
- **IPv4 only.** The script does not touch `ip6tables`. If the server has a public IPv6 address, `accept` mode places no restriction on IPv6 inbound traffic.
- The list comes from a GeoIP database, so a small number of misclassified ranges is normal.

### Generate the list yourself

Requires Go 1.26 or later.

```bash
go run .
```

The program downloads `GeoLite2-Country.mmdb`, walks every network in it, merges the ones whose country code is `CN`, and writes the result to `CN.txt`. The whole run takes about a second. The database file is kept locally and re-downloaded automatically when it is more than 6 hours old; deleting the file also forces a refresh.

Country lookup prefers `country.iso_code` and falls back to `registered_country.iso_code` when it is empty.

### Data source

The database is the MaxMind GeoLite2 Country database as distributed by [du5/geoip](https://github.com/du5/geoip).

This product includes GeoLite2 data created by MaxMind, available from <https://www.maxmind.com>.
