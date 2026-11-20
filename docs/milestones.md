# Development milestones and hardware reference

For the current M6.1 build and a first playback test, see the
[project README](../README.md).

Run shell and notebook examples from the repository root unless noted
otherwise.

## Milestone 1: single-oscillator audio overlay

This overlay implements one 32-bit DDS sine oscillator in the Zynq-7020 PL,
controlled by PS AXI4-Lite and transmitted to the onboard ADAU1761 as stereo
24-bit I2S. No external DAC is used.

### Architecture

- PS7 FCLK0 runs AXI4-Lite at 100 MHz.
- A Clock Wizard generates the ADAU1761's 10 MHz MCLK.
- A second Clock Wizard generates 49.154929 MHz. `i2s_tx` divides this by 16
  for 3.072183 MHz BCLK and by 1024 for 48.002860 kHz LRCLK.
- `dds_config_cdc` transfers FTW and enable atomically into the audio domain.
- `dds_sine` advances a 32-bit phase accumulator once per audio frame and uses
  its upper 10 bits to address a 1,024-entry, signed 24-bit block-ROM sine.
- The same sample is sent to left and right 32-bit I2S slots.

The roughly 60 ppm sample-rate offset is included in the Python FTW formula,
so a requested 440 Hz tone remains 440 Hz to DDS quantization accuracy.

### AXI4-Lite registers

The peripheral is mapped at `0x43c00000` in the generated block design.

| Offset | Access | Description |
|---:|:---:|---|
| `0x00` | R/W | CONTROL bit 0: oscillator enable |
| `0x04` | R/W | 32-bit frequency tuning word |
| `0x08` | R | STATUS bit 0: synchronized audio-domain enable |
| `0x0c` | R | Design ID, `0x4f524731` (`ORG1`) |

The tuning equation is:

```text
FTW = round(frequency_hz * 2^32 / 48002.8603515625)
```

### Source layout

- `rtl/dds_sine.v`: parameterized phase accumulator and block ROM
- `rtl/i2s_tx.v`: ADAU1761-compatible stereo I2S transmitter
- `rtl/axi_lite_dds_regs.v`: AXI4-Lite register bank
- `rtl/dds_config_cdc.v`: AXI-to-audio bundled-data crossing
- `rtl/organ_dds_i2s.v`: integration module used directly in IP Integrator
- `rtl/sine_1024x24.mem`: generated ROM initialization
- `vivado/create_project.tcl`: complete project/block-design/build script
- `vivado/pynq_z2_audio.xdc`: verified PYNQ-Z2 audio/I2C pins
- `pynq_organ.py`: PYNQ 3.1.1 driver and codec setup
- `board_test.py`: low-volume, two-second 440 Hz smoke test

### Build with Vivado 2026.1

```bash
source /path/to/Vivado/2026.1/settings64.sh
vivado -mode batch -source vivado/create_project.tcl -tclargs build
```

Outputs:

```text
build/organ_dds.bit
build/organ_dds.hwh
build/timing_summary.rpt
build/utilization.rpt
build/clocks.rpt
```

The top RTL is added to IP Integrator as a **module reference**, so no mutable
packaged-IP repository is needed. The `X_INTERFACE_INFO` attributes on
`organ_dds_i2s.v` cause Vivado to infer its `S_AXI` AXI4-Lite interface. The
Tcl script connects it with AXI automation and assigns `0x43c00000`.

If conventional packaged IP is required later, open the generated project,
select **Tools → Create and Package New IP → Package your current project**,
make `organ_dds_i2s` the top, verify `S_AXI` is identified as AXI4-Lite, and
add the resulting repository with `set_property ip_repo_paths ...`. This is
not required for this build.

If the PYNQ-Z2 board part is not installed, obtain the official board files and
point the build at the directory containing `tul.com.tw/pynq-z2/part0/1.0`:

```bash
export PYNQ_BOARD_REPO=/absolute/path/to/board_files
vivado -mode batch -source vivado/create_project.tcl -tclargs build
```

### Codec initialization

The custom overlay must be loaded before codec initialization because it
provides MCLK. `OrganOverlay` then constructs the installed
`pynq.lib.audio.AudioADAU1761` driver and calls `configure()` for:

- I2C1, address `0x3b`
- 10 MHz input PLL to the codec core clock
- codec I2S slave mode
- DAC, serial routing, power, and codec clock enables

PYNQ's `configure()` deliberately leaves playback muted until its software
`play()` routine runs. Since this design streams from PL, `OrganOverlay` makes
the four equivalent follow-up writes: left/right DAC mixer routing at `0x401c`
and `0x401e`, and left/right HP enable/volume at `0x4023` and `0x4024`.

### Board test

Copy the repository and the built overlay files to the board. Connect
headphones or powered speakers to HP+MIC, and start at low physical volume.

From the repository root over SSH:

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 board_test.py
'
```

Equivalent Jupyter code:

```python
from pathlib import Path
import time
from pynq_organ import OrganOverlay

root = Path.cwd()
organ = OrganOverlay(root / "build/organ_dds.bit", codec_volume=39)
organ.set_frequency(440.0)
organ.enable()
time.sleep(2.0)
organ.disable()
organ.mute_codec()
```

`codec_volume=39` is -18 dB, about 12.6% of nominal voltage. Raise it only one
step at a time; 43 is about -14 dB/20%, while 57 is nominal 0 dB.

### Expected measurements

With an oscilloscope referenced to board ground:

| Signal | Pin | Expected |
|---|---|---:|
| MCLK | U5 | 10.000 MHz |
| BCLK | R18 | approximately 3.072183 MHz |
| LRCLK | T17 | approximately 48.002860 kHz |
| SDATA | G18 | I2S data; active on both channels when enabled |

An audio analyzer, oscilloscope FFT, or phone tuner at HP OUT should report
approximately 440 Hz. Test 220, 440, and 880 Hz without reloading the overlay
to prove AXI FTW control. Disable must produce silence and STATUS must return
to zero after the clock-domain synchronizer latency.

### Troubleshooting

- Load `.bit` and `.hwh` with the same base name and from the same build.
- An ID mismatch means the wrong bitstream/HWH pair or AXI address is loaded.
- If codec configuration hangs, check for 10 MHz at U5; the PLL waits for lock.
- If AXI works but HP OUT is silent, verify `0x3b` on I2C1, HP+MIC seating,
  powered speakers/headphones, and playback mixer writes.
- If pitch is about 1.7% sharp, an older 100 MHz-divider I2S design was loaded;
  this overlay uses the separate 49.154929 MHz audio clock.
- If SDATA is present but distorted, verify the one-BCLK I2S delay, LRCLK-low
  left convention, and 24 data bits within each 32-bit slot.
- Raw SSH `python3` is not the PYNQ environment; source `pynq_venv.sh` and run
  as root because this image's FPGA/UIO nodes are root-only.

### Milestone-1 implementation results

Vivado 2026.1 implementation for `xc7z020clg400-1` reports:

- WNS: +3.132 ns
- WHS: +0.037 ns
- zero failing timing endpoints
- zero routed DRC errors
- 528 LUTs, 749 registers, one RAMB36, and two MMCMs

## Milestone 2: eight-voice wavetable organ

Milestone 2 leaves the verified codec, clock, and I2S path intact and replaces
the single sine DDS with eight phase accumulators feeding one shared wavetable
ROM and gain multiplier. Four 1,024-sample, signed 24-bit tables are included:

| Stop ID | Name | Harmonic mix |
|---:|---|---|
| 0 | `sine` | fundamental |
| 1 | `principal` | fundamental plus harmonics 2, 3, 4, 5, 6, and 8 |
| 2 | `flute` | fundamental with weak harmonics 2, 3, and 4 |
| 3 | `reed` | fundamental plus strong harmonics 2 through 8 |

The engine uses 24 audio-clock cycles per frame to process all eight voices;
about 1,024 cycles are available. Each voice has an independent 32-bit phase
accumulator, FTW, stop selector, Q1.15 gain, gate, and phase-retrigger command.
The saturating mixer produces one mono 24-bit value for both I2S channels.

### Milestone-2 AXI4-Lite registers

The module is mapped at `0x43c00000`. Voice fields are staged in the AXI
domain and transferred together through an acknowledged one-entry mailbox, so
frequency, stop, gain, and gate cannot tear across the clock boundary.

| Offset | Access | Description |
|---:|:---:|---|
| `0x00` | R/W | GLOBAL_CONTROL bit 0: master enable |
| `0x04` | R/W | VOICE_SELECT bits 2:0 |
| `0x08` | R/W | VOICE_CONTROL: bit 0 gate, bit 1 retrigger, bits 9:8 stop ID |
| `0x0c` | R/W | VOICE_FTW: 32-bit frequency tuning word |
| `0x10` | R/W | VOICE_GAIN bits 15:0: unsigned Q1.15 |
| `0x14` | W | COMMIT bit 0: submit staged command; ignored while busy |
| `0x18` | R | STATUS bits 7:0 active voice mask, bit 31 mailbox busy |
| `0x1c` | R | Design ID `0x4f524732` (`ORG2`) |

The FTW formula is unchanged:

```text
FTW = round(frequency_hz * 2^32 / 48002.8603515625)
```

### Milestone-2 files and build

- `rtl/wavetable_voice_engine.v`: time-multiplexed oscillators and mixer
- `rtl/organ_wavetable_rom.v`: synchronous four-table ROM
- `rtl/voice_command_cdc.v`: acknowledged AXI-to-audio command mailbox
- `rtl/axi_lite_m2_regs.v`: staged voice register bank
- `rtl/organ_m2_i2s.v`: Milestone-2 integration module
- `scripts/generate_organ_wavetables.py`: reproducible table generator
- `pynq_organ_m2.py`: PYNQ driver and codec initialization
- `board_test_m2.py`: four-stop audition and eight-voice smoke test
- `vivado/create_m2_project.tcl`: complete Vivado project/build script

Generate the ROM and build the overlay with Vivado 2026.1:

```bash
python3 scripts/generate_organ_wavetables.py
source /path/to/Vivado/2026.1/settings64.sh
vivado -mode batch -source vivado/create_m2_project.tcl -tclargs build
```

Outputs are `build/organ_m2.bit`, `build/organ_m2.hwh`, and the three
`build/m2_*.rpt` sign-off reports.

### Python API and board test

Start with headphones or powered speakers at low physical volume. The complete
automated smoke test auditions all four stops at 440 Hz, then plays an
eight-note chord for two seconds:

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 board_test_m2.py
'
```

Minimal Jupyter use:

```python
from pathlib import Path
import time
from pynq_organ_m2 import OrganM2Overlay

root = Path.cwd()
organ = OrganM2Overlay(root / "build/organ_m2.bit", codec_volume=39)
organ.note_on(0, 440.0, stop="principal", gain=0.10)
time.sleep(2.0)
organ.note_off(0)
organ.close()
```

Keep the sum of simultaneous voice gains conservative. For eight voices,
`gain=0.05` to `0.06` per voice is a safe starting range. Wavetables contain
fixed harmonics, so keep reed fundamentals below about 3 kHz to prevent its
eighth harmonic crossing the 24 kHz Nyquist limit.

### Milestone-2 implementation results

Vivado 2026.1 implementation reports WNS +3.244 ns, WHS +0.047 ns, zero
failing endpoints, zero routed DRC errors, 732 logic LUTs, 1,512 registers,
three RAMB36 blocks, one DSP48, and two MMCMs. The live board test completed
with active mask `0xff` for all eight voices and `0x00` after note-off.

## Milestone 3: 128-voice polyphony and note allocation

Milestone 3 expands the independent phase, FTW, gain, stop, and gate state to
128 voices. The synthesis datapath remains time-multiplexed: a single ROM port
and DSP48 process one voice in three audio-clock cycles. All voices therefore
complete in 384 of the 1,024 clocks available per audio frame.

Voice allocation runs in Python. Free voices are assigned from 0 upward. When
all 128 voices are occupied, the oldest active note is replaced deterministically.
The application may use conventional MIDI note/channel keys or arbitrary
application note IDs with explicit frequencies.

### Milestone-3 AXI4-Lite registers

The peripheral remains at `0x43c00000`.

| Offset | Access | Description |
|---:|:---:|---|
| `0x00` | R/W | GLOBAL_CONTROL bit 0: master enable |
| `0x04` | R/W | VOICE_SELECT bits 6:0 |
| `0x08` | R/W | VOICE_CONTROL: bit 0 gate, bit 1 retrigger, bits 9:8 stop ID |
| `0x0c` | R/W | VOICE_FTW |
| `0x10` | R/W | VOICE_GAIN bits 15:0, unsigned Q1.15 |
| `0x14` | W | COMMIT bit 0; ignored while the mailbox is busy |
| `0x18` | R | STATUS bit 31: mailbox busy |
| `0x1c` | R | Design ID `0x4f524733` (`ORG3`) |
| `0x20` | R | Active mask, voices 31:0 |
| `0x24` | R | Active mask, voices 63:32 |
| `0x28` | R | Active mask, voices 95:64 |
| `0x2c` | R | Active mask, voices 127:96 |
| `0x30` | R | Voice capacity, 128 |

### Milestone-3 files and build

- `rtl/wavetable_voice_engine_128.v`: 128-voice engine and saturating mixer
- `rtl/voice_command_cdc_m3.v`: seven-bit voice command mailbox
- `rtl/axi_lite_m3_regs.v`: control registers and four activity words
- `rtl/organ_m3_i2s.v`: clock-domain and I2S integration
- `pynq_organ_m3.py`: PYNQ driver and oldest-note allocator
- `board_test_m3.py`: full-capacity, stealing, note-off, and audio test
- `vivado/create_m3_project.tcl`: reproducible Vivado 2026.1 build

```bash
source /path/to/Vivado/2026.1/settings64.sh
vivado -mode batch -source vivado/create_m3_project.tcl -tclargs build
```

The outputs are `build/organ_m3.bit`, `build/organ_m3.hwh`, and the
`build/m3_*.rpt` reports.

### Python note API

```python
from pathlib import Path
import time
from pynq_organ_m3 import OrganM3Overlay

root = Path.cwd()
organ = OrganM3Overlay(root / "build/organ_m3.bit", codec_volume=39)

# MIDI note 60 is middle C. The return value is the allocated PL voice.
voice = organ.note_on(60, channel=0, stop="principal", gain=0.02)
time.sleep(1.0)
organ.note_off(60, channel=0)

# Explicit frequency with an arbitrary application-level note ID.
voice = organ.note_on_hz("manual-A4", 440.0, stop="flute", gain=0.02)
time.sleep(1.0)
organ.note_off_hz("manual-A4")
organ.close()
```

For worst-case 128-note operation, start around `gain=0.0025` per voice. A
larger gain such as `0.02` is suitable for a single note but will clip if used
unchanged across a large chord. The hardware mixer saturates instead of
wrapping, but gain staging should prevent saturation during normal playing.

Run the complete board test with:

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 board_test_m3.py
'
```

Expected output includes four `0xffffffff` active masks, an active count of
128, voice 0 selected for the 129th-note stealing test, and four zero masks
after `all_notes_off()`.

### Milestone-3 implementation results

Vivado 2026.1 reports WNS +1.433 ns, WHS +0.044 ns, zero failing timing
endpoints, and zero routed DRC errors. The design uses 3,848 logic LUTs,
11,759 registers, three RAMB36 blocks, one DSP48, and two MMCMs. The live-board
test activated all 128 voices, verified oldest-note stealing, and released all
voices successfully.

## Milestone 4: real-time MIDI-file playback

`midi_player_m4.py` pre-parses a Standard MIDI File into a flat tuple of
absolute-time note and controller events. During playback it schedules against
`time.monotonic()` absolute deadlines; processing latency therefore does not
accumulate as tempo drift. Playback can run synchronously, in a stoppable
background thread, or for a bounded excerpt using `--start-seconds` and
`--max-seconds`. Seeking reconstructs the MIDI note and controller state at
the starting timestamp and starts sounding held notes there.

The requested Mutopia BWV 565 file has been validated as format 1 with four
tracks, 384 ticks per beat, one tempo event, 7,302 note events, a duration of
572 seconds, and score peak polyphony of nine. Its six program-change messages
are reported and ignored. It contains no control-change messages, though the
player supports sustain (CC64), volume (CC7), expression (CC11), all-sound-off
(CC120), reset-controllers (CC121), and all-notes-off (CC123).

### Install and download

On the PYNQ board:

```bash
sudo bash -c '
source /etc/profile.d/pynq_venv.sh
python3 -m pip install -r requirements.txt
'

curl --fail --location --output ToccataFugue.mid \
  https://www.mutopiaproject.org/ftp/BachJS/BWV565/ToccataFugue/ToccataFugue.mid
```

The expected SHA-256 digest is:

```text
1aabd00967aded08d6633482c211af46f679d97f01cfeaca43c83a59dfeeeb6b
```

Parse without programming the FPGA:

```bash
python3 midi_player_m4.py ToccataFugue.mid --dry-run
```

### Safe opening test and complete playback

Connect headphones or powered speakers to HP OUT. The following command plays
the first 30 score-seconds at the original tempo, then releases every voice and
mutes the codec:

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 midi_player_m4.py ToccataFugue.mid \
  --bitfile build/organ_m3.bit \
  --stop principal --gain 0.03 --codec-volume 39 \
  --max-seconds 30 --stats-interval 1
'
```

Remove `--max-seconds 30` to play the complete 9-minute-32-second file. The
opening should contain the recognizable paired-octave gesture, fast descending
runs, and large punctuating chords. For this file, `peak` should remain near 9,
`stolen` should remain 0, and `on_err`, `off_err`, and `ctl_err` should remain 0.

M3 reports `clip=n/a`. Its mixer saturates, and lowering `--gain` reduces the
risk of saturation. The hardware clip flag is available on M5 and later.

### Jupyter playback and stop()

```python
from pathlib import Path
from pynq_organ_m3 import OrganM3Overlay
from midi_player_m4 import OrganMidiPlayer, prepare_midi_file

root = Path.cwd()
organ = OrganM3Overlay(root / "build/organ_m3.bit", codec_volume=39)
prepared = prepare_midi_file(root / "ToccataFugue.mid")
player = OrganMidiPlayer(organ, prepared, stop="principal", voice_gain=0.03)
player.play_async()                 # Background playback at real-time speed.
```

In a later notebook cell:

```python
player.stop()
player.join()
organ.close()
```

`stop()` wakes the scheduler promptly, and the playback `finally` block calls
`all_notes_off()` even after interruption or an event error.

### Statistics and troubleshooting

- `polyphony` is the current software-allocated voice count; `peak` is the
  highest count observed during the run.
- `stolen` increments whenever a 129th simultaneous note replaces the oldest
  active note. A file exceeding capacity will show `peak=128` with `stolen>0`.
- `errors` combines note-on, note-off, and controller failures. The final line
  prints the three counters separately.
- `late_events` counts events dispatched more than 10 ms after their absolute
  deadline. `max_lateness_ms` shows the worst delay.

If playback timing is uneven, close CPU-heavy notebooks, avoid running other
MMIO clients, and check `late_events`. Absolute scheduling catches up after a
late chord instead of permanently shifting the remainder of the piece. Keep
`--speed 1.0` for real-time playback.

If notes are missing, confirm that `mido` imports in the sourced PYNQ virtual
environment, verify the MIDI SHA-256 digest, inspect the printed event/error
counts, and check `stolen`. MIDI `note_on` with velocity zero is intentionally
handled as note-off. Unsupported messages are counted in `ignored` but do not
stop playback.

If a note sticks, press Ctrl-C once or call `player.stop()`. Both normal and
exceptional exits issue `all_notes_off()`. A process killed with `SIGKILL`
cannot run cleanup; in that case rerun the player or reload the overlay to
reset all PL gates.

Milestone-4 tests are in `tests/test_midi_player_m4.py` and cover the exact
BWV 565 parse, sustain-pedal release, final cleanup, and asynchronous stop.

## Milestone 5: four-line Feedback Delay Network

M5 inserts a stereo Feedback Delay Network between the verified 128-voice
mixer and I2S transmitter. Four prime-length 24-bit delays use 1493, 1601,
1747, and 1867 samples (about 31.1–38.9 ms). An orthonormal 4x4 Hadamard matrix
mixes the returns, and Q1.15 feedback and wet controls are committed through a
second acknowledged clock-domain mailbox. Disabling the FDN gives the original
dry path and invalidates old delay contents before the next enable.

The new registers are appended without changing the voice-control offsets:

| Offset | Access | Description |
|---:|:---:|---|
| `0x34` | R/W | Reverb control: bit 0 enable, bit 1 clear sticky clip |
| `0x38` | R/W | Feedback coefficient, unsigned Q1.15; hardware limit 0.99 |
| `0x3c` | R/W | Wet coefficient, unsigned Q1.15 |
| `0x40` | W | Reverb configuration commit, bit 0 |
| `0x44` | R | Reverb status: bit 31 busy, bit 0 sticky clip |

Important files are `rtl/fdn_reverb.v`, `rtl/reverb_config_cdc.v`,
`rtl/axi_lite_m5_regs.v`, `rtl/organ_m5_i2s.v`, `pynq_organ_m5.py`,
`board_test_m5.py`, and `vivado/create_m5_project.tcl`.

Build and smoke-test:

```bash
source /path/to/Vivado/2026.1/settings64.sh
vivado -mode batch -source vivado/create_m5_project.tcl -tclargs build

sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 board_test_m5.py
'
```

Play BWV 565 through the FDN:

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 midi_player_m4.py ToccataFugue.mid \
  --overlay m5 --bitfile build/organ_m5.bit \
  --stop principal --gain 0.03 --codec-volume 39 \
  --feedback 0.90 --wet 0.25
'
```

Start with feedback 0.88–0.92 and wet 0.20–0.30. Reduce note gain or wet mix
if `clip=YES`; clear the sticky flag with `organ.clear_clip()` after adjusting.

Vivado 2026.1 reports WNS +0.492 ns, WHS +0.021 ns, zero failing endpoints,
and zero routed DRC errors. M5 uses 4,752 logic LUTs, 12,124 registers, nine
BRAM tiles, eight DSP48s, and two MMCMs. The live dry/wet comparison completed
through the three-second decay interval with `clip=False`.

## Milestone 6: damped FDN and sparse early reflections

M6 preserves the M3/M5 voice and reverb offsets, then appends acoustic controls.
Each Hadamard feedback path contains a Q1.15 one-pole filter implementing
`y += alpha * (x - y)`. One DSP48 is time-shared across the four filters and
all eight early-reflection reads. The early history is a 2048x24 simple
dual-port BRAM and is strictly feedforward: it is mixed into the wet stereo
output but never written into an FDN delay line.

Left early taps are 528, 816, 1104, and 1392 samples (11, 17, 23, and 29 ms).
Right taps are 576, 864, 1152, and 1440 samples (12, 18, 24, and 30 ms). The
four gain registers are shared by the corresponding left/right tap pair. The
defaults are gains 0.60/0.40/0.30/0.20 and damping coefficients
0.52/0.50/0.48/0.46.

### M6 AXI-Lite additions

All numeric acoustic coefficients use unsigned Q1.15. Existing offsets
`0x00` through `0x44` retain their M5 meanings.

| Offset | Access | Description |
|---:|:---:|---|
| `0x34` | R/W | Reverb control: bit 0 FDN enable, bit 1 clear sticky clip, bit 2 early-reflection enable |
| `0x38` | R/W | FDN feedback, hardware-clamped to 0.99 |
| `0x3c` | R/W | Wet mix |
| `0x40` | W | Atomically commit all staged acoustic parameters, bit 0 |
| `0x44` | R | Status: bit 31 mailbox busy, bit 0 sticky clip |
| `0x48` | R/W | Damping alpha 0 in bits 15:0; alpha 1 in bits 31:16 |
| `0x4c` | R/W | Damping alpha 2 in bits 15:0; alpha 3 in bits 31:16 |
| `0x50` | R/W | Early gains 0 and 1, packed low/high halfwords |
| `0x54` | R/W | Early gains 2 and 3, packed low/high halfwords |

The RTL clamps every alpha to 0.1--0.9. The Python driver validates alpha,
gain, feedback, and wet ranges before issuing the acknowledged configuration
commit. `pynq_organ_m6.py` retains the complete M3 allocator API and adds
`set/get_feedback()`, `set/get_wet_mix()`, `set/get_damping_alpha()`,
`set/get_early_reflection_gains()`, and early-reflection/reverb enable accessors.

Build and run the non-subjective board smoke test:

```bash
source /path/to/Vivado/2026.1/settings64.sh
vivado -mode batch -source vivado/create_m6_project.tcl -tclargs build

sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 board_test_m6.py
'
```

Run the complete objective BWV 565 validation with:

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 board_full_bwv_m6.py
'
```

The runner checks the expected 7,302 events and 572-second duration, uses the
monotonic absolute-time scheduler, and fails on any sticky clip indication,
voice steal, or MIDI dispatch error.

The complete real-time board run finished with peak polyphony 9, zero voice
steals, zero note-on/note-off/controller errors, zero events more than 10 ms
late, maximum lateness 5.751201 ms, zero clipping events, and final
`clip=False`.

For a larger-space preset, the following M6 command has also been checked on
the 30-second opening (do not select M5, which bypasses M6 damping and early
reflections):

```bash
sudo bash -c '
source /etc/profile.d/xrt_setup.sh 2>/dev/null || true
source /etc/profile.d/pynq_venv.sh
python3 midi_player_m4.py ToccataFugue.mid \
  --overlay m6 --bitfile build/organ_m6.bit \
  --stop principal --gain 0.045 --codec-volume 50 \
  --feedback 0.955 --wet 0.38 \
  --damping-alpha 0.52,0.50,0.48,0.46 \
  --early-gains 0.60,0.40,0.30,0.20 --max-seconds 30
'
```

That opening test reached seven voices with `clip=False`, no dispatch errors,
and 2.932 ms maximum lateness. `board_stress_grand_m6.py` then held nine
full-velocity voices for five seconds and observed a six-second tail; its
sticky clip result was also false. A DJI MIC MINI capture at 48 kHz/24-bit
measured -21.88 dBFS peak and -36.62 dBFS RMS, with no capture clipping.

Vivado 2026.1 post-route results are WNS +2.811 ns and WHS +0.027 ns with zero
failing timing endpoints. M6 uses 5,474 logic LUTs (5,535 total LUTs), 12,888
flip-flops, 10.5 BRAM tiles, nine DSP48s, and two MMCMs. Compared with M5 this
is +722 logic LUTs, +764 flip-flops, +1.5 BRAM tiles, and +1 DSP48. The
early-reflection BRAM template avoids a 1,024-LUT distributed-memory mapping.

## Milestone 6.1: voice envelopes

M6.1 adds gain ramps at note transitions ahead of the FDN. Each of the 128
voices now ramps its effective gain on note-on and note-off, continues phase
advancement during release, and remains present in the hardware active mask
until the release reaches zero. Typical attack is 5--8 ms and the measured
release at gain 0.045 is 30.555 ms. The allocator excludes releasing hardware
slots when an idle slot is available, and overlapping identical MIDI notes are
reference-counted without redundant phase retriggers.

The M6 AXI-Lite acoustic register map remains unchanged. M6.1 uses design ID
`0x4f523631` (`OR61`) and the PYNQ driver `pynq_organ_m61.py`.

Follow the [M6.1 build and playback instructions](../README.md) for the host
build, board setup, and example MIDI command.

Vivado 2026.1 post-route results are WNS +2.411 ns and WHS +0.025 ns with zero
failing endpoints. M6.1 uses 6,927 LUTs, 14,898 flip-flops, 10.5 BRAM tiles,
and nine DSP48s. The envelope adds no DSP or BRAM relative to M6. The board
test confirms release-aware allocation (`release_voice=0`, `new_voice=1`) and
`clip=False`.
