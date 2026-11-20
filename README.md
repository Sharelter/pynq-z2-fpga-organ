# FPGA Pipe Organ for PYNQ-Z2

English | [简体中文](README.zh-CN.md)

A 128-voice wavetable pipe organ that plays Standard MIDI Files through the
PYNQ-Z2's onboard ADAU1761 codec and headphone output. Python on the Arm
processor schedules MIDI events and allocates voices. The FPGA generates the
audio, applies stereo reverb, and feeds the codec over I²S.

- Four stops: `sine`, `principal`, `flute`, and `reed`.
- Per-voice attack and release envelopes with release-aware voice allocation.
- Four-delay feedback delay network (FDN) with frequency-dependent damping,
  stereo early reflections, and runtime controls over AXI4-Lite.
- MIDI playback at the file's tempo, optional excerpt playback, and reporting
  for polyphony, voice steals, timing, MIDI errors, and digital clipping.

## Hardware and tools

| Component | Tested setup |
|---|---|
| Board | TUL PYNQ-Z2, Zynq-7020 (`xc7z020clg400-1`) |
| FPGA build | Vivado 2026.1 with Zynq-7000 device support |
| Board runtime | PYNQ 3.1.1, Python 3.10 |
| Audio | Onboard ADAU1761, approximately 48.003 kHz, 24-bit stereo I²S in 32-bit slots |

## Build the M6.1 overlay

Run from the repository root on the development machine. If Vivado cannot
resolve `tul.com.tw:pynq-z2:part0:1.0`, install the PYNQ-Z2 board files or set
`PYNQ_BOARD_REPO` to the directory containing the unpacked board definitions.
See the [PYNQ board-file instructions](https://pynq.readthedocs.io/en/v3.1/overlay_design_methodology/board_settings.html).

```bash
source /path/to/Vivado/2026.1/settings64.sh
# If you need an external board-file repository:
# export PYNQ_BOARD_REPO=/path/to/board-files
vivado -mode batch -source vivado/create_m61_project.tcl -tclargs build
```

The build uses the included ROM initialization files and writes
`build/organ_m61.bit`, `build/organ_m61.hwh`, and `build/m61_*.rpt`. Keep the
overlay files from the same build together with the same basename.

## Play a MIDI file

Copy the repository source and the built `.bit` and `.hwh` to the board,
keeping the overlay pair under `build/`. On the PYNQ-Z2, connect headphones
or powered speakers to HP+MIC and start with low physical volume. Run the
following from the board's repository root:

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

The BWV 565 example comes from the [Mutopia Project](https://www.mutopiaproject.org/ftp/BachJS/BWV565/ToccataFugue/ToccataFugue-a4.pdf).
You can substitute your own MIDI file. Time offsets are in score seconds.
Omit both excerpt options to play the complete file. Press `Ctrl+C` to stop.
If playback reports `clip=YES`, lower `--gain`. `--codec-volume` adjusts the
headphone level after the digital mix.

## Verify the build

The Python tests use a simulated voice allocator and run without Vivado or
a PYNQ board. The exact BWV 565 fixture test runs when `ToccataFugue.mid` is
present in the repository root.

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python -m unittest discover -s tests -v
```

On the board, run `python3 board_test_m61.py` under the same PYNQ environment
and privileges as the playback example. It checks the release time, active
voice masks, release-aware allocation, and the sticky clip flag. A successful
run prints `M61_ENVELOPE PASS`.

The recorded M6.1 implementation closed timing at **+2.411 ns WNS** and
**+0.025 ns WHS**, using **6,927 LUTs**, **14,898 flip-flops**, **10.5 BRAM
tiles**, and **9 DSP48s**. A 20-second M6.1 board playback of *Jesu, Joy of
Man's Desiring* reached 11 allocated voices with zero steals, MIDI errors,
or digital clipping. The full 572-second BWV 565 run was measured on M6.

## Source guide

- [`rtl/`](rtl/) contains the FPGA voice engines, I²S transmitter, and reverb.
- [`vivado/`](vivado/) contains batch build scripts and PYNQ-Z2 pin constraints.
- [`pynq_organ_m61.py`](pynq_organ_m61.py) is the M6.1 driver.
- [`midi_player_m4.py`](midi_player_m4.py) is the MIDI parser and scheduler.
- [`scripts/`](scripts/) contains the ROM generators.
- [Development milestones and hardware reference](docs/milestones.md) contains
  the register maps, clocking details, and earlier build and validation results.

## License

The original project source and documentation are available under the
[MIT License](LICENSE). Third-party tools, dependencies, and separately
downloaded MIDI files are covered by their respective terms.
