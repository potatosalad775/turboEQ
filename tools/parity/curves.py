"""Curve sources for the parity fixtures.

Every curve is deterministic: noise uses a seeded generator, and the real
measurements are read from files. The *pipeline* stages therefore regenerate
to within the 9-decimal rounding floor on any machine. Upstream's optimizer
output does not — see the note on reproducibility in README.md.
"""
import os

import numpy as np

# Upstream's own working grid. FrequencyResponse.interpolate() resamples onto
# this, so feeding curves at a different resolution exercises the interpolator.
AUTOEQ_STEP = 1.01
# 1/48 octave, a common resolution for published measurement graphs.
OCT48_STEP = 2 ** (1 / 48)


def log_grid(f_min=20.0, f_max=20000.0, step=OCT48_STEP):
    f, out = f_min, []
    while f <= f_max:
        out.append(f)
        f *= step
    return np.array(out)


def _gaussians(f, peaks):
    """Sum of log-frequency gaussians. peaks is (fc, gain_db, width_decades)."""
    l = np.log10(f)
    v = np.zeros_like(f)
    for fc, gain, width in peaks:
        v += gain * np.exp(-((l - np.log10(fc)) / width) ** 2)
    return v


def flat(f):
    return np.zeros_like(f)


def gentle(f):
    """A well-behaved headphone: bass rolloff, 3 kHz peak, 9 kHz dip."""
    v = _gaussians(f, [(200, 2, 0.20), (3000, 6, 0.09), (9000, -7, 0.05)])
    v += -5 * (1 / (1 + (f / 90) ** 2))
    return v


def bumpy(f):
    """Ten alternating features. Deliberately needs many bands."""
    return _gaussians(f, [
        (60, -6, 0.12), (150, 4, 0.10), (400, -3, 0.09), (900, 3, 0.08),
        (1800, -4, 0.07), (3200, 6, 0.06), (5000, -5, 0.06), (7000, 4, 0.05),
        (9500, -6, 0.05), (13000, 3, 0.07),
    ])


def noisy_narrow_dip(f, seed=0):
    """bumpy() plus measurement noise and a deep narrow dip at 8.8 kHz.

    This is the case that separates the two lineages. The dip is exactly what
    the perceptual pipeline must refuse to fill.
    """
    rng = np.random.default_rng(seed)
    v = bumpy(f)
    v += -9 * np.exp(-((np.log10(f) - np.log10(8800)) / 0.012) ** 2)
    v += rng.normal(0, 0.35, len(f))
    return v


def harman_ish(f):
    """A plausible target: bass shelf, ear-gain bump, gentle treble tilt."""
    v = _gaussians(f, [(2700, 3.0, 0.16)])
    v += 6.0 / (1 + (f / 105) ** 2)
    v += -0.5 * np.log2(np.clip(f, 20, 20000) / 630)
    return v


SOURCES = {
    'flat': flat,
    'gentle': gentle,
    'bumpy': bumpy,
    'noisy_narrow_dip': noisy_narrow_dip,
}

TARGETS = {
    'flat': flat,
    'harman_ish': harman_ish,
}

# (id, source, target, grid_step). Kept small on purpose; every case multiplies
# fixture size and review effort.
CASES = [
    ('gentle_vs_flat',        'gentle',           'flat',       OCT48_STEP),
    ('bumpy_vs_flat',         'bumpy',            'flat',       OCT48_STEP),
    ('bumpy_vs_harman',       'bumpy',            'harman_ish', OCT48_STEP),
    ('noisy_dip_vs_flat',     'noisy_narrow_dip', 'flat',       OCT48_STEP),
    ('bumpy_coarse_grid',     'bumpy',            'flat',       2 ** (1 / 12)),
]


# ---------------------------------------------------------------------------
# Real measurements. See real/README.md for provenance and for why these four.
#
# Synthetic curves are smooth in ways real ones are not, and the branchy parts
# of the pipeline take their decisions from structure a generated curve lacks.
# These also arrive on their own frequency axes, so source and target no longer
# share a grid — which is what a caller actually hands the library.
# ---------------------------------------------------------------------------
REAL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'real')


def read_measurement(name):
    """Read one vendored curve. Two formats appear: tab-separated with no
    header and sometimes a third phase column, or comma-separated with a
    `frequency,raw` header. Returns (frequency, dB) as float64 arrays.

    Nothing is rounded, resampled or cleaned here. The fixture records what
    upstream was fed, and upstream is fed the file.
    """
    f, db = [], []
    with open(os.path.join(REAL_DIR, name), encoding='utf-8-sig') as fh:
        for line in fh:
            line = line.strip()
            if not line or line[0] not in '0123456789.-+':
                continue  # header, comment or blank
            parts = line.replace(',', '\t').split('\t')
            f.append(float(parts[0]))
            db.append(float(parts[1]))
    return np.array(f, dtype=np.float64), np.array(db, dtype=np.float64)


# (id, source file, target file). A target of None means flat, generated on
# the source's own axis.
REAL_CASES = [
    ('real_rough_treble', 'rough_treble_iem.txt', 'target_harman_ie_2019v2.txt'),
    ('real_deep_dip',     'deep_dip_overear.txt', None),
    ('real_bass_shelf',   'bass_heavy_iem.txt',   'target_harman_ie_2019v2.txt'),
]
