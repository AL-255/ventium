#!/usr/bin/env python3
"""Exercise the production mouse checkpoint functions, without a DUT build."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'ao486-sim/ven/sim_ven.cpp'


def checkpoint_source():
    source = SOURCE.read_text()
    start = source.index('static void mouse_checkpoint_save(VerilatedSave &os) {')
    end = source.index('static void checkpoint_config(', start)
    return source[start:end]


FIXTURE = r'''
#include <cassert>
#include <cstdint>
#include <cstring>
#include <deque>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
static bool g_mouse_en=true;
enum { MS_IDLE, MS_RECV, MS_SEND };
static int g_ms_state=0,g_ms_pclkout=1,g_ms_edge=0,g_ms_sub=0;
static uint8_t g_ms_rxbyte=0;
static bool g_ms_expect_param=false,g_ms_streaming=false;
static std::deque<uint8_t> g_ms_txq;
static int g_ms_txbits[11]{},g_ms_txphase=-1,g_ms_txsub=0,g_ms_txgap=0;
[[noreturn]] static void checkpoint_fail(const char* reason) {
    throw std::runtime_error(reason);
}
struct VerilatedSave {
    std::vector<uint8_t> bytes;
    void write(const void* data,size_t count) {
        const auto* p=static_cast<const uint8_t*>(data);
        bytes.insert(bytes.end(),p,p+count);
    }
};
struct VerilatedRestore {
    const std::vector<uint8_t>& bytes;
    size_t offset=0;
    void read(void* data,size_t count) {
        if(offset>bytes.size() || count>bytes.size()-offset)
            checkpoint_fail("truncated fixture input");
        std::memcpy(data,bytes.data()+offset,count);
        offset+=count;
    }
};
@PRODUCTION@
static VerilatedSave capture(int state=MS_IDLE,unsigned queued=3) {
    g_mouse_en=true;g_ms_state=state;g_ms_pclkout=0;
    g_ms_edge=state==MS_IDLE?11:7;g_ms_sub=47;g_ms_rxbyte=0x96;
    g_ms_expect_param=true;g_ms_streaming=true;
    g_ms_txphase=state==MS_SEND?10:-1;g_ms_txsub=47;g_ms_txgap=80;
    for(int i=0;i<11;++i)g_ms_txbits[i]=i&1;
    g_ms_txq.clear();
    for(unsigned i=0;i<queued;++i)g_ms_txq.push_back(uint8_t(i));
    VerilatedSave saved;mouse_checkpoint_save(saved);
    return saved;
}
static void mutate32(std::vector<uint8_t>& bytes,size_t offset,int32_t value) {
    assert(offset+4<=bytes.size());
    std::memcpy(bytes.data()+offset,&value,4);
}
static bool rejected(std::vector<uint8_t> bytes,bool enabled=true) {
    g_mouse_en=enabled;
    try {VerilatedRestore restored{bytes};mouse_checkpoint_load(restored);}
    catch(const std::runtime_error&) {return true;}
    return false;
}
int main(int argc,char** argv) {
    assert(argc==2);const std::string mode=argv[1];
    if(mode=="roundtrip") {
        for(int state:{MS_IDLE,MS_RECV,MS_SEND}) {
            for(unsigned queued:{0u,1u,3u,1024u}) {
                const auto before=capture(state,queued);
                assert(before.bytes.size()==92+queued);
                g_ms_state=99;g_ms_txq.clear();g_ms_rxbyte=0;g_ms_txphase=99;
                VerilatedRestore input{before.bytes};mouse_checkpoint_load(input);
                VerilatedSave after;mouse_checkpoint_save(after);
                assert(input.offset==before.bytes.size());
                assert(after.bytes==before.bytes);
            }
        }
    } else if(mode=="disabled") {
        auto before=capture();g_mouse_en=false;
        VerilatedSave off;mouse_checkpoint_save(off);
        VerilatedRestore input{off.bytes};mouse_checkpoint_load(input);
        VerilatedSave after;mouse_checkpoint_save(after);
        assert(after.bytes==off.bytes);
        assert(rejected(before.bytes,false));
        assert(rejected(off.bytes,true));
    } else if(mode=="bounds") {
        const auto good=capture().bytes;
        auto bad=good;mutate32(bad,0,2);assert(rejected(bad));
        for(const auto& pair:std::vector<std::pair<unsigned,int32_t>>{
            {0,-1},{0,3},{1,-1},{1,2},{2,-1},{2,12},{3,-1},{3,48},
            {4,-1},{4,256},{5,-1},{5,2},{6,-1},{6,2},{7,-2},{7,11},
            {8,-1},{8,48},{9,-1},{9,81}}) {
            bad=good;mutate32(bad,4+pair.first*4,pair.second);
            assert(rejected(bad));
        }
        for(unsigned i=10;i<21;++i) {
            bad=good;mutate32(bad,4+i*4,2);assert(rejected(bad));
            bad=good;mutate32(bad,4+i*4,-1);assert(rejected(bad));
        }
        bad=good;mutate32(bad,88,1025);assert(rejected(bad));
    } else if(mode=="truncation") {
        const auto good=capture().bytes;
        for(size_t i=0;i<good.size();++i)
            assert(rejected(std::vector<uint8_t>(good.begin(),good.begin()+i)));
    } else if(mode=="queue_cap") {
        bool failed=false;
        try {capture(MS_IDLE,1025);}catch(const std::runtime_error&) {failed=true;}
        assert(failed);
    } else {return 2;}
    std::cout<<"MOUSE-NATIVE-HOST-OK "<<mode<<'\n';
}
'''


class MouseNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='ventium-mouse-native-test.')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / 'mouse-native-test'
        source = FIXTURE.replace('@PRODUCTION@', checkpoint_source())
        subprocess.run(['g++', '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
                        '-x', 'c++', '-', '-o', str(cls.binary)], input=source,
                       text=True, check=True, timeout=30, capture_output=True)

    def check_mode(self, mode):
        completed = subprocess.run([str(self.binary), mode], text=True,
                                   capture_output=True, check=True, timeout=5)
        self.assertEqual(completed.stdout, f'MOUSE-NATIVE-HOST-OK {mode}\n')
        self.assertEqual(completed.stderr, '')

    def test_all_states_and_queue_roundtrip(self):
        self.check_mode('roundtrip')

    def test_disabled_and_presence_mismatch(self):
        self.check_mode('disabled')

    def test_every_scalar_and_queue_bound(self):
        self.check_mode('bounds')

    def test_every_truncation(self):
        self.check_mode('truncation')

    def test_save_queue_cap(self):
        self.check_mode('queue_cap')


if __name__ == '__main__':
    unittest.main()
