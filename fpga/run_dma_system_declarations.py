"""Repeat declaration-order controls through both real DMA controllers."""
import hashlib
from pathlib import Path

original=Path(__file__).with_name('run_dma_declaration_order.py')
text=original.read_text()
assert hashlib.sha256(text.encode()).hexdigest()=='cb73d525e83f516320d2e1b3a3c03abd6aae1d10fd7361e80735804833011696'
assert text.count('tb_dma_declaration_order')==2
text=text.replace('tb_dma_declaration_order','tb_dma_system_declarations')
assert text.count("'checks=74'")==1
text=text.replace("'checks=74'","'checks=82'")
assert text.count('Path(recipe.__file__),Path(__file__)')==1
text=text.replace('Path(recipe.__file__),Path(__file__)','Path(recipe.__file__),Path(__file__),original')
exec(compile(text,str(original),'exec'),globals())
