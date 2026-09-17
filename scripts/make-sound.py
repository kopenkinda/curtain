#!/usr/bin/env python3
"""Generate Curtain's closing sweep and subtle threshold cue."""
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

# A short, quiet rounded tone distinguishes activation from the closing sweep.
samples = []
duration = 0.14
for i in range(int(rate * duration)):
    t = i / rate
    envelope = (1 - math.exp(-t * 500)) * math.exp(-t * 35)
    envelope *= min(1, (duration - t) / 0.02)
    tone = math.sin(2 * math.pi * 740 * t) + 0.18 * math.sin(2 * math.pi * 1110 * t)
    samples.append(struct.pack('<h', round(0.075 * envelope * tone * 32767)))
with wave.open(str(Path(__file__).resolve().parent.parent / 'Resources/Threshold.wav'), 'wb') as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(rate)
    output.writeframes(b''.join(samples))
