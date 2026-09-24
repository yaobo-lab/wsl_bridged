# WSL 使用笔记本扬声器、麦克风和摄像头

本文档适用于当前环境：

- Windows 宿主机通过 Hyper-V 外部交换机连接 WSL；
- WSL 使用 `bridged` 网络模式；
- Windows `vEthernet (wsl-net)` 当前地址为 `10.10.20.107/16`；
- WSL `eth0` 最近一次成功测试的地址为 `10.10.251.17/16`；
- 默认网关为 `10.10.0.1`；
- 扬声器和麦克风通过 WSLg 共享；
- 摄像头由 Windows FFmpeg 采集，再通过 UDP 单播发送到 WSL。

> Windows 和 WSL 的地址由 DHCP 分配，重启、重新连接 Wi-Fi 或租约更新后可能变化。执行摄像头推流前，应重新确认实际地址。

## 最终方案

| 硬件         | 使用方式                                 |
| ------------ | ---------------------------------------- |
| 扬声器、耳机 | WSLg PulseAudio 输出到 Windows           |
| 笔记本麦克风 | WSLg PulseAudio 从 Windows 获取输入      |
| 内置摄像头   | Windows FFmpeg 采集，通过 UDP 推送到 WSL |

这种组合保留 WSL 的独立局域网地址，不需要将网络模式改为 `mirrored`，也不依赖 `usbipd attach --wsl`。

## 实际实施记录（按时间顺序）

1. WSL 通过 Hyper-V 外部交换机 `wsl-net` 桥接到物理 Wi-Fi，并通过 DHCP 获得独立的 `10.10.x.x/16` 地址。
2. 在 `/mnt/wslg` 中确认了 `PulseAudioRDPSink`、`PulseAudioRDPSource` 和 `PulseServer`，因此扬声器和麦克风选择 WSLg 方案。
3. Windows 识别到内置摄像头的 USB 设备 `1-6`，但执行 `usbipd attach --wsl --busid 1-6` 时提示 `Networking mode 'bridged' is not supported`。
4. 为了继续保留桥接网络和 WSL 独立 IP，摄像头改用“Windows FFmpeg 采集 → UDP 单播 → WSL ffplay 接收”的方案。
5. 最初在 WSL 中执行 `-f dshow`，出现 `Unknown input format: 'dshow'`。确认 `dshow` 是 Windows DirectShow 输入，只能在 Windows 版 FFmpeg 中使用。
6. Windows FFmpeg 成功枚举到视频设备 `Integrated Camera`，以及 Windows 麦克风阵列。
7. 第一次使用 `640x480@15fps` 打开摄像头时出现 `Could not set video options`。
8. 使用 `-list_options true` 确认该摄像头在 `640x480` 下只支持 `30fps`，并支持 `NV12` 和 `YUYV422`；最终选择 `NV12 640x480@30fps`。
9. Windows FFmpeg 成功采集、编码并发送 H.264/MPEG-TS，日志显示约 `30fps`、`1.3Mbit/s`，但 WSL `ffplay` 最初一直显示 `nan`。
10. 排查发现 Windows 仍向旧的 WSL 地址 `10.10.250.212` 发送，而 WSL DHCP 地址已经变化为 `10.10.251.17`。
11. 将 UDP 目标改为 `10.10.251.17:9000` 后，WSL 成功弹出视频窗口并显示摄像头画面。

最终确认的关键点：

- `dshow` 命令必须在 Windows PowerShell 执行；
- WSL 负责运行 `ffplay` 或其他视频接收程序；
- 摄像头使用 `NV12 640x480@30fps`；
- WSL 地址由 DHCP 动态分配，每次推流前必须重新查询，不能长期写死旧地址；
- UDP 发送端不会确认目标是否实际存在，因此 FFmpeg 显示正常发送并不代表 WSL 一定收到。

---

## 一、确认当前网络地址

### Windows

在 PowerShell 中执行：

```powershell
Get-NetIPAddress `
    -InterfaceAlias "vEthernet (wsl-net)" `
    -AddressFamily IPv4 |
    Format-Table InterfaceAlias, IPAddress, PrefixLength
```

当前示例：

```text
vEthernet (wsl-net)  10.10.20.107  16
```

### WSL

```bash
ip -4 addr show dev eth0
ip route
```

当前示例：

```text
inet 10.10.251.17/16 brd 10.10.255.255 scope global eth0
default via 10.10.0.1 dev eth0
```

验证 Windows 和 WSL 互通。

Windows：

```powershell
ping 10.10.251.17
```

WSL：

```bash
ping -c 4 10.10.20.107
```

如果地址发生变化，后续命令中的地址也必须相应修改。

---

## 二、确认 WSLg 正常

在 WSL 中执行：

```bash
ls -la /mnt/wslg
echo "$PULSE_SERVER"
echo "$WAYLAND_DISPLAY"
```

当前机器已确认存在：

```text
/mnt/wslg/PulseAudioRDPSink
/mnt/wslg/PulseAudioRDPSource
/mnt/wslg/PulseServer
```

并且环境变量为：

```text
PULSE_SERVER=unix:/mnt/wslg/PulseServer
WAYLAND_DISPLAY=wayland-0
```

它们分别表示：

- `PulseAudioRDPSink`：WSL 向 Windows 扬声器或耳机播放声音；
- `PulseAudioRDPSource`：WSL 使用 Windows 默认麦克风；
- `PulseServer`：WSL 应用连接的音频服务；
- `WAYLAND_DISPLAY`：WSLg 图形程序显示通道。

如果这些文件或变量不存在，在管理员 PowerShell 中更新并重启 WSL：

```powershell
wsl --update
wsl --shutdown
wsl
```

---

## 三、安装 WSL 音视频工具

Ubuntu 22.04 中执行：

```bash
sudo apt update
sudo apt install -y pulseaudio-utils alsa-utils libasound2-plugins ffmpeg tcpdump
```

确认工具：

```bash
pactl --version
ffmpeg -version
ffplay -version

pactl --version; ffmpeg -version; ffplay -version
```

---

## 四、使用 Windows 扬声器或耳机

### 1. 查看播放设备

```bash
pactl info
pactl list short sinks
```

通常可以看到 WSLg 的 RDP sink，例如：

```text
rdp-sink
```

### 2. 测试声音播放

```bash
speaker-test -D pulse -c 2 -t wav
```

应该从 Windows 当前默认扬声器或耳机听到左右声道测试音。按 `Ctrl+C` 结束。

也可以播放 WAV 文件：

```bash
paplay /usr/share/sounds/alsa/Front_Center.wav
```

如果该文件不存在，查找可用声音文件：

```bash
find /usr/share/sounds -type f -name '*.wav'
```

### 3. 切换 Windows 输出设备

WSL 音频会跟随 Windows 当前默认输出设备。需要切换扬声器、蓝牙耳机或有线耳机时，在 Windows 中打开：

```text
设置 → 系统 → 声音 → 输出
```

通常不需要修改 WSL 配置。

---

## 五、使用 Windows 麦克风

### 1. 检查 Windows 权限

打开：

```text
设置 → 隐私和安全性 → 麦克风
```

启用：

- 麦克风访问；
- 允许应用访问麦克风；
- 允许桌面应用访问麦克风。

然后打开：

```text
设置 → 系统 → 声音 → 输入
```

确认：

- 选择了正确的默认麦克风；
- 输入音量不为零；
- Windows 麦克风测试可以检测到声音。

### 2. 查看 WSL 麦克风

```bash
pactl list short sources
```

通常可以看到：

```text
rdp-source
rdp-sink.monitor
```

其中：

- `rdp-source` 是 Windows 默认麦克风；
- `rdp-sink.monitor` 是 Windows 播放声音的监听源，不是物理麦克风。

### 3. 录制并回放

录制 5 秒：

```bash
arecord \
    -D pulse \
    -d 5 \
    -f S16_LE \
    -r 48000 \
    -c 1 \
    /tmp/microphone-test.wav
```

播放录音：

```bash
aplay -D pulse /tmp/microphone-test.wav
```

也可以通过 PulseAudio 播放：

```bash
paplay /tmp/microphone-test.wav
```

### 4. 查看音频日志

如果连接失败：

```bash
cat /mnt/wslg/pulseaudio.log
```

只查看错误：

```bash
grep -iE 'error|fail|denied' /mnt/wslg/pulseaudio.log
```

检查 PulseAudio 连接：

```bash
pactl info
```

---

## 六、在 Windows 安装 FFmpeg

打开 PowerShell：

```powershell
winget install --exact --id Gyan.FFmpeg
```

安装后关闭并重新打开 PowerShell，确认：

```powershell
ffmpeg -version
ffplay -version
```

如果命令仍然找不到，重新登录 Windows，或者检查 FFmpeg 是否已经加入 `PATH`。

---

## 七、查找 Windows 摄像头名称和格式

### 1. 列出 DirectShow 设备

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

寻找视频设备名称，例如：

```text
Integrated Camera
```

必须使用 FFmpeg 输出的准确名称，不要仅根据设备管理器中的名称猜测。

### 2. 查看摄像头支持的格式

假设名称为 `Integrated Camera`：

```powershell
ffmpeg `
    -f dshow `
    -list_options true `
    -i video="Integrated Camera"
```

记录摄像头支持的：

- 分辨率；
- 帧率；
- 像素或压缩格式，例如 `mjpeg`、`yuyv422`、`nv12`。

### 3. 在 Windows 本地预览

```powershell

ffplay -f dshow -i video="Integrated Camera"

//或者
ffplay `
    -f dshow `
    -pixel_format nv12 `
    -video_size 640x480 `
    -framerate 30 `
    -i video="Integrated Camera"
```

如果本地预览失败，应先解决 Windows 摄像头名称、权限或占用问题，再进行网络推流。

常见占用摄像头的程序包括：

- Windows 相机；
- 微信、QQ、Teams、Zoom；
- 浏览器中的视频网页；
- OBS；
- Windows Hello。

---

## 八、Windows 向 WSL 推送摄像头

视频使用 UDP 单播，不是广播。最近一次成功测试的目标地址是 `10.10.251.17:9000`，但该地址由 DHCP 动态分配，不能长期写死。

发送前，在 Windows PowerShell 中自动查询 WSL `eth0` 的当前地址：

```powershell
$WslIp = (wsl -d ubuntu-22.04 sh -lc "ip -4 -o addr show dev eth0 | cut -d' ' -f7 | cut -d/ -f1").Trim()
if (-not $WslIp) {
    throw "Unable to determine the WSL eth0 IPv4 address."
}
Write-Host "Current WSL IPv4: $WslIp"
```

先在 WSL 启动接收，再在 Windows 启动发送。

### 1. WSL 启动接收播放器

```bash
ffplay \
    -fflags nobuffer \
    -flags low_delay \
    -framedrop \
    "udp://0.0.0.0:9000?fifo_size=1000000&overrun_nonfatal=1"
```

WSLg 会在 Windows 桌面显示 `ffplay` 窗口。

### 2. Windows 开始推流

本机摄像头枚举结果已确认：`640x480` 只支持 `30fps`，不支持 `15fps`；输入像素格式支持 `NV12` 和 `YUYV422`。首先使用带宽较低的 `NV12 640x480@30fps`：

```powershell
ffmpeg `
    -f dshow `
    -rtbufsize 256M `
    -pixel_format nv12 `
    -video_size 640x480 `
    -framerate 30 `
    -i video="Integrated Camera" `
    -an `
    -c:v libx264 `
    -preset ultrafast `
    -tune zerolatency `
    -pix_fmt yuv420p `
    -g 30 `
    -f mpegts `
    "udp://${WslIp}:9000?pkt_size=1316"
```

参数说明：

- `-f dshow`：使用 Windows DirectShow 采集；
- `-rtbufsize 256M`：增加采集缓冲区；
- `-pixel_format nv12`：选择摄像头实际支持、带宽低于 `YUYV422` 的输入格式；
- `-video_size 640x480`：使用低分辨率开始测试；
- `-framerate 30`：使用该摄像头在 `640x480` 下实际支持的帧率；
- `-an`：不把摄像头音频加入视频流，麦克风继续使用 WSLg；
- `libx264`：编码为 H.264；
- `ultrafast` 和 `zerolatency`：优先降低延迟；
- `mpegts`：适合 UDP 传输；
- `pkt_size=1316`：降低 IP 分片概率。

成功后，可以提高到该摄像头同样明确支持的 `NV12 1280x720@30fps`：

```powershell
ffmpeg `
    -f dshow `
    -rtbufsize 512M `
    -pixel_format nv12 `
    -video_size 1280x720 `
    -framerate 30 `
    -i video="Integrated Camera" `
    -an `
    -c:v libx264 `
    -preset ultrafast `
    -tune zerolatency `
    -pix_fmt yuv420p `
    -g 30 `
    -f mpegts `
    "udp://${WslIp}:9000?pkt_size=1316"
```

不要使用 `640x480@15fps`，该组合不在本机摄像头的 DirectShow 能力列表中，会出现 `Could not set video options`。

### 3. 停止推流

Windows FFmpeg 窗口中按：

```text
q
```

或者按 `Ctrl+C`。

WSL 的 `ffplay` 中按：

```text
q
```

---

## 九、验证视频包是否到达 WSL

如果 WSL 没有画面，先不要立即判断为编码问题。在 WSL 中抓取 UDP 9000：

```bash
sudo tcpdump -ni eth0 'udp dst port 9000'
```

显示详细信息：

```bash
sudo tcpdump -ni eth0 -vv 'udp dst port 9000'
```

判断方式：

| 抓包结果                     | 说明                                            |
| ---------------------------- | ----------------------------------------------- |
| 持续看到大量 UDP 9000 数据包 | 网络正常，检查 FFmpeg 编码或 `ffplay` 参数      |
| 完全没有 UDP 9000            | 地址错误、Windows 未发送、路由或防火墙问题      |
| 只有少量包后停止             | FFmpeg 采集或编码失败，检查 Windows FFmpeg 输出 |

再次确认 WSL 地址：

```bash
ip -4 addr show dev eth0
```

如果地址与 Windows FFmpeg 当前使用的目标地址不同，必须重新查询 `$WslIp` 后再启动发送。Windows FFmpeg 的 UDP 发送日志只能说明数据已提交给本机网络栈，不能证明目标 WSL 已经收到。

---

## 十、防火墙配置

### Linux UFW

查看状态：

```bash
sudo ufw status
```

如果 UFW 已启用，可以仅允许 Windows 宿主机访问 UDP 9000：

```bash
sudo ufw allow from 10.10.20.107 to any port 9000 proto udp
```

如果 Windows 地址变化，需要更新规则。

不要为了测试长期关闭整个防火墙。

### Windows 防火墙

Windows FFmpeg 执行的是出站 UDP 连接，通常不需要添加入站规则。首次运行时如果 Windows 弹出网络访问提示，只允许当前可信的专用网络即可。

---

## 十一、供程序读取视频流

此方案不会在 WSL 中创建 `/dev/video0`。应用应读取网络流：

```text
udp://0.0.0.0:9000
```

### 使用 FFmpeg 验证解码

```bash
ffmpeg \
    -i "udp://0.0.0.0:9000?fifo_size=1000000&overrun_nonfatal=1" \
    -f null -
```

### 使用 OpenCV

安装：

```bash
sudo apt install -y python3-opencv
```

示例：

```python
import cv2

stream_url = "udp://0.0.0.0:9000"
capture = cv2.VideoCapture(stream_url, cv2.CAP_FFMPEG)

while True:
    ok, frame = capture.read()
    if not ok:
        print("Unable to read camera stream")
        break

    cv2.imshow("Windows Camera", frame)
    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

capture.release()
cv2.destroyAllWindows()
```

如果目标程序强制要求 `/dev/video0`，则不能直接使用本方案，需要额外配置虚拟 V4L2 设备，或者临时改用 `mirrored` 网络和 USB 直通。

---

## 十二、使用 OBS 处理画面

如果需要裁剪、旋转、叠加文字或组合多个画面，可以使用 OBS：

1. Windows 安装并启动 OBS；
2. 添加“视频采集设备”；
3. 选择 `Integrated Camera`；
4. 在 OBS 中完成裁剪、旋转或叠加；
5. 启动“虚拟摄像机”；
6. 使用 FFmpeg 列出 DirectShow 设备：

    ```powershell
    ffmpeg -list_devices true -f dshow -i dummy
    ```

7. 找到 OBS 虚拟摄像头的准确名称，通常类似：

    ```text
    OBS Virtual Camera
    ```

8. 将 FFmpeg 输入改为：

    ```powershell
    -i video="OBS Virtual Camera"
    ```

其他编码和 UDP 目标参数保持不变。

---

## 十三、隐私和安全注意事项

1. UDP MPEG-TS 默认不加密，也不认证。
2. 当前命令使用单播，只发送到 WSL 地址，不要改成局域网广播地址。
3. 不要将摄像头流发送到不可信网络或公网地址。
4. 使用企业、校园或公共 Wi-Fi 时，应确认网络安全策略。
5. 测试完成后及时停止 FFmpeg，避免摄像头持续工作。
6. Windows 摄像头指示灯亮起时，说明摄像头正在被应用使用。

---

## 十四、常见故障

### WSL 扬声器没有声音

```bash
pactl info
pactl list short sinks
speaker-test -D pulse -c 2 -t wav
```

确认 Windows 默认输出设备和音量设置。

### WSL 麦克风录音为空

```bash
pactl list short sources
```

检查 Windows 麦克风隐私权限、默认输入设备和输入音量。

### Windows FFmpeg 提示找不到摄像头

重新获取准确名称：

```powershell
ffmpeg -list_devices true -f dshow -i dummy
```

确保名称的空格、括号和大小写与输出一致。

### 摄像头被占用

关闭 Windows 相机、浏览器、会议软件和 OBS，然后重新执行 FFmpeg。

### FFmpeg 提示不支持分辨率或帧率

查看支持选项：

```powershell
ffmpeg `
    -f dshow `
    -list_options true `
    -i video="Integrated Camera"
```

选择输出中实际支持的组合。

### WSL 抓包能看到数据但没有画面

优先使用本文提供的 MPEG-TS 和 H.264 参数，并查看 `ffplay`、Windows FFmpeg 两端的错误输出。

### 视频延迟较大

可以：

- 使用 `-preset ultrafast`；
- 使用 `-tune zerolatency`；
- 降低分辨率；
- 降低帧率；
- 使用有线网络时通常会比拥挤 Wi-Fi 更稳定；
- 避免 Windows 和 WSL 同时运行高负载编码任务。

---

## 十五、完整执行顺序

### 第一次准备

WSL：

```bash
sudo apt update
sudo apt install -y \
    pulseaudio-utils \
    alsa-utils \
    libasound2-plugins \
    ffmpeg \
    tcpdump
```

Windows：

```powershell
winget install --exact --id Gyan.FFmpeg
```

### 每次使用扬声器

```bash
speaker-test -D pulse -c 2 -t wav
```

### 每次使用麦克风

```bash
arecord -D pulse -d 5 -f S16_LE -r 48000 -c 1 /tmp/microphone-test.wav
aplay -D pulse /tmp/microphone-test.wav
```

### 每次使用摄像头

1. WSL 查询当前地址：

    ```bash
    ip -4 addr show dev eth0
    ```

2. WSL 启动接收：

    ```bash
    ffplay \
        -fflags nobuffer \
        -flags low_delay \
        -framedrop \
        "udp://0.0.0.0:9000?fifo_size=1000000&overrun_nonfatal=1"
    ```

3. Windows PowerShell 自动查询当前 WSL 地址并开始推送：

    ```powershell
    $WslIp = (wsl -d ubuntu-22.04 sh -lc "ip -4 -o addr show dev eth0 | cut -d' ' -f7 | cut -d/ -f1").Trim()
    if (-not $WslIp) {
        throw "Unable to determine the WSL eth0 IPv4 address."
    }
    Write-Host "Streaming camera to WSL ${WslIp}:9000"

    ffmpeg `
        -f dshow `
        -rtbufsize 256M `
        -pixel_format nv12 `
        -video_size 640x480 `
        -framerate 30 `
        -i video="Integrated Camera" `
        -an `
        -c:v libx264 `
        -preset ultrafast `
        -tune zerolatency `
        -pix_fmt yuv420p `
        -g 30 `
        -f mpegts `
        "udp://${WslIp}:9000?pkt_size=1316"
    ```

4. 无画面时，WSL 抓包：

    ```bash
    sudo tcpdump -ni eth0 'udp dst port 9000'
    ```

完成以上配置后，WSL 可以通过 WSLg 使用 Windows 扬声器和默认麦克风，并通过桥接网络接收 Windows 摄像头的视频流。
