"""Remove operand classification from the SRT quotient initialization enable.

The accepted-start edge owns initialization. Division and iterative remainder
already write zero there. Square root and special-result paths never consume
qacc; every later operation which consumes it initializes it again first.
No request, busy/done, state transition or result equation is changed.
"""
import hashlib

PARENT = '96f615d962f864e42ce651b29fedaf419acc8215697045b0fc3b2df4368ef7d4'
ANCHOR = '''          if (start) begin
            mode_q <= mode;
'''
REPLACEMENT = '''          if (start) begin
            mode_q <= mode;
            // Initialize the quotient on every accepted operation. Special
            // results and sqrt do not consume it; div/rem consume zero before
            // their first step. Keep late operand classification off its CE.
            qacc <= 128'sd0;
'''
REM = "                  qacc    <= 128'sd0;\n"
DIV = "                qacc <= 128'sd0;\n"


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('SRT source drift')
    for token in (ANCHOR, REM, DIV):
        if source.count(token) != 1:
            raise ValueError('ambiguous quotient initialization')
    result = source.replace(ANCHOR, REPLACEMENT).replace(REM, '').replace(DIV, '')
    if result.count("qacc <= 128'sd0;") != 1:
        raise ValueError('quotient initialization count')
    return result
