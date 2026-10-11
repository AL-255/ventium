"""Keep the dead SRT quotient zero in IDLE, eliminating its start-input enable.

Division and iterative remainder already initialize qacc on the accepted-start
edge. It is not consumed by IDLE, special-result or square-root states. Clearing
in IDLE leaves that edge unchanged and makes its initialization enable depend
only on the registered local phase, not on the producer's late start signal.
"""
import hashlib

PARENT = '96f615d962f864e42ce651b29fedaf419acc8215697045b0fc3b2df4368ef7d4'
ANCHOR = '''        ST_IDLE: begin
          if (start) begin
'''
REPLACEMENT = '''        ST_IDLE: begin
          // qacc is dead in IDLE/sqrt/special. Every consuming operation
          // enters from IDLE, so zero it here without a late start-input CE.
          qacc <= 128'sd0;
          if (start) begin
'''
REM = "                  qacc    <= 128'sd0;\n"
DIV = "                qacc <= 128'sd0;\n"


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('SRT source drift')
    for token in (ANCHOR, REM, DIV):
        if source.count(token) != 1:
            raise ValueError('ambiguous quotient initialization')
    result=source.replace(ANCHOR,REPLACEMENT).replace(REM,'').replace(DIV,'')
    if result.count("qacc <= 128'sd0;") != 1:
        raise ValueError('quotient initialization count')
    return result
