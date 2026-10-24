# Outbound HTTPS, without stalling the server.
#
# Bend 2.0.38's IO has TCP but no TLS or DNS, so HTTPS goes through the system
# curl. But on the JS runner Process.run blocks the whole
# event loop until the child exits, and upstream requests take seconds. So a
# request is a background job: Process.run starts `sh`, which launches curl
# detached (stdio on files) and exits at once; the calling computation then
# polls for the job's result file with IO.sleep, which lets the server's other
# computations run. Every argument reaches curl as a literal argv entry.
#
# A job `<id>` in the jobs directory writes <id>.body (the response body),
# <id>.err (curl's stderr) and, last, <id>.code ("<http status> <curl exit>").

import Base
import ./text.bend as T

def user_agent() -> String:
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

# $1 jobs dir, $2 job id, then curl's arguments.
def script() -> String:
  T.concat(["d=$1; id=$2; shift 2; rm -f \"$d/$id.body\" \"$d/$id.err\" \"$d/$id.tmp\" \"$d/$id.code\"; ",
    "( curl \"$@\" -o \"$d/$id.body\" -w '%{http_code}' >\"$d/$id.tmp\" 2>\"$d/$id.err\"; ",
    "echo \" $?\" >>\"$d/$id.tmp\"; mv \"$d/$id.tmp\" \"$d/$id.code\" ) </dev/null >/dev/null 2>&1 &"])

# Short timeouts on every phase (the box egresses through a slow proxy).
def curl_args(+url: String, extra: List<&2, String>) -> List<&2, String>:
  List.concat(&2, String, [["-sS", "-L", "--compressed", "--max-time", "20", "--connect-timeout", "8",
    "--max-filesize", "4194304", "-A", user_agent(), "-H", "Accept-Language: en-US,en;q=0.9"],
    extra, [url]])

# A reusable list of strings as the effects take it.
def affine(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      x <> affine(rest)

def path(+dir: String, +id: String, +suffix: String) -> String:
  dir ++ "/" ++ id ++ suffix

# Reading job files
# -----------------

def read_text.done(r: File & Result<&1, &1, U32 & String, String>) -> IO(Maybe<&2, String>):
  (f, res) = r
  match res:
    case Done{s}:
      do IO<Maybe<&2, String>>:
        File.close(f)
        return Some{s}
    case Fail{e}:
      do IO<Maybe<&2, String>>:
        File.close(f)
        return None{}

def read_text.open(r: Result<&1, &1, U32 & String, File>) -> IO(Maybe<&2, String>):
  match r:
    case Done{f}:
      IO.bind(File & Result<&1, &1, U32 & String, String>, Maybe<&2, String>,
        File.read(f, 16777216), read_text.done)
    case Fail{e}:
      IO.pure(Maybe<&2, String>, None{})

# A whole text file, or None if it cannot be read.
def read_text(path: String) -> IO(Maybe<&2, String>):
  IO.bind(Result<&1, &1, U32 & String, File>, Maybe<&2, String>, File.open(path, "r"), read_text.open)

def cleanup(+dir: String, +id: String) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("rm",
      affine(["-f", path(dir, id, ".body"), path(dir, id, ".err"), path(dir, id, ".code")]), "", 4096, 5000)
    return Unit{}

# Results
# -------

# "200 0" -> (200, 0).
def codes(+s: String) -> Nat & Nat:
  +t = String.trim(s)
  (Maybe.default(&2, Nat, Nat.read(T.until(t, ' ')), 0n),
    Maybe.default(&2, Nat, Nat.read(String.trim(T.after(t, ' '))), 1n))

def outcome(+url: String, cs: Nat & Nat, +err: String, body: Maybe<&2, String>) -> Result<&2, &2, String, String>:
  (+status, +exit) = cs
  match body:
    case None{}:
      Fail{url ++ ": " ++ Bool.pick(String, Nat.is_eq(exit, 0n), "no body", String.trim(err))}
    case Some{b}:
      Bool.pick(Result<&2, &2, String, String>, Nat.is_ne(exit, 0n), Fail{String.trim(err)},
        Bool.pick(Result<&2, &2, String, String>, Nat.is_eq(status, 200n), Done{b},
          Fail{url ++ ": HTTP " ++ Nat.show(status)}))

def finish(+dir: String, +id: String, +url: String, +code: String) -> IO(Result<&2, &2, String, String>):
  do IO<Result<&2, &2, String, String>>:
    body : Maybe<&2, String> <- read_text(path(dir, id, ".body"))
    err : Maybe<&2, String> <- read_text(path(dir, id, ".err"))
    cleanup(dir, id)
    return outcome(url, codes(code), Maybe.default(&2, String, err, ""), body)

def poll.k(m: Maybe<&2, String>, +dir: String, +id: String, +url: String,
  more: Unit -> IO(Result<&2, &2, String, String>)) -> IO(Result<&2, &2, String, String>):
  match m:
    case Some{code}:
      finish(dir, id, url, code)
    case None{}:
      more(Unit{})

# Waits for <id>.code, 100ms at a time, for at most `fuel` polls.
def poll(fuel: Nat, +dir: String, +id: String, +url: String) -> IO(Result<&2, &2, String, String>):
  match fuel:
    case 0n:
      do IO<Result<&2, &2, String, String>>:
        cleanup(dir, id)
        return Fail{url ++ ": timed out"}
    case 1n+f:
      do IO<Result<&2, &2, String, String>>:
        IO.sleep(100)
        m : Maybe<&2, String> <- read_text(path(dir, id, ".code"))
        r : Result<&2, &2, String, String> <- poll.k(m, dir, id, url, u => poll(f, dir, id, url))
        return r

def started(r: Result<&1, &1, U32 & String, U32 & (String & String)>, +dir: String, +id: String,
  +url: String) -> IO(Result<&2, &2, String, String>):
  match r:
    case Done{(+status, out)}:
      Bool.pick(IO(Result<&2, &2, String, String>), U32.is_eq(status, 0), poll(250n, dir, id, url),
        IO.pure(Result<&2, &2, String, String>, Fail{"could not start curl"}))
    case Fail{(c, m)}:
      IO.pure(Result<&2, &2, String, String>, Fail{"could not start curl: " ++ m})

def launch(+dir: String, +id: String, +url: String, extra: List<&2, String>) -> IO(Result<&2, &2, String, String>):
  do IO<Result<&2, &2, String, String>>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("sh",
      affine(List.concat(&2, String, [["-c", script(), "sh", dir, id], curl_args(url, extra)])), "", 65536, 5000)
    out : Result<&2, &2, String, String> <- started(r, dir, id, url)
    return out

def job_id(r: Result<&1, &1, U32 & String, U32>, +tag: String) -> String:
  match r:
    case Done{n}:
      tag ++ "-" ++ U32.show(n)
    case Fail{e}:
      tag

# GETs (or, with --data-binary in `extra`, POSTs) `url`; the body on HTTP 200.
# `tag` names the job files; a random suffix keeps concurrent jobs apart.
def get(+dir: String, +tag: String, +url: String, extra: List<&2, String>) -> IO(Result<&2, &2, String, String>):
  do IO<Result<&2, &2, String, String>>:
    r : Result<&1, &1, U32 & String, U32> <- IO.random_u32()
    out : Result<&2, &2, String, String> <- launch(dir, job_id(r, tag), url, extra)
    return out
