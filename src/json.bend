# JSON: value model, serializer, lexer and parser.
#
# The serializer writes <, > and & as \u003c, \u003e and \u0026, and `pretty`
# lays out objects with two-space indentation.
#
# Everything that walks text is tail-recursive: the runner's stack is a few
# tens of thousands of frames deep, and provider bodies and file contents are
# longer than that. Output is built in a reversed "builder" string (`acc`):
# pushing `s` is `String.reverse.go(s, acc)`, and one `String.reverse` at the
# end yields the text. Nesting depth is the only non-tail recursion.

import Base

type Json is Data:
  JNull{}
  JBool{value: Bool}
  JNum{value: String}
  JStr{value: String}
  JArr{items: List<&2, Json>}
  JObj{fields: List<&2, JField>}

type JField is Data:
  JF{key: String, value: Json}

# Builders
# --------

def put(s: String, acc: String) -> String:
  String.reverse.go(s, acc)

def hex_digit(+n: U32) -> Char:
  Bool.pick(Char, U32.is_lt(n, 10), Chr{(n + 48 : U32)}, Chr{(n + 87 : U32)})

def hex4(+n: U32, acc: String) -> String:
  d3 = hex_digit(((n >> 12n) .&. 15 : U32))
  d2 = hex_digit(((n >> 8n) .&. 15 : U32))
  d1 = hex_digit(((n >> 4n) .&. 15 : U32))
  d0 = hex_digit((n .&. 15 : U32))
  SCon{d0, SCon{d1, SCon{d2, SCon{d3, acc}}}}

def esc_ctrl(+x: U32, acc: String, ctrl: Bool) -> String:
  match ctrl:
    case True{}:
      hex4(x, SCon{'u', SCon{'\\', acc}})
    case False{}:
      SCon{Chr{x}, acc}

def esc_char(c: Char, acc: String) -> String:
  match c:
    case '"':
      SCon{'"', SCon{'\\', acc}}
    case '\\':
      SCon{'\\', SCon{'\\', acc}}
    case '\n':
      SCon{'n', SCon{'\\', acc}}
    case '\r':
      SCon{'r', SCon{'\\', acc}}
    case '\t':
      SCon{'t', SCon{'\\', acc}}
    case Chr{8}:
      SCon{'b', SCon{'\\', acc}}
    case Chr{12}:
      SCon{'f', SCon{'\\', acc}}
    case '<':
      hex4(60, SCon{'u', SCon{'\\', acc}})
    case '>':
      hex4(62, SCon{'u', SCon{'\\', acc}})
    case '&':
      hex4(38, SCon{'u', SCon{'\\', acc}})
    case Chr{+x}:
      esc_ctrl(x, acc, Bool.or(U32.is_lt(x, 32), Bool.or(U32.is_eq(x, 8232), U32.is_eq(x, 8233))))

# Pushes the JSON-escaped body of `s` (no quotes) onto the builder.
def esc_into(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      acc
    case SCon{h, t}:
      esc_into(t, esc_char(h, acc))

def escape(s: String) -> String:
  String.reverse(esc_into(s, ""))

def quote(s: String) -> String:
  "\"" ++ escape(s) ++ "\""

# Serializer
# ----------

# `fresh` is True when `j` is a whole value; False when `j` is the rest of a
# container whose opening bracket and first item are already out.
def ser(j: Json, fresh: Bool, acc: String) -> String:
  match j fresh:
    case JNull{} _:
      put("null", acc)
    case JBool{True{}} _:
      put("true", acc)
    case JBool{False{}} _:
      put("false", acc)
    case JNum{n} _:
      put(n, acc)
    case JStr{s} _:
      SCon{'"', esc_into(s, SCon{'"', acc})}
    case JArr{Nil{}} True{}:
      put("[]", acc)
    case JArr{Nil{}} False{}:
      SCon{']', acc}
    case JArr{Con{h, t}} True{}:
      ser(JArr{t}, False{}, ser(h, True{}, SCon{'[', acc}))
    case JArr{Con{h, t}} False{}:
      ser(JArr{t}, False{}, ser(h, True{}, SCon{',', acc}))
    case JObj{Nil{}} True{}:
      put("{}", acc)
    case JObj{Nil{}} False{}:
      SCon{'}', acc}
    case JObj{Con{JF{k, v}, t}} True{}:
      ser(JObj{t}, False{}, ser(v, True{}, SCon{':', SCon{'"', esc_into(k, SCon{'"', SCon{'{', acc}})}}))
    case JObj{Con{JF{k, v}, t}} False{}:
      ser(JObj{t}, False{}, ser(v, True{}, SCon{':', SCon{'"', esc_into(k, SCon{'"', SCon{',', acc}})}}))

def stringify(j: Json) -> String:
  String.reverse(ser(j, True{}, ""))

# Indented, as json.MarshalIndent(v, "", "  "). `ind` is the indent of the
# line the value starts on; `fresh` as in `ser`.
def pp(j: Json, fresh: Bool, +ind: String, acc: String) -> String:
  match j fresh:
    case JNull{} _:
      put("null", acc)
    case JBool{True{}} _:
      put("true", acc)
    case JBool{False{}} _:
      put("false", acc)
    case JNum{n} _:
      put(n, acc)
    case JStr{s} _:
      SCon{'"', esc_into(s, SCon{'"', acc})}
    case JArr{Nil{}} True{}:
      put("[]", acc)
    case JArr{Nil{}} False{}:
      SCon{']', put(ind, SCon{'\n', acc})}
    case JArr{Con{h, t}} True{}:
      pp(JArr{t}, False{}, ind, pp(h, True{}, "  " ++ ind, put(ind, put("  ", put("[\n", acc)))))
    case JArr{Con{h, t}} False{}:
      pp(JArr{t}, False{}, ind, pp(h, True{}, "  " ++ ind, put(ind, put("  ", put(",\n", acc)))))
    case JObj{Nil{}} True{}:
      put("{}", acc)
    case JObj{Nil{}} False{}:
      SCon{'}', put(ind, SCon{'\n', acc})}
    case JObj{Con{JF{k, v}, t}} True{}:
      pp(JObj{t}, False{}, ind, pp(v, True{}, "  " ++ ind,
        put("\": ", esc_into(k, SCon{'"', put(ind, put("  ", put("{\n", acc)))}))))
    case JObj{Con{JF{k, v}, t}} False{}:
      pp(JObj{t}, False{}, ind, pp(v, True{}, "  " ++ ind,
        put("\": ", esc_into(k, SCon{'"', put(ind, put("  ", put(",\n", acc)))}))))

def pretty(j: Json) -> String:
  String.reverse(pp(j, True{}, "", ""))

# Lexer
# -----

type Tok is Data:
  TLBrace{}
  TRBrace{}
  TLBrack{}
  TRBrack{}
  TColon{}
  TComma{}
  TStr{value: String}
  TNum{value: String}
  TWord{value: String}
  TBad{msg: String}

# `acc` fields are reversed. LUni counts the hex digits still to read.
type Lex is Data:
  LNorm{}
  LStr{acc: String}
  LEsc{acc: String}
  LUni{acc: String, left: Nat, code: U32}
  LNum{acc: String}
  LWord{acc: String}

def hex_val(c: Char) -> U32:
  match c:
    case Chr{+x}:
      Bool.pick(U32, U32.is_le(x, 57), (x - 48 : U32),
        Bool.pick(U32, U32.is_le(x, 70), (x - 55 : U32), (x - 87 : U32)))

def is_num_char(c: Char) -> Bool:
  match c:
    case '-':
      True{}
    case '+':
      True{}
    case '.':
      True{}
    case 'e':
      True{}
    case 'E':
      True{}
    case d:
      Char.is_digit(d)

# A low surrogate right after a high one merges into one code point.
def uni_merge(+hi: U32, +code: U32, rest: String, pair: Bool) -> String:
  match pair:
    case True{}:
      SCon{Chr{(65536 + ((hi - 55296) << 10n) + (code - 56320) : U32)}, rest}
    case False{}:
      SCon{Chr{code}, SCon{Chr{hi}, rest}}

def uni_push(acc: String, +code: U32) -> String:
  match acc:
    case SCon{Chr{+hi}, rest}:
      uni_merge(hi, code, rest, Bool.and(Bool.and(U32.is_ge(hi, 55296), U32.is_le(hi, 56319)),
        Bool.and(U32.is_ge(code, 56320), U32.is_le(code, 57343))))
    case SNil{}:
      SCon{Chr{code}, SNil{}}

def lex_alpha(+d: Char, toks: List<&2, Tok>, alpha: Bool) -> Lex & List<&2, Tok>:
  match alpha:
    case True{}:
      (LWord{SCon{d, SNil{}}}, toks)
    case False{}:
      (LNorm{}, TBad{"unexpected character " ++ Char.show(d)} <> toks)

def lex_numc(+d: Char, toks: List<&2, Tok>, numc: Bool) -> Lex & List<&2, Tok>:
  match numc:
    case True{}:
      (LNum{SCon{d, SNil{}}}, toks)
    case False{}:
      lex_alpha(d, toks, Char.is_alpha(d))

def lex_space(+d: Char, toks: List<&2, Tok>, space: Bool) -> Lex & List<&2, Tok>:
  match space:
    case True{}:
      (LNorm{}, toks)
    case False{}:
      lex_numc(d, toks, is_num_char(d))

def lex_norm(c: Char, toks: List<&2, Tok>) -> Lex & List<&2, Tok>:
  match c:
    case '{':
      (LNorm{}, TLBrace{} <> toks)
    case '}':
      (LNorm{}, TRBrace{} <> toks)
    case '[':
      (LNorm{}, TLBrack{} <> toks)
    case ']':
      (LNorm{}, TRBrack{} <> toks)
    case ':':
      (LNorm{}, TColon{} <> toks)
    case ',':
      (LNorm{}, TComma{} <> toks)
    case '"':
      (LStr{""}, toks)
    case +d:
      lex_space(d, toks, Char.is_space(d))

def lex_esc(c: Char, acc: String) -> Lex:
  match c:
    case 'n':
      LStr{SCon{'\n', acc}}
    case 't':
      LStr{SCon{'\t', acc}}
    case 'r':
      LStr{SCon{'\r', acc}}
    case 'b':
      LStr{SCon{Chr{8}, acc}}
    case 'f':
      LStr{SCon{Chr{12}, acc}}
    case 'u':
      LUni{acc, 4n, 0}
    case other:
      LStr{SCon{other, acc}}

def lex_num_more(+c: Char, acc: String, toks: List<&2, Tok>, more: Bool) -> Lex & List<&2, Tok>:
  match more:
    case True{}:
      (LNum{SCon{c, acc}}, toks)
    case False{}:
      lex_norm(c, TNum{String.reverse(acc)} <> toks)

def lex_word_more(+c: Char, acc: String, toks: List<&2, Tok>, more: Bool) -> Lex & List<&2, Tok>:
  match more:
    case True{}:
      (LWord{SCon{c, acc}}, toks)
    case False{}:
      lex_norm(c, TWord{String.reverse(acc)} <> toks)

def lex_uni(acc: String, left: Nat, +code2: U32, toks: List<&2, Tok>) -> Lex & List<&2, Tok>:
  match left:
    case 0n:
      (LStr{uni_push(acc, code2)}, toks)
    case 1n+p:
      (LUni{acc, 1n+p, code2}, toks)

def lex_str(c: Char, acc: String, toks: List<&2, Tok>) -> Lex & List<&2, Tok>:
  match c:
    case '"':
      (LNorm{}, TStr{String.reverse(acc)} <> toks)
    case '\\':
      (LEsc{acc}, toks)
    case other:
      (LStr{SCon{other, acc}}, toks)

def lex_step(+c: Char, st: Lex, toks: List<&2, Tok>) -> Lex & List<&2, Tok>:
  match st:
    case LNorm{}:
      lex_norm(c, toks)
    case LStr{acc}:
      lex_str(c, acc, toks)
    case LEsc{acc}:
      (lex_esc(c, acc), toks)
    case LUni{acc, left, code}:
      lex_uni(acc, Nat.sub(left, 1n), ((code << 4n) .|. hex_val(c) : U32), toks)
    case LNum{acc}:
      lex_num_more(c, acc, toks, is_num_char(c))
    case LWord{acc}:
      lex_word_more(c, acc, toks, Char.is_alpha(c))

def lex_end(st: Lex, toks: List<&2, Tok>) -> List<&2, Tok>:
  match st:
    case LNorm{}:
      toks
    case LNum{acc}:
      TNum{String.reverse(acc)} <> toks
    case LWord{acc}:
      TWord{String.reverse(acc)} <> toks
    case other:
      TBad{"unterminated string"} <> toks

# Tokens come out reversed; `tokenize` puts them in order.
def lex(s: String, cur: Lex & List<&2, Tok>) -> List<&2, Tok>:
  match s:
    case SNil{}:
      (st, toks) = cur
      lex_end(st, toks)
    case SCon{c, t}:
      (st, toks) = cur
      lex(t, lex_step(c, st, toks))

def tokenize(s: String) -> List<&2, Tok>:
  List.reverse(&2, Tok, lex(s, (LNorm{}, Nil{})))

# Parser
# ------

# A stack machine, one token per step. Item and field lists are reversed.
type Frame is Data:
  FArr{items: List<&2, Json>}
  FObj{fields: List<&2, JField>}
  FKey{fields: List<&2, JField>, key: String}
  FVal{fields: List<&2, JField>, key: String}
  FTop{value: Json}
  FErr{msg: String}

def push_value(v: Json, stack: List<&2, Frame>) -> List<&2, Frame>:
  match stack:
    case Nil{}:
      [FTop{v}]
    case Con{FArr{items}, rest}:
      FArr{v <> items} <> rest
    case Con{FVal{fields, k}, rest}:
      FObj{JF{k, v} <> fields} <> rest
    case Con{FErr{m}, rest}:
      FErr{m} <> rest
    case other:
      [FErr{"value in an unexpected position"}]

def word_value(+w: String) -> Json:
  Bool.pick(Json, String.eq(w, "true"), JBool{True{}},
    Bool.pick(Json, String.eq(w, "false"), JBool{False{}}, JNull{}))

def close_arr(stack: List<&2, Frame>) -> List<&2, Frame>:
  match stack:
    case Con{FArr{items}, rest}:
      push_value(JArr{List.reverse(&2, Json, items)}, rest)
    case Con{FErr{m}, rest}:
      [FErr{m}]
    case other:
      [FErr{"unbalanced ]"}]

def close_obj(stack: List<&2, Frame>) -> List<&2, Frame>:
  match stack:
    case Con{FObj{fields}, rest}:
      push_value(JObj{List.reverse(&2, JField, fields)}, rest)
    case Con{FErr{m}, rest}:
      [FErr{m}]
    case other:
      [FErr{"unbalanced }"}]

def on_str(s: String, stack: List<&2, Frame>) -> List<&2, Frame>:
  match stack:
    case Con{FObj{fields}, rest}:
      FKey{fields, s} <> rest
    case other:
      push_value(JStr{s}, other)

def on_colon(stack: List<&2, Frame>) -> List<&2, Frame>:
  match stack:
    case Con{FKey{fields, k}, rest}:
      FVal{fields, k} <> rest
    case other:
      [FErr{"unexpected :"}]

def parse_step(tok: Tok, stack: List<&2, Frame>) -> List<&2, Frame>:
  match tok:
    case TLBrace{}:
      FObj{Nil{}} <> stack
    case TRBrace{}:
      close_obj(stack)
    case TLBrack{}:
      FArr{Nil{}} <> stack
    case TRBrack{}:
      close_arr(stack)
    case TColon{}:
      on_colon(stack)
    case TComma{}:
      stack
    case TStr{s}:
      on_str(s, stack)
    case TNum{n}:
      push_value(JNum{n}, stack)
    case TWord{w}:
      push_value(word_value(w), stack)
    case TBad{m}:
      [FErr{m}]

def parse_go(toks: List<&2, Tok>, stack: List<&2, Frame>) -> List<&2, Frame>:
  match toks:
    case Nil{}:
      stack
    case Con{t, rest}:
      parse_go(rest, parse_step(t, stack))

def parse_fin(stack: List<&2, Frame>) -> Result<&2, &2, String, Json>:
  match stack:
    case [FTop{v}]:
      Done{v}
    case Con{FErr{m}, rest}:
      Fail{"invalid JSON: " ++ m}
    case Nil{}:
      Fail{"invalid JSON: empty input"}
    case other:
      Fail{"invalid JSON: unexpected end of input"}

def parse(s: String) -> Result<&2, &2, String, Json>:
  parse_fin(parse_go(tokenize(s), Nil{}))

# Accessors
# ---------

def field.if(v: Json, rest: Unit -> Maybe<&2, Json>, hit: Bool) -> Maybe<&2, Json>:
  match hit:
    case True{}:
      Some{v}
    case False{}:
      rest(Unit{})

def field(fs: List<&2, JField>, +key: String) -> Maybe<&2, Json>:
  match fs:
    case Nil{}:
      None{}
    case Con{JF{k, v}, rest}:
      field.if(v, u => field(rest, key), String.eq(k, key))

def get(j: Json, key: String) -> Maybe<&2, Json>:
  match j:
    case JObj{fs}:
      field(fs, key)
    case other:
      None{}

def as_str(m: Maybe<&2, Json>) -> String:
  match m:
    case Some{JStr{s}}:
      s
    case other:
      ""

def as_num(m: Maybe<&2, Json>) -> U32:
  match m:
    case Some{JNum{n}}:
      Maybe.default(&2, U32, U32.read(String.take(n, 10n)), 0)
    case other:
      0

def as_bool(m: Maybe<&2, Json>) -> Bool:
  match m:
    case Some{JBool{b}}:
      b
    case other:
      False{}

def as_list(m: Maybe<&2, Json>) -> List<&2, Json>:
  match m:
    case Some{JArr{xs}}:
      xs
    case other:
      Nil{}

def get_str(j: Json, key: String) -> String:
  as_str(get(j, key))

def get_num(j: Json, key: String) -> U32:
  as_num(get(j, key))

def get_list(j: Json, key: String) -> List<&2, Json>:
  as_list(get(j, key))

def is_obj(j: Json) -> Bool:
  match j:
    case JObj{fs}:
      True{}
    case other:
      False{}

# Builders for common shapes.
def str(s: String) -> Json:
  JStr{s}

def num(n: U32) -> Json:
  JNum{U32.show(n)}

def kv(k: String, v: Json) -> JField:
  JF{k, v}

# The integer part of a number literal ("46571", "1.5e3" -> "1").
def until_dot(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{'.', t}:
      String.reverse(acc)
    case SCon{'e', t}:
      String.reverse(acc)
    case SCon{'E', t}:
      String.reverse(acc)
    case SCon{c, t}:
      until_dot(t, SCon{c, acc})

def as_nat(m: Maybe<&2, Json>) -> Nat:
  match m:
    case Some{JNum{n}}:
      Maybe.default(&2, Nat, Nat.read(until_dot(n, "")), 0n)
    case other:
      0n

def get_nat(j: Json, key: String) -> Nat:
  as_nat(get(j, key))

def get_obj(j: Json, key: String) -> Json:
  Maybe.default(&2, Json, get(j, key), JNull{})

def nat(n: Nat) -> Json:
  JNum{Nat.show(n)}

def bool(b: Bool) -> Json:
  JBool{b}
