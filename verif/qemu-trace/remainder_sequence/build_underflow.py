"""Prepare a fresh bounded reference build after the active FPGA family closes."""
from pathlib import Path
import build
import prepare_underflow

build.PARENT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/build-exceptions-r1')
build.PARENT_BINARY_SHA='b81831c8976043f8d8d6fc7eeb1d1a981337ca274848f2fcc32b2d3fffbf8e48'
build.prepare=prepare_underflow
original_save=build.save


def save(path,value):
    if path.name=='started.json':
        wrapper=Path(__file__).resolve();value['pins'][str(wrapper)]=build.sha(wrapper)
    original_save(path,value)


build.save=save
if __name__=='__main__':raise SystemExit(build.main())
