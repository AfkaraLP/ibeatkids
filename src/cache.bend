# Cached upstreams (cache.go). Each source lives in memory and in
# data/<name>.json; a failed refresh never overwrites the last good value.
#
#   live:  the last refresh succeeded
#   stale: the last refresh failed (or the disk cache is not yet confirmed
#          this run), so the last good data is served
#   seed:  never fetched successfully; serving the archived 2024 snapshot

import Base
import ./text.bend as T
import ./json.bend as J
import ./clock.bend as C
import ./fetch.bend as F
import ./upstream.bend as U

# Times in ms, 0 for never.
type Src is Data:
  Src{name: String, payload: U.Payload, fetched: Nat, upstream: String, status: String,
    last_err: String, last_try: Nat}

# Loading
# -------

def from_json(src: Src, +status: String, +j: J.Json) -> Src:
  match src:
    case Src{+name, payload, fetched, upstream, old, err, try}:
      Src{name, U.payload_of(name, J.get_obj(j, "data")), U.time_of(J.get_str(j, "fetchedAt")),
        J.get_str(j, "upstream"), status, err, try}

def load.json(+src: Src, +status: String, r: Result<&2, &2, String, J.Json>) -> Src & Bool:
  match r:
    case Done{+j}:
      Bool.pick(Src & Bool, J.is_obj(j), (from_json(src, status, j), True{}), (src, False{}))
    case Fail{e}:
      (src, False{})

def load.text(src: Src, +status: String, m: Maybe<&2, String>) -> Src & Bool:
  match m:
    case None{}:
      (src, False{})
    case Some{+text}:
      load.json(src, status, J.parse(text))

def load.disk(r: Src & Bool, +name: String, +dir: String) -> IO(Src):
  (src, ok) = r
  do IO<Src>:
    Bool.pick(IO(Unit), ok, IO.pure(Unit, Unit{}), IO.print_err(name ++ ": seed: cannot read seed/state/" ++ name ++ ".json"))
    m : Maybe<&2, String> <- F.read_text(dir ++ "/" ++ name ++ ".json")
    return Pair.fst(Src, Bool, load.text(src, "stale", m))

# The archived snapshot from seed/state/, then data/<name>.json over it.
def load(+name: String, +dir: String) -> IO(Src):
  do IO<Src>:
    m : Maybe<&2, String> <- F.read_text("seed/state/" ++ name ++ ".json")
    s : Src <- load.disk(load.text(Src{name, U.empty(name), 0n, "", "seed", "", 0n}, "seed", m), name, dir)
    return s

# Persisting
# ----------

def state_json(src: Src) -> J.Json:
  match src:
    case Src{name, payload, +fetched, upstream, status, err, try}:
      J.JObj{[J.JF{"data", U.payload_json(payload)}, J.JF{"fetchedAt", J.JStr{C.rfc3339_ms(fetched)}},
        J.JF{"upstream", J.JStr{upstream}}]}

def write.done(r: File & Result<&1, &1, U32 & String, Unit>, +tmp: String, +path: String) -> IO(Unit):
  (f, res) = r
  do IO<Unit>:
    File.close(f)
    m : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("mv", [tmp, path], "", 4096, 5000)
    return Unit{}

def write.open(r: Result<&1, &1, U32 & String, File>, +text: String, +tmp: String, +path: String) -> IO(Unit):
  match r:
    case Done{f}:
      IO.bind(File & Result<&1, &1, U32 & String, Unit>, Unit, File.write(f, text), x => write.done(x, tmp, path))
    case Fail{(c, m)}:
      IO.print_err("persist " ++ path ++ ": " ++ m)

def Src.name(s: Src) -> String:
  match s:
    case Src{name, p, f, u, st, e, t}:
      name

# Writes data/<name>.json atomically (a temp file, then mv), indented like
# json.MarshalIndent.
def persist(+dir: String, +src: Src) -> IO(Unit):
  +name = Src.name(src)
  +tmp = dir ++ "/.tmp-" ++ name ++ ".json"
  IO.bind(Result<&1, &1, U32 & String, File>, Unit, File.open(tmp, "w"),
    r => write.open(r, J.pretty(state_json(src)), tmp, dir ++ "/" ++ name ++ ".json"))

# Refreshing
# ----------

# A successful fetch: the new data and the upstream that produced it.
type Fresh is Data:
  Fresh{payload: U.Payload, upstream: String}

def stale_of(+status: String) -> String:
  Bool.pick(String, String.eq(status, "live"), "stale", status)

# Folds a refresh into the source: (new source, the log line, whether to persist).
def apply(src: Src, r: Result<&2, &2, String, Fresh>, +now: Nat) -> Src & (String & Bool):
  match src r:
    case Src{+name, p, f, u, +status, err, try} Fail{+e}:
      (Src{name, p, f, u, stale_of(status), e, now},
        (name ++ ": refresh failed (serving " ++ stale_of(status) ++ "): " ++ e, False{}))
    case Src{+name, p, f, u, status, err, try} Done{Fresh{payload, +up}}:
      (Src{name, payload, now, up, "live", "", now}, (name ++ ": refreshed via " ++ up, True{}))

def Src.payload(s: Src) -> U.Payload:
  match s:
    case Src{n, p, f, u, st, e, t}:
      p

# YouTube's two halves over the last good value (fetchYouTube): the feed
# gives the video (and the name), the channel page the channel.
type Merge is Data:
  Merge{d: U.YtData, used: List<&2, String>, errs: List<&2, String>}

def merge.rss(m: Merge, r: Result<&2, &2, String, U.RssItem>) -> Merge:
  match m r:
    case Merge{U.YtData{U.YtChannel{name, subs, desc, thumb}, v}, used, errs} Done{U.RssItem{v2, +title}}:
      Merge{U.YtData{U.YtChannel{Bool.pick(String, String.is_empty(title), name, title), subs, desc, thumb}, v2},
        "rss" <> used, errs}
    case Merge{d, used, errs} Fail{e}:
      Merge{d, used, ("rss: " ++ e) <> errs}

def merge.page(m: Merge, r: Result<&2, &2, String, U.YtChannel>) -> Merge:
  match m r:
    case Merge{U.YtData{c, v}, used, errs} Done{c2}:
      Merge{U.YtData{c2, v}, "channel-page" <> used, errs}
    case Merge{d, used, errs} Fail{e}:
      Merge{d, used, ("channel page: " ++ e) <> errs}

def merge.fin(m: Merge) -> Result<&2, &2, String, Fresh>:
  match m:
    case Merge{d, Nil{}, errs}:
      Fail{T.join(List.reverse(&2, String, errs), "\n")}
    case Merge{d, Con{u, us}, Nil{}}:
      Done{Fresh{U.PYouTube{d}, T.join(List.reverse(&2, String, u <> us), "+")}}
    case Merge{d, Con{u, us}, Con{e, es}}:
      Done{Fresh{U.PYouTube{d}, T.join(List.reverse(&2, String, u <> us), "+") ++
        " (partial: " ++ T.join(List.reverse(&2, String, e <> es), "\n") ++ ")"}}

def merge.prev(p: U.Payload) -> U.YtData:
  match p:
    case U.PYouTube{d}:
      d
    case other:
      U.YtData{U.empty_channel(), U.empty_video()}

def merge_youtube(p: U.Payload, r: U.YtResult) -> Result<&2, &2, String, Fresh>:
  match r:
    case U.YtResult{rss, page}:
      merge.fin(merge.page(merge.rss(Merge{merge.prev(p), Nil{}, Nil{}}, rss), page))

# Status
# ------

def opt(+k: String, +v: String, +rest: List<&2, J.JField>) -> List<&2, J.JField>:
  Bool.pick(List<&2, J.JField>, String.is_empty(v), rest, J.JF{k, J.JStr{v}} <> rest)

# One source in /api/status (empty upstream and lastError are omitted).
def status_json(src: Src) -> J.Json:
  match src:
    case Src{name, p, +fetched, +up, status, +err, +try}:
      J.JObj{J.JF{"status", J.JStr{status}} <> opt("upstream", up,
        J.JF{"fetchedAt", J.JStr{C.rfc3339_ms(fetched)}} <> J.JF{"lastTry", J.JStr{C.rfc3339_ms(try)}}
          <> opt("lastError", err, Nil{}))}
