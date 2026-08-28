# Win95 clean FPGA acceptance run

Run start: 2026-08-21 22:51:22 UTC.  Exact desktop result: approximately
23:07 UTC.

- non-fast source-matched image SHA-256:
  `0247cb33f5397fc3b42f003af5fa4cabbed9396c5cfd04bd9e712259a951957e`
- pristine pre-run disk SHA-256:
  `877ae318beb3dc784f966fefaa148af2446abc7beb52eb50d288e3225f5995f8`
- board probe SHA-256:
  `e9d08dd339935b82761c065202701f87b48b779210d441d86b299f5550827d1d`
- measured core clock: 2.929714 MHz
- no input injection, cache flush, guest patch, freeze, comparator, or trace
  index write was used

Exact source-controlled result:

```text
samples=1500 transitions=954
top_last_ar=001021c0:1500
top_eip=000001e6:744, 000001e5:727, 00000138:2, 00000162:2, 00000193:2, 0000feb0:2, 000089c2:1, 00000170:1
lowmem EBDA_seg=9fc0 IVT13=024c0122 IVT19=05b0002f tick=0017133d->00171407
DESKTOP SIGNATURE PRESENT
```

Read-only corroboration after success:

```text
vga_text printable=0/2000 nonblank=0/2000 nonzero_attrs=0/2000
elapsed=10.000087s cycles=29297397 retired=571624
clock=2.929714MHz ipc=0.019511 io_cycles=0 irq_ack=134
axi rd_beats=0 ar_hs=0 b_hs=3082
```

The blank B8000 page corroborates graphics mode. The VMM last-AR and paired
System-VM idle EIPs are the established automated desktop proxy. Offsets
`0x1a0/0x1b0` are deliberately omitted from semantic evidence because the
external debug block hard-codes stale FSM numbers.
