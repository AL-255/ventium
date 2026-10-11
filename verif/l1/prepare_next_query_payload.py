"""Private next-read address cofactor; never alter request/commit permission."""
import hashlib
import re

PARENT_SHA = 'e8cddd9561a4b69c3be59c53b99216bf87851e8732ab5be7e9770f8a372d6129'
OLD = '  assign mem_next_addr = (agi_prime_select || ref_prime_select || mc_prime_offer) ? mc_query_phys : mc_phys_q;'
NEW = '''  // Retain the old descriptor only when its registered owner is valid.
  // With no retained owner, prepare the live address without waiting for the
  // permission/extent-qualified offer. Request and commit remain unchanged.
  // Every offered request sees the former address; inactive payload may differ.
  assign mem_next_addr = (mc_valid_q &&
      !(agi_prime_select || ref_prime_select || mc_prime_offer))
      ? mc_phys_q : mc_query_phys;'''


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT_SHA or source.count(OLD) != 1:
        raise ValueError('next-query source drift')
    return source.replace(OLD, NEW)


def assignment(source, name):
    source = re.sub(r'/\*.*?\*/|//[^\n]*', '', source, flags=re.S)
    match = re.search(r'\bassign\s+' + re.escape(name) + r'\s*=\s*([^;]+);', source)
    if not match:
        raise ValueError('assignment not found: ' + name)
    return ' '.join(match[1].split())


def require_conjunct(expr, guard):
    """Check syntactically that a whole assignment implies its first guard.

    Reject top-level OR/ternary/XOR rather than assuming a leading && makes
    an arbitrary expression guarded. Nested subexpressions are unrestricted.
    The source files are separately pinned; this is not a general SV parser.
    """
    if not expr.startswith(guard + ' && '):
        raise ValueError('missing leading guard')
    depth = 0
    for char in expr:
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
            if depth < 0:
                raise ValueError('unbalanced expression')
        elif depth == 0 and char in '|?^':
            raise ValueError('guard bypass at top level')
    if depth:
        raise ValueError('unbalanced expression')
