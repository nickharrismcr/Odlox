import json
import math
import os
import struct
import sys
import wave

# Renders data/sfx.json (produced by extract_sfx.lox) into assets/*.wav.
# Lox can't write binary WAV data itself (os.write unescapes a literal
# "\n" into a real newline byte, corrupting anything binary -- see
# extract_sfx.lox's own header comment), so this stays a separate
# offline step, stdlib only. Usage: python tools/render_sfx.py
# [data/sfx.json] [assets]

SAMPLE_RATE = 44100
AMPLITUDE = 20000
T_STATES_PER_HALF_PERIOD = 13
Z80_CLOCK_HZ = 3500000
GAP_S = 0.02  # 20ms between explosion sweep repeats


def half_period_s(pitch):
    return pitch * T_STATES_PER_HALF_PERIOD / Z80_CLOCK_HZ


def square_wave_segment(pitch, samples_out):
    # One ON half-period at +AMPLITUDE, one OFF half-period at
    # -AMPLITUDE -- a real square wave, not beeper on/DC-off, so the
    # rendered clip doesn't carry a DC offset.
    hp = half_period_s(pitch)
    on_samples = max(1, round(hp * SAMPLE_RATE))
    samples_out.extend([AMPLITUDE] * on_samples)
    samples_out.extend([-AMPLITUDE] * on_samples)


def render_tone(cue):
    samples = []
    for _ in range(cue["cycles"]):
        square_wave_segment(cue["pitch"], samples)
    return samples


def render_sweep_up(cue):
    samples = []
    for pitch in range(cue["pitch"], cue["pitch"] + cue["cycles"]):
        square_wave_segment(pitch, samples)
    return samples


def render_explosion(cue):
    samples = []
    gap = [0] * round(GAP_S * SAMPLE_RATE)
    for repeat in range(cue["cycles"]):
        if repeat > 0:
            samples.extend(gap)
        for pitch in range(cue["pitch"], 0, -1):
            square_wave_segment(pitch, samples)
    return samples


RENDERERS = {
    "tone": render_tone,
    "sweep_up": render_sweep_up,
    "explosion": render_explosion,
}


def write_wav(path, samples):
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(struct.pack("<%dh" % len(samples), *samples))


def main():
    sfx_path = sys.argv[1] if len(sys.argv) > 1 else "data/sfx.json"
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "assets"

    with open(sfx_path) as f:
        cues = json.load(f)

    os.makedirs(out_dir, exist_ok=True)
    for cue in cues:
        renderer = RENDERERS[cue["kind"]]
        samples = renderer(cue)
        out_path = os.path.join(out_dir, cue["name"] + ".wav")
        write_wav(out_path, samples)
        print("wrote %s (%d samples, %.3fs)" % (out_path, len(samples), len(samples) / SAMPLE_RATE))


if __name__ == "__main__":
    main()
