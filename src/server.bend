# HTTP/1.1 serving over Bend TCP: reading a request, writing a response, and
# the static file tree. Every response closes the
# connection; Caddy, in front, keeps its own connections to clients alive.

import Base
import ./text.bend as T
import ./clock.bend as C

# Requests
# --------

type Request is Data:
  Request{method: String, path: String}

# How much of "\r\n\r\n" has just gone by, after byte `b`.
def crlf_next(n: Nat, +b: U32) -> Nat:
  match n:
    case 0n:
      Bool.pick(Nat, U32.is_eq(b, 13), 1n, 0n)
    case 1n:
      Bool.pick(Nat, U32.is_eq(b, 10), 2n, Bool.pick(Nat, U32.is_eq(b, 13), 1n, 0n))
    case 2n:
      Bool.pick(Nat, U32.is_eq(b, 13), 3n, 0n)
    case other:
      Bool.pick(Nat, U32.is_eq(b, 10), 4n, Bool.pick(Nat, U32.is_eq(b, 13), 1n, 0n))

# The bytes before the blank line, reversed onto `acc`; None if it has not
# arrived yet.
def head.go(bs: List<&2, U32>, acc: List<&2, U32>, seen: Nat) -> Maybe<&2, List<&2, U32>>:
  match bs seen:
    case rest 4n:
      Some{List.reverse(&2, U32, acc)}
    case Nil{} _:
      None{}
    case Con{+b, t} n:
      head.go(t, b <> acc, crlf_next(n, b))

def head(bs: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  head.go(bs, Nil{}, 0n)

def rev_onto(bs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match bs:
    case Nil{}:
      acc
    case Con{b, rest}:
      rev_onto(rest, b <> acc)

def unpct.hex(ha: Maybe<&2, U32>, hb: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match ha hb:
    case Some{+x} Some{+y}:
      Some{((x << 4n) .|. y : U32)}
    case _ _:
      None{}

# The byte a "%XX" stands for, given what follows the '%'.
def unpct.byte(+rest: List<&2, U32>) -> Maybe<&2, U32>:
  match rest:
    case Con{+a, Con{+b, t}}:
      unpct.hex(T.hex_val(Chr{a}), T.hex_val(Chr{b}))
    case other:
      None{}

# The bytes so far (reversed), and the hex digits of an escape still to skip.
type Unpct is Data:
  Unpct{acc: List<&2, U32>, skip: Nat}

def unpct.push(m: Maybe<&2, U32>, acc: List<&2, U32>) -> Unpct:
  match m:
    case Some{x}:
      Unpct{x <> acc, 2n}
    case None{}:
      Unpct{37 <> acc, 0n}

# %XX escapes in a path, at the byte level (then decoded as UTF-8).
def unpct.go(s: List<&2, U32>, st: Unpct) -> List<&2, U32>:
  match s st:
    case Nil{} Unpct{acc, _}:
      List.reverse(&2, U32, acc)
    case Con{x, rest} Unpct{acc, 1n+p}:
      unpct.go(rest, Unpct{acc, p})
    case Con{37, +rest} Unpct{acc, 0n}:
      unpct.go(rest, unpct.push(unpct.byte(rest), acc))
    case Con{x, rest} Unpct{acc, 0n}:
      unpct.go(rest, Unpct{x <> acc, 0n})

def unpct(s: String) -> String:
  T.utf8_decode(unpct.go(T.utf8_encode(s), Unpct{Nil{}, 0n}))

# "GET /a%20b?x=1 HTTP/1.1" -> Request{"GET", "/a b"}.
def parse_line(+line: String) -> Request:
  +target = T.until(T.after(line, ' '), ' ')
  Request{T.until(line, ' '), unpct(T.until(target, '?'))}

def parse_head(+h: String) -> Request:
  parse_line(T.until(h, '\r'))

def got.k(m: Maybe<&2, List<&2, U32>>, sock: Socket, +rev: List<&2, U32>,
  more: Socket -> List<&2, U32> -> IO(Socket & Maybe<&2, Request>)) -> IO(Socket & Maybe<&2, Request>):
  match m:
    case Some{h}:
      IO.pure(Socket & Maybe<&2, Request>, (sock, Some{parse_head(T.utf8_decode(h))}))
    case None{}:
      more(sock, rev)

def got(r: Socket & Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>, Unit>,
  acc: List<&2, U32>, more: Socket -> List<&2, U32> -> IO(Socket & Maybe<&2, Request>)) ->
  IO(Socket & Maybe<&2, Request>):
  (sock, res) = r
  match res:
    case Ready{Done{Some{bs}}}:
      +rev = rev_onto(bs, acc)
      got.k(head(List.reverse(&2, U32, rev)), sock, rev, more)
    case other:
      IO.pure(Socket & Maybe<&2, Request>, (sock, None{}))

# Reads up to the end of the request head: 16 reads, 10s each, at most.
def read(fuel: Nat, sock: Socket, acc: List<&2, U32>) -> IO(Socket & Maybe<&2, Request>):
  match fuel:
    case 0n:
      IO.pure(Socket & Maybe<&2, Request>, (sock, None{}))
    case 1n+f:
      IO.bind(Socket & Poll<&1, &1, Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>, Unit>,
        Socket & Maybe<&2, Request>, TCP.try_recv_bytes(sock, 65536, 10000),
        r => got(r, acc, s => a => read(f, s, a)))

# Responses
# ---------

type Header is Data:
  Header{name: String, value: String}

type Body is Data:
  BText{text: String}
  BFile{bytes: List<&2, U32>}

type Response is Data:
  Response{status: Nat, headers: List<&2, Header>, body: Body}

def reason(+code: Nat) -> String:
  Bool.pick(String, Nat.is_eq(code, 200n), "OK",
    Bool.pick(String, Nat.is_eq(code, 302n), "Found",
      Bool.pick(String, Nat.is_eq(code, 404n), "Not Found",
        Bool.pick(String, Nat.is_eq(code, 405n), "Method Not Allowed", "Internal Server Error"))))

def header_lines(hs: List<&2, Header>, acc: String) -> String:
  match hs:
    case Nil{}:
      acc
    case Con{Header{n, v}, rest}:
      header_lines(rest, T.put("\r\n", T.put(v, T.put(": ", T.put(n, acc)))))

def body_len(+b: Body) -> Nat:
  match b:
    case BText{s}:
      T.utf8_len(s)
    case BFile{bs}:
      T.count(bs)

def head_text(+status: Nat, hs: List<&2, Header>, +len: Nat, +now: Nat) -> String:
  String.reverse(T.put("\r\nConnection: close\r\n\r\n", T.put(Nat.show(len),
    T.put("\r\nContent-Length: ", T.put(C.http_date(now), T.put("Date: ", header_lines(hs,
      String.reverse(T.concat(["HTTP/1.1 ", Nat.show(status), " ", reason(status), "\r\n"])))))))))

def closed(r: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  (sock, res) = r
  Socket.close(sock)

def send_bytes(r: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, bs: List<&2, U32>) -> IO(Unit):
  (sock, res) = r
  match res:
    case Done{u}:
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit, TCP.send_bytes(sock, bs), closed)
    case Fail{e}:
      Socket.close(sock)

def write.body(sock: Socket, +head: String, b: Body, with_body: Bool) -> IO(Unit):
  match b with_body:
    case _ False{}:
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit, TCP.send(sock, head), closed)
    case BText{s} True{}:
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit, TCP.send(sock, head ++ s), closed)
    case BFile{bs} True{}:
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit, TCP.send(sock, head),
        r => send_bytes(r, bs))

# Sends `r` and closes the socket; a HEAD request gets the head only.
def write(sock: Socket, r: Response, with_body: Bool, +now: Nat) -> IO(Unit):
  match r:
    case Response{+status, hs, +b}:
      write.body(sock, head_text(status, hs, body_len(b), now), b, with_body)

def h(n: String, v: String) -> Header:
  Header{n, v}

def text_plain() -> String:
  "text/plain; charset=utf-8"

def json_type() -> String:
  "application/json; charset=utf-8"

# http.Error: plain text plus nosniff, with a trailing newline.
def error(+status: Nat, +msg: String) -> Response:
  Response{status, [h("Content-Type", text_plain()), h("X-Content-Type-Options", "nosniff")],
    BText{msg ++ "\n"}}

def not_allowed() -> Response:
  Response{405n, [h("Allow", "GET, HEAD"), h("Content-Type", text_plain()),
    h("X-Content-Type-Options", "nosniff")], BText{"Method Not Allowed\n"}}

def html_escape.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{'<', t}:
      html_escape.go(t, T.put("&lt;", acc))
    case SCon{'>', t}:
      html_escape.go(t, T.put("&gt;", acc))
    case SCon{'&', t}:
      html_escape.go(t, T.put("&amp;", acc))
    case SCon{'"', t}:
      html_escape.go(t, T.put("&#34;", acc))
    case SCon{'\'', t}:
      html_escape.go(t, T.put("&#39;", acc))
    case SCon{c, t}:
      html_escape.go(t, SCon{c, acc})

# http.Redirect(w, r, url, 302), with Cache-Control: no-store.
def redirect(+url: String) -> Response:
  Response{302n, [h("Cache-Control", "no-store"), h("Content-Type", "text/html; charset=utf-8"),
    h("Location", url)], BText{"<a href=\"" ++ html_escape.go(url, "") ++ "\">Found</a>.\n\n"}}

# Static files
# ------------

def mime(+e: String) -> String:
  Bool.pick(String, String.eq(e, "html"), "text/html; charset=utf-8",
  Bool.pick(String, String.eq(e, "css"), "text/css; charset=utf-8",
  Bool.pick(String, String.eq(e, "js"), "text/javascript; charset=utf-8",
  Bool.pick(String, String.eq(e, "json"), "application/json",
  Bool.pick(String, String.eq(e, "png"), "image/png",
  Bool.pick(String, String.eq(e, "jpg"), "image/jpeg",
  Bool.pick(String, String.eq(e, "jpeg"), "image/jpeg",
  Bool.pick(String, String.eq(e, "gif"), "image/gif",
  Bool.pick(String, String.eq(e, "webp"), "image/webp",
  Bool.pick(String, String.eq(e, "svg"), "image/svg+xml",
  Bool.pick(String, String.eq(e, "ico"), "image/vnd.microsoft.icon",
  Bool.pick(String, String.eq(e, "ttf"), "font/ttf",
  Bool.pick(String, String.eq(e, "woff"), "font/woff",
  Bool.pick(String, String.eq(e, "woff2"), "font/woff2",
  Bool.pick(String, String.eq(e, "txt"), text_plain(),
  Bool.pick(String, String.eq(e, "xml"), "text/xml; charset=utf-8",
    "application/octet-stream"))))))))))))))))

def clean.push(+seg: String, +stack: List<&2, String>) -> List<&2, String>:
  Bool.pick(List<&2, String>, Bool.or(String.is_empty(seg), String.eq(seg, ".")), stack,
    Bool.pick(List<&2, String>, String.eq(seg, ".."), List.tail(&2, String, stack), seg <> stack))

def clean.go(segs: List<&2, String>, stack: List<&2, String>) -> List<&2, String>:
  match segs:
    case Nil{}:
      List.reverse(&2, String, stack)
    case Con{+seg, rest}:
      clean.go(rest, clean.push(seg, stack))

# path.Clean("/" + p): no empty, "." or ".." segments, no trailing slash.
def clean(+p: String) -> String:
  "/" ++ T.join(clean.go(T.split(p, '/'), Nil{}), "/")

def read_file.done(r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Maybe<&2, List<&2, U32>>):
  (f, res) = r
  match res:
    case Done{bs}:
      do IO<Maybe<&2, List<&2, U32>>>:
        File.close(f)
        return Some{bs}
    case Fail{e}:
      do IO<Maybe<&2, List<&2, U32>>>:
        File.close(f)
        return None{}

def read_file.open(r: Result<&1, &1, U32 & String, File>) -> IO(Maybe<&2, List<&2, U32>>):
  match r:
    case Done{f}:
      IO.bind(File & Result<&1, &1, U32 & String, List<&2, U32>>, Maybe<&2, List<&2, U32>>,
        File.read_bytes(f, 67108864), read_file.done)
    case Fail{e}:
      IO.pure(Maybe<&2, List<&2, U32>>, None{})

# A regular file's bytes; None for a missing file or a directory (reading
# one fails with EISDIR).
def read_file(path: String) -> IO(Maybe<&2, List<&2, U32>>):
  IO.bind(Result<&1, &1, U32 & String, File>, Maybe<&2, List<&2, U32>>, File.open(path, "r"), read_file.open)

def found(m: Maybe<&2, List<&2, U32>>, +ctype: String, more: Unit -> IO(Response)) -> IO(Response):
  match m:
    case Some{bs}:
      IO.pure(Response, Response{200n, [h("Content-Type", ctype)], BFile{bs}})
    case None{}:
      more(Unit{})

# The first candidate that is a regular file under `web`.
def try_files(cs: List<&2, String>, +web: String) -> IO(Response):
  match cs:
    case Nil{}:
      IO.pure(Response, error(404n, "404 page not found"))
    case Con{+c, rest}:
      IO.bind(Maybe<&2, List<&2, U32>>, Response, read_file(web ++ c),
        m => found(m, mime(T.ext(c)), u => try_files(rest, web)))

def api_file(m: Maybe<&2, List<&2, U32>>) -> Response:
  match m:
    case Some{bs}:
      Response{200n, [h("Content-Type", json_type())], BFile{bs}}
    case None{}:
      error(404n, "{\"error\":\"not found\"}")

def static.api(+p: String, +web: String) -> IO(Response):
  IO.bind(Maybe<&2, List<&2, U32>>, Response, read_file(web ++ p), m => IO.pure(Response, api_file(m)))

# The old Caddy config: try_files {path} {path}.html {path}/index.html
# /index.html. Under /api/ only exact files count, and they are JSON (the
# archived API files have no extension).
def static(+raw: String, +web: String) -> IO(Response):
  +p = clean(raw)
  Bool.pick(IO(Response), T.starts_with(p, "/api/"), static.api(p, web),
    try_files([p, p ++ ".html", p ++ "/index.html", "/index.html"], web))
