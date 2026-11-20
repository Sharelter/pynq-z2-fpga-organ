# PYNQ-Z2 FPGA 管风琴

[English](README.md) | 简体中文

这是一个支持 128 声部复音的波表管风琴，可以播放标准 MIDI 文件，声音经 PYNQ-Z2 板载
ADAU1761 编解码器从耳机接口输出。Arm 处理器上的 Python 程序负责调度 MIDI 事件和分配声部。
FPGA 负责合成音频、添加立体声混响，并通过 I²S 将音频送入编解码器。

- 四种音栓：`sine`（正弦）、`principal`（主音栓）、`flute`（长笛音栓）和 `reed`（簧管音栓）。
- 每个声部都有起音和释音包络，分配新声部时会优先使用已完成释音的空闲声部。
- 四条延迟线的反馈延迟网络（FDN），支持频率相关的阻尼、立体声早期反射，以及通过 AXI4-Lite 在运行时调整参数。
- 按 MIDI 文件的速度播放，可截取片段，并报告复音数、声部抢占次数、调度延迟、MIDI 错误和数字削波。

## 硬件和工具

| 项目 | 已验证的配置 |
|---|---|
| 开发板 | TUL PYNQ-Z2，Zynq-7020（`xc7z020clg400-1`） |
| FPGA 构建 | Vivado 2026.1，需安装 Zynq-7000 器件支持 |
| 板端运行环境 | PYNQ 3.1.1、Python 3.10 |
| 音频 | 板载 ADAU1761，约 48.003 kHz，24 位立体声 I²S，每个声道时隙宽 32 位 |

## 构建 M6.1 Overlay

在开发机的仓库根目录执行。如果 Vivado 无法找到 `tul.com.tw:pynq-z2:part0:1.0`，请安装
PYNQ-Z2 板卡文件，或将 `PYNQ_BOARD_REPO` 设为解压后的板卡定义所在目录。
参见 [PYNQ 板卡文件安装说明（英文）](https://pynq.readthedocs.io/en/v3.1/overlay_design_methodology/board_settings.html)。

```bash
source /path/to/Vivado/2026.1/settings64.sh
# 如需使用外部板卡文件目录：
# export PYNQ_BOARD_REPO=/path/to/board-files
vivado -mode batch -source vivado/create_m61_project.tcl -tclargs build
```

构建使用仓库自带的 ROM 初始化文件，生成 `build/organ_m61.bit`、`build/organ_m61.hwh` 和
`build/m61_*.rpt`。`.bit` 和 `.hwh` 文件应来自同一次构建，放在同一目录且文件主名一致。

## 播放 MIDI 文件

将仓库源文件和构建生成的 `.bit`、`.hwh` 复制到 PYNQ-Z2，两个构建产物都放在 `build/` 下。
将耳机或有源音箱接到板上的 HP+MIC 接口，将实际输出音量调低后，从板端仓库根目录执行：

```bash
curl --fail --location --output ToccataFugue.mid \
  https://www.mutopiaproject.org/ftp/BachJS/BWV565/ToccataFugue/ToccataFugue.mid

sudo bash -c '
  if [ -r /etc/profile.d/xrt_setup.sh ]; then source /etc/profile.d/xrt_setup.sh; fi
  source /etc/profile.d/pynq_venv.sh
  python3 -m pip install -r requirements.txt &&
  python3 midi_player_m4.py ToccataFugue.mid \
    --overlay m61 --bitfile build/organ_m61.bit \
    --stop principal --gain 0.025 --codec-volume 39 \
    --feedback 0.90 --wet 0.25 --start-seconds 90 --max-seconds 20
'
```

示例使用 [Mutopia Project](https://www.mutopiaproject.org/ftp/BachJS/BWV565/ToccataFugue/ToccataFugue-a4.pdf)
提供的 BWV 565，也可以换成自己的 MIDI 文件。`--start-seconds` 和 `--max-seconds` 分别指定曲目中的
起始位置和片段时长，单位均为秒。省略这两个选项即可播放全曲，按 `Ctrl+C` 停止。
如果出现 `clip=YES`，请降低 `--gain`。`--codec-volume` 调节数字混音后的耳机音量。

## 验证

Python 测试使用模拟声部分配器，可以在没有 Vivado 和 PYNQ 开发板的环境中运行。
仓库根目录存在 `ToccataFugue.mid` 时，还会校验 BWV 565 的 MIDI 解析结果。

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
```

在板端，使用与播放示例相同的 PYNQ 环境和权限运行 `python3 board_test_m61.py`。
脚本检查释音时长、活动声部位掩码、释音期间的声部分配以及置位后保持的削波标志。
测试通过时会打印 `M61_ENVELOPE PASS`。

M6.1 的布局布线结果满足时序要求，**WNS 为 +2.411 ns**，**WHS 为 +0.025 ns**，资源占用为
**6,927 个 LUT**、**14,898 个触发器**、**10.5 个 BRAM 块**和 **9 个 DSP48**。
M6.1 在板上播放《耶稣，人类仰望的喜悦》的 20 秒片段，峰值为 11 个已分配声部，声部抢占、
MIDI 错误和数字削波均为零。BWV 565 的 572 秒全曲测试在 M6 上完成。

## 源码导览

- [`rtl/`](rtl/)：FPGA 声部引擎、I²S 发送器和混响模块。
- [`vivado/`](vivado/)：批处理构建脚本和 PYNQ-Z2 引脚约束。
- [`pynq_organ_m61.py`](pynq_organ_m61.py)：M6.1 驱动。
- [`midi_player_m4.py`](midi_player_m4.py)：MIDI 解析和播放调度。
- [`scripts/`](scripts/)：ROM 生成脚本。
- [开发里程碑和硬件参考（英文）](docs/milestones.md)：寄存器映射、时钟配置，以及早期版本的构建和验证结果。

## 许可证

项目原创源码和文档采用 [MIT 许可证](LICENSE)。第三方工具、依赖和单独下载的 MIDI 文件遵循各自的条款。
