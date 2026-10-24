# ibeatkids: serves the archived ibeatkids.com rebuild plus live JSON endpoints
# in the shapes web/assets/js/update.js expects. Written in Bend2.
#
#   bend main.bend                                  listen on 127.0.0.1:16711
#   bend main.bend -- -addr 127.0.0.1:16712          flags: -addr, -web, -data
#   IBEATKIDS_ADDR=127.0.0.1:16712 bend main.bend    (a flag wins over the env)
#
# The program is a few computations on Bend's event loop:
#   - the acceptor hands every connection to the state loop over a channel;
#   - the state loop owns the cache, folds refresh results into it (and
#     persists them), and spawns one handler per connection with a snapshot;
#   - three refreshers fetch their upstream, report back, and sleep 5 minutes.

import Base
import ./src/text.bend as T
import ./src/json.bend as J
import ./src/clock.bend as C
import ./src/fetch.bend as F
import ./src/upstream.bend as U
import ./src/cache.bend as K
import ./src/server.bend as S
import ./src/download.bend as D

# Each upstream is hit at most this often. Responses carry time = now + this,
# which update.js uses as its localStorage expiry.
def refresh_ms() -> Nat:
  300000n

# Loops bounded by the outside world count down this much fuel (~9000 years
# of one request a second).
def forever() -> Nat:
  Nat.mul(4294967295n, 65535n)

# `epoch`: wall-clock ms at IO.now() == 0.
type Cfg is Data:
  Cfg{host: String, port: U32, web: String, data: String, epoch: Nat}

def Cfg.jobs(c: Cfg) -> String:
  match c:
    case Cfg{h, p, w, data, e}:
      data ++ "/.jobs"

def Cfg.data(c: Cfg) -> String:
  match c:
    case Cfg{h, p, w, data, e}:
      data

def Cfg.web(c: Cfg) -> String:
  match c:
    case Cfg{h, p, web, d, e}:
      web

def Cfg.epoch(c: Cfg) -> Nat:
  match c:
    case Cfg{h, p, w, d, epoch}:
      epoch

def wall(+cfg: Cfg) -> IO(Nat):
  IO.bind(Nat, Nat, IO.now(), t => IO.pure(Nat, Nat.add(Cfg.epoch(cfg), t)))

type State is Data:
  State{youtube: K.Src, twitch: K.Src, twitter: K.Src, pack: String, pack_at: Nat}

type Up is Data:
  UYouTube{r: U.YtResult}
  UTwitch{r: Result<&2, &2, String, U.TwitchData>}
  UTwitter{r: Result<&2, &2, String, U.TwitterData>}
  UPack{link: String, at: Nat}

type Msg is Type:
  MConn{sock: Socket}
  MPut{up: Up}

# Options
# -------

type Opts is Data:
  Opts{addr: String, web: String, data: String}

def opt_set(o: Opts, +key: String, +v: String) -> Opts:
  match o:
    case Opts{+addr, +web, +data}:
      Bool.pick(Opts, String.eq(key, "addr"), Opts{v, web, data},
        Bool.pick(Opts, String.eq(key, "web"), Opts{addr, v, data},
          Bool.pick(Opts, String.eq(key, "data"), Opts{addr, web, v}, Opts{addr, web, data})))

def flag_name(+a: String) -> String:
  T.until(Bool.pick(String, T.starts_with(a, "--"), T.drop(a, 2n), T.drop(a, 1n)), '=')

def arg(+o: Opts, +pending: String, +a: String) -> Opts & String:
  Bool.pick(Opts & String, Bool.not(String.is_empty(pending)), (opt_set(o, pending, a), ""),
    Bool.pick(Opts & String, Bool.not(T.starts_with(a, "-")), (o, ""),
      Bool.pick(Opts & String, T.has(a, "="), (opt_set(o, flag_name(a), T.after(a, '=')), ""),
        (o, flag_name(a)))))

# -addr X, --addr X, -addr=X (and the same for -web, -data). `pending`: the
# flag still waiting for its value.
def parse_args(xs: List<&2, String>, +o: Opts, +pending: String) -> Opts:
  match xs:
    case Nil{}:
      o
    case Con{+a, rest}:
      parse_args(rest, Pair.fst(Opts, String, arg(o, pending, a)), Pair.snd(Opts, String, arg(o, pending, a)))

def to_data(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, rest}:
      x <> to_data(rest)

def env_or(r: Result<&1, &1, U32 & String, String>, +d: String) -> String:
  match r:
    case Done{+v}:
      Bool.pick(String, String.is_empty(v), d, v)
    case Fail{e}:
      d

# Handlers
# --------

def api(+src: K.Src, j: J.Json) -> S.Response:
  match src:
    case K.Src{n, p, +fetched, u, status, e, t}:
      S.Response{200n, List.concat(&2, S.Header, [[S.h("Content-Type", S.json_type()),
        S.h("X-Upstream-Status", status)],
        Bool.pick(List<&2, S.Header>, Nat.is_eq(fetched, 0n), Nil{}, [S.h("X-Upstream-Fetched", C.rfc3339(fetched))])]),
        S.BText{J.stringify(j) ++ "\n"}}

def str(s: String) -> J.Json:
  J.JStr{s}

def kv(k: String, v: J.Json) -> J.JField:
  J.JF{k, v}

def thumbnail(+id: String) -> String:
  Bool.pick(String, String.is_empty(id), "", "https://i.ytimg.com/vi/" ++ id ++ "/hqdefault.jpg")

def yt_data(p: U.Payload) -> U.YtData:
  K.merge.prev(p)

def youtube_json(d: U.YtData, +now: Nat) -> J.Json:
  match d:
    case U.YtData{U.YtChannel{name, +subs, desc, thumb}, U.YtVideo{+id, title, vdesc, +published, +views}}:
      J.JObj{[kv("channel", J.JObj{[kv("name", str(name)), kv("subscribers", str(Nat.show(subs))),
          kv("subscribersText", str(C.abbrev(subs) ++ " subscribers")), kv("description", str(desc)),
          kv("thumbnail", str(thumb))]}),
        kv("video", J.JObj{[kv("title", str(title)), kv("description", str(vdesc)),
          kv("thumbnail", str(thumbnail(id))), kv("published", str(C.rfc3339(published))),
          kv("publishedText", str(C.ago(published, now))), kv("views", str(Nat.show(views))),
          kv("viewsText", str(C.abbrev(views) ++ " views")), kv("id", str(id))]}),
        kv("time", J.nat(Nat.add(now, refresh_ms())))]}

def latest_json(d: U.YtData, +now: Nat) -> J.Json:
  match d:
    case U.YtData{c, U.YtVideo{+id, title, vdesc, +published, +views}}:
      J.JObj{[kv("title", str(title)), kv("id", str(id)), kv("url", str("https://www.youtube.com/watch?v=" ++ id)),
        kv("thumbnail", str(thumbnail(id))), kv("viewCount", J.nat(views)),
        kv("viewCountText", str(C.commas(views) ++ " views")), kv("published", str(C.rfc3339(published))),
        kv("publishedText", str(C.ago(published, now))), kv("cache_refresh_in", J.nat(refresh_ms()))]}

def twitch_data(p: U.Payload) -> U.TwitchData:
  match p:
    case U.PTwitch{d}:
      d
    case other:
      U.TwitchData{0n, False{}, 0n}

def twitter_data(p: U.Payload) -> U.TwitterData:
  match p:
    case U.PTwitter{d}:
      d
    case other:
      U.TwitterData{0n}

def twitter_json(d: U.TwitterData, +now: Nat) -> J.Json:
  match d:
    case U.TwitterData{+f}:
      J.JObj{[kv("username", str("gamerboy8O")), kv("followers", J.nat(f)),
        kv("followersText", str(C.abbrev(f) ++ " followers")), kv("time", J.nat(Nat.add(now, refresh_ms())))]}

def twitch_json(d: U.TwitchData, +now: Nat) -> J.Json:
  match d:
    case U.TwitchData{+f, live, viewers}:
      J.JObj{[kv("totalfollowers", J.nat(f)), kv("followersText", str(C.abbrev(f) ++ " followers")),
        kv("time", J.nat(Nat.add(now, refresh_ms())))]}

# Never claims "live" from stale data.
def islive_json(d: U.TwitchData, +status: String, +now: Nat) -> J.Json:
  match d:
    case U.TwitchData{f, live, +viewers}:
      +on = Bool.and(live, String.eq(status, "live"))
      J.JObj{[kv("islive", J.JBool{on}), kv("viewers", J.nat(Bool.pick(Nat, on, viewers, 0n))),
        kv("time", J.nat(Nat.add(now, refresh_ms())))]}

def status_resp(st: State) -> S.Response:
  match st:
    case State{y, t, x, p, a}:
      S.Response{200n, [S.h("Content-Type", S.json_type())],
        S.BText{J.pretty(J.JObj{[kv("twitch", K.status_json(t)), kv("twitter", K.status_json(x)),
          kv("youtube", K.status_json(y))]}) ++ "\n"}}

def pack_done(r: Result<&2, &2, String, String>, +ch: Chan(Msg), +now: Nat) -> IO(S.Response):
  match r:
    case Done{+link}:
      do IO<S.Response>:
        s : Result<&1, &1, Msg, Unit> <- Chan.send(Msg, ch, MPut{UPack{link, now}})
        return S.redirect(link)
    case Fail{e}:
      do IO<S.Response>:
        IO.print_err("texture pack: " ++ e ++ "; falling back to MediaFire page")
        return S.redirect(D.page_url())

def pack(+link: String, +at: Nat, +cfg: Cfg, +ch: Chan(Msg), +now: Nat) -> IO(S.Response):
  Bool.pick(IO(S.Response), Bool.and(Bool.not(String.is_empty(link)), Nat.is_lt(Nat.sub(now, at), D.link_ttl())),
    IO.pure(S.Response, S.redirect(link)),
    IO.bind(Result<&2, &2, String, String>, S.Response, D.resolve(Cfg.jobs(cfg)), r => pack_done(r, ch, now)))

def Src.status(s: K.Src) -> String:
  match s:
    case K.Src{n, p, f, u, status, e, t}:
      status

def route_id(+p: String) -> Nat:
  Bool.pick(Nat, String.eq(p, "/api/youtube"), 1n,
  Bool.pick(Nat, String.eq(p, "/api/youtube/latestvideo"), 2n,
  Bool.pick(Nat, String.eq(p, "/api/twitter"), 3n,
  Bool.pick(Nat, String.eq(p, "/api/twitch"), 4n,
  Bool.pick(Nat, String.eq(p, "/api/twitch/islive"), 5n,
  Bool.pick(Nat, String.eq(p, "/api/status"), 6n,
  Bool.pick(Nat, String.eq(p, "/download/shortsword"), 7n, 0n)))))))

def route.go(id: Nat, +p: String, st: State, +cfg: Cfg, +ch: Chan(Msg), +now: Nat) -> IO(S.Response):
  match id st:
    case 1n State{+y, t, x, link, at}:
      IO.pure(S.Response, api(y, youtube_json(yt_data(K.Src.payload(y)), now)))
    case 2n State{+y, t, x, link, at}:
      IO.pure(S.Response, api(y, latest_json(yt_data(K.Src.payload(y)), now)))
    case 3n State{y, t, +x, link, at}:
      IO.pure(S.Response, api(x, twitter_json(twitter_data(K.Src.payload(x)), now)))
    case 4n State{y, +t, x, link, at}:
      IO.pure(S.Response, api(t, twitch_json(twitch_data(K.Src.payload(t)), now)))
    case 5n State{y, +t, x, link, at}:
      IO.pure(S.Response, api(t, islive_json(twitch_data(K.Src.payload(t)), Src.status(t), now)))
    case 6n State{y, t, x, link, at}:
      IO.pure(S.Response, status_resp(State{y, t, x, link, at}))
    case 7n State{y, t, x, +link, +at}:
      pack(link, at, cfg, ch, now)
    case other st2:
      S.static(p, Cfg.web(cfg))

def route(+p: String, st: State, +cfg: Cfg, +ch: Chan(Msg), +now: Nat) -> IO(S.Response):
  route.go(route_id(p), p, st, cfg, ch, now)

def logged(+req: S.Request, +t0: Nat) -> IO(Unit):
  match req:
    case S.Request{m, +p}:
      Bool.pick(IO(Unit), Bool.or(T.starts_with(p, "/api/"), T.starts_with(p, "/download/")),
        IO.bind(Nat, Unit, IO.now(), t1 => IO.print(m ++ " " ++ p ++ " " ++ Nat.show(Nat.sub(t1, t0)) ++ "ms")),
        IO.pure(Unit, Unit{}))

def respond(sock: Socket, +req: S.Request, +st: State, +cfg: Cfg, +ch: Chan(Msg), +t0: Nat, +now: Nat) -> IO(Unit):
  match req:
    case S.Request{+m, +p}:
      +head = String.eq(m, "HEAD")
      +ok = Bool.or(String.eq(m, "GET"), head)
      do IO<Unit>:
        r : S.Response <- Bool.pick(IO(S.Response), ok, route(p, st, cfg, ch, now), IO.pure(S.Response, S.not_allowed()))
        S.write(sock, r, Bool.not(head), now)
        logged(req, t0)

def handle.req(r: Socket & Maybe<&2, S.Request>, +st: State, +cfg: Cfg, +ch: Chan(Msg)) -> IO(Unit):
  (sock, m) = r
  match m:
    case Some{+req}:
      do IO<Unit>:
        t0 : Nat <- IO.now()
        now : Nat <- wall(cfg)
        respond(sock, req, st, cfg, ch, t0, now)
    case None{}:
      Socket.close(sock)

def handle(sock: Socket, +st: State, +cfg: Cfg, +ch: Chan(Msg)) -> IO(Unit):
  IO.bind(Socket & Maybe<&2, S.Request>, Unit, S.read(16n, sock, Nil{}), r => handle.req(r, st, cfg, ch))

# The state loop
# --------------

def fold.fin(r: K.Src & (String & Bool), k: K.Src -> State) -> State & ((String & Bool) & K.Src):
  (+s, info) = r
  (k(s), (info, s))

def fresh_twitch(r: Result<&2, &2, String, U.TwitchData>) -> Result<&2, &2, String, K.Fresh>:
  match r:
    case Done{d}:
      Done{K.Fresh{U.PTwitch{d}, "twitch-gql"}}
    case Fail{e}:
      Fail{e}

def fresh_twitter(r: Result<&2, &2, String, U.TwitterData>) -> Result<&2, &2, String, K.Fresh>:
  match r:
    case Done{d}:
      Done{K.Fresh{U.PTwitter{d}, "fxtwitter"}}
    case Fail{e}:
      Fail{e}

def fold(st: State, u: Up, +now: Nat) -> State & ((String & Bool) & K.Src):
  match st u:
    case State{+y, t, x, p, a} UYouTube{r}:
      fold.fin(K.apply(y, K.merge_youtube(K.Src.payload(y), r), now), s => State{s, t, x, p, a})
    case State{y, t, x, p, a} UTwitch{r}:
      fold.fin(K.apply(t, fresh_twitch(r), now), s => State{y, s, x, p, a})
    case State{y, t, x, p, a} UTwitter{r}:
      fold.fin(K.apply(x, fresh_twitter(r), now), s => State{y, t, s, p, a})
    case State{+y, t, x, p, a} UPack{link, at}:
      (State{y, t, x, link, at}, (("", False{}), y))

def after_fold(r: State & ((String & Bool) & K.Src), +cfg: Cfg, more: State -> IO(Unit)) -> IO(Unit):
  (st, rest) = r
  (info, src) = rest
  (+line, save) = info
  do IO<Unit>:
    Bool.pick(IO(Unit), String.is_empty(line), IO.pure(Unit, Unit{}), IO.print(line))
    Bool.pick(IO(Unit), save, K.persist(Cfg.data(cfg), src), IO.pure(Unit, Unit{}))
    more(st)

def step(m: Maybe<&1, Msg>, +st: State, +cfg: Cfg, +ch: Chan(Msg), more: State -> IO(Unit)) -> IO(Unit):
  match m:
    case Some{MConn{sock}}:
      do IO<Unit>:
        IO.spawn(Unit, handle(sock, st, cfg, ch))
        more(st)
    case Some{MPut{u}}:
      IO.bind(Nat, Unit, wall(cfg), now => after_fold(fold(st, u, now), cfg, more))
    case None{}:
      IO.pure(Unit, Unit{})

def state_loop(fuel: Nat, +st: State, +cfg: Cfg, +ch: Chan(Msg)) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      IO.bind(Maybe<&1, Msg>, Unit, Chan.recv(Msg, ch), m => step(m, st, cfg, ch, s => state_loop(f, s, cfg, ch)))

# The acceptor and the refreshers
# -------------------------------

def accepted(r: Listener & Result<&1, &1, U32 & String, Socket>, +ch: Chan(Msg), more: Listener -> IO(Unit)) -> IO(Unit):
  (l, res) = r
  match res:
    case Done{sock}:
      do IO<Unit>:
        s : Result<&1, &1, Msg, Unit> <- Chan.send(Msg, ch, MConn{sock})
        more(l)
    case Fail{(c, m)}:
      do IO<Unit>:
        IO.print_err("accept: " ++ m)
        IO.sleep(100)
        more(l)

def acceptor(fuel: Nat, l: Listener, +ch: Chan(Msg)) -> IO(Unit):
  match fuel:
    case 0n:
      Listener.close(l)
    case 1n+f:
      IO.bind(Listener & Result<&1, &1, U32 & String, Socket>, Unit, TCP.accept(l),
        r => accepted(r, ch, l2 => acceptor(f, l2, ch)))

def fetch_one(+which: Nat, +jobs: String) -> IO(Up):
  match which:
    case 0n:
      IO.bind(U.YtResult, Up, U.fetch_youtube(jobs), r => IO.pure(Up, UYouTube{r}))
    case 1n:
      IO.bind(Result<&2, &2, String, U.TwitchData>, Up, U.fetch_twitch(jobs), r => IO.pure(Up, UTwitch{r}))
    case other:
      IO.bind(Result<&2, &2, String, U.TwitterData>, Up, U.fetch_twitter(jobs), r => IO.pure(Up, UTwitter{r}))

# Refreshes right away, then every 5 minutes.
def refresher(fuel: Nat, +which: Nat, +cfg: Cfg, +ch: Chan(Msg)) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      do IO<Unit>:
        u : Up <- fetch_one(which, Cfg.jobs(cfg))
        s : Result<&1, &1, Msg, Unit> <- Chan.send(Msg, ch, MPut{u})
        IO.sleep(U32.from_nat(refresh_ms()))
        refresher(f, which, cfg, ch)

# Startup
# -------

def Cfg.addr(c: Cfg) -> String:
  match c:
    case Cfg{host, +port, w, d, e}:
      host ++ ":" ++ U32.show(port)

def run(l: Listener, +ch: Chan(Msg), +st: State, +cfg: Cfg) -> IO(Unit):
  do IO<Unit>:
        IO.spawn(Unit, acceptor(forever(), l, ch))
        IO.spawn(Unit, refresher(forever(), 0n, cfg, ch))
        IO.spawn(Unit, refresher(forever(), 1n, cfg, ch))
        IO.spawn(Unit, refresher(forever(), 2n, cfg, ch))
        IO.print("listening on " ++ Cfg.addr(cfg) ++ ", serving " ++ Cfg.web(cfg))
        state_loop(forever(), st, cfg, ch)

def listening(r: Result<&1, &1, U32 & String, Listener>, +st: State, +cfg: Cfg) -> IO(Unit):
  match r:
    case Done{l}:
      IO.bind(Chan(Msg), Unit, Chan.new(Msg, 256), ch => run(l, ch, st, cfg))
    case Fail{(c, m)}:
      IO.die(Unit, 1, "listen on " ++ Cfg.addr(cfg) ++ ": " ++ m)

def boot(+cfg: Cfg) -> IO(Unit):
  match cfg:
    case Cfg{+host, +port, w, +data, e}:
      do IO<Unit>:
        y : K.Src <- K.load("youtube", data)
        t : K.Src <- K.load("twitch", data)
        x : K.Src <- K.load("twitter", data)
        r : Result<&1, &1, U32 & String, Listener> <- TCP.listen(host, port)
        listening(r, State{y, t, x, "", 0n}, cfg)

# `date +%s%3N`, less IO.now(): the wall clock at IO.now() == 0.
def epoch_of(r: Result<&1, &1, U32 & String, U32 & (String & String)>, +t: Nat) -> Nat:
  match r:
    case Done{(code, (out, err))}:
      Nat.sub(Maybe.default(&2, Nat, Nat.read(String.trim(out)), 0n), t)
    case Fail{e}:
      0n

def start(o: Opts) -> IO(Unit):
  match o:
    case Opts{+addr, +web, +data}:
      do IO<Unit>:
        m : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("mkdir", ["-p", data ++ "/.jobs"], "", 4096, 5000)
        d : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("date", ["+%s%3N"], "", 4096, 5000)
        t : Nat <- IO.now()
        boot(Cfg{T.until(addr, ':'), Maybe.default(&2, U32, U32.read(T.after(addr, ':')), 16711), web, data, epoch_of(d, t)})

def main() -> IO(Unit):
  do IO<Unit>:
    env : Result<&1, &1, U32 & String, String> <- IO.get_env("IBEATKIDS_ADDR")
    args : List<String> <- IO.args()
    start(parse_args(List.tail(&2, String, to_data(args)), Opts{env_or(env, "127.0.0.1:16711"), "web", "data"}, ""))
