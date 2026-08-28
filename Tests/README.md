# 测试

没有摄像机也能验证这个客户端。做法是把真实抓包用一个自写的 Python RTSP
服务器回放，让 App 的源码跑真的 socket、真的解包、真的渲染器。

## 为什么不是 XCTest

这些驱动是把 App 的源文件和一个 `main.swift` 一起 `swiftc` 出来的命令行程序。
端到端场景要起一个真的服务器子进程、连真的 socket、按真的时间配速，
挂在 Xcode test target 下面反而更难跑也更难看结果。

代价是 `Tests/` 不在 Xcode 工程里（`project.pbxproj` 里 `Tests` 出现 0 次）。
这是故意的：工程用的是 `fileSystemSynchronizedGroups`，同步范围限定在
`path = RTSPClient`。要是 `Tests/` 被扫进 App target，五个驱动各自的
顶层 `main` 会撞成一堆符号冲突。

## 跑

```sh
Tests/build.sh      # 先编，五个驱动都出到 Tests/.build/
Tests/unit.sh       # 单元测试，期望 217/217
Tests/matrix.sh     # 26 个会话层场景，一张表
Tests/player.sh     # 3 个播放器层场景，三条恢复路径
Tests/latency.sh    # 延迟 A/B，和改动前的 250ms 预缓冲对照
Tests/docs.sh       # 文档里的 Mermaid 图能不能渲染（不用先 build.sh）
```

从仓库任何目录敲都行，脚本自己定位。

## 目录

| 路径 | 是什么 |
| --- | --- |
| `Server/server.py` | 最小 RTSP 服务器，回放抓包。20 多个开关模拟各种固件行为 |
| `Unit/` | 单元测试：SDP、解包、时间轴、URL 与基址、历史记录、设备档案 |
| `SessionDriver/` | 会话层驱动，直接开 `RTSPSession` |
| `PlayerDriver/` | 播放器层驱动，走 `RTSPPlayer`，能覆盖换传输和退避重连 |
| `LatencyDriver/` | 延迟测量，不需要服务器 |
| `Fixtures/` | 抓包、SDP、逐帧尺寸的 ground truth |
| `Fixtures/Capture/` | 合成抓包的脚本（需要 ffmpeg），和从真机抓包里抽 RTP 的 `extract_rtp.py`（需要 tshark） |
| `MermaidCheck/` | 校验文档里的 Mermaid 图，用 VS Code 自带那份解析器 |

`Tests/.build/` 是产物（二进制、服务器日志、对照实验的补丁副本），已被
`.gitignore` 管住 —— 无前导斜杠的模式在任意层级匹配。

## 驱动必须从 Fixtures 里跑

抓包是按相对路径读的。跑错目录不会报错，只会静默少掉一批用例：
单元测试从别处跑是 `151/157 通过`，从 `Fixtures/` 跑是 `217/217` ——
60 个用例读不到 `video.sdp` 就直接 return 了，看起来还是「全部通过」。
所以用上面那几个脚本，别直接敲 `.build/` 里的二进制。
（`server.py` 例外，它按 `__file__` 定位，从哪跑都行。）

## 两台真机的差异都用开关模拟

服务器默认是 Oraimo 那台的行为。记录仪那台加 `--dashcam`：

| 开关 | 模拟的固件行为 |
| --- | --- |
| `--oraimo` | 回放 Oraimo 抓包；SETUP 应答不给 `server_port` / `source` |
| `--dashcam` | 回放记录仪抓包；DESCRIBE 带 `Content-Base`，control 是 `track1`，Session 不带 `timeout`，无音频轨 |
| `--no-content-base` | 只跟 `--dashcam` 一起用，把那个头去掉当对照 |

`--dashcam` 下三个 URI 是**故意各不相同**的，这是它的全部意义：

```
请求 URL       rtsp://127.0.0.1:8554/livestream/1/
Content-Base   rtsp://127.0.0.1/00000000/          ← 路径不同，而且没有端口
media control  track1                              ← 相对值
SETUP 该发的    rtsp://127.0.0.1/00000000/track1
```

按请求 URL 去拼会得到 `/livestream/1/track1`，服务器直接回 404。
（真机那台是用 `rtsp://192.168.1.254:554/xxx.mov` 收 DESCRIBE 的，
路径和端口都不一样 —— 测试台只复刻「三者互不相同」这个结构，不复刻字面值。）

基址里没有端口是安全的，因为连接在 DESCRIBE 之前就建好了，基址只当字符串
拼接用，客户端不会拿它重新拨号。真要有人写出重新拨号的回归，症状是连
`127.0.0.1:554` 失败 —— 测试台听的是 8554。

**判据是服务器校验 Request-URI。** `check_dashcam_base()` 对 SETUP 和 PLAY
都查一遍，路径里没有 `/00000000/` 就回 `404 Stream Not Found`。真机就是
这么挑的。不这么做，客户端拼错基址照样能播，这个场景等于白测。

## 为什么还留着音频抓包

App 已经完全不放音频了，但 `audio.rtp` / `audio_pcma.rtp` 必须留着 ——
它们测的是画面和统计的正确性，不是音频功能。

有固件不管客户端 SETUP 了什么，照样把音频往视频那一路发。客户端靠 SDP 里
声明的音频负载类型把这些包挡在 H.264 解包器外面。挡不住的后果分两种，
都实测过（同一段字节流，只把保护关掉作对照）：

- **PCMA**：裸样本字节被当成 H.264 NAL 解，凭空造出假帧。
  126 帧 / 6 关键帧 / 0 乱序 → **151 / 12 / 22**，另外丢包从 0 变成三位数。
- **AAC**：负载头两字节是 `00 10`，NAL type 0 是 unspecified，解包器直接丢，
  所以帧数不变（127/6/0）；但音频的 RTP 序号会污染丢包统计，丢包从 0 变成
  三位数，界面上会把一条完好的流显示成「丢包 800 多」。

**丢包那一列不要当定值核对。** 两轨交错的时机每次跑都不一样，实测
562 / 586 / 853 / 859 都出现过。判据是「从 0 变成三位数」。
帧数、关键帧、乱序这三列是稳的，回归看它们。

矩阵里 `mismux_*` 三行压的是保护生效，`ctl_aac` / `ctl_pcma` 是把保护
关掉的对照。

## 对照组预期就是坏的

`ctl_aac` 和 `ctl_pcma` 用 `--hide-audio-sdp` 让 SDP 不声明音频轨，
于是 `audioPayloadType` 是 -1，保护自动失效。**这两行通过才是问题** ——
说明矩阵测不出它本该测出的缺陷。

`AAC` 那一行尤其要看丢包列。它的帧数和通过的行一模一样（127/6/0），
只有丢包从 0 变成三位数。表里没有丢包这一列的时候，这个对照组看起来
和通过完全一样，等于白测。

`ctl_nobase` 是记录仪那台的对照：`--dashcam --no-content-base` 让服务器
不发 `Content-Base`，别的一个字节不改。客户端于是只能按请求 URL 拼
`control`，拼出 `/livestream/1/track1`，服务器回 `404 Stream Not Found`。
**这一行能出画就是问题** —— 说明 `dashcam` 那两行不是靠基址解析过的，
碰巧对上而已。

延迟测量同理：`latency_old` 是把预缓冲常量从 80ms 改回 250ms 编出来的，
补丁打在 `.build/patched/` 的副本上，绝不碰仓库源文件。`build.sh` 打完补丁
会 `grep` 验证，因为常量写法一变 `sed` 就静默失配，两个二进制会变得
一模一样 —— 对照实验无声失效，还看起来「通过」。

## 基线

矩阵（默认 5 秒窗口）里所有真实场景都该是 **丢包=0**。几行需要解释的：

| ID | 读数 | 为什么是对的 |
| --- | --- | --- |
| `chunk` | 5 帧 | 服务器每小块 sleep 0.5ms，1 字节一块约 2000 B/s。这一行已经单独给了 `--long`（9 秒），仍然只传得完这么多 —— 不是回归 |
| `h265` | 乱序 48 | 该流有 72 个 B 帧，解码顺序里 PTS 本就不单调 |
| `noidr` | 0～2 帧 / 0 关键帧 | 视频里没有 IDR，本来就出不了画。帧数取决于窗口结束时凑齐了几个非 IDR 分片，实测 0 和 2 都出现过 —— 判据是**关键帧=0** |
| `nodata` | 0 帧 / 0 字节 | 握手全成功，PLAY 之后一个字节都不发 |
| `udpreply` | 报错 | 服务器既不给 UDP 也不给交织，客户端必须判为不支持 |
| `drop` | 报错 | 中途断流，会话层看到连接关闭就结束 —— 重连在播放器层 |
| `dashcam` | 86 帧 / 6 关键帧 | 记录仪抓包的真实回放，848x480。帧数就是抓包里的 marker 数 |
| `dashcam_tcp` | 86 帧 / 6 关键帧 | 同一段字节流走交织，读数必须和 UDP 那行**逐字节一致**（431719 字节） |
| `ctl_nobase` | 0 帧 / `404` | 对照组，见上一节。出画就是回归 |

`Tests/unit.sh` 期望 217/217。长窗口（`--long`，9 秒）下 H.264 是
150 帧 / 6 关键帧 / 0 乱序，H.265 是 100 / 4 / 48 且 `format_changes=1`
（`video265.sdp` 没有 sprop-vps/sps/pps，参数集只在流内，首帧建 format 是对的）。

## 三条恢复路径要分开看

`player.sh` 的三个场景压的是三条不同的路，判据是 `state_path` 和
`reconnect_attempts` **一起**看，单看重连次数分不出来：

| 场景 | state_path | reconnect_attempts |
| --- | --- | --- |
| UDP 黑洞 | `connecting>buffering>connecting>buffering>playing` | `-` |
| UDP 正常 | `connecting>buffering>playing` | `-` |
| 中途断流 | 反复 `playing>connecting>buffering>playing` | `1` |

前两条的重连次数都是 `-`，因为换传输重来不走退避重连那条路。
第三条结束时 `reconnect_attempt=0`（重连成功后会归零），
所以次数必须在轮询里当场记下来 —— 跑完再读什么都看不到。

采样状态要「观察 + 轮询」两条路并用。纯轮询不行：换交织那次重连里
`connecting → buffering` 在本机只有两三毫秒，10ms 采样实测漏过一次，
路径看起来就像根本没重连过（所以退到了 2ms）。纯观察也不稳：
`withObservationTracking` 的 onChange 在写入前触发，得延一拍才读到新值，
同一轮里连续两次变更仍可能只看到最后一个。两条路谁先看到算谁的，
`Trace` 自己去重。

## 延迟

`latency.sh` 量的是预缓冲摊进端到端延迟的那一段。原理：`MediaRenderer`
把时基设成「首帧 PTS − preroll」，所以任何一帧送进渲染器的那一刻，
它的 PTS 都比当前播放时刻晚 preroll。这个差值可以直接量。

当前读数：

| 流 | 现行（自适应） | 对照（固定 250ms） |
| --- | --- | --- |
| H.264（无 B 帧） | 76.4ms，late 0 | 246.6ms，late 0 |
| H.265（乱序 120ms） | 128.5ms，late 0 | 188.2ms，late 0 |

**`late_frames` 必须是 0。** 它统计的是送进渲染器时 PTS 已经过去的帧 ——
说明预缓冲装不下这条流的乱序幅度，画面会顿。固定 80ms 在 H.265 上
曾经是 85 帧里 40 帧迟到（最多迟 44.7ms），这就是预缓冲改成自适应的原因：
从 80ms 起步，遇到迟到帧按欠量往上长、只长不缩（乱序深度是流的属性，
缩回去只会再迟一次）。

这个数只是客户端渲染器的贡献。真机上的端到端延迟还包含摄像机编码、
网络传输和解码，那部分量不到。

## 重新采集抓包

需要 ffmpeg。抓包格式是「4 字节大端长度 + 包体」重复。

```sh
cd Tests/Fixtures && python3 Capture/capture.py      # H.264 + AAC
cd Tests/Fixtures && python3 Capture/capture265.py   # H.265（带 B 帧）
cd Tests/Fixtures && python3 Capture/capture_pcma.py # PCMA
```

`ffprobe` 的逐帧 packet size 就是 ground truth，存在
`expected_video_sizes.txt` / `expected_265_sizes.txt`，单元测试拿它
和解包出的 AVCC 长度逐帧比对。

`video_noidr.rtp` 是 `video.rtp` 把 IDR 的 NAL 类型从 5 改写成 1 得到的，
没有采集脚本。

另外两个来自真机抓包，用 `Capture/extract_rtp.py` 从 `Captures/` 里抽：

| 抓包 | 抓包文件 | 抽出的 fixture |
| --- | --- | --- |
| Oraimo 摄像机 | `Captures/Oraimo/Oraimo.pcap` | `oraimo_video.rtp` |
| 记录仪 | `Captures/Dashcam/RTSP.pcapng` | `dashcam_video.rtp`（366 包，PT 96） |

第三个参数是 tshark 显示过滤器（默认 `rtp`）：

```sh
cd Tests/Fixtures && python3 Capture/extract_rtp.py \
    ../../Captures/Dashcam/RTSP.pcapng dashcam_video.rtp \
    'rtp && ip.src==192.168.1.254'
```

这条命令复现出的 `dashcam_video.rtp` 和仓库里那份**逐字节一致**
（366 包，负载类型 96，序号 29942..30307），可以直接核对。

**过滤要带方向。** 抓包里两个方向都有包，客户端会往同一个端口发几个空包
打 NAT 洞，混进来会被当成畸形 RTP。所以过滤器要写 `ip.src==<设备IP>`。
抽错方向的症状是负载类型那一栏出现多个值 —— 脚本跑完会打出来，当场就能看见。

用的是读取过滤 `-Y` 而不是抓包过滤 `-f`：RTP 要靠 RTSP 的 SETUP 才认得出来，
得跑完整解析。脚本自己找 tshark（`PATH` 上没有就退到 Wireshark.app 里那个，
Wireshark 4.x 不再装 `/usr/bin/tshark` 软链接）。

**按抓包顺序输出，不排序。** 乱序本身就是要测的东西，排一遍就没了。

**ffmpeg 8.1 的 `-rtsp_flags listen` 不能当服务器用**，它仍然向外拨号，
直接报 Connection refused。这就是服务器得自己写的原因。

## 文档里的图

`docs.sh` 把仓库里所有 markdown 的 Mermaid 块喂给真正的解析器过一遍。
起因是交互图提交出去之后 VS Code 预览直接报解析错误：**分号在 Mermaid 里是
语句分隔符**，写进消息文本就把语句截断了，解析器把后半截当成新的参与者名，
找不到箭头就报到 NEWLINE。这类错误肉眼扫不出来。

用的是 VS Code 自带那份 mermaid（`markdown-language-features` 里的
`mermaid.core-*.js`），不是 npm 装的。理由是报错的就是它 —— 编辑器预览失败时
抛的那串 token 列表，和这里抛的逐字一致，所以它说过就是真的能渲染。
npm 上的版本可能新可能旧，过了不代表编辑器里能过；而且这个项目不引第三方依赖。

隔离过两个隐患各自的影响：

| 写法 | parse | 说明 |
| --- | --- | --- |
| `RTP/AVP;unicast;client_port=` | ✗ | 分号截断语句，这是真凶 |
| `SETUP <control>` | ✓ | 语法上没问题，但渲染时会被当未知 HTML 标签消掉 |

所以精确的头部原文放在图后面的代码块里，图里只写叙述。代码块不参与
Mermaid 解析，信息不丢。

**这项检查只做 parse，不做 render。** 渲染要真实 DOM 去量文字宽度，在 node
里立不起来；而且为了绕开无 DOM 环境，校验器把 bundle 副本里的 `sanitize`
短路成了 `String` —— 正好把消毒环节跳过了。上面表格第二行那种渲染期问题，
这里查不出来，得靠预览确认。

找不到 VS Code 或找不到 node ≥ 18 时脚本报「跳过」并退 0。
**跳过不等于通过** —— 这台机器上没法验，和验过了是两件事。

## 踩过的坑

- **陈旧的服务器进程会伪造「通过」**。旧 `server.py` 还占着 8554 时，
  新进程直接退出，命令行参数根本没生效，测试却一切正常。所以
  `scenario.sh` 三件事都要确认：端口先是空的、新进程活着、
  跑完日志里出现了该参数的标记。少一件结论就不可信。
- `pkill -f "python3 server.py"` 一个也匹配不上。Homebrew 的 python3 是
  符号链接，进程命令行里是解析后的绝对路径。要匹配 `server.py`。
- 两段抓包各自有随机起始时间戳，交错发送前要按各自首包归零，
  否则一整轨会排到另一轨后面。
- 轨内必须保持抓包顺序。H.265 有 B 帧，RTP 时间戳本身不单调，
  按时间戳排序会打乱 RTP 序号，客户端会误报大量丢包。
  用「时间戳的运行最大值」作排序键 + 稳定排序。
  `LatencyDriver` 配速也用同一个键，否则节奏会乱。
- 沙盒验证必须放进真正的 `.app` bundle（要有 `CFBundleIdentifier`）。
  ad-hoc 签名的裸可执行文件会被直接 SIGTRAP 杀掉（exit 133），
  和网络权限无关。
- `RTSPPlayer` 内部全是 `DispatchQueue.main.async`，驱动必须跑 main run loop。
  它可以无窗口跑：macOS 上 `AVSampleBufferDisplayLayer` 不需要窗口。
- 驱动给 `StreamHistoryStore` 注入临时 UserDefaults suite，跑完
  `removePersistentDomain` —— 别污染用户真实的播放历史。
- **`build.sh` 不会自动收新目录。** Xcode 那边靠
  `fileSystemSynchronizedGroups` 自动扫，这里是一个目录一条显式 glob。
  加了 `RTSPClient/Devices/` 之后编译照样过，但 `RTSPPlayer.defaultAddress`
  从那里取值，漏掉就是链接期才报错。App 编得过不代表驱动编得过。
- 服务器按轨名认音频（`trackID=1` / `track1`）。记录仪那台的**视频**轨
  正好也叫 `track1`，所以那个判断必须先排除 `--dashcam`。撞上了在交织模式
  下看不出来（两轨走同一条 TCP），UDP 模式下是零帧。

