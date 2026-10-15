"""Two unchanged short cold-PC controls; not duration-valid CoreMark scores."""
import hashlib
from pathlib import Path

original_driver=Path(__file__).with_name('run_fetch_fragment_coremark.py')
text=original_driver.read_text()
for old,new in (
    ('ventium-fetch-fragment-cm10-','ventium-pair-next-disjoint-cm10-'),
    ("root=soc/'coremark-r2';root.mkdir()","root=soc/'coremark-r1';root.mkdir()"),
    ('original,Path(native_observation.__file__),Path(__file__).resolve(),model,',
     'original,original_driver,Path(native_observation.__file__),Path(__file__).resolve(),model,'),
):
    assert text.count(old)==1,old
    text=text.replace(old,new)
exec(compile(text,str(__file__),'exec'),globals())
