"""Build golden fixtures for the Swift K96 port.

Writes synthetic raw logger files (same format as the AIMNet Python UI: no header, `pc_time, <device tokens>`) and the
outputs of the reference Python pipeline (k96_rt.MultiModel with EVERY model of k96/config.json) for each of them.

    python3 make_golden.py --k96 /path/to/AIMNet_realtime/k96 --out /tmp/k96golden

The scenarios are synthetic: they exercise the code paths (cold start in N2, hot restart, room-air zero then a
switch to N2, shifted air state, flow steps, data gaps, a stuck gas-temperature sensor, slow sampling, a power
cycle), not the physics. Replace or extend them with real recordings when available.
"""
import argparse, csv, datetime, json, math, os, sys

OUT_COLS = ['cnt', 'CH4_ppm', 'CH4_ppm_raw', 'zeroed', 'state', 'zero_offset_ppm', 'flow_transient', 'bme_suspect', 'zero_suspect',
            'expected_abs_err_ppm', 'optics_invalid', 'temp_rate_C_per_5min', 'reliability', 'reliability_reason']


class Rng:
    """small deterministic generator (same numbers on every machine, no numpy dependency in the fixtures)"""
    def __init__(s, seed): s.x = seed & 0xFFFFFFFF
    def u(s):
        s.x = (1103515245 * s.x + 12345) & 0x7FFFFFFF
        return s.x / 0x7FFFFFFF
    def n(s): return math.sqrt(-2 * math.log(max(s.u(), 1e-12))) * math.cos(2 * math.pi * s.u())


def frame(cnt, f1, f2, f3, P, T1, T1b, T2, RH, T3, H2O, CH4, CO2, flag=0):
    return [int(round(v)) for v in (cnt, f1, f2, f3, P, T1, T1b, 0, T2, RH, T3, flag, H2O, CH4, CO2)]


def scenario(name, seed, segments, manual_zero_at=None):
    """segments: list of (n_frames, dt_s, cnt_start or None, fn(k, t, rng) -> dict of channel values)"""
    rng = Rng(seed); rows = []; t_abs = 0.0
    for n, dt, cnt0, fn in segments:
        t = 0.0 if cnt0 is not None else t
        base_cnt = cnt0 if cnt0 is not None else base_cnt
        for k in range(n):
            if fn is None: t += dt; t_abs += dt; continue      # a gap: time passes, no frames
            v = fn(k, t, rng)
            rows.append((t_abs, frame(base_cnt + math.floor(t), **v)))
            t += dt; t_abs += dt
    return name, rows, manual_zero_at


def warm(t, t0=22.0, t1=26.0, tau=900.0):
    return t1 - (t1 - t0) * math.exp(-t / tau)


def cold_n2(k, t, g, f1=-800.0, ch4_pulse=None, p_step_at=None, Tend=26.0):
    T = warm(t, 22.0, Tend)
    ch4 = 40367 + 26 * (T - 26.0) + 2 * g.n()
    if ch4_pulse and ch4_pulse[0] <= t < ch4_pulse[1]: ch4 -= 2 * ch4_pulse[2]     # gain 2 counts per ppm, CH4 counts fall with methane
    P = 9848 + 2 * g.n() + (35 if p_step_at and t >= p_step_at else 0)
    return dict(f1=f1 + 20 * g.n(), f2=-12 + 3 * g.n(), f3=-165 + 4 * g.n(), P=P, T1=T * 100 + 10, T1b=T * 100 + 3 * g.n(),
                T2=(T - 1.0) * 100, RH=0, T3=(T + 1.0) * 100, H2O=42404 + 10 * g.n(), CH4=ch4, CO2=41787 + 10 * g.n())


def hot_restart(k, t, g):
    v = cold_n2(k, t + 3600, g); v['f1'] = 32767
    return v


def room_air(k, t, g, switch_at=None, f1=200.0):
    T = warm(t, 23.0, 25.5, 600)
    n2 = switch_at is not None and t >= switch_at
    f2 = (-10 if n2 else 450) + 3 * g.n()
    h2o = (42400 if n2 else 39800) + 10 * g.n()
    return dict(f1=f1 + 15 * g.n(), f2=f2, f3=(-160 if n2 else 900) + 4 * g.n(), P=9850 + 2 * g.n(), T1=T * 100, T1b=T * 100 + 3 * g.n(),
                T2=(T - 0.8) * 100, RH=4000 + 30 * g.n(), T3=(T + 0.9) * 100, H2O=h2o, CH4=40200 + 20 * (T - 25) + 2 * g.n(),
                CO2=(41800 if n2 else 40600) + 10 * g.n())


def air_shift(k, t, g, stuck_from=None):
    v = room_air(k, t, g, f1=1500.0)
    T = 25.0 + (9.0 * min(max((t - 3000) / 2400, 0), 1))     # warms to 34 C (outside the trained range) after 50 min
    v.update(T1=T * 100, T1b=T * 100 + 3 * g.n(), T2=(T - 0.8) * 100)
    v['T3'] = 2600 if stuck_from is not None and t >= stuck_from else (T + 0.9) * 100
    return v


SCENARIOS = [
    scenario('cold_n2_then_hot_restart', 11, [
        (3000, 1.222, 1, lambda k, t, g: cold_n2(k, t, g, ch4_pulse=(2400, 2700, 25), p_step_at=3300)),
        (35, 1.222, None, None),                                            # ~43 s with no frames (Bluetooth drop)
        (2500, 1.222, None, lambda k, t, g: cold_n2(k, t, g, ch4_pulse=(5000, 5200, 10))),
        (1600, 1.222, 2, hot_restart),                                       # power cycle: counter starts again
    ]),
    scenario('room_air_zero_then_n2', 22, [
        (5200, 1.222, 3, lambda k, t, g: room_air(k, t, g, switch_at=3200)),
    ]),
    scenario('air_shift_hot_stuck_bme', 33, [
        (4800, 1.222, 1, lambda k, t, g: air_shift(k, t, g, stuck_from=4300)),
    ]),
    scenario('slow_sampling_n2', 44, [
        (1500, 3.0, 5, lambda k, t, g: cold_n2(k, t, g, f1=-700.0)),
    ]),
    scenario('manual_zero_cold_n2', 55, [
        (2600, 1.222, 4, lambda k, t, g: cold_n2(k, t, g, ch4_pulse=(2600, 2800, 15))),
    ], manual_zero_at=1400),
]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--k96', required=True); ap.add_argument('--out', required=True); a = ap.parse_args()
    sys.path.insert(0, a.k96); import k96_rt
    cfg, specs = k96_rt.load_config(a.k96)
    keys = [sp['key'] for sp in specs]
    if cfg['warnings']: print('python warnings:', cfg['warnings'])
    os.makedirs(a.out, exist_ok=True)
    start = datetime.datetime(2026, 11, 1, 9, 0, 0)
    for name, rows, manual_zero_at in SCENARIOS:
        with open(os.path.join(a.out, f'{name}.meta.json'), 'w') as fh:
            json.dump({'manual_zero_at': manual_zero_at, 'models': keys}, fh)
        raw_path = os.path.join(a.out, f'{name}.raw.csv')
        with open(raw_path, 'w', newline='') as fh:
            w = csv.writer(fh)
            for t_abs, fr in rows:
                ts = (start + datetime.timedelta(seconds=t_abs)).strftime('%Y-%m-%d %H:%M:%S')
                w.writerow([ts, fr[0], 'start'] + fr[1:11] + ['end'] + fr[11:])
        mm = k96_rt.MultiModel(specs)
        if manual_zero_at is not None: mm.set_zero_mode('manual')
        with open(os.path.join(a.out, f'{name}.expected.csv'), 'w', newline='') as fh:
            w = csv.writer(fh); w.writerow(['model'] + OUT_COLS)
            for j, fr in enumerate(k96_rt.raw_frames(raw_path)):
                if j == manual_zero_at: mm.zero_now()
                out = mm.push(fr)
                for k in keys:
                    o = out[k]; w.writerow([k] + [repr(float(o[c])) if isinstance(o[c], float) else o[c] for c in OUT_COLS])
        print(f'{name}: {len(rows)} frames')


if __name__ == '__main__':
    main()
