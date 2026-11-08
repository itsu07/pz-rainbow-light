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
Options: --root DIR (default %USERPROFILE%\\PZTest_rainbow), --gif (frames for make_gif.py),
         --car (headlights only: the server puts a car down, marks its headlights rainbow and the
         game reads the light in front of it), --ball (mirror ball only: a lamp with the mirror
         ball bulb; the spots, how fast a spot light shows, the weight, and the floor-marker mode),
         --room (the mirror ball in a room of a house: spots inside, nothing through the walls)
"""
import argparse
import colorsys
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
GIF_FRAMES = 25
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



def parse_car(text):
    """carlight answer -> ({'E': (r, g, b, class), ...}, state text)"""
    strips, state = {}, ''
    for part in text.split('|'):
        words = part.split()
        if words and words[0] in ('E', 'W', 'S', 'N') and len(words) >= 5:
            vals = dict(p.split('=') for p in words[1:4])
            strips[words[0]] = (float(vals['r']), float(vals['g']), float(vals['b']), words[4])
        else:
            state = part.strip()
    return strips, state


def hue_sector(strip):
    """(r, g, b, class) -> which sixth of the color wheel (0 red, 1 yellow, 2 green, 3 cyan, 4 blue,
    5 magenta), or None when the light is nearly white"""
    if not strip:
        return None
    h, s, _ = colorsys.rgb_to_hsv(*strip[:3])
    return None if s < 0.2 else int(h * 6 + 0.5) % 6


def car_tests(pilot, x, y, z, shots):
    """Headlights (prototype): does createSpotLightColor change the beam color on screen?"""
    kind, text, _ = pilot.run(f'server car {x} {y} {z}', 30)
    note(f'car: {kind} {text}')
    if kind != 'done':
        mt.problem('車を置けませんでした: ' + text)
        return
    vid, cx, cy, cz = text.split()[:4]
    # stand beside the car, out of the beams
    mt.rcon(f'teleportto "test1" {cx},{int(cy) + 4},{cz}')
    time.sleep(6)
    note('server night: ' + pilot.run('server night 0 0 0 hour=23', 30)[1])
    note('client ' + pilot.run('time 23')[1])
    note('settle: ' + pilot.run(f'carsettle {vid}', 170)[1])
    pilot.run('ui off')

    def shot(name):
        pilot.run(f'shot {name}')
        time.sleep(2)

    def look(label):
        text = pilot.run(f'carlight {vid}')[1]
        note(f'{label}: {text}')
        return parse_car(text)

    off, _ = look('C0 headlights off')
    shot('rl_car_0_off.png')
    note('server ' + pilot.run(f'server lights 0 0 0 id={vid} on=1', 30)[1])
    time.sleep(3)
    on, state = look('C1 headlights on')
    shot('rl_car_1_white.png')
    # the beam side: where the light grew most when the headlights came on
    gain = {d: sum(on[d][:3]) - sum(off[d][:3]) for d in on if d in off}
    front = max(gain, key=gain.get) if gain else 'E'
    mt.result('PASS' if gain.get(front, 0) > 0.1 else 'FAIL', 'C1',
              f'ヘッドライトを点けると前が明るくなる: 前={front} 明るさの増え方 '
              + ' '.join(f'{d}={g:+.3f}' for d, g in gain.items()) + f' ({state})')

    note('server ' + pilot.run(f'server mark 0 0 0 id={vid} on=1', 30)[1])
    time.sleep(2)
    _, state = look('mark')
    mt.result('PASS' if 'mark=true' in state else 'FAIL', 'C2', f'サーバーで付けた印がゲームに届く: {state}')

    pilot.run('cycle off')
    for cid, h, want, png in (('C3', 0.0, 'red', 'rl_car_3_red.png'), ('C4', 1 / 3, 'green', 'rl_car_4_green.png'),
                              ('C5', 2 / 3, 'blue', 'rl_car_5_blue.png')):
        note(pilot.run(f'carhue {h:.4f}')[1])
        time.sleep(1.5)
        strips, state = look(f'{cid} hue {h:.2f}')
        got = strips.get(front, (0, 0, 0, '?'))
        mt.result('PASS' if got[3] == want else 'FAIL', cid,
                  f'ビームが{want}になる: 前 r={got[0]:.3f} g={got[1]:.3f} b={got[2]:.3f} -> {got[3]}')
        shot(png)

    # the rainbow running: sample at uneven gaps (a steady gap that divides the 2 s trip evenly
    # keeps landing on the same colors)
    seen = []
    note('cycle ' + pilot.run('cycle on')[1])
    for i in range(12):
        time.sleep((0.35, 0.5, 0.8)[i % 3])
        strips, _ = look(f'C6 rainbow {i + 1}')
        seen.append(hue_sector(strips.get(front)))
        if i in (3, 7):
            shot(f'rl_car_6_rainbow_{i + 1}.png')
    # the beam follows the hue closely, so it is mostly a mix of two channels ("red+green"); count
    # the sixths of the color wheel it was seen in instead
    kinds = sorted(set(k for k in seen if k is not None))
    mt.result('PASS' if len(kinds) >= 4 else 'FAIL', 'C6',
              f'虹色（2 秒で一周）: 12 回で見えた色相 6 区分のうち {len(kinds)} 区分 {kinds}（並び {seen}、0=赤 1=黄 2=緑 3=水色 4=青 5=赤紫）')
    mt.result('INFO', 'P1', f'車 1 台を虹色: {pilot.run("perf 10", 25)[1]}')
    pilot.run('cycle off')
    mt.result('INFO', 'P2', f'虹色を止めたとき: {pilot.run("perf 10", 25)[1]}')

    note('server ' + pilot.run(f'server mark 0 0 0 id={vid} on=0', 30)[1])
    pilot.run('cycle on')
    time.sleep(2)
    strips, state = look('C7 unmarked')
    got = strips.get(front, (0, 0, 0, '?'))
    # the normal headlight is a warm white (VehicleLight r=1.0 g=0.82 b=0.71): red >= green >= blue,
    # close together
    warm = got[0] >= got[1] >= got[2] and got[0] - got[2] < 0.15
    mt.result('PASS' if warm and 'colored=0' in state else 'FAIL', 'C7',
              f'印を外すと普通の色（やや黄色い白）に戻る: 前 r={got[0]:.3f} g={got[1]:.3f} b={got[2]:.3f} ({state})')
    shot('rl_car_7_back.png')
    pilot.run('ui on')


def ball_tests(pilot, x, y, z, shots):
    """Mirror ball (prototype): spots from small lights switched on and off around a lamp"""
    ball_bulb = 'RainbowLight.LightBulbMirrorBall'
    pilot.run('ballpause on')
    kind, text, _ = pilot.run(f'server place {x} {y} {z} bulb={ball_bulb}', 30)
    note(f'place: {kind} {text}')
    if kind != 'done':
        mt.problem('ランプを置けませんでした: ' + text)
        return
    lx, ly, lz = text.split()[:3]
    lamp = f'{lx} {ly} {lz}'
    mt.rcon(f'teleportto "test1" {int(lx) + 2},{int(ly) + 3},{lz}')
    time.sleep(6)
    note('server night: ' + pilot.run('server night 0 0 0 hour=23', 30)[1])
    note('client ' + pilot.run('time 23')[1])
    note('settle: ' + pilot.run(f'settle {lamp}', 170)[1])
    pilot.run('ui off')

    def shot(name):
        pilot.run(f'shot {name}')
        time.sleep(2)

    info = pilot.run('ball')[1]
    lamp_now = pilot.run(f'measure {lamp}')[1]
    note(f'ball: {info} / {lamp_now}')
    vals = dict(p.split('=') for p in info.split() if '=' in p)
    mt.result('PASS' if int(vals.get('lights', 0)) > 0 else 'FAIL', 'B1',
              f'ミラーボール電球のランプの周りに光の点用の光ができる: {info}')
    shot('rl_ball_0_paused.png')

    # spots standing still: lit spot squares against dark ones
    for cid, turn in (('B2', 0.0), ('B3', 0.37)):
        note(pilot.run(f'ballturn {turn}')[1])
        time.sleep(2)
        text = pilot.run('ballmeasure')[1]
        parts = text.split()   # lit=N avg=A dark=N avg=A colorMatch=M/N
        lit = float(parts[1].split('=')[1])
        dark = float(parts[3].split('=')[1])
        mt.result('PASS' if lit - dark > 0.1 else 'FAIL', cid,
                  f'止めた点が床に見える（回転 {turn}）: 点のマス {lit:.3f} / 暗いマス {dark:.3f} / {text}')
        shot(f'rl_ball_{cid}.png')

    # how fast one spot light shows and goes, without and with the lamp's switchLight
    for cid, mode in (('B4', 'none'), ('B5', 'switch'), ('B6', 'none'), ('B7', 'switch')):
        note(pilot.run('balloff')[1])
        time.sleep(4)
        text = pilot.run(f'balllatency {mode}', 25)[1]
        mt.result('INFO', cid, f'光の点 1 つを点けて消す（{"そのまま" if mode == "none" else "switchLight あり"}）: {text}')
        time.sleep(1)

    # turning
    pilot.run('ballpause off')
    time.sleep(2)
    for i in range(10):
        pilot.run(f'shot rl_ball_run_{i:02d}.png')
        time.sleep(0.3)
    mt.result('INFO', 'P1', f'ミラーボールが回っているとき: {pilot.run("perf 10", 25)[1]} / {pilot.run("ball")[1]}')
    pilot.run('ballpause on')
    pilot.run('ballturn 0')
    time.sleep(1)
    mt.result('INFO', 'P2', f'止めたとき: {pilot.run("perf 10", 25)[1]}')

    # floor markers instead of lights
    note(pilot.run('ballmode marker')[1])
    pilot.run('ballpause off')
    time.sleep(3)
    note(pilot.run('ball')[1])
    for i in range(4):
        pilot.run(f'shot rl_ball_marker_{i:02d}.png')
        time.sleep(0.5)
    mt.result('INFO', 'P3', f'床の印で回しているとき: {pilot.run("perf 10", 25)[1]}')
    pilot.run('ballmode light')
    pilot.run('ui on')


def room_tests(pilot, x, y, z, shots):
    """Mirror ball in a room of a house: spots inside, and nothing through the walls"""
    ball_bulb = 'RainbowLight.LightBulbMirrorBall'
    pilot.run('ballpause on')
    kind, text, _ = pilot.run(f'server placeroom {x} {y} {z} bulb={ball_bulb}', 30)
    note(f'placeroom: {kind} {text}')
    if kind != 'done':
        mt.problem('部屋にランプを置けませんでした: ' + text)
        return
    lx, ly, lz, sx, sy = text.split()[:5]
    lamp = f'{lx} {ly} {lz}'
    mt.rcon(f'teleportto "test1" {sx},{sy},{lz}')
    time.sleep(6)
    note('server night: ' + pilot.run('server night 0 0 0 hour=23', 30)[1])
    note('client ' + pilot.run('time 23')[1])
    note('settle: ' + pilot.run(f'settle {lamp}', 170)[1])
    pilot.run('ui off')

    def shot(name):
        pilot.run(f'shot {name}')
        time.sleep(2)

    info = pilot.run('ballroom')[1]
    vals = dict(p.split('=') for p in info.split() if '=' in p)
    n = int(vals.get('squares', 0))
    mt.result('PASS' if n > 0 and vals.get('inRoom') == str(n) else 'FAIL', 'I1',
              f'部屋の中のランプで、光の点用の光が全部同じ部屋にできる: {info}')
    shot('rl_room_0_paused.png')

    # a spot lights its square: the lit spot squares, then the same squares with every spot off;
    # lit squares against the rest is kept for information (the spots' light fills a small room)
    for cid, turn in (('I2', 0.0), ('I3', 0.37)):
        note(pilot.run(f'ballturn {turn}')[1])
        time.sleep(2)
        spread = pilot.run('ballmeasure')[1]
        shot(f'rl_room_{cid}.png')
        text = pilot.run(f'ballgain {turn}', 20)[1]
        vals = dict(p.split('=') for p in text.split() if '=' in p)
        on, off = float(vals.get('on', 0)), float(vals.get('off', 0))
        mt.result('PASS' if on - off > 0.1 else 'FAIL', cid,
                  f'部屋の中で止めた点が床に見える（回転 {turn}）: 点のマス 点けたとき {on:.3f} / 消したとき {off:.3f}'
                  f' / {text} / 点のマスとほかのマス: {spread}')

    pilot.run('ballpause off')
    time.sleep(2)
    for i in range(10):
        pilot.run(f'shot rl_room_run_{i:02d}.png')
        time.sleep(0.3)
    mt.result('INFO', 'P1', f'部屋の中で回しているとき: {pilot.run("perf 10", 25)[1]}')

    # from outdoors: does the light come through the wall?
    kind, spot, _ = pilot.run('ballwallspot')
    note(f'wall spot: {kind} {spot}')
    if kind != 'done':
        mt.result('INFO', 'I4', f'部屋のそばに外のマスがないので壁の確認はできない: {spot}')
        pilot.run('ui on')
        return
    wx, wy, wz = spot.split()
    mt.rcon(f'teleportto "test1" {wx},{wy},{wz}')
    time.sleep(6)
    note(pilot.run('balloff')[1])
    time.sleep(4)
    text = pilot.run('ballwall', 25)[1]
    note('ballwall: ' + text)
    try:
        vals = dict(p.split('=') for p in text.split('|')[-2].split())
        wall_max, probe_max = float(vals['wallMax']), float(vals['probeMax'])
        # wallMax -1: no seen square away from windows and doors
        ok = 0 <= wall_max < 0.05 and probe_max > wall_max + 0.1
    except (IndexError, KeyError, ValueError):
        ok = False
    mt.result('PASS' if ok else 'FAIL', 'I4', '壁ぎわの光を全部点けても、窓やドアから離れた壁の外は明るくならない'
              f'（外に同じ光を置くと明るくなる）: {text}')
    pilot.run('ballpause off')
    time.sleep(2)
    for i in range(4):
        pilot.run(f'shot rl_room_outside_{i:02d}.png')
        time.sleep(0.5)
    pilot.run('ui on')


def run_tests(root, gif=False, car=False, ball=False, room=False):
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
        if car:
            car_tests(pilot, x, y, z, shots)
            return
        if ball:
            ball_tests(pilot, x, y, z, shots)
            return
        if room:
            room_tests(pilot, x, y, z, shots)
            return
        kind, text, _ = pilot.run(f'server place {x} {y} {z} bulb=Base.LightBulb', 30)
        note(f'place: {kind} {text}')
        if kind != 'done':
            mt.problem('ランプを置けませんでした: ' + text)
            return
        lx, ly, lz = text.split()[:3]
        lamp = f'{lx} {ly} {lz}'
        mt.rcon(f'teleportto "test1" {int(lx) + 2},{int(ly) + 2},{lz}')
        time.sleep(6)

        if not gif:
            # R: the rainbow bulb is made from one bulb of each of the 9 colors (screwdriver kept)
            colors = ['Red', 'Orange', 'Yellow', 'Green', 'Cyan', 'Blue', 'Purple', 'Magenta', 'Pink']
            bulbs = [f'Base.LightBulb{c}' for c in colors]
            recipe = 'RL_MakeRainbowBulb'
            note('strip: ' + pilot.run('server strip 0 0 0', 30)[1])
            time.sleep(2)
            can = pilot.run(f'cancraft {recipe}')[1]
            mt.result('PASS' if can == 'false' else 'FAIL', 'R1', f'電球なしでは作れない: cancraft={can}')
            note(pilot.run('server give 0 0 0 items=' + ','.join(bulbs[:-1] + ['Base.Screwdriver']), 30)[1])
            time.sleep(2)
            can = pilot.run(f'cancraft {recipe}')[1]
            mt.result('PASS' if can == 'false' else 'FAIL', 'R2', f'ピンクだけ足りないと作れない: cancraft={can}')
            note(pilot.run('server give 0 0 0 items=Base.LightBulbPink', 30)[1])
            time.sleep(2)
            can = pilot.run(f'cancraft {recipe}')[1]
            made = pilot.run(f'craft {recipe}', 70)[1]
            counts = pilot.run(f'count {BULB} Base.Screwdriver ' + ' '.join(bulbs))[1]
            note(f'craft: {made} / {counts}')
            vals = dict(p.split('=') for p in counts.split())
            ok = (can == 'true' and vals.get(BULB) == '1' and vals.get('Base.Screwdriver') == '1'
                  and all(vals.get(b) == '0' for b in bulbs))
            mt.result('PASS' if ok else 'FAIL', 'R3',
                      f'9 色そろうと作れて、9 色が減りドライバーは残る: cancraft={can} {made} {counts}')

        kind, text, _ = pilot.run('server night 0 0 0 hour=23', 30)
        note(f'server night: {text}')
        note('client ' + pilot.run('time 23')[1])
        # night falls slowly; until it is dark the light is capped and no color shows
        note('settle: ' + pilot.run(f'settle {lamp}', 170)[1])
        pilot.run('ui off')

        if gif:
            # one trip around the rainbow in GIF_FRAMES steps, each shown after the light settled;
            # tools/make_gif.py plays them back at the mod's speed (PERIOD_MS)
            note('server ' + pilot.run(f'server bulb {lamp} bulb={BULB}', 30)[1])
            note('cycle ' + pilot.run('cycle off')[1])
            time.sleep(3)
            for i in range(GIF_FRAMES):
                pilot.run(f'hue {i / GIF_FRAMES:.4f}')
                time.sleep(0.6)
                pilot.run(f'shot rl_gif_{i:02d}.png')
                time.sleep(0.6)
            note(f'{GIF_FRAMES} frames: ' + str(shots / 'rl_gif_*.png'))
            return

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
    ap.add_argument('--gif', action='store_true', help='only film one trip around the rainbow for tools/make_gif.py')
    ap.add_argument('--car', action='store_true', help='only the headlight tests (prototype)')
    ap.add_argument('--ball', action='store_true', help='only the mirror ball tests (prototype)')
    ap.add_argument('--room', action='store_true', help='only the mirror ball in a room of a house (prototype)')
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
    run_tests(root, gif=a.gif, car=a.car, ball=a.ball, room=a.room)

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
