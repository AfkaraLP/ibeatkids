# Text utilities. Every walk over a long string is a self tail call (Bend
# compiles those to loops), because the channel page is over a megabyte. A
# condition a loop needs is computed by the caller and carried into the next
# iteration as an argument, since a match may only inspect parameters.
# Builders (`acc`) are reversed strings.

import Base

# Pushes `s` onto a reversed builder.
def put(s: String, acc: String) -> String:
  String.reverse.go(s, acc)

def concat.go(xs: List<&2, String>, acc: String) -> String:
  match xs:
    case Nil{}:
      String.reverse(acc)
    case Con{x, rest}:
      concat.go(rest, put(x, acc))

# Concatenates without the non-tail `++` walk over the left operand.
def concat(xs: List<&2, String>) -> String:
  concat.go(xs, "")

def join.go(xs: List<&2, String>, +sep: String, acc: String) -> String:
  match xs:
    case Nil{}:
      String.reverse(acc)
    case Con{x, rest}:
      join.go(rest, sep, put(x, put(sep, acc)))

def join(xs: List<&2, String>, +sep: String) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, rest}:
      join.go(rest, sep, put(x, ""))

def len.go(s: String, n: Nat) -> Nat:
  match s:
    case SNil{}:
      n
    case SCon{c, t}:
      len.go(t, 1n+n)

def len(s: String) -> Nat:
  len.go(s, 0n)

def count.go(xs: List<&2, U32>, n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case Con{x, t}:
      count.go(t, 1n+n)

# Length of a byte list (Base's List.length is not a tail call).
def count(xs: List<&2, U32>) -> Nat:
  count.go(xs, 0n)

# Prefixes and search
# -------------------

# `ok` carries the last comparison, so the walk stays a self tail call.
def prefix.go(p: String, s: String, ok: Bool) -> Bool:
  match p s ok:
    case _ _ False{}:
      False{}
    case SNil{} _ True{}:
      True{}
    case SCon{a, pt} SNil{} True{}:
      False{}
    case SCon{Chr{x}, pt} SCon{Chr{y}, st} True{}:
      prefix.go(pt, st, U32.is_eq(x, y))

def starts_with(s: String, p: String) -> Bool:
  prefix.go(p, s, True{})

def drop(s: String, n: Nat) -> String:
  match s n:
    case SNil{} _:
      SNil{}
    case SCon{c, t} 0n:
      SCon{c, t}
    case SCon{c, t} 1n+p:
      drop(t, p)

def take_rev(s: String, n: Nat, acc: String) -> String:
  match s n:
    case SNil{} _:
      acc
    case SCon{c, t} 0n:
      acc
    case SCon{c, t} 1n+p:
      take_rev(t, p, SCon{c, acc})

def take(s: String, n: Nat) -> String:
  String.reverse(take_rev(s, n, ""))

def seek.go(s: String, +needle: String, hit: Bool) -> Maybe<&2, String>:
  match s hit:
    case rest True{}:
      Some{drop(rest, len(needle))}
    case SNil{} False{}:
      None{}
    case SCon{c, +t} False{}:
      seek.go(t, needle, starts_with(t, needle))

# What follows the first occurrence of `needle`, if any.
def seek(+s: String, +needle: String) -> Maybe<&2, String>:
  seek.go(s, needle, starts_with(s, needle))

def has(+s: String, +needle: String) -> Bool:
  Maybe.is_some(&2, String, seek(s, needle))

# (before, after) around the first `sep`, or (s, "") when it does not occur.
# `done` is set when the previous char was `sep`.
def split.loop(s: String, +sep: Char, +acc: String, done: Bool) -> String & String:
  match s done:
    case rest True{}:
      (String.reverse(acc), rest)
    case SNil{} False{}:
      (String.reverse(acc), "")
    case SCon{Chr{+x}, t} False{}:
      +hit = Char.is_eq(Chr{x}, sep)
      split.loop(t, sep, Bool.pick(String, hit, acc, SCon{Chr{x}, acc}), hit)

def split_once(s: String, +sep: Char) -> String & String:
  split.loop(s, sep, "", False{})

# The text before the first `sep` (all of it if there is none).
def until(s: String, +sep: Char) -> String:
  Pair.fst(String, String, split_once(s, sep))

# The text after the first `sep` ("" if there is none).
def after(s: String, +sep: Char) -> String:
  Pair.snd(String, String, split_once(s, sep))

def head_is(+s: String, +sep: Char) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      Char.is_eq(c, sep)

def head_digit(+s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      Char.is_digit(c)

# `hit`: the head of `s` is `sep`.
def split.all(s: String, +sep: Char, cur: String, acc: List<&2, String>, hit: Bool) -> List<&2, String>:
  match s hit:
    case SNil{} _:
      List.reverse(&2, String, String.reverse(cur) <> acc)
    case SCon{c, +t} True{}:
      split.all(t, sep, "", String.reverse(cur) <> acc, head_is(t, sep))
    case SCon{c, +t} False{}:
      split.all(t, sep, SCon{c, cur}, acc, head_is(t, sep))

# Splits on every `sep`: "a/b" is ["a", "b"], "" is [""].
def split(+s: String, +sep: Char) -> List<&2, String>:
  split.all(s, sep, "", Nil{}, head_is(s, sep))

def is_digit(c: Char) -> Bool:
  Char.is_digit(c)

def digits.go(s: String, acc: String, ok: Bool) -> String & String:
  match s ok:
    case SCon{c, +t} True{}:
      digits.go(t, SCon{c, acc}, head_digit(t))
    case rest _:
      (String.reverse(acc), rest)

# (leading decimal digits, the rest).
def digits(+s: String) -> String & String:
  digits.go(s, "", head_digit(s))

# Replaces the first occurrence of `from` with `to`.
def replace_first.go(s: String, +from: String, +to: String, acc: String, hit: Bool) -> String:
  match s hit:
    case rest True{}:
      String.reverse(put(drop(rest, len(from)), put(to, acc)))
    case SNil{} False{}:
      String.reverse(acc)
    case SCon{c, +t} False{}:
      replace_first.go(t, from, to, SCon{c, acc}, starts_with(t, from))

def replace_first(+s: String, +from: String, +to: String) -> String:
  replace_first.go(s, from, to, "", starts_with(s, from))

def ends_with(s: String, p: String) -> Bool:
  starts_with(String.reverse(s), String.reverse(p))

def ext.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'.', t}:
      String.to_lower(acc)
    case SCon{'/', t}:
      ""
    case SCon{c, t}:
      ext.go(t, SCon{c, acc})

# The extension of the last path segment, lowercased, without the dot.
def ext(s: String) -> String:
  ext.go(String.reverse(s), "")

# Entities and escapes
# --------------------

def hex_val(+c: Char) -> Maybe<&2, U32>:
  match c:
    case Chr{+x}:
      Bool.pick(Maybe<&2, U32>, Char.is_digit(Chr{x}), Some{(x - 48 : U32)},
        Bool.pick(Maybe<&2, U32>, Bool.and(U32.is_ge(x, 97), U32.is_le(x, 102)), Some{(x - 87 : U32)},
          Bool.pick(Maybe<&2, U32>, Bool.and(U32.is_ge(x, 65), U32.is_le(x, 70)), Some{(x - 55 : U32)}, None{})))

def hex_read.step(acc: Maybe<&2, U32>, d: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match acc d:
    case Some{+n} Some{+v}:
      Some{((n << 4n) .|. v : U32)}
    case _ _:
      None{}

def hex_read.go(s: String, acc: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      acc
    case SCon{c, t}:
      hex_read.go(t, hex_read.step(acc, hex_val(c)))

def hex_read(s: String) -> Maybe<&2, U32>:
  match s:
    case SNil{}:
      None{}
    case SCon{c, t}:
      hex_read.go(SCon{c, t}, Some{0})

def entity_num(+body: String) -> Maybe<&2, U32>:
  match body:
    case SCon{'x', t}:
      hex_read(t)
    case SCon{'X', t}:
      hex_read(t)
    case other:
      Maybe.bind(&2, Nat, U32, Nat.read(other), n => Some{U32.from_nat(n)})

# The character an entity body (between & and ;) stands for.
def entity(+body: String) -> Maybe<&2, U32>:
  match body:
    case SCon{'#', t}:
      entity_num(t)
    case other:
      Bool.pick(Maybe<&2, U32>, String.eq(other, "amp"), Some{38},
        Bool.pick(Maybe<&2, U32>, String.eq(other, "lt"), Some{60},
          Bool.pick(Maybe<&2, U32>, String.eq(other, "gt"), Some{62},
            Bool.pick(Maybe<&2, U32>, String.eq(other, "quot"), Some{34},
              Bool.pick(Maybe<&2, U32>, String.eq(other, "apos"), Some{39},
                Bool.pick(Maybe<&2, U32>, String.eq(other, "nbsp"), Some{160}, None{}))))))

# An entity is at most 10 chars before its ';'.
def entity_body(s: String, n: Nat, acc: String) -> Maybe<&2, String>:
  match s n:
    case SNil{} _:
      None{}
    case SCon{c, t} 0n:
      None{}
    case SCon{';', t} 1n+p:
      Some{String.reverse(acc)}
    case SCon{c, t} 1n+p:
      entity_body(t, p, SCon{c, acc})

def unescape.code(+b: String, code: Maybe<&2, U32>) -> Char & Nat:
  match code:
    case None{}:
      ('&', 0n)
    case Some{x}:
      (Chr{x}, 1n+len(b))

# (char to emit, chars of the input to skip after the '&').
def unescape.ent(body: Maybe<&2, String>) -> Char & Nat:
  match body:
    case None{}:
      ('&', 0n)
    case Some{+b}:
      unescape.code(b, entity(b))

def fst_char(r: Char & Nat) -> Char:
  Pair.fst(Char, Nat, r)

def snd_nat(r: Char & Nat) -> Nat:
  Pair.snd(Char, Nat, r)

# `skip` counts the chars of an entity already decoded.
def unescape.go(s: String, acc: String, skip: Nat) -> String:
  match s skip:
    case SNil{} _:
      String.reverse(acc)
    case SCon{c, t} 1n+p:
      unescape.go(t, acc, p)
    case SCon{'&', +t} 0n:
      unescape.go(t, SCon{fst_char(unescape.ent(entity_body(t, 12n, ""))), acc}, snd_nat(unescape.ent(entity_body(t, 12n, ""))))
    case SCon{c, t} 0n:
      unescape.go(t, SCon{c, acc}, 0n)

# Decodes HTML / XML character references (&amp;, &#39;, &#x2F;, ...).
def unescape(s: String) -> String:
  unescape.go(s, "", 0n)

# UTF-8
# -----

def utf8_size(+x: U32) -> Nat:
  Bool.pick(Nat, U32.is_lt(x, 128), 1n,
    Bool.pick(Nat, U32.is_lt(x, 2048), 2n,
      Bool.pick(Nat, U32.is_lt(x, 65536), 3n, 4n)))

def utf8_len.go(s: String, n: Nat) -> Nat:
  match s:
    case SNil{}:
      n
    case SCon{Chr{x}, t}:
      utf8_len.go(t, Nat.add(utf8_size(x), n))

# Bytes needed to encode `s`: HTTP's Content-Length counts these.
def utf8_len(s: String) -> Nat:
  utf8_len.go(s, 0n)

def cont(+x: U32, +k: Nat) -> U32:
  (128 .|. ((x >> k) .&. 63) : U32)

# Pushes the encoding of `x` onto a reversed byte list.
def utf8_put(+x: U32, size: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match size:
    case 1n:
      x <> acc
    case 2n:
      cont(x, 0n) <> (192 .|. (x >> 6n) : U32) <> acc
    case 3n:
      cont(x, 0n) <> cont(x, 6n) <> (224 .|. (x >> 12n) : U32) <> acc
    case other:
      cont(x, 0n) <> cont(x, 6n) <> cont(x, 12n) <> (240 .|. (x >> 18n) : U32) <> acc

def utf8_encode.go(s: String, acc: List<&2, U32>) -> List<&2, U32>:
  match s:
    case SNil{}:
      List.reverse(&2, U32, acc)
    case SCon{Chr{+x}, t}:
      utf8_encode.go(t, utf8_put(x, utf8_size(x), acc))

def utf8_encode(s: String) -> List<&2, U32>:
  utf8_encode.go(s, Nil{})

# Decoder state: the code point so far and the continuation bytes still due.
def utf8_lead(+b: U32) -> U32 & Nat:
  Bool.pick(U32 & Nat, U32.is_lt(b, 128), (b, 0n),
    Bool.pick(U32 & Nat, U32.is_lt(b, 224), ((b .&. 31 : U32), 1n),
      Bool.pick(U32 & Nat, U32.is_lt(b, 240), ((b .&. 15 : U32), 2n),
        ((b .&. 7 : U32), 3n))))

def utf8_decode.lead(acc: String, st: U32 & Nat) -> String & (U32 & Nat):
  (cp, need) = st
  match need:
    case 0n:
      (SCon{Chr{cp}, acc}, (0, 0n))
    case 1n+p:
      (acc, (cp, 1n+p))

def utf8_decode.step(+b: U32, acc: String, st: U32 & Nat) -> String & (U32 & Nat):
  (cp, need) = st
  match need:
    case 0n:
      utf8_decode.lead(acc, utf8_lead(b))
    case 1n:
      (SCon{Chr{((cp << 6n) .|. (b .&. 63) : U32)}, acc}, (0, 0n))
    case 2n+p:
      (acc, (((cp << 6n) .|. (b .&. 63) : U32), 1n+p))

def utf8_decode.go(bs: List<&2, U32>, cur: String & (U32 & Nat)) -> String:
  match bs:
    case Nil{}:
      (acc, st) = cur
      String.reverse(acc)
    case Con{b, rest}:
      (acc, st) = cur
      utf8_decode.go(rest, utf8_decode.step(b, acc, st))

def utf8_decode(bs: List<&2, U32>) -> String:
  utf8_decode.go(bs, ("", (0, 0n)))
