#!/usr/bin/env python3
"""Execute the real plain-cosim I/O service lambda against repeated settle calls.

No RTL, synthesized circuit, guest memory or architectural trace is replaced.
This leaf tests diagnostic accounting at the device's once-only service point.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=Path(__file__).with_name('tb_main.cpp'))
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    assert __debug__
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert Path(os.environ['TMPDIR']).resolve()==scratch
    assert args.out.resolve().is_relative_to(scratch)
    args.out.mkdir()
    original=args.source.read_text()
    start=original.index('    bool     io_pending_in = false;')
    end=original.index('\n    };',original.index('    auto service_io = [&]() {',start))+7
    fragment=original[start:end]
    assert fragment.count('auto service_io = [&]()')==1
    source=r'''
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
namespace ventium { struct DevIn { uint32_t port,size; uint64_t val; std::string region; }; }
struct Ports { uint32_t io_req=0,io_we=0,io_addr=0,io_size=1,io_wdata=0,io_rdata=0,io_ack=0; };
int main() {
  Ports ports; auto *top=&ports;
  struct { bool cosim=true; } args;
  bool cosim_mode=true;
  std::vector<ventium::DevIn> devins;
  size_t devin_idx=0;
ACTUAL_FRAGMENT
  auto expect=[&](bool ok,const char* message) {
    if(!ok) { std::fprintf(stderr,"IO-SERVICE-FAIL: %s count=%llu\n",message,
                          (unsigned long long)io_out_count); std::exit(1); }
  };
  unsigned checks=0;
  for(unsigned width: {1u,2u,4u}) {
    for(unsigned port: {0x80u,0x3f8u,0xf4u}) {
      top->io_req=0; service_io();
      top->io_req=1; top->io_we=1; top->io_addr=port; top->io_size=width;
      top->io_wdata=0x42;
      uint64_t before=io_out_count;
      for(int phase=0;phase<12;phase++) {
        service_io();
        expect(io_out_count==before+1,"one write across repeated settle/held request calls");
        expect(top->io_ack==1,"serviced request stays acknowledged");
        checks+=2;
      }
      if(port==0xf4) { expect(io_exit && io_exit_al==0x42,"debug exit consumed once"); checks++; }
      top->io_req=0; service_io();
      expect(io_out_count==before+1 && top->io_ack==0,"deasserted request must not count again");
      checks++;
      top->io_req=1; top->io_we=0;
      for(int phase=0;phase<4;phase++) service_io();
      expect(io_out_count==before+1,"IN must not increment OUT counter"); checks++;
    }
  }
  expect(io_out_count==9,"exact total distinct OUT episodes"); checks++;
  std::printf("IO-SERVICE-COUNT-OK checks=%u writes=%llu\n",checks,(unsigned long long)io_out_count);
}
'''.replace('ACTUAL_FRAGMENT',fragment)
    (args.out/'check.cpp').write_text(source)
    command=['g++','-std=c++17','-O0','-o',str(args.out/'check'),str(args.out/'check.cpp')]
    with (args.out/'build.log').open('x') as log:
        compile=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=30)
    status=None
    if compile.returncode==0:
        with (args.out/'native.log').open('x') as log:
            run=subprocess.run([str(args.out/'check')],stdout=log,stderr=subprocess.STDOUT,timeout=30)
        status=run.returncode
    receipt=dict(source=str(args.source.resolve()),sha256=hashlib.sha256(original.encode()).hexdigest(),
                 build_exit=compile.returncode,native_exit=status,inputs_unchanged=args.source.read_text()==original,
                 rtl_acceptance=False,gameplay_ipc=None)
    (args.out/'result.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
    return 0 if compile.returncode==0 and status==0 and receipt['inputs_unchanged'] else 1


if __name__=='__main__':
    raise SystemExit(main())
