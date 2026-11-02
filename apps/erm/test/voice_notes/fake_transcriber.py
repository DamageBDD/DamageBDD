#!/usr/bin/env python3
"""Local process fixture. It never attempts to recognise the fixture waveform."""
import pathlib,sys,time
args=sys.argv[1:]
model=pathlib.Path(args[args.index('-m')+1]).read_text()
if model=='timeout':time.sleep(2)
else:time.sleep(.2)
pathlib.Path(args[args.index('-of')+1]+'.txt').write_text('Fixture transcript, not recognised speech.\n')
