"""Private, revision-checked 8042 AUX status repair; never modify live inputs."""
import hashlib

PARENT = '1e4920f53d5a9616d6b121a7148906490a3edd166d2aaecca5fa0ec9439fcf2d'
OLD = '        ~(mouse_fifo_empty),         // Bit 5: Mouse output buffer full\n'
NEW = ('        status_mousebufferfull,      // Bit 5: Origin of the selected output byte\n')


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('PS/2 source drift or repair already applied')
    if source.count(OLD) != 1:
        raise ValueError('PS/2 AUX status expression is not unique')
    # Data, IRQ and FIFO-pop selection already use this latched owner. Queue
    # occupancy can change while a keyboard byte is still selected for port 60h.
    return source.replace(OLD, NEW)


def variant(source, name):
    choices = {'parent': source, 'fixed': transform(source),
               'zero': transform(source).replace(NEW, NEW.replace('status_mousebufferfull', "1'b0")),
               'one': transform(source).replace(NEW, NEW.replace('status_mousebufferfull', "1'b1"))}
    result = choices[name]
    if result.count('module ps2\n') != 1:
        raise ValueError('PS/2 module declaration drift')
    return result.replace('module ps2\n', 'module ps2_aux_' + name + '\n')
