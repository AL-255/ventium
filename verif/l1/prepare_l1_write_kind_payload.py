"""Prepare backing write direction independently of load/store-pair readiness.

Private timing experiment. Request/ACK/credit/address/data/strobe equations stay
unchanged. Only an inactive request's direction can differ. Never edit a frozen
input tree in place.
"""
import hashlib

PARENTS = {
    '11ed3337a28f0eebd546860ad2abad7996352036d2fc86c930b578009e0c42e0',
    '401f52cc73746b5d130c0d5d8e9a6009f9372b78dc6b40f316c61690e48dd11d',
}
OLD = '      m_req=c_pair_req && c_pair_ready; m_we=m_req; m_addr=c_pair_addr;\n'
NEW = '''      // This branch can only offer V's write. Prepare its direction before
      // admission; m_req alone authorizes the backing transaction. Keeping
      // m_we dependent on pair readiness puts that late control ahead of the
      // master's extent arithmetic. With m_req=1 the old direction is also 1.
      m_req=c_pair_req && c_pair_ready; m_we=1'b1; m_addr=c_pair_addr;
'''


def transform(source):
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest not in PARENTS or source.count(OLD) != 1:
        raise ValueError('L1 write-direction source drift')
    result = source.replace(OLD, NEW)
    if result.replace(NEW, OLD) != source:
        raise ValueError('non-reversible payload edit')
    return result


def backing_block(source):
    begin = source.index('  always_comb begin', source.index('  // backing-side drive:'))
    end = source.index('  // REVIEW_Jul29 H-13:', begin)
    block = source[begin:end]
    if block.count('always_comb') != 1 or 'm_we=' not in block:
        raise ValueError('backing block structure drift')
    return block
