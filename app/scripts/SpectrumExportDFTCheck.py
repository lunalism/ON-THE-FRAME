"""Independent reference for SP-4A-01. Usage: python3 <script> <generated fixture directory>."""
import cmath
import json
import math
from pathlib import Path
import struct
import sys
import wave

root = Path(sys.argv[1])
with wave.open(str(root / 'selected.wav'), 'rb') as wav:
    assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (2, 2, 48000)
    raw = wav.readframes(wav.getnframes())
pcm = struct.unpack('<' + 'h' * (len(raw) // 2), raw)
report = json.loads((root / 'result.json').read_text())
assert report['status'] == 'PASS'
rows = []
for frame, expected in [(60, 220), (180, 440), (300, 880)]:
    # Timeline start 0, sourceIn 30 frames. 90ms centered Hann window.
    center = (frame + 30) * 1600
    count = 4320
    values = [(pcm[(center - count // 2 + i) * 2] / 32768) *
              (0.5 - 0.5 * math.cos(2 * math.pi * i / (count - 1))) for i in range(count)]
    amplitudes = {hz: abs(sum(value * cmath.exp(-2j * math.pi * hz * i / 48000)
                             for i, value in enumerate(values))) for hz in [220, 440, 880]}
    peak = max(amplitudes, key=amplitudes.get)
    bands = report['bands'][str(frame)]
    engine_band = max(range(len(bands)), key=bands.__getitem__)
    expected_band = math.floor(math.log(expected / 20) / math.log(2000 / 20) * 64)
    assert peak == expected and engine_band == expected_band
    rows.append(dict(frame=frame, sourceFrame=frame + 30, DFTAmplitudes=amplitudes,
                     DFTPeakHz=peak, enginePeakBand=engine_band, expectedBand=expected_band))
# RMS envelope frequency: slow/fast/medium = 2/4/3 pulses per second.
envelope_checks = []
for section, rate in enumerate([2, 4, 3]):
    rms = []
    for frame in range(120):
        start = (30 + section * 120 + frame) * 1600 * 2
        block = pcm[start:start + 3200]
        rms.append(math.sqrt(sum((v / 32768) ** 2 for v in block) / len(block)))
    active = [value > 0.15 for value in rms]
    starts = sum(value and (index == 0 or not active[index - 1]) for index, value in enumerate(active))
    assert starts == rate * 4, (section, starts)
    envelope_checks.append(dict(section=section, pulses=starts, expectedPulses=rate * 4))
result = dict(frequencies=rows, envelopes=envelope_checks, status='PASS')
(root / 'independent-dft.json').write_text(json.dumps(result, indent=2) + '\n')
print('PASS: independent DFT, sourceIn and slow/fast/medium RMS envelope')
