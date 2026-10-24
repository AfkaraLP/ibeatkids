# Wall-clock time and number formatting (cache.go's timestamps, format.go).
#
# A time is a Nat of milliseconds since the Unix epoch, with 0 standing for
# Go's zero time.Time. IO.now() counts from process start, so main reads the
# epoch once at startup and keeps the offset (see `Clock`).

import Base
import ./text.bend as T

# Dates
# -----

# Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
# days_from_civil, in Nat: valid for every year from 1 on).
def days_from_civil(y: Nat, +m: Nat, d: Nat) -> Nat:
  +early = Nat.is_le(m, 2n)
  +yy = Nat.sub(Nat.add(y, 400n), Bool.pick(Nat, early, 1n, 0n))
  +era = Nat.div(yy, 400n)
  +yoe = Nat.sub(yy, Nat.mul(era, 400n))
  +mp = Bool.pick(Nat, early, Nat.add(m, 9n), Nat.sub(m, 3n))
  +doy = Nat.add(Nat.div(Nat.add(Nat.mul(153n, mp), 2n), 5n), Nat.sub(d, 1n))
  +doe = Nat.add(Nat.sub(Nat.add(Nat.mul(yoe, 365n), Nat.div(yoe, 4n)), Nat.div(yoe, 100n)), doy)
  Nat.sub(Nat.add(Nat.mul(Nat.sub(era, 1n), 146097n), doe), 719468n)

type Civil is Data:
  Civil{y: Nat, m: Nat, d: Nat}

def civil_from_days(z0: Nat) -> Civil:
  +z = Nat.add(z0, 719468n)
  +era = Nat.div(z, 146097n)
  +doe = Nat.sub(z, Nat.mul(era, 146097n))
  +yoe = Nat.div(Nat.sub(Nat.add(Nat.sub(doe, Nat.div(doe, 1460n)), Nat.div(doe, 36524n)), Nat.div(doe, 146096n)), 365n)
  +doy = Nat.sub(doe, Nat.sub(Nat.add(Nat.mul(365n, yoe), Nat.div(yoe, 4n)), Nat.div(yoe, 100n)))
  +mp = Nat.div(Nat.add(Nat.mul(5n, doy), 2n), 153n)
  +d = Nat.add(Nat.sub(doy, Nat.div(Nat.add(Nat.mul(153n, mp), 2n), 5n)), 1n)
  +m = Bool.pick(Nat, Nat.is_lt(mp, 10n), Nat.add(mp, 3n), Nat.sub(mp, 9n))
  +y = Nat.add(yoe, Nat.mul(era, 400n))
  Civil{Bool.pick(Nat, Nat.is_le(m, 2n), Nat.add(y, 1n), y), m, d}

# Zero-padded decimal of width `w`.
def pad(+n: Nat, w: Nat) -> String:
  +s = Nat.show(n)
  String.repeat("0", Nat.sub(w, T.len(s))) ++ s

def day_ms() -> Nat:
  86400000n

def stamp.date(c: Civil, +secs: Nat) -> String:
  match c:
    case Civil{+y, +m, +d}:
      T.concat([pad(y, 4n), "-", pad(m, 2n), "-", pad(d, 2n), "T",
        pad(Nat.div(secs, 3600n), 2n), ":", pad(Nat.mod(Nat.div(secs, 60n), 60n), 2n), ":",
        pad(Nat.mod(secs, 60n), 2n)])

# "2026-10-24T07:42:50" for a time in ms (no zone, no fraction).
def stamp(+ms: Nat) -> String:
  +secs = Nat.div(Nat.mod(ms, day_ms()), 1000n)
  stamp.date(civil_from_days(Nat.div(ms, day_ms())), secs)

def zero_time() -> String:
  "0001-01-01T00:00:00Z"

# time.RFC3339 in UTC: "2026-10-24T07:42:50Z".
def rfc3339(+ms: Nat) -> String:
  Bool.pick(String, Nat.is_eq(ms, 0n), zero_time(), stamp(ms) ++ "Z")

def frac.trim(s: String) -> String:
  match s:
    case SCon{'0', t}:
      frac.trim(t)
    case other:
      other

# time.RFC3339Nano in UTC, at millisecond precision: trailing zeros of the
# fraction are dropped, as Go does ("…:50.743Z", "…:50.7Z", "…:50Z").
def rfc3339_ms(+ms: Nat) -> String:
  +f = String.reverse(frac.trim(String.reverse(pad(Nat.mod(ms, 1000n), 3n))))
  Bool.pick(String, Nat.is_eq(ms, 0n), zero_time(),
    stamp(ms) ++ Bool.pick(String, String.is_empty(f), "", "." ++ f) ++ "Z")

def rfc_name(n: Nat, xs: List<&2, String>) -> String:
  Maybe.default(&2, String, List.get(&2, String, xs, n), "")

def weekday(+days: Nat) -> String:
  rfc_name(Nat.mod(Nat.add(days, 4n), 7n), ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"])

def month_name(+m: Nat) -> String:
  rfc_name(Nat.sub(m, 1n), ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])

def http_date.civil(c: Civil, +days: Nat, +secs: Nat) -> String:
  match c:
    case Civil{+y, +m, +d}:
      T.concat([weekday(days), ", ", pad(d, 2n), " ", month_name(m), " ", pad(y, 4n), " ",
        pad(Nat.div(secs, 3600n), 2n), ":", pad(Nat.mod(Nat.div(secs, 60n), 60n), 2n), ":",
        pad(Nat.mod(secs, 60n), 2n), " GMT"])

# The Date header: "Sat, 24 Oct 2026 07:45:46 GMT".
def http_date(+ms: Nat) -> String:
  +days = Nat.div(ms, day_ms())
  http_date.civil(civil_from_days(days), days, Nat.div(Nat.mod(ms, day_ms()), 1000n))

# Parsing
# -------

def num_at(+s: String, +at: Nat, +w: Nat) -> Maybe<&2, Nat>:
  Nat.read(T.take(T.drop(s, at), w))

def frac_ms.go(r: String & String) -> Nat:
  (ds, rest) = r
  Maybe.default(&2, Nat, Nat.read(T.take(ds ++ "000", 3n)), 0n)

def frac_ms(+s: String) -> Nat:
  frac_ms.go(T.digits(s))

def zone.hm(+t: String) -> Nat:
  Nat.mul(Nat.add(Nat.mul(Maybe.default(&2, Nat, num_at(t, 0n, 2n), 0n), 60n),
    Maybe.default(&2, Nat, num_at(t, 3n, 2n), 0n)), 60000n)

def zone.go(+z: String) -> Bool & Nat:
  match z:
    case SCon{'+', t}:
      (False{}, zone.hm(t))
    case SCon{'-', t}:
      (True{}, zone.hm(t))
    case other:
      (False{}, 0n)

# The zone after the seconds (and fraction): (sign is minus, offset in ms).
def zone(+s: String) -> Bool & Nat:
  zone.go(Pair.snd(String, String, T.digits(s)))

def parse.fin(+base: Nat, z: Bool & Nat) -> Nat:
  (minus, +off) = z
  Bool.pick(Nat, minus, Nat.add(base, off), Nat.sub(base, off))

def parse.fields(+s: String, y: Nat, mo: Nat, d: Nat, +h: Nat, +mi: Nat, +se: Nat) -> Maybe<&2, Nat>:
  +days = days_from_civil(y, mo, d)
  +tail = T.drop(s, 19n)
  +frac = Bool.pick(Nat, T.starts_with(tail, "."), frac_ms(T.drop(tail, 1n)), 0n)
  +base = Nat.add(Nat.mul(Nat.add(Nat.add(Nat.add(Nat.mul(days, 86400n), Nat.mul(h, 3600n)), Nat.mul(mi, 60n)), se), 1000n), frac)
  Some{parse.fin(base, zone(Bool.pick(String, T.starts_with(tail, "."), T.drop(tail, 1n), tail)))}

def parse.year.go(+s: String, +y: Nat, early: Bool) -> Maybe<&2, Nat>:
  match early:
    case True{}:
      Some{0n}
    case False{}:
      do Maybe<&2, Nat>:
        mo : Nat <- num_at(s, 5n, 2n)
        d : Nat <- num_at(s, 8n, 2n)
        h : Nat <- num_at(s, 11n, 2n)
        mi : Nat <- num_at(s, 14n, 2n)
        se : Nat <- num_at(s, 17n, 2n)
        r : Nat <- parse.fields(s, y, mo, d, h, mi, se)
        return r

def parse.year(+s: String, +y: Nat) -> Maybe<&2, Nat>:
  parse.year.go(s, y, Nat.is_lt(y, 1970n))

# RFC 3339 ("2024-12-21T18:00:17+00:00", "2026-10-24T07:42:50.743519479Z")
# to ms. Years before 1970 (Go's zero time) read as 0.
def parse(+s: String) -> Maybe<&2, Nat>:
  Maybe.bind(&2, Nat, Nat, num_at(s, 0n, 4n), y => parse.year(s, y))

# Relative time and numbers (format.go)
# -------------------------------------

def ago.unit(+n: Nat, +name: String) -> String:
  Bool.pick(String, Nat.is_eq(n, 1n), "1 " ++ name ++ " ago", Nat.show(n) ++ " " ++ name ++ "s ago")

type Span is Data:
  Span{name: String, size: Nat}

def ago.go(+d: Nat, us: List<&2, Span>) -> String:
  match us:
    case Nil{}:
      "just now"
    case Con{Span{+name, +size}, rest}:
      Bool.pick(String, Nat.is_ge(d, size), ago.unit(Nat.div(d, size), name), ago.go(d, rest))

# A YouTube-style relative time ("3 weeks ago"); "" for the zero time.
def ago(+t: Nat, +now: Nat) -> String:
  Bool.pick(String, Nat.is_eq(t, 0n), "",
    ago.go(Nat.sub(now, t), [Span{"year", Nat.mul(365n, day_ms())}, Span{"month", Nat.mul(30n, day_ms())},
      Span{"week", Nat.mul(7n, day_ms())}, Span{"day", day_ms()}, Span{"hour", 3600000n},
      Span{"minute", 60000n}, Span{"second", 1000n}]))

# n / unit to one decimal: (n * 10 / unit) rounded half up.
def tenths(+n: Nat, +unit: Nat) -> String:
  +t = Nat.div(Nat.add(Nat.mul(n, 20n), unit), Nat.mul(unit, 2n))
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n))

# The original site's style: 712000 -> "712.0k", 1500000 -> "1.5M".
def abbrev(+n: Nat) -> String:
  Bool.pick(String, Nat.is_ge(n, 1000000n), tenths(n, 1000000n) ++ "M",
    Bool.pick(String, Nat.is_ge(n, 1000n), tenths(n, 1000n) ++ "k", Nat.show(n)))

def commas.go(s: String, +i: Nat, +acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{+c, t}:
      commas.go(t, 1n+i, Bool.pick(String, Bool.and(Nat.is_eq(Nat.mod(i, 3n), 0n), Nat.is_gt(i, 0n)),
        SCon{c, SCon{',', acc}}, SCon{c, acc}))

# 188291 -> "188,291".
def commas(+n: Nat) -> String:
  commas.go(String.reverse(Nat.show(n)), 0n, "")
