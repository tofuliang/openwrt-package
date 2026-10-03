# OpenWrt multiwan（HomeRouter）

从 `root@192.168.2.1` **只读** 拉取的自定义三 WAN 负载均衡脚本。本仓库不写回远程。

## 路径对照

| 本地 | 远程 |
|------|------|
| `usr/sbin/multiwan` | `/usr/sbin/multiwan` |
| `usr/sbin/multiwan_tracker` | `/usr/sbin/multiwan_tracker` |
| `lib/multiwan_common.sh` | `/lib/multiwan_common.sh` |
| `etc/init.d/multiwan` | `/etc/init.d/multiwan` |
| `etc/hotplug.d/iface/99-multiwan` | `/etc/hotplug.d/iface/99-multiwan` |
| `etc/multiwan/multiwan.nft` | `/etc/multiwan/multiwan.nft` |
| `etc/config/multiwan` | `/etc/config/multiwan` |
| `usr/sbin/multiwan-isp-update` | `/usr/sbin/multiwan-isp-update` |

`etc/config/network`、`mwan3`、`syncdial` 是快照，实际负载均衡走 `multiwan`，不走 mwan3。

## 中国移动（vwan2）

- 接口名：`vwan2`（防火墙 wan zone 已包含）
- 路由表 `400`，ip rule 优先级 `2004`
- 线路标记占用 bit16–19：WAN=`0x00010000`、VWAN1=`0x00020000`、IPTV=`0x00030000`、VWAN2=`0x00040000`
- ip rule 使用 `fwmark <线路标记>/0x000f0000`，因此保留 OAF appid 和其他 mark 状态位
- 默认 PCC：`mod 3` → WAN / VWAN1 / VWAN2
- IPTV 不参与三线均衡
- 故障降级：三线 → 任意两线 hash → 单线 redirect

拨号占位：`etc/config/network.vwan2.snippet`（账号密码未填，禁止提交真实口令到公开远程）。

线路标记写入 conntrack 时使用常量 RHS：`(ct mark and 0xfff0ffff) or <线路标记>`。这样兼容 Linux 6.12，不依赖双变量 bitwise；低16位及高位 OAF 状态不会被 MultiWAN 覆盖。

`multiwan status` 的累计出口计数和采样窗口从 `save_mark` 读取上述高位线路标记；`multiwan connections` 只按 bit16–19 归类线路，单独带有 OAF appid 而未分配线路的连接会显示在“其他”中，不代表旧线路标记残留。


## 目的地址策略

新连接按以下优先级选择 IPv4 出口：

1. IPTV 与 `no_balanced` 例外；
2. `cloudflare_destinations` → 移动 `vwan2`（线路位 `0x00040000`）；
3. `mobile_destinations` → 移动 `vwan2`（线路位 `0x00040000`）；
4. `telecom_destinations` → 电信 `wan`/`vwan1` 两线 PCC；
5. 其他中国大陆地址 → 三线 PCC；
6. 国际及未知地址 → 三线 PCC（`mod 3`）。

路由器自身发出的 IPv6 先按目的地分流（`cloudflare6`/`mobile6`/`telecom6`/`china6`，与 IPv4 同构），未命中再走 `route_international6` 三线哈希；出口由 `masq6_multiwan` 按 fwmark 改写源地址。IPv6 转发流量（LAN 客户端）不参与策略，仍按主表源前缀路由。v6 列表随 `update` 一同下载，落在同一个版本目录（`mobile6/telecom6/china6/cloudflare6.cidr`）。

`usr/sbin/multiwan-isp-update` 从配置的数据源下载并在同一个 nft 批次中更新 4 组 IPv4 与 4 组 IPv6 CIDR 集合。当前默认数据源为 `ispip.clang.cn` 的移动/电信（v4 与 v6）与 `all_cn_ipv6`、`mayaxcn/china-ip-list` 的中国大陆 v4 列表，以及 Cloudflare 官方 `ips-v4`/`ips-v6`；这些是运营商归属近似，不保证实际最优路径。下载、CIDR 校验或 nft 预检失败时不触碰运行中的集合；nft 应用失败时恢复上一份缓存指针，首次无缓存则删除本次指针。首次无缓存时集合为空，不影响默认电信策略。

线路状态切换只重建策略子链，不重载整张 nft 表，因此不会清空已下载的 CIDR 集合。移动线路离线时，移动目标降级到在线电信两线 PCC；电信目标不会被分配到移动线路，国际目标默认固定主电信。

更新命令：

```sh
/usr/sbin/multiwan-isp-update update   # 下载并应用，成功后只保留当前版本目录
/usr/sbin/multiwan-isp-update apply    # 仅按缓存重新应用（服务启动时自动调用）
```

`update` 会新建 `versions/<时间戳>` 目录并把 `current` 指针指过去；应用失败时把 `current` 写回上一次的版本名（回滚在同一次运行内完成，不依赖旧目录长期驻留），并删除本次目录；应用成功后只保留当前版本目录，其余全部清理。CIDR 集合不随服务重启失效，需定时刷新：

```sh
30 4 * * 1 /usr/sbin/multiwan-isp-update update
```
## OpenWrt 25.12 回归

25.12.1 远程升级后曾将 `/lib/multiwan_common.sh` 回退为不含 `setup_route()` 的版本；但 `/etc/init.d/multiwan` 和 `99-multiwan` 仍调用该函数。结果接口 `iptv` 显示 up、nft 规则也能打上 IPTV 线路标记，但路由表 300 为空，流量按 `main` 表从 `pppoe-wan` 出口发送。

恢复本仓库的 `lib/multiwan_common.sh` 后，`setup_route()` 会根据 ubus 的 `l3_device` 和 peer 网关重新安装对应策略表默认路由。`iptv` 继续保持 `option defaultroute '0'`。

验证目标：

```sh
ip -4 route show table 300
ip -4 route get 183.59.59.26 mark 0x00030000
```

第二条应显示 `dev pppoe-iptv`，而不是 `dev pppoe-wan`。

当前标记布局固定使用 bit16–19：WAN=`0x00010000`、VWAN1=`0x00020000`、IPTV=`0x00030000`、VWAN2=`0x00040000`，新版路由器已完成迁移。启动过程中 nft 文件预检失败或应用失败只报错退出，不恢复旧 nft 表或 ip rule。

服务 stop/start 之间会把四个 WireGuard endpoint 动态集合保存到 `/tmp/multiwan-restart-special/`，并以 `/tmp/multiwan-restart-special.pending` 标识快照有效；启动成功恢复集合后清理 marker 和快照。这样重启跨进程仍能保留动态映射，快照失败时不会留下可消费的 marker。

部署前在路由器上先建好 `vwan2` PPPoE，再安排维护窗口覆盖本仓库脚本并 `/etc/init.d/multiwan restart`。本地改动只代表源码状态，不代表已写入远程路由器；部署时应先执行 `nft -c`、准备规则快照并确保控制台保障，禁止未经这些准备直接 SSH 覆盖。

## 诊断工具

`tools/` 下是路由器上使用的只读排障工具（依赖 nft；解码在 awk 内完成，只需 openssl 之外的 auk 环境）：

- `tools/adguard-window-attrib.sh`：统计 AdGuardHome 查询日志中**最近指定窗口全部** A 应答 IP 的多 WAN 归属，输出集合命中明细、出口口径汇总（vwan2 / wan+vwan1 / 三线哈希）、各归属域名样例与查询量 top10。
  ```sh
  sh tools/adguard-window-attrib.sh [窗口起点UTC前缀] [排除的客户端IP]
  # 缺省窗口 = 最近 24 小时；缺省排除 192.168.20.22
  ADGUARD_QUERYLOG=...  DNSDEC=...   # 可覆盖路径
  ```
- `tools/dnsdec-all.awk`：批处理解码器，输入 `域名|base64应答`，输出 `域名|IP`。在 awk 内完成 base64 解码与 DNS 报文解析（压缩指针、RR 头 10 字节），无需逐条 fork openssl/hexdump。

归属口径：策略按 `cloudflare → mobile → telecom → china → international` 顺序匹配，故多集合命中时优先判为 `route_mobile`，其次 `route_telecom`、`route_china`，未命中集合的走 `route_international`。

## 强制出口（指定 IP 走指定线路）

需要把某个 IPv4/IPv6 目的地固定到某条线时，用强制出口集合（优先级高于全部目的地分类与 ICMP 例外）：

```sh
multiwan force-wan   <IP>     # 固定走 WAN（0x00010000）
multiwan force-vwan1 <IP>     # 固定走 VWAN1（0x00020000）
multiwan force-vwan2 <IP>     # 固定走 VWAN2/移动（0x00040000）
multiwan unforce     <IP>     # 从所有强制集合移除
multiwan list-force           # 列出
```

按 IP 自动选择集合：IPv4 → `force_{wan,vwan1,vwan2}`，IPv6 → `force6_{wan,vwan1,vwan2}`。

条目会写入 `/etc/multiwan/force_egress.list`（随 sysupgrade 保留），服务启动时由 `restore_force_sets` 重新灌入 nft，因此**重启/升级后自动恢复**；`unforce` 同时删除 nft 元素与持久化记录。规则同时挂在 `prerouting_hook`（LAN 转发）与 `output_hook`（路由器自身），且在 `output_hook` 中位于 ICMP 例外之前，因此 ping 也遵循强制出口。IPv6 转发流量被强制后会经 `masq6_multiwan` 改写源地址（NAT66），与 `cloudflare6` 的既有行为一致。

## IPTV 组播出口（rtp2httpd / msd_lite）

内核按"到组地址的路由"选择发送 IGMP 入组请求的接口。若主表默认路由落在 `pppoe-vwan2`（移动），入组请求会被发到移动线，ISP 收不到，组播永不投递。

`etc/hotplug.d/iface/98-iptv-mcast` 在 `iptv` 接口 up 时为 IPTV 使用的组播网段固定路由（可用 `IPTV_MCAST_NETS` 覆盖）：

```sh
ip route replace 239.77.0.0/24 dev pppoe-iptv   # 以及 239.77.1.0/24 239.253.43.0/24 239.0.10.0/24
```

只加这些网段而不是整段 `239.0.0.0/8`，避免把 LAN 内的 SSDP（239.255.255.250）也带去 WAN。防火墙侧需要放行 `iifname pppoe-iptv` 的 IGMP 与 UDP 组播（现有 `Allow IPTV` 规则已覆盖）。

## IPTV 单播出口（WG0/apifox 转发与路由器自身）

`@iptv` 集合里的地址只在 `pppoe-iptv` 上可达，必须打上 `0x00030000` 才会命中 table 300。修复前两条链各漏一段：

- `prerouting_hook` 的 `iifname { "lo", "apifox", "WG0" } counter return` 排在 `ip daddr @iptv` 之前，WG0/apifox 转发流量提前 return，落回 main 表默认出口（`pppoe-vwan2`），表现为 LAN 设备能访问 IPTV 单播地址、走 WireGuard 的设备不能；
- `output_hook` 里没有任何 `@iptv` 规则，路由器自身发起的 curl/ping 同样落回 main 表。

修复后（`etc/multiwan/multiwan.nft`）：

- `prerouting_hook` 在跳过规则**之前**加一条限定 `iifname { "lo", "apifox", "WG0" }` 的 `@iptv → 0x00030000`，只影响此前被跳过的接口；br-lan 既有路径（跳过规则之后的无条件 `ip daddr @iptv`）与 `force_*`、`no_balanced` 的既有优先级完全不变。
- `output_hook` 在强制出口之后、ICMP 例外与 `oifname` 跳过之前加无条件 `@iptv → 0x00030000`，与强制出口「优先于 ICMP 例外」的既有口径一致（此时 `type route` 钩子会重跑路由查找，源地址改从 table 300 选取）。

回归测试：

```sh
bash tests/nft_iptv_egress_test.sh   # 断言两处规则存在且顺序正确，修复前会 FAIL
```

验证：

```sh
ip -4 route get 183.59.59.26 mark 0x00030000   # 应为 dev pppoe-iptv，而非 dev pppoe-vwan2
```
