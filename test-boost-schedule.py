# Mirror of windowOpen() in jgrp-skills/config.lua, to exercise the wrap cases.
DAYS = dict(sun=1, mon=2, tue=3, wed=4, thu=5, fri=6, sat=7)
NAME = {v: k for k, v in DAYS.items()}

def minutes_of(t):
    h, m = t.split(':'); h, m = int(h), int(m)
    return None if (h > 23 or m > 59) else h * 60 + m

def days_of(entry):
    d = entry.get('days')
    if not d: return None
    s = {DAYS[x] for x in d if x in DAYS}
    return s or None

def window_open(entry, wday, hour, minute):
    frm, to = minutes_of(entry['from']), minutes_of(entry['to'])
    if frm is None or to is None: return False
    days = days_of(entry)
    now = hour * 60 + minute
    if frm <= to:
        if days and wday not in days: return False
        return frm <= now <= to
    yesterday = 7 if wday == 1 else wday - 1
    if now >= frm:  return (days is None) or (wday in days)
    if now <= to:   return (days is None) or (yesterday in days)
    return False

WEEKEND = {'days': ['fri','sat','sun'], 'from':'00:00', 'to':'23:59'}
FRINIGHT = {'days': ['fri'], 'from':'18:00', 'to':'02:00'}
NIGHTLY = {'from':'18:00', 'to':'02:00'}

cases = [
    ("weekend, Sat noon",        WEEKEND,  7, 12, 0,  True),
    ("weekend, Mon noon",        WEEKEND,  2, 12, 0,  False),
    ("weekend, Fri 00:00 edge",  WEEKEND,  6,  0, 0,  True),
    ("weekend, Sun 23:59 edge",  WEEKEND,  1, 23,59,  True),
    ("fri-night, Fri 20:00",     FRINIGHT, 6, 20, 0,  True),
    ("fri-night, Sat 01:00",     FRINIGHT, 7,  1, 0,  True),
    ("fri-night, Sat 20:00",     FRINIGHT, 7, 20, 0,  False),
    ("fri-night, Fri 03:00",     FRINIGHT, 6,  3, 0,  False),
    ("fri-night, Sun 01:00",     FRINIGHT, 1,  1, 0,  False),
    ("fri-night, Fri 18:00 edge",FRINIGHT, 6, 18, 0,  True),
    ("fri-night, Sat 02:00 edge",FRINIGHT, 7,  2, 0,  True),
    ("fri-night, Sat 02:01",     FRINIGHT, 7,  2, 1,  False),
    ("nightly, Wed 23:00",       NIGHTLY,  4, 23, 0,  True),
    ("nightly, Wed 01:00",       NIGHTLY,  4,  1, 0,  True),
    ("nightly, Wed 12:00",       NIGHTLY,  4, 12, 0,  False),
]

bad = 0
for name, entry, wday, h, m, want in cases:
    got = window_open(entry, wday, h, m)
    ok = got == want
    bad += not ok
    print("%-4s %-28s %s(%s) -> %-5s want %-5s" % ("ok" if ok else "FAIL", name, NAME[wday], "%02d:%02d" % (h, m), got, want))
print("\n%d/%d passed" % (len(cases) - bad, len(cases)))
