"""Rainbow Light: does changing a lamp's color repaint the light on screen? Runs by itself.

Usage (from the RainbowLight folder):
  python tools\\light_test.py

Starts a dedicated test server with -Ddebug and one game started with -debug, which joins by
itself (lua/client/RainbowLight_TestPilot.lua). The server places a lamp next to the player
(lua/server/RainbowLight_ServerTest.lua) and makes it night. Then the game changes the lamp color
in different ways and reads the light its own screen draws around the lamp
(IsoGridSquare:getLightInfo), and takes screenshots. Results: <root>\\light_test_result.txt,
screenshots: <root>\\client1\\Screenshots\\rl_*.png.

Reuses the server/client launching of ..\\CheeseMaking\\tools\\mp_test.py (imported, with the
pilot file names switched to RainbowLight_*).
Options: --root DIR (default %USERPROFILE%\\PZTest_rainbow)
"""
import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / 'CheeseMaking' / 'tools'))
import mp_test as mt  # noqa: E402

MOD_ID = 'itsu07_RainbowLight'
BULB = 'RainbowLight.LightBulbRainbow'
mt.PILOT_CFG = 'RainbowLight_pilot.txt'
mt.PILOT_STATUS = 'RainbowLight_pilot_status.txt'
mt.PILOT_CMD = 'RainbowLight_pilot_cmd.txt'
mt.PILOT_OUT = 'RainbowLight_pilot_out.txt'

say = mt.say
LOG = []


def note(text):
    LOG.append(text)
    say('     ' + text)

def parse_two(text):
    """'light r=.. g=.. b=.. | 3 tiles r=.. g=.. b=.. | ...' -> ((r, g, b) or None, (r, g, b) or None)"""
    out = []
    for part in text.split('|')[:2]:
        try:
            vals = dict(p.split('=') for p in part.split() if '=' in p)
            out.append((float(vals['r']), float(vals['g']), float(vals['b'])))
        except Exception:  # noqa: BLE001
            out.append(None)
    while len(out) < 2:
        out.append(None)
    return out[0], out[1]


def strength(rgb, ch):
    """how much channel ch stands out over the other two"""
    others = [v for i, v in enumerate(rgb) if i != ch]
    return rgb[ch] - sum(others) / 2



def run_tests(root):
    mods = [MOD_ID]
    server = mt.Server(root, mods)
    client = root / 'client1'
    mt.enable_menu_mods(client, mods)
    # without this marker the first start in a new folder empties default.txt (no mods active,
    # so the pilot never loads); the game writes the same line itself on that first start
    (client / 'mods' / 'reset-mods-42_00.txt').write_text(
        'If this file does not exist, default.txt will be reset to empty (no mods active).', encoding='utf-8')
    mt.write_pilot(client, 'test1', 'test1')
    pilot = mt.Pilot(client, 'test1')
    shots = client / 'Screenshots'

    server.prepare(autotest=False)
    server.start()
    alive = lambda: server.proc is not None and server.proc.poll() is None  # noqa: E731
    try:
        if not server.wait_for('SERVER STARTED', 600, 'SERVER STARTED'):
            return
        while not mt.rcon_alive():
            time.sleep(1)
        mt.rcon('adduser "test1" "test1"')
        mt.rcon('setpassword "test1" "test1"')
        mt.rcon('setaccesslevel "test1" "admin"')
        mt.ok('test1 を管理者にしました')

        game_dir, _ = mt.launcher_parts(root / 'client1.cmd')
        subprocess.Popen(['cmd', '/c', str(root / 'client1.cmd')], cwd=game_dir,
                         creationflags=subprocess.CREATE_NEW_CONSOLE)
        if not mt.bring_in([pilot], alive):
            return
        mt.rcon('godmodeplayer "test1" -true')
        mt.rcon('invisibleplayer "test1" -true')
        time.sleep(5)

        kind, pos, _ = pilot.run('ping')
        note(f'player at {pos}')
        x, y, z = pos.split(',')
        kind, text, _ = pilot.run(f'server place {x} {y} {z} bulb=Base.LightBulb', 30)
        note(f'place: {kind} {text}')
        if kind != 'done':
            mt.problem('ランプを置けませんでした: ' + text)
            return
        lx, ly, lz = text.split()[:3]
        lamp = f'{lx} {ly} {lz}'
        mt.rcon(f'teleportto "test1" {int(lx) + 2},{int(ly) + 2},{lz}')
        time.sleep(6)

        kind, text, _ = pilot.run('server night 0 0 0 hour=23', 30)
        note(f'server night: {text}')
        note('client ' + pilot.run('time 23')[1])
        # night falls slowly; until it is dark the light is capped and no color shows
        note('settle: ' + pilot.run(f'settle {lamp}', 170)[1])
        pilot.run('ui off')

        def shot(name):
            pilot.run(f'shot {name}')
            time.sleep(2)

        shot('rl_0_white.png')

        # how long until the light on screen shows a new color, per way of changing it;
        # each color differs from the one before, so the light has to change every time
        steps = [
            ('S1', 'none', (1, 0, 0), 'rl_1_red_coloronly.png'),
            ('S2', 'none', (0, 1, 0), 'rl_2_green_coloronly.png'),
            ('S3', 'none', (0, 0, 1), 'rl_3_blue_coloronly.png'),
            ('S4', 'switch', (1, 0, 0), 'rl_4_red_switch.png'),
            ('S5', 'switch', (0, 1, 0), 'rl_5_green_switch.png'),
            ('S6', 'switch', (0, 0, 1), 'rl_6_blue_switch.png'),
        ]
        for cid, mode, (r, g, b), png in steps:
            label = ('色だけ' if mode == 'none' else '色 + switchLight') + f' -> {r},{g},{b}'
            kind, text, _ = pilot.run(f'watch {mode} {r} {g} {b} {lamp}', 15)
            mt.result('PASS' if text.startswith('seen') else 'FAIL', cid, f'{label}: {text}')
            time.sleep(1)
            shot(png)

        note('server ' + pilot.run(f'server bulb {lamp} bulb={BULB}', 30)[1])
        for cid, mode in (('S7', 'none'), ('S8', 'switch')):
            note('cycle ' + pilot.run(f'cycle on {mode}')[1])
            seen = []
            for i in range(12):
                time.sleep(0.7)
                kind, text, _ = pilot.run(f'class {lamp}')
                note(f'{cid} rainbow ({mode}) {i + 1}s: {text}')
                seen.append(text.split()[0])
                if i in (3, 7):
                    shot(f'rl_{cid[1]}_rainbow_{mode}_{i + 1}s.png')
            kinds = sorted(set(k for k in seen if k not in ('none', '?')))
            # S7 (color only) is kept for comparison: it lags 1-4 s, so at the default speed it
            # cannot keep up and is only recorded; S8 is the way the mod works
            level = ('PASS' if len(kinds) >= 4 else 'FAIL') if mode == 'switch' else 'INFO'
            mt.result(level, cid,
                      f'虹色（{mode}）: 12 回で見えた色 {len(kinds)} 種 {kinds}（並び {seen}）')
        # depth: extra lights of the same color on the lamp. Per setting, the lamp shows red, green
        # and blue (cycling paused); "strength" = the lamp's color minus the mean of the other two,
        # next to the lamp and 3 tiles away
        pilot.run('cycle off')
        for cid, n, radius in (('D0', 0, 0), ('D1', 1, 0), ('D2', 2, 0), ('D3', 3, 0), ('D4', 1, 15)):
            made = pilot.run(f'extras {n} {radius}')[1]
            near_s, far_s = [], []
            for ch, h in ((0, 0.0), (1, 1 / 3), (2, 2 / 3)):
                pilot.run(f'hue {h:.4f}')
                time.sleep(1.5)
                text = pilot.run(f'measure {lamp}')[1]
                near, far = parse_two(text)
                note(f'{cid} {made} hue {h:.2f}: {text}')
                if near:
                    near_s.append(strength(near, ch))
                if far:
                    far_s.append(strength(far, ch))
                if ch == 0:
                    shot(f'rl_{cid}_red.png')
            avg = lambda v: sum(v) / len(v) if v else float('nan')  # noqa: E731
            mt.result('INFO', cid, f'重ねる光 {n} 個' + (f'・半径 {radius}' if radius else '')
                      + f': 色の強さ ランプの横 {avg(near_s):.3f} / 3 マス先 {avg(far_s):.3f}')

        # weight: frame rate and CPU time per frame (P1-P4), and the cost of the change itself (P5)
        perf = [
            ('P1', 'cycle off', '4000 0', 0, '虹色を止めたとき'),
            ('P2', 'cycle on switch', '4000 0', 0, '4 秒で一周・毎フレーム・重ねる光なし'),
            ('P3', 'cycle on switch', '4000 0', 3, '4 秒で一周・毎フレーム・重ねる光 3 個'),
            ('P4', 'cycle on switch', '2000 0', 2, '2 秒で一周・毎フレーム・重ねる光 2 個（今の初期設定）'),
        ]
        for cid, cycle, speed, n, label in perf:
            pilot.run(f'speed {speed}')
            pilot.run(f'extras {n}')
            pilot.run(cycle)
            time.sleep(2)
            mt.result('INFO', cid, f'{label}: {pilot.run("perf 10", 25)[1]}')
        pilot.run('cycle off')
        pilot.run('extras 0')
        pilot.run('speed 4000 0')
        mt.result('INFO', 'P5', f'色の変更をまとめて実行: {pilot.run(f"bench 200 {lamp}", 30)[1]}')
        pilot.run('ui on')
    finally:
        try:
            pilot.run('quit', 15)
        except Exception:  # noqa: BLE001
            pass
        time.sleep(5)
        for pid in mt.java_pids(client):
            subprocess.run(['taskkill', '/PID', str(pid), '/F'], capture_output=True)
        server.stop()
        mt.remove_pilot(client)
    say(f'スクリーンショット: {shots}')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--root', default=str(Path(os.environ.get('USERPROFILE', '')) / 'PZTest_rainbow'))
    a = ap.parse_args()
    try:
        sys.stdout.reconfigure(errors='replace')
    except Exception:  # noqa: BLE001
        pass
    root = Path(a.root)
    if mt.rcon_alive():
        say(f'ポート {mt.RCON_PORT} にもうサーバーがいます。先に止めてください')
        return 1
    mt.setup(root, [MOD_ID])
    run_tests(root)

    for name, path in (('client1', root / 'client1' / 'console.txt'), ('server', root / 'server' / 'server-console.txt')):
        errs = mt.mod_errors(mt.read_log(path), [MOD_ID, 'RainbowLight'])
        if errs:
            mt.problem(f'{name} のログに MOD 関係のエラーが {len(errs)} 行')
            for e in errs[:8]:
                say('     ' + e[:200])
        else:
            mt.ok(f'{name} のログに MOD 関係のエラーなし')

    lines = LOG + [f'{lv} {cid} {t}' for lv, cid, t in mt.RESULTS] + ['NG ' + p for p in mt.problems]
    (root / 'light_test_result.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8-sig')
    say('')
    fails = [r for r in mt.RESULTS if r[0] == 'FAIL']
    say(f'PASS {len(mt.RESULTS) - len(fails)} / FAIL {len(fails)}' + (f' / NG {len(mt.problems)}' if mt.problems else ''))
    return 1 if fails or mt.problems else 0


if __name__ == '__main__':
    sys.exit(main())
