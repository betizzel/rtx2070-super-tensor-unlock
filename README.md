# RTX 2070 SUPER (TU104) full-rate FP16→FP32 tensor cores

**First reported run of [nlzy/turing-unlock](https://github.com/nlzy/turing-unlock) on a TU104 card.**
That module lists `10de:1e84` (RTX 2070 SUPER) as "not tested". On one card it
worked unmodified at commit `1d379b7`: FP16-input / FP32-accumulate tensor-core
throughput went from half rate to full rate, and LLM prompt processing got
**1.76× faster**.

This repository holds the measurements, logs and the small tools we used.
It contains **no firmware, no compiled module and no exploit code**. The unlock
itself is entirely the upstream work credited below.

> **Risk.** This runs a firmware exploit on the GPU before the driver loads. A
> failure can hang the GPU until a full power-off. Nothing is flashed, and the
> unlock is lost on every reboot, but it is still untested on any other
> TU104 board, VBIOS or host. One card and one host are not a compatibility
> guarantee.

## Results

| Measurement | Locked (stock) | Unlocked | Change |
|---|---:|---:|---:|
| NVIDIA RM rate getter `fmla32` / `imla4` | 1 / 1 (half) | **0 / 0 (full)** | |
| FP16→FP32 `mma.sync` issue rate | 35.6–39.2 TFLOPS | **65.0–73.3 TFLOPS** | ~1.8–2× |
| FP16→FP16 `mma.sync` (control, never limited) | 64.7–78.2 TFLOPS | 64.8–65.4 TFLOPS | clock-dependent |
| Ratio FP32-acc / FP16-acc | **0.50**–0.55 | **1.00**–1.12 | 2× |
| FP32-accumulate correctness vs CPU (32,768 outputs, K=4096) | | worst rel. err 8.1e-7, **PASS** | |
| Strata prompt reading, 19.8K-token code prompt | 241.7 tok/s (81.9 s) | **426.3 tok/s (46.4 s)** | **1.76×** |
| Strata generation (decode) | ~32–39 tok/s † | 30.3–32.6 tok/s | none expected |

The ratio is the clean metric. Absolute TFLOPS move with boost clocks, which
were not pinned (215 W stock power limit). The control column shows that
spread. Raw outputs are in [`results/`](results/).

† We did not run the decode benchmark before unlocking. That figure comes from
our earlier Strata measurements on the same card and config. Decode is limited
by memory/PCIe bandwidth, not tensor issue rate, so no change is expected. The
measured unlocked values are consistent with that.

### Why the LLM number matters

[Strata](https://github.com/Niko1221/Strata) with `STRATA_BF16_TC=1` runs its
BF16 projections on Turing's FP16 tensor cores **with FP32 accumulation**,
which is exactly the path GeForce halves. Prompt processing is mostly those
GEMMs, so it nearly doubled. Token generation stayed the same.

Model: `qwen3.8-flash-next-coder-iq1_m`. Strata engine: 0.1.47 prebuilt CUDA 13.
Config: 128K context, KV streaming, speculative decoding. The benchmarks were
run greedy (temperature 0).

## Test system

| | |
|---|---|
| GPU | Gigabyte RTX 2070 SUPER, `10de:1e84`, subsystem `1458:400d`, TU104 rev a1, 8 GB, 40 SMs |
| VBIOS | `90.04.76.80.2E` |
| Board / CPU | ASUS ROG STRIX B550-F GAMING WIFI II (BIOS 2604), Ryzen 5 5600X |
| OS | Arch Linux, kernel `7.2.11-arch1-1`, GRUB, mkinitcpio (systemd hook) |
| Driver | NVIDIA open `615.78.08` (unmodified) |
| Unlock | nlzy/turing-unlock `1d379b7`, firmware generated from pinned NVIDIA `610.43.03` inputs (hashes matched the upstream manifest) |
| Platform | Secure Boot off, IOMMU on (translated), GPU is the only GPU and drives the display, PCIe FLR supported |

### What the module saw on this card

From [`logs/unlock-boot.log`](logs/unlock-boot.log):

- entry: `plm=0xffffff8f ss0=0x4001 ss1=0x6 wpr2=0x0:0x1ffffe00`. The card was
  in a clean pre-driver state after a **warm** reboot, so no FLR was needed.
- FB `0x200000000` (8 GiB), FRTS `0x1ffe00000`
- native FWSEC parsed from this card's VBIOS: descriptor `0x3c0201`, V2 image
  `0x9e00` bytes, interface v1, mapper v3
- FWSEC FRTS latched WPR2 `0x1ffee00:0x1ffe000`
- the TU102 Booter + V67 payload ran on SEC2. Result: `plm=0xffffffff`,
  `ss0=0x88888888 ss1=0x8 readout=0x0`, `TU102 FEAT UNLOCKED`

Why the TU102 path also fits TU104: in NVIDIA 610.43.03's generated HAL
(`g_kernel_gsp_nvoc.c`), TU102, TU104 and TU106 share the Booter-load
ucode (`kgspGetBinArchiveBooterLoadUcode_TU102`), the FWSEC execution, and
the WPR-meta population. The per-card values (FB size, VGA workspace, FWSEC
image) are read from the card itself, not hardcoded.

## The one Xid in the log

The kernel log of the unlock boot contains one `Xid 31`. It is **ours, not the
unlock's**. Our first `mma_validate` build tried to allocate ~400 MB while the
Strata engine held most of the 8 GB. `cudaMalloc` failed, and the unchecked
pointers faulted (`name=mma_validate ... faulted @ 0x0_000e0000`). The test now
checks every CUDA call and uses less memory. Its later runs passed and logged
no further Xid. The driver and Strata ran normally throughout.

## Reproducing

All scripts are in [`tools/`](tools/). Read them first. They hardcode this card's
PCI address `0000:07:00.0` and ID `10de:1e84`, so change them for your system.

1. `tools/prepare.sh`: clones nlzy/turing-unlock at the tested commit, downloads
   and hash-checks the NVIDIA inputs, generates the firmware, builds the module
   for your running kernel and writes the hash files. No root, no GPU access.
2. Measure stock first, with the driver loaded: `tools/verify.sh` (the RM
   getter is `read_sm_rates.py` from
   [gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada); point
   `RM_RATES` at it). Optionally run `tools/strata_bench.py prefill` and
   `decode` against your own OpenAI-compatible endpoint.
3. `sudo tools/oneshot-root.sh` installs the module and firmware, builds a
   **separate** initramfs, adds a non-default GRUB entry with
   `turing_unlock.targets=<bdf>`, and arms it for **one** boot with
   `grub-reboot`. The boot after that is stock again. `--remove` undoes it.
   - On a btrfs root without `btrfs-progs`, mkinitcpio's `fsck` hook makes every
     build exit 1. The script drops that hook from its own config only.
4. Reboot, then run `tools/verify.sh` and compare.
5. Only after a clean trial: `tools/persist.sh`, as your user. It installs the
   upstream Arch packages (DKMS, so the module is rebuilt on each kernel
   update), rebuilds the normal initramfs and adds the parameter to
   `GRUB_CMDLINE_LINUX_DEFAULT`. `--remove` undoes it.

## Status and limits

- One card, one host. The unlock trial boot, everything in `results/`, and the
  `persist.sh` install were all done on 2026-10-25. **A boot from the
  persistent install has not been verified yet.**
- No long-duration stability, thermal or power study. The stock 215 W power
  limit was left in place, and power draw under load was not logged.
- Only the FP16→FP32 path was measured. IMLA4 also reads full rate, but integer
  tensor throughput was not tested.
- Correctness: one synthetic check (FP16 inputs, FP32 accumulation, against
  a double-precision CPU reference) plus normal LLM output. This is not an
  exhaustive numerical validation.

## Credits

The unlock is entirely prior work:
[nlzy/turing-unlock](https://github.com/nlzy/turing-unlock) (Turing adaptation of)
[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock), built on the CMP
unlock research ([xrip/cmp50hx-unlock](https://github.com/xrip/cmp50hx-unlock),
[PZH1gdmu/CMP40HX-Unlock](https://github.com/PZH1gdmu/CMP40HX-Unlock)), Jon Pry's
V67 canary research, and NVIDIA's open driver interfaces.
[KohakUnlock](https://github.com/KohakuBlueleaf/KohakUnlock) and
[haohervchb/Turing-unlock](https://github.com/haohervchb/Turing-unlock) were the
TU102 references we started from.
[gpu-unlock-ada](https://github.com/JustAResearcher/gpu-unlock-ada) supplied
the RM rate getter.

## License

Our tools and text: MIT (see [LICENSE](LICENSE)). Upstream projects keep their
own licenses. NVIDIA firmware is not included and is subject to NVIDIA's terms.
