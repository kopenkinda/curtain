#!/usr/bin/env python3
"""Generate Curtain's original short sweep and soft closing click."""
import math
from pathlib import Path
import random
import struct
import wave

random.seed(7)
rate = 44100
samples = []
filtered = 0.0
for i in range(int(rate * 0.36)):
    t = i / rate
    progress = t / 0.36
    filtered = 0.86 * filtered + 0.14 * random.uniform(-1, 1)
    sweep = filtered * math.sin(math.pi * progress) ** 1.6 * 0.3
    end = max(0, t - 0.255)
    click = 0 if t < 0.255 else 0.12 * math.exp(-end * 70) * math.sin(2 * math.pi * 420 * end)
    samples.append(struct.pack('<h', round((sweep + click) * 32767)))
with wave.open(str(Path(__file__).resolve().parent.parent / 'Resources/Activation.wav'), 'wb') as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(rate)
    output.writeframes(b''.join(samples))
