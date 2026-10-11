"""Negative controls for the passive whole-core AXI-byte checker."""
import copy
import unittest

from observe_fragment_exact_core import check_bytes


def valid_rows(first=3):
    base=dict(clk=1,__VnbaTriggered=1,fx_act=1,fx_abort_q=0,fx_start=0,mem_req=1,
        state=42,cur_lin_nat=0x9000-first,cur_size=4,fx_first=first,bd_we=0,fx_wr=0,
        bypass=1,m_axi_arvalid=1,m_axi_arready=1,m_axi_arlen=0)
    rows=[dict(base,event='replacement',fx_abort_q=1,fx_start=1,fx_first=2,mem_wstrb=(1<<first)-1)]
    # Independent simple byte-wise splitting is valid though not necessarily
    # the optimized L1 planner's chosen decomposition.
    for phase,(address,width) in enumerate(((0x9000-first,first),(0x9000,4-first))):
        for byte in range(width):
            rows.append(dict(base,event='axi-ar',fx_ph=phase,fbase=address,
                byp_strobes=(1<<width)-1,m_axi_araddr=address+byte,m_axi_arsize=0))
    rows += [dict(base,event='core-ack',fx_ph=1),dict(base,event='first-beat-complete')]
    return rows


class ByteChecker(unittest.TestCase):
    def test_all_page_offsets(self):
        for first in (1,2,3):self.assertEqual(len(check_bytes(valid_rows(first),first)),4)

    def test_overread_duplicate_missing_and_stale_owner(self):
        good=valid_rows(); mutations=[]
        overread=copy.deepcopy(good); overread[1].update(m_axi_araddr=0x9000,m_axi_arsize=2); mutations.append(overread)
        duplicate=copy.deepcopy(good); duplicate.insert(2,dict(duplicate[1])); mutations.append(duplicate)
        missing=copy.deepcopy(good); del missing[1]; mutations.append(missing)
        stale=copy.deepcopy(good); stale[0]['mem_wstrb']=3; mutations.append(stale)
        for rows in mutations:
            with self.assertRaises(AssertionError):check_bytes(rows,3)

    def test_only_real_edge_handshakes(self):
        for field,value in (('__VnbaTriggered',0),('m_axi_arready',0),('m_axi_arlen',1),('bypass',0)):
            rows=valid_rows(); rows[1][field]=value
            with self.assertRaises(AssertionError):check_bytes(rows,3)


if __name__=='__main__':unittest.main()
