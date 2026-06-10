# PS / RTL peripheral split — fit the KV260 by offloading slow devices to the A53

The KV260 PL is routing/congestion-bound, so not every SoC peripheral can live in
the fabric. This framework lets **a config file choose, per peripheral, whether it
runs in RTL (PL) or as a C model on the PS A53** — without changing any per-record
verification guarantee.

## How it works

```
fpga/periph_split.config   ──gen_periph_split.py──►  +VEN_<DEV>_PS  (RTL build flags)
   (rtl | ps per device)                             ps_periph_table.inc (C dispatch)
```

* A device marked `rtl` is synthesized into `ventium_soc` as its `ven_*.sv` module
  (the default — the SoC is byte-identical to the all-RTL build when nothing is `ps`).
* A device marked `ps` is **not** instantiated in RTL. `ventium_soc` decodes its I/O
  port range into `io_ps_sel`, and forwards the access on the `io_ps_*` bridge to
  `ven_soc_axil` → the A53, which runs the matching C model in this directory. The
  core **stalls in `S_IO` until `io_ps_ack`**, so the C model's latency cannot perturb
  the instruction stream — only the *value* matters.

The SAME `<model>.c` compiles into the **A53 firmware** (gcc, C) and into **`tb_soc`**
(g++, C++) for verification. It is a 1:1 behavioural port of the `ven_*.sv` RTL.

## Verification — "C model == RTL == qemu"

Each PS C model is proven bit-exact with the existing per-record gate, just with the
device served by the C model instead of the RTL module:

```sh
bash verif/soc/run-soc-ps-cosim-gate.sh uart   # build +VEN_UART_PS, run psocuart,
                                                # diff vs qemu-system -> EQUIVALENT
```

EQUIVALENT here means the C model is byte-identical to qemu over every retired
instruction — the same bar the RTL module met. (`run-soc-uart-ps-gate.sh` is the
no-arg wrapper the soc-gate aggregate runs.)

## Adding a peripheral to PS

1. Port `rtl/soc/ven_<dev>.sv`'s register logic to `sw/ps_periph/<model>.c`
   (provide `<model>_new()` returning a `ven_periph_t*`; see `ven_uart16550.c`).
2. Register it in `tb_soc.cpp`'s `ps_devs` (port range → ctor) and add the
   `port range -> model` row to `PERIPH` in `gen_periph_split.py`.
3. Flip the device to `ps` in `fpga/periph_split.config`.
4. `bash verif/soc/run-soc-ps-cosim-gate.sh <dev>` → EQUIVALENT.

## Status

| device | placement | C model | cosim |
|--------|-----------|---------|-------|
| uart   | **ps**    | ✅ `ven_uart16550.c` | ✅ EQUIVALENT (110) |
| pic/pit/port92/ide/dma/dma2 | rtl | — (bus-critical, stay in PL) | — |
| rtc/i8042/vga/acpipm/fdc | rtl (→ps) | pending C model | — |

The framework + the io-bridge seam are verified end-to-end on the UART; the
remaining slow peripherals move to PS as their C models land (mechanical ports,
each proven by the same cosim gate).
