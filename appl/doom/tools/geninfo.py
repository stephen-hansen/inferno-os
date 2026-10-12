#!/usr/bin/env python3
# Generate info.m / info.b for the Limbo Doom port from doomgeneric's
# information tables.  Reference C sources are read-only; the output
# is a Limbo Info module holding:
#   sprnames, states[] (sprite/frame/tics/action-name/next/misc),
#   mobjinfo[], the SPR_/S_/MT_ constant enums, MF_ flags, and the
#   exact finesine[10240] + rndtable[256] lookup tables.
#
# Usage: tools/geninfo.py <doomgeneric-dir> <out-dir>

import re
import sys
from pathlib import Path


def strip_c_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return text


def parse_enum_c(src, name):
    """Extract an enum body (names only, in order) from a C header."""
    m = re.search(r'typedef enum\s*\{([^}]*)\}\s*' + re.escape(name) + r'\s*;', src, re.S)
    if not m:
        raise SystemExit(f"enum {name} not found")
    body = strip_c_comments(m.group(1))
    out = []
    for part in body.split(','):
        part = part.strip()
        if part:
            out.append(part)
    return out


def parse_sprnames(src):
    m = re.search(r'char \*sprnames\[\]\s*=\s*\{([^}]*)\}', src, re.S)
    if not m:
        raise SystemExit("sprnames not found")
    return re.findall(r'"([A-Z0-9]+)"', m.group(1))


def parse_states(src):
    """Return list of (spr, frame, tics, action, next, misc1, misc2)."""
    m = re.search(r'state_t\s+states\[NUMSTATES\]\s*=\s*\{(.*)\n\};', src, re.S)
    if not m:
        raise SystemExit("states array not found")
    pat = re.compile(
        r'\{(SPR_\w+),\s*(-?\d+),\s*(-?\d+),\s*\{(\w+)\},\s*(\w+),\s*(-?\d+),\s*(-?\d+)\}'
    )
    rows = []
    for mm in pat.finditer(m.group(1)):
        spr, frame, tics, act, nxt, m1, m2 = mm.groups()
        rows.append((spr, int(frame), int(tics), act, nxt, int(m1), int(m2)))
    return rows


def parse_mobjinfo(src: str):
    """Return list of 23 raw field strings per mobjinfo entry."""
    m = re.search(r'mobjinfo_t\s+mobjinfo\[NUMMOBJTYPES\]\s*=\s*\{(.*)\n\};', src, re.S)
    if not m:
        raise SystemExit("mobjinfo array not found")
    body = m.group(1)
    # each entry starts with "{ ... // MT_NAME" and ends at a line with "}"
    entries = []
    cur = None
    for line in body.splitlines():
        if re.search(r'\{\s*(//|/\*)\s*MT_', line):
            if cur is not None:
                entries.append(cur)
            cur = line[line.index('{'):]
        elif cur is not None:
            cur += '\n' + line
            if re.match(r'\s*\}', line):
                entries.append(cur)
                cur = None
    if cur is not None:
        entries.append(cur)
    out = []
    for e in entries:
        inner = re.search(r'\{(.*)\}', e, re.S)
        if not inner:
            raise SystemExit(f"mobjinfo entry missing braces: {e[:80]}")
        clean = strip_c_comments(inner.group(1))
        fields = [f.strip() for f in clean.split(',')]
        fields = [f for f in fields if f != '']
        out.append(fields)
    return out


def parse_mf_flags(src):
    m = re.search(r'typedef enum\s*\{([^}]*)\}\s*mobjflag_t\s*;', src, re.S)
    if not m:
        raise SystemExit("mobjflag_t not found")
    body = strip_c_comments(m.group(1))
    vals = {}
    nxt = 0
    for part in body.split(','):
        part = part.strip()
        if not part:
            continue
        if '=' in part:
            name, v = part.split('=', 1)
            name = name.strip()
            v = v.strip().rstrip('uU')
            vals[name] = int(v, 0)
            nxt = vals[name] + 1
        else:
            vals[part] = nxt
            nxt += 1
    return vals


def parse_finesine(src):
    m = re.search(r'finesine\[10240\]\s*=\s*\{([^}]*)\}', src, re.S)
    if not m:
        raise SystemExit("finesine not found")
    return [int(x) for x in re.findall(r'-?\d+', m.group(1))]


def parse_rndtable(src):
    m = re.search(r'rndtable\[256\]\s*=\s*\{([^}]*)\}', src, re.S)
    if not m:
        raise SystemExit("rndtable not found")
    return [int(x) for x in re.findall(r'\d+', m.group(1))]


def limbo_enum(names, skip_suffixes=()):
    """Emit a Limbo `A, B, C: con iota;` constant-list body."""
    keep = [n for n in names if not any(n.endswith(s) for s in skip_suffixes)]
    lines = []
    for i in range(0, len(keep), 6):
        chunk = keep[i:i + 6]
        suffix = ',' if i + 6 < len(keep) else ': con iota;'
        lines.append('\t' + ', '.join(chunk) + suffix)
    return '\n'.join(lines)


def limbo_ints(vals, per=8):
    lines = []
    for i in range(0, len(vals), per):
        lines.append('\t' + ', '.join(str(v) for v in vals[i:i + per]) + ',')
    # trailing comma on last line is fine inside array[] literal? strip final comma
    if lines:
        lines[-1] = lines[-1].rstrip(',')
    return '\n'.join(lines)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    dg = Path(sys.argv[1])
    out = Path(sys.argv[2])

    info_c = (dg / 'info.c').read_text()
    info_h = (dg / 'info.h').read_text()
    pmobj_h = (dg / 'p_mobj.h').read_text()
    sounds_h = (dg / 'sounds.h').read_text()
    tables_c = (dg / 'tables.c').read_text()
    mrand_c = (dg / 'm_random.c').read_text()

    sprnames = parse_sprnames(info_c)
    spr_enum = parse_enum_c(info_h, 'spritenum_t')
    st_enum = parse_enum_c(info_h, 'statenum_t')
    mt_enum = parse_enum_c(info_h, 'mobjtype_t')
    sfx_enum = parse_enum_c(sounds_h, 'sfxenum_t')
    mf = parse_mf_flags(pmobj_h)
    states = parse_states(info_c)
    mobjinfo = parse_mobjinfo(info_c)
    finesine = parse_finesine(tables_c)
    rndtable = parse_rndtable(mrand_c)

    # sanity: enum counts match table sizes
    real_sprites = [n for n in spr_enum if not n.startswith('NUM')]
    real_states = [n for n in st_enum if not n.startswith('NUM')]
    real_mtypes = [n for n in mt_enum if not n.startswith('NUM')]
    real_sfx = [n for n in sfx_enum if not n.startswith('NUM')]
    assert len(sprnames) == len(real_sprites), (len(sprnames), len(real_sprites))
    assert len(states) == len(real_states), (len(states), len(real_states))
    assert len(mobjinfo) == len(real_mtypes), (len(mobjinfo), len(real_mtypes))
    assert len(finesine) == 10240
    assert len(rndtable) == 256

    # sfx -> int map
    sfx_val = {n: i for i, n in enumerate(sfx_enum)}
    # S_ / MT_ / SPR_ maps for expression eval
    spr_val = {n: i for i, n in enumerate(spr_enum)}
    st_val = {n: i for i, n in enumerate(st_enum)}
    mt_val = {n: i for i, n in enumerate(mt_enum)}

    # action name table (0 = none)
    actnames = ['None']
    act_val = {'NULL': 0}

    def act_index(name):
        if name == 'NULL':
            return 0
        if name not in act_val:
            act_val[name] = len(actnames)
            actnames.append(name)
        return act_val[name]

    state_rows = []
    for spr, frame, tics, act, nxt, m1, m2 in states:
        state_rows.append((spr_val[spr], frame, tics, act_index(act), st_val[nxt], m1, m2))

    env = {
        'FRACUNIT': 65536,
        'FRACBITS': 16,
        **{k: v for k, v in mf.items()},
        **sfx_val,
        **st_val,
        **mt_val,
        **spr_val,
    }

    mi_rows = []
    for fields in mobjinfo:
        if len(fields) != 23:
            raise SystemExit(f"mobjinfo entry has {len(fields)} fields, want 23: {fields}")
        row = []
        for f in fields:
            row.append(int(eval(f, {'__builtins__': {}}, env)))
        mi_rows.append(row)

    # ---- info.m ----------------------------------------------------------
    m = []
    m.append('# Generated by tools/geninfo.py from doomgeneric\'s info.c/info.h,')
    m.append('# p_mobj.h, sounds.h, tables.c and m_random.c (GPL-2).  Do not edit;')
    m.append('# regenerate instead.  States store the action as an index into')
    m.append('# actnames (0 = none) and nextstate as an S_ index.')
    m.append('')
    m.append('Info: module {')
    m.append('')
    m.append('\tPATH:\tcon "/dis/doom/info.dis";')
    m.append('')
    m.append('\t# --- sprites (spritenum_t) ---')
    m.append(limbo_enum(real_sprites))
    m.append('')
    m.append('\t# --- states (statenum_t); NUMSTATES = ' + str(len(real_states)) + ' ---')
    m.append(limbo_enum(real_states))
    m.append('')
    m.append('\t# --- mobj types (mobjtype_t); NUMMOBJTYPES = ' + str(len(real_mtypes)) + ' ---')
    m.append(limbo_enum(real_mtypes))
    m.append('')
    m.append('\t# --- mobj flags (mobjflag_t from p_mobj.h) ---')
    for k in sorted(mf, key=lambda x: mf[x]):
        m.append('\t%s:\tcon 16r%x;' % (k, mf[k]))
    m.append('')
    m.append('\tNUMSPRITES:\tcon ' + str(len(real_sprites)) + ';')
    m.append('\tNUMSTATES:\tcon ' + str(len(real_states)) + ';')
    m.append('\tNUMMOBJTYPES:\tcon ' + str(len(real_mtypes)) + ';')
    m.append('')
    m.append('\tState: adt {')
    m.append('\t\tsprite, frame, tics:\tint;')
    m.append('\t\taction:\tint;\t\t# index into actnames, 0 = none')
    m.append('\t\tnextstate:\tint;\t# S_ index')
    m.append('\t\tmisc1, misc2:\tint;')
    m.append('\t};')
    m.append('')
    m.append('\tMobjInfo: adt {')
    m.append('\t\tdoomednum, spawnstate, spawnhealth:\tint;')
    m.append('\t\tseestate, seesound, reactiontime, attacksound:\tint;')
    m.append('\t\tpainstate, painchance, painsound:\tint;')
    m.append('\t\tmeleestate, missilestate, deathstate, xdeathstate:\tint;')
    m.append('\t\tdeathsound, speed, radius, height, mass:\tint;')
    m.append('\t\tdamage, activesound, flags, raisestate:\tint;')
    m.append('\t};')
    m.append('')
    m.append('\t# build the tables; call once before any other use')
    m.append('\tinit:\tfn(): string;')
    m.append('')
    m.append('\t# S_/MT_ name for diagnostics (nil if out of range)')
    m.append('\tstatename:\tfn(s: int): string;')
    m.append('\tmtypename:\tfn(t: int): string;')
    m.append('')
    m.append('\tstates:\t\tarray of State;')
    m.append('\tmobjinfo:\tarray of MobjInfo;')
    m.append('\tsprnames:\tarray of string;')
    m.append('\tactnames:\tarray of string;')
    m.append('\tstatenames:\tarray of string;\t# S_ names for diagnostics')
    m.append('\tmtypenames:\tarray of string;\t# MT_ names for diagnostics')
    m.append('\tfinesine:\tarray of int;\t# 10240; finecosine is [i+2048]')
    m.append('\trndtable:\tarray of int;\t# 256, P_Random index in game.b')
    m.append('')
    m.append('};')
    (out / 'info.m').write_text('\n'.join(m) + '\n')

    # ---- info.b ----------------------------------------------------------
    b = []
    b.append('implement Info;')
    b.append('')
    b.append('include "info.m";')
    b.append('')
    b.append('init(): string')
    b.append('{')
    b.append('\tsprnames = array[] of {')
    for i in range(0, len(sprnames), 10):
        chunk = sprnames[i:i + 10]
        comma = ',' if i + 10 < len(sprnames) else ''
        b.append('\t\t' + ', '.join('"%s"' % s for s in chunk) + comma)
    b.append('\t};')
    b.append('')
    b.append('\tactnames = array[] of {')
    b.append('\t\t' + ', '.join('"%s"' % a for a in actnames))
    b.append('\t};')
    b.append('')
    b.append('\tstatenames = array[] of {')
    for i in range(0, len(real_states), 8):
        chunk = real_states[i:i + 8]
        comma = ',' if i + 8 < len(real_states) else ''
        b.append('\t\t' + ', '.join('"%s"' % s for s in chunk) + comma)
    b.append('\t};')
    b.append('')
    b.append('\tmtypenames = array[] of {')
    for i in range(0, len(real_mtypes), 6):
        chunk = real_mtypes[i:i + 6]
        comma = ',' if i + 6 < len(real_mtypes) else ''
        b.append('\t\t' + ', '.join('"%s"' % s for s in chunk) + comma)
    b.append('\t};')
    b.append('')
    b.append('\tstates = array[] of {')
    for i, (spr, frame, tics, act, nxt, m1, m2) in enumerate(state_rows):
        comma = ',' if i + 1 < len(state_rows) else ''
        b.append('\t\tState(%d, %d, %d, %d, %d, %d, %d)%s'
                 % (spr, frame, tics, act, nxt, m1, m2, comma))
    b.append('\t};')
    b.append('')
    b.append('\tmobjinfo = array[] of {')
    for i, row in enumerate(mi_rows):
        comma = ',' if i + 1 < len(mi_rows) else ''
        b.append('\t\tMobjInfo(%s)%s' % (', '.join(str(v) for v in row), comma))
    b.append('\t};')
    b.append('')
    b.append('\tfinesine = array[] of {')
    for i in range(0, len(finesine), 16):
        chunk = finesine[i:i + 16]
        comma = ',' if i + 16 < len(finesine) else ''
        b.append('\t\t' + ', '.join(str(v) for v in chunk) + comma)
    b.append('\t};')
    b.append('')
    b.append('\trndtable = array[] of {')
    for i in range(0, len(rndtable), 16):
        chunk = rndtable[i:i + 16]
        comma = ',' if i + 16 < len(rndtable) else ''
        b.append('\t\t' + ', '.join(str(v) for v in chunk) + comma)
    b.append('\t};')
    b.append('')
    b.append('\treturn nil;')
    b.append('}')
    b.append('')
    b.append('statename(s: int): string')
    b.append('{')
    b.append('\tif (s < 0 || s >= len statenames)')
    b.append('\t\treturn nil;')
    b.append('\treturn statenames[s];')
    b.append('}')
    b.append('')
    b.append('mtypename(t: int): string')
    b.append('{')
    b.append('\tif (t < 0 || t >= len mtypenames)')
    b.append('\t\treturn nil;')
    b.append('\treturn mtypenames[t];')
    b.append('}')
    (out / 'info.b').write_text('\n'.join(b) + '\n')

    sys.stderr.write(
        'geninfo: %d sprites, %d states, %d mobjinfo, %d actions, %d finesine\n'
        % (len(sprnames), len(states), len(mobjinfo), len(actnames), len(finesine))
    )


if __name__ == '__main__':
    main()
