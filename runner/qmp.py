#!/usr/bin/env python3
"""QMP control plane for the lab guest. Runs inside the runner container, where
/labrun/qmp.sock is qemu's QMP socket.

    qmp.py shot  <png-path>
    qmp.py keys  <string>            Oligarchy key encoding, see below
    qmp.py mouse <x> <y> [button] [clicks]
    qmp.py powerdown
    qmp.py raw   <json-command>
    qmp.py selftest                  key-encoding vectors, no VM needed
    qmp.py proxy <port>              stdio <-> 127.0.0.1:<port> (ssh ProxyCommand)

Key encoding (ported from ThePrimeagen/Oligarchy src/qemu/keys.ts, which is the
spec — wire behaviour must match it):
  - letters type as written; "A" is shift+a, you never add shift yourself
  - special keys in angle brackets: <ENTER> <ESC> <TAB> <BS> <DEL> <SPACE> <UP>
    <DOWN> <LEFT> <RIGHT> <HOME> <END> <PGUP> <PGDN> <F1>..<F24> <LT> <GT>
  - modifiers: <C-c> ctrl, <A-x> alt, <S-x> shift, <M-x> meta; combine <C-S-c>
  - a bare <META_L> taps the Super key
"""
import json
import re
import socket
import sys
import time

SOCK = "/labrun/qmp.sock"

# Chords are paced: the guest drains input slowly, and virtio-input's small
# event virtqueue drops events when the guest has no buffer posted. 60ms per
# chord keeps a 1000-char string lossless (Oligarchy's measured value).
KEY_CHORD_GAP = 0.06
# Guest double-click detection needs a gap between press/release pairs.
MULTI_CLICK_GAP = 0.05
# QEMU INPUT_EVENT_ABS_MAX: tablet axes run 0..0x7fff.
TABLET_AXIS_MAX = 0x7FFF

NAMED = {
    "ENTER": "ret", "RETURN": "ret", "CR": "ret", "RET": "ret",
    "ESC": "esc", "ESCAPE": "esc", "TAB": "tab",
    "BS": "backspace", "BACKSPACE": "backspace",
    "DEL": "delete", "DELETE": "delete", "INS": "insert", "INSERT": "insert",
    "SPACE": "spc", "SPC": "spc",
    "UP": "up", "DOWN": "down", "LEFT": "left", "RIGHT": "right",
    "HOME": "home", "END": "end",
    "PGUP": "pgup", "PAGEUP": "pgup", "PGDN": "pgdn", "PAGEDOWN": "pgdn",
    "LT": "less", "MENU": "menu",
    "CAPSLOCK": "caps_lock", "NUMLOCK": "num_lock", "SCROLLLOCK": "scroll_lock",
    "PRINT": "print", "PAUSE": "pause", "SYSREQ": "sysrq",
    "CTRL": "ctrl", "ALT": "alt", "SHIFT": "shift", "META_L": "meta_l",
}

SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", ":": "semicolon",
    '"': "apostrophe", "~": "grave_accent", "|": "backslash",
    "<": "comma", ">": "dot", "?": "slash",
}

UNSHIFTED = {
    " ": "spc", "\n": "ret", "\r": "ret", "\t": "tab",
    "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right",
    ";": "semicolon", "'": "apostrophe", "`": "grave_accent", "\\": "backslash",
    ",": "comma", ".": "dot", "/": "slash",
}

MODIFIERS = {
    "C": "ctrl", "CTRL": "ctrl", "CONTROL": "ctrl",
    "A": "alt", "ALT": "alt",
    "S": "shift", "SHIFT": "shift",
    "M": "meta_l", "META": "meta_l",
}


def char_chord(char):
    if "a" <= char <= "z" or "0" <= char <= "9":
        return [char]
    if "A" <= char <= "Z":
        return ["shift", char.lower()]
    if char in UNSHIFTED:
        return [UNSHIFTED[char]]
    if char in SHIFTED:
        return ["shift", SHIFTED[char]]
    raise SystemExit(f'qmp: unsupported character "{char}"')


def key_name(name):
    if name.upper() in NAMED:
        return [NAMED[name.upper()]]
    if len(name) == 1:
        return char_chord(name)
    # Any documented qcode token (f1..f24, kp_*, caps_lock, ...) passes through;
    # qcodes are lowercase [a-z0-9_], so a stray "f}" never reaches QMP.
    lower = name.lower()
    if re.fullmatch(r"[a-z0-9_]+", lower) and (lower == "unmapped" or "_" in lower or lower.startswith("f")):
        return [lower]
    raise SystemExit(f'qmp: unknown key "{name}"')


def angle_chord(inner):
    if inner == "":
        raise SystemExit("qmp: empty key sequence")
    parts = inner.split("-")
    chord = []
    for part in parts[:-1]:
        if part.upper() not in MODIFIERS:
            raise SystemExit(f'qmp: unknown modifier "{part}"')
        chord.append(MODIFIERS[part.upper()])
    name = parts[-1]
    if name.upper() == "GT":  # shift+dot on a US keyboard
        return chord + ["shift", "dot"]
    return chord + key_name(name)


def parse_keys(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "<":
            end = s.find(">", i + 1)
            if end < 0:
                raise SystemExit("qmp: unterminated key sequence")
            out.append(angle_chord(s[i + 1:end]))
            i = end + 1
        else:
            out.append(char_chord(s[i]))
            i += 1
    return out


def connect():
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    f = s.makefile("rw")
    f.readline()  # greeting
    return f


def execute(f, command, arguments=None):
    msg = {"execute": command}
    if arguments is not None:
        msg["arguments"] = arguments
    f.write(json.dumps(msg) + "\n")
    f.flush()
    while True:
        reply = json.loads(f.readline())
        if "event" in reply:  # async events interleave; skip to our reply
            continue
        if "error" in reply:
            raise SystemExit(f"qmp: {command}: {reply['error']['desc']}")
        return reply["return"]


def abs_at(x, y):
    return [
        {"type": "abs", "data": {"axis": "x", "value": round(x * TABLET_AXIS_MAX)}},
        {"type": "abs", "data": {"axis": "y", "value": round(y * TABLET_AXIS_MAX)}},
    ]


# Last pointer position, so the next move can start where the previous ended.
# Lives beside the socket so it resets with the VM.
POINTER = "/labrun/pointer.json"
SWEEP_STEPS = 20
SWEEP_STEP_GAP = 0.02

def sweep(f, x, y):
    # A single absolute warp updates the cursor but Hyprland's follow_mouse does
    # not refocus on it; a stepped sweep across the window boundary does
    # (measured on Hyprland 0.56). So every move is a short sweep from the last
    # known position, which is also what a hand does.
    try:
        with open(POINTER) as p:
            sx, sy = json.load(p)
    except (OSError, ValueError):
        sx, sy = 0.5, 0.5
    # Refocus needs motion. If the target is where we already are, start the
    # sweep from a point nudged toward the screen centre instead.
    if abs(x - sx) < 0.01 and abs(y - sy) < 0.01:
        sx = x + (0.05 if x < 0.5 else -0.05)
        sy = y + (0.05 if y < 0.5 else -0.05)
    for i in range(1, SWEEP_STEPS + 1):
        t = i / SWEEP_STEPS
        execute(f, "input-send-event", {"events": abs_at(sx + (x - sx) * t, sy + (y - sy) * t)})
        time.sleep(SWEEP_STEP_GAP)
    with open(POINTER, "w") as p:
        json.dump([x, y], p)

# The vectors from Oligarchy's keys.test.ts: the port must keep matching them.
VECTORS = {
    "hi": [["h"], ["i"]], "42": [["4"], ["2"]], "A": [["shift", "a"]],
    "Hi": [["shift", "h"], ["i"]], " ": [["spc"]], "\n": [["ret"]], "\t": [["tab"]],
    "-": [["minus"]], ".": [["dot"]], "/": [["slash"]], "!": [["shift", "1"]],
    "?": [["shift", "slash"]], ":": [["shift", "semicolon"]], "{": [["shift", "bracket_left"]],
    "<ENTER>": [["ret"]], "<enter>": [["ret"]], "<RETURN>": [["ret"]], "<esc>": [["esc"]],
    "<BS>": [["backspace"]], "<SPACE>": [["spc"]], "<PGDN>": [["pgdn"]],
    "<C-c>": [["ctrl", "c"]], "<CTRL-c>": [["ctrl", "c"]], "<A-x>": [["alt", "x"]],
    "<M-x>": [["meta_l", "x"]], "<S-a>": [["shift", "a"]], "<C-S-c>": [["ctrl", "shift", "c"]],
    "<C-ENTER>": [["ctrl", "ret"]], "<LT>": [["less"]], "<GT>": [["shift", "dot"]],
    "<F1>": [["f1"]], "<F13>": [["f13"]], "<kp_enter>": [["kp_enter"]],
    "<caps_lock>": [["caps_lock"]], "<unmapped>": [["unmapped"]],
    "Hi<ENTER>": [["shift", "h"], ["i"], ["ret"]], "a<C-c>b": [["a"], ["ctrl", "c"], ["b"]],
    "": [], "a": [["a"]], "<META_L>": [["meta_l"]], "<M-ENTER>": [["meta_l", "ret"]],
}


def selftest():
    bad = {s: parse_keys(s) for s, want in VECTORS.items() if parse_keys(s) != want}
    for s in ["<nope>", "<Q-x>", "<", "é"]:
        try:
            parse_keys(s)
            bad[s] = "accepted, should reject"
        except SystemExit:
            pass
    if bad:
        raise SystemExit(f"qmp selftest: {len(bad)} failure(s): {bad}")
    print(f"qmp selftest: {len(VECTORS)} vectors + 4 rejections ok")


# ssh ProxyCommand target: relays stdin/stdout to a TCP port inside this
# container's network namespace. With the container on --network none, this is
# the only way in — qemu's hostfwd listens on the container's loopback, which
# nothing outside the container can reach.
def proxy(port):
    import selectors
    s = socket.create_connection(("127.0.0.1", port))
    sel = selectors.DefaultSelector()
    sel.register(sys.stdin.buffer, selectors.EVENT_READ, "in")
    sel.register(s, selectors.EVENT_READ, "sock")
    while True:
        for key, _ in sel.select():
            if key.data == "in":
                data = sys.stdin.buffer.read1(65536)
                if not data:
                    s.shutdown(socket.SHUT_WR)
                    sel.unregister(sys.stdin.buffer)
                    continue
                s.sendall(data)
            else:
                data = s.recv(65536)
                if not data:
                    return
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()


def main(argv):
    if argv[0] == "selftest":
        selftest()
        return
    if argv[0] == "proxy":
        proxy(int(argv[1]))
        return
    f = connect()
    execute(f, "qmp_capabilities")
    op = argv[0]
    if op == "shot":
        execute(f, "screendump", {"filename": argv[1], "format": "png"})
    elif op == "keys":
        # Not send-key: that presses, waits hold-time, then releases, and a guest
        # stalled under load between the two sees its own autorepeat fire
        # ("@" typed as "@@@@@" was measured). One input-send-event list keeps
        # press and release adjacent in the guest's queue, so no gap can open.
        chords = parse_keys(argv[1])
        for i, chord in enumerate(chords):
            down = [{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": c}}} for c in chord]
            up = [{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": c}}} for c in reversed(chord)]
            execute(f, "input-send-event", {"events": down + up})
            if i + 1 < len(chords):
                time.sleep(KEY_CHORD_GAP)
    elif op == "mouse":
        x, y = float(argv[1]), float(argv[2])
        sweep(f, x, y)
        if len(argv) < 4:
            return
        button = argv[3]
        clicks = int(argv[4]) if len(argv) > 4 else 1
        # The tablet applies an event list then syncs once, so down and up in the
        # same list cancel out and the guest never sees a click: two sends.
        for i in range(clicks):
            execute(f, "input-send-event",
                    {"events": abs_at(x, y) + [{"type": "btn", "data": {"button": button, "down": True}}]})
            execute(f, "input-send-event",
                    {"events": [{"type": "btn", "data": {"button": button, "down": False}}]})
            if i + 1 < clicks:
                time.sleep(MULTI_CLICK_GAP)
    elif op == "powerdown":
        execute(f, "system_powerdown")
    elif op == "raw":
        msg = json.loads(argv[1])
        print(json.dumps(execute(f, msg["execute"], msg.get("arguments"))))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
