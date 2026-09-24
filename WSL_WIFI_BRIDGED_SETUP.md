# WSL 2 通过 Wi-Fi 桥接接入局域网

本文档用于将 WSL 2 通过 Hyper-V 外部虚拟交换机桥接到 Wi-Fi，使 WSL 获得独立的局域网 IPv4 地址。

> 注意：WSL 的 `bridged` 网络模式已经被微软标记为弃用，后续 WSL 版本可能移除或改变其行为。如果只要求 WSL 稳定联网而不要求独立局域网 IP，建议改用 `mirrored` 模式。

## 当前已验证的网络结构

本机当前配置示例：

| 对象 | IPv4 地址 | 前缀/掩码 | 默认网关 |
| --- | --- | --- | --- |
| Windows `vEthernet (wsl-net)` | `10.10.20.107` | `/16`，即 `255.255.0.0` | `10.10.0.1` |
| WSL `eth0` | `10.10.250.212` | `/16`，即 `255.255.0.0` | `10.10.0.1` |
| Hyper-V `Default Switch` | `172.18.192.1` | `/20` | 无 |

`10.10.20.107/16` 和 `10.10.250.212/16` 都属于 `10.10.0.0/16`，因此 Windows 与 WSL 位于同一个局域网。

`vEthernet (Default Switch)` 的 `172.18.192.1/20` 是另一个 Hyper-V NAT 网络，与当前桥接模式无关。

上述 DHCP 地址可能在重新连接网络后变化，应以实际命令输出为准。

---

## 一、前置条件

1. Windows 已启用 WSL 2、虚拟机平台和 Hyper-V。
2. 当前使用物理 Wi-Fi 网卡联网。
3. 以下 Windows 命令在“以管理员身份运行”的 PowerShell 中执行。
4. 创建或修改外部交换机时，Windows 网络可能短暂断开。不要在只能依赖当前网络的远程会话中操作。

查看 WSL 版本：

```powershell
wsl --version
wsl --status
```

查看物理网卡：

```powershell
Get-NetAdapter -Physical |
    Format-Table Name, InterfaceDescription, Status, LinkSpeed
```

本机使用的物理无线网卡是：

```text
Intel(R) Wi-Fi 6 AX203
```

不要将外部交换机绑定到以下适配器：

- `Microsoft KM-TEST` 环回适配器；
- `vEthernet (...)` 虚拟适配器；
- VPN 适配器；
- 蓝牙网络连接；
- 已断开的有线网卡。

---

## 二、创建 Hyper-V 外部交换机

### 方法 A：使用图形界面

1. 打开“Hyper-V 管理器”。
2. 打开“虚拟交换机管理器”。
3. 新建“外部”虚拟网络交换机。
4. 名称填写：

   ```text
   wsl-net
   ```

5. “外部网络”选择真实的物理 Wi-Fi 网卡：

   ```text
   Intel(R) Wi-Fi 6 AX203
   ```

6. 勾选：

   ```text
   允许管理操作系统共享此网络适配器
   ```

7. 应用配置。

交换机名称前后不能包含空格。

### 方法 B：使用 PowerShell

先确认无线接口的 `Name`：

```powershell
Get-NetAdapter -Physical |
    Format-Table Name, InterfaceDescription, Status
```

假设接口名称为 `Wi-Fi`，创建交换机：

```powershell
New-VMSwitch `
    -Name "wsl-net" `
    -NetAdapterName "Wi-Fi" `
    -AllowManagementOS $true
```

如果交换机已经存在，不要重复执行创建命令。

### 验证交换机

```powershell
Get-VMSwitch -Name "wsl-net" |
    Format-List Name, SwitchType, NetAdapterInterfaceDescription
```

预期结果：

```text
Name                           : wsl-net
SwitchType                     : External
NetAdapterInterfaceDescription : Intel(R) Wi-Fi 6 AX203
```

检查名称是否存在不可见的前后空格：

```powershell
Get-VMSwitch | ForEach-Object {
    "[{0}] Length={1}" -f $_.Name, $_.Name.Length
}
```

正确的 `wsl-net` 长度为 `7`：

```text
[wsl-net] Length=7
```

---

## 三、配置 `.wslconfig`

项目目录中已提供：

```text
D:\nets\.wslconfig
```

内容为：

```ini
[wsl2]
networkingMode=bridged
vmSwitch=wsl-net
dhcp=true
```

将它复制到当前 Windows 用户目录：

```powershell
Copy-Item "D:\nets\.wslconfig" "C:\Users\admin\.wslconfig" -Force
```

确认最终文件名是 `.wslconfig`，而不是 `.wslconfig.txt`：

```powershell
Get-Item "C:\Users\admin\.wslconfig" |
    Format-List FullName, Length
```

完全关闭 WSL：

```powershell
wsl --shutdown
```

等待几秒后重新启动：

```powershell
wsl
```

---

## 四、检查 WSL 是否取得 IPv4

在 WSL 中执行：

```bash
ip link show eth0
ip -4 addr show dev eth0
ip route
```

正常结果应包含一个局域网地址和默认路由，例如：

```text
inet 10.10.250.212/16 brd 10.10.255.255 scope global dynamic eth0
default via 10.10.0.1 dev eth0
10.10.0.0/16 dev eth0 proto kernel scope link src 10.10.250.212
```

如果只有下面这种 IPv6 地址，说明还没有取得 IPv4：

```text
fe80::.../64
```

### 手动请求 DHCP 地址

```bash
sudo dhclient -r eth0
sudo dhclient -v eth0
```

成功时会看到类似：

```text
DHCPOFFER of 10.10.250.212 from 10.10.0.1
DHCPACK of 10.10.250.212 from 10.10.0.1
bound to 10.10.250.212
```

再次检查：

```bash
ip -4 addr show dev eth0
ip route
```

如果持续出现：

```text
No DHCPOFFERS received
```

说明 DHCP 请求没有得到响应。常见原因包括：

- 无线网卡驱动不支持这种桥接方式；
- 路由器或无线接入点不允许同一 Wi-Fi 连接后面出现额外 MAC；
- 企业、校园、酒店或需要认证的 Wi-Fi 限制额外终端；
- 接入点开启了客户端隔离。

---

## 五、让 WSL 启动时自动请求 DHCP

如果每次执行 `wsl --shutdown` 后都必须手动运行 `dhclient`，可以配置启动命令。

确认 `dhclient` 路径：

```bash
command -v dhclient
```

通常输出：

```text
/usr/sbin/dhclient
```

编辑 `/etc/wsl.conf`：

```bash
sudo nano /etc/wsl.conf
```

如果文件没有其他配置，写入：

```ini
[boot]
command=/usr/sbin/dhclient -4 eth0
```

如果已经启用了 systemd，可以合并到同一个 `[boot]` 段：

```ini
[boot]
systemd=true
command=/usr/sbin/dhclient -4 eth0
```

不要创建多个重复的 `[boot]` 段，也不要删除文件中已有且仍然需要的配置。

回到 Windows 执行：

```powershell
wsl --shutdown
wsl
```

进入 WSL 后等待几秒，再检查：

```bash
ip -4 addr show dev eth0
ip route
```

---

## 六、诊断并修复 DNS

出现以下错误时：

```text
ping: www.baidu.com: Temporary failure in name resolution
```

先不要直接判断为完全无法联网。该错误只说明域名解析失败。

### 1. 分层测试

在 WSL 中执行：

```bash
ip route
ping -c 4 10.10.0.1
ping -c 4 1.1.1.1
cat /etc/resolv.conf
```

判断方式：

| 测试结果 | 结论 |
| --- | --- |
| 网关和 `1.1.1.1` 都能通 | 网络正常，只有 DNS 故障 |
| 网关能通，`1.1.1.1` 不通 | 上游路由、VPN 或网络策略问题 |
| 网关不通 | 桥接链路、地址或路由有问题 |
| `ip route` 没有默认路由 | DHCP 没有正确写入默认路由 |

如果缺少默认路由，可以临时添加：

```bash
sudo ip route replace default via 10.10.0.1 dev eth0
```

然后重新测试：

```bash
ping -c 4 1.1.1.1
```

### 2. 临时修复 DNS

先查看 DHCP 下发的 DNS：

```bash
grep -R "domain-name-servers" /var/lib/dhcp 2>/dev/null
```

如果 DHCP 没有提供可用信息，可以先使用当前网关和公共 DNS：

```bash
sudo rm -f /etc/resolv.conf
printf 'nameserver 10.10.0.1\nnameserver 223.5.5.5\nnameserver 1.1.1.1\n' |
    sudo tee /etc/resolv.conf >/dev/null
```

验证：

```bash
cat /etc/resolv.conf
getent hosts www.baidu.com
ping -c 4 www.baidu.com
```

企业网络或 VPN 可能禁止公共 DNS。这种情况下，应使用企业 DHCP 或 VPN 下发的内部 DNS 地址。

### 3. 永久保留手动 DNS

编辑 `/etc/wsl.conf`：

```bash
sudo nano /etc/wsl.conf
```

将 DHCP 启动命令和 DNS 设置合并为：

```ini
[boot]
command=/usr/sbin/dhclient -4 eth0

[network]
generateResolvConf=false
```

如果原来已设置 `systemd=true`，保留它：

```ini
[boot]
systemd=true
command=/usr/sbin/dhclient -4 eth0

[network]
generateResolvConf=false
```

重新创建 DNS 文件：

```bash
sudo rm -f /etc/resolv.conf
printf 'nameserver 10.10.0.1\nnameserver 223.5.5.5\nnameserver 1.1.1.1\n' |
    sudo tee /etc/resolv.conf >/dev/null
```

回到 Windows 重启 WSL：

```powershell
wsl --shutdown
wsl
```

重新验证：

```bash
ip -4 addr show dev eth0
ip route
cat /etc/resolv.conf
ping -c 4 1.1.1.1
ping -c 4 www.baidu.com
```

---

## 七、验证 Windows、WSL 和局域网互通

### Windows 查看桥接接口

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
    Sort-Object InterfaceAlias |
    Format-Table InterfaceAlias, IPAddress, PrefixLength
```

本机已验证的 Windows 接口是：

```text
vEthernet (wsl-net)  10.10.20.107  16
```

Windows 测试 WSL：

```powershell
ping 10.10.250.212
```

WSL 测试 Windows：

```bash
ping -c 4 10.10.20.107
```

实际 DHCP 地址可能变化，请使用当前 `ipconfig` 和 `ip -4 addr` 输出中的地址。

### 测试局域网访问 WSL 服务

在 WSL 中启动临时 HTTP 服务：

```bash
python3 -m http.server 8080 --bind 0.0.0.0
```

在 Windows 中测试：

```powershell
Test-NetConnection 10.10.250.212 -Port 8080
```

浏览器访问：

```text
http://10.10.250.212:8080
```

也可以从局域网中的另一台电脑或手机访问这个地址。

正式服务必须监听 `0.0.0.0` 或 WSL 的局域网地址；如果只监听 `127.0.0.1`，其他设备无法访问。

如果 WSL 可以主动访问网络，但其他设备无法访问 WSL 服务，应继续检查：

- Linux 防火墙，如 `ufw`、`iptables` 或 `nftables`；
- Windows Defender 防火墙和 Hyper-V 防火墙；
- 服务的监听地址与端口；
- 无线接入点是否启用了客户端隔离。

不要为了测试长期关闭整个防火墙，优先只放行需要的端口。

---

## 八、检查 VPN 对路由的影响

本机存在 Cisco VPN 相关接口：

```text
以太网 2
IPv4: 10.100.169.206/16
网关: 10.100.0.1
DNS 后缀: ciscovnp.com
```

同时，Wi-Fi 桥接接口的默认网关是 `10.10.0.1`。Windows 上可能同时存在两条默认路由。

查看 Windows 默认路由及优先级：

```powershell
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" |
    Sort-Object RouteMetric |
    Format-Table InterfaceAlias, NextHop, RouteMetric, InterfaceMetric
```

查看完整 IPv4 路由：

```powershell
route print -4
```

如果只有连接 VPN 后 WSL 才无法访问互联网或企业内网，通常需要根据 VPN 的分流策略、内部网段和内部 DNS 单独配置路由。不要盲目删除 VPN 路由。

---

## 九、固定 WSL 地址

WSL 当前地址由 DHCP 动态分配，可能在重启、重新连接 Wi-Fi 或租约更新后改变。

查看 WSL MAC 地址：

```bash
ip link show eth0
```

当前示例 MAC：

```text
5e:bb:f6:9e:ee:fa
```

执行 `wsl --shutdown` 并重新启动后，再次检查 MAC：

```bash
ip link show eth0
```

如果 MAC 保持不变，可以在路由器的 DHCP 地址保留页面中，为该 MAC 固定一个 `10.10.0.0/16` 内且不冲突的地址。

如果 MAC 会变化，不要直接依赖 DHCP 保留；需要进一步固定 MAC 或根据网络管理员提供的地址配置静态 IP。配置静态地址前必须确认：

- 地址未被其他设备使用；
- 地址最好位于 DHCP 自动分配池之外；
- 前缀长度是 `/16`；
- 默认网关是 `10.10.0.1`；
- DNS 地址可用。

---

## 十、常见错误

### 找不到虚拟交换机

错误示例：

```text
找不到 VmSwitch“wsl-net”
WSL_E_VMSWITCH_NOT_FOUND
```

检查名称：

```powershell
Get-VMSwitch | ForEach-Object {
    "[{0}] Length={1}" -f $_.Name, $_.Name.Length
}
```

确保 Hyper-V 交换机名称与 `.wslconfig` 中的 `vmSwitch=wsl-net` 完全一致，并且前后没有空格。

### `eth0` 只有 `fe80::` 地址

说明网卡已启动，但未取得 IPv4。运行：

```bash
sudo dhclient -v eth0
```

### 能访问 IP，不能访问域名

说明 DNS 故障，按照“六、诊断并修复 DNS”处理。

### WSL 地址和 `Default Switch` 不在同一网段

这是正常现象。桥接模式使用 `wsl-net`，不是 `Default Switch`。应该比较：

- Windows `vEthernet (wsl-net)`；
- WSL `eth0`。

### Windows 能联网，WSL 无法取得 DHCP 地址

可能是 Wi-Fi 驱动、路由器或无线接入点禁止额外 MAC。可以先用完整 Hyper-V 虚拟机连接同一个外部交换机进行对照测试；如果同样失败，通常是无线网络侧限制。

---

## 十一、回退到推荐的镜像网络模式

如果桥接模式在当前 WSL 版本、Wi-Fi 或 VPN 环境下不稳定，并且不再要求 WSL 拥有独立局域网 IP，可以将 `C:\Users\admin\.wslconfig` 改为：

```ini
[wsl2]
networkingMode=mirrored
firewall=true
dnsTunneling=true
autoProxy=true
```

应用配置：

```powershell
wsl --shutdown
wsl
```

镜像模式通常更适合 Wi-Fi、VPN、IPv6 和日常开发，但它不等同于为 WSL 分配一个独立的局域网 IPv4 地址。

---

## 十二、最终检查清单

依次确认：

1. Hyper-V 存在名为 `wsl-net` 的 `External` 交换机。
2. `wsl-net` 绑定到 `Intel(R) Wi-Fi 6 AX203`。
3. 已勾选“允许管理操作系统共享此网络适配器”。
4. `C:\Users\admin\.wslconfig` 指定 `networkingMode=bridged` 和 `vmSwitch=wsl-net`。
5. Windows `vEthernet (wsl-net)` 获得 `10.10.x.x/16` 地址。
6. WSL `eth0` 通过 DHCP 获得另一个 `10.10.x.x/16` 地址。
7. WSL 存在 `default via 10.10.0.1 dev eth0` 路由。
8. WSL 能 ping 通 `10.10.0.1` 和公网 IP。
9. `/etc/resolv.conf` 包含可用 DNS，域名解析正常。
10. 局域网其他设备能访问 WSL 对外监听的服务端口。
