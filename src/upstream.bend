# The three upstreams: the data each one yields, its on-disk JSON, the
# fetchers and the parsers. Parsing is plain Bend over the raw body; there
# is no regex engine, so each expected pattern is a small scanner.

import Base
import ./text.bend as T
import ./json.bend as J
import ./clock.bend as C
import ./fetch.bend as F

def youtube_channel_id() -> String:
  "UCuAj31T2G04FZkCR-6carEA"

def twitch_login() -> String:
  "gamerboy80twitch"

# The public web-player client ID: no auth involved.
def twitch_client_id() -> String:
  "kimne78kx3ncx6brgo4mv6wki5h1ko"

# The real handle; the site styles it as @gamerboy8O.
def twitter_handle() -> String:
  "gamerboy80"

# Data
# ----

type YtChannel is Data:
  YtChannel{name: String, subscribers: Nat, description: String, thumbnail: String}

# `published` is in ms (0: unknown).
type YtVideo is Data:
  YtVideo{id: String, title: String, description: String, published: Nat, views: Nat}

# The newest video, and the feed's title (the channel name).
type RssItem is Data:
  RssItem{video: YtVideo, title: String}

type YtData is Data:
  YtData{channel: YtChannel, video: YtVideo}

type TwitchData is Data:
  TwitchData{followers: Nat, live: Bool, viewers: Nat}

type TwitterData is Data:
  TwitterData{followers: Nat}

type Payload is Data:
  PYouTube{d: YtData}
  PTwitch{d: TwitchData}
  PTwitter{d: TwitterData}

def empty_channel() -> YtChannel:
  YtChannel{"", 0n, "", ""}

def empty_video() -> YtVideo:
  YtVideo{"", "", "", 0n, 0n}

def empty(+name: String) -> Payload:
  Bool.pick(Payload, String.eq(name, "youtube"), PYouTube{YtData{empty_channel(), empty_video()}},
    Bool.pick(Payload, String.eq(name, "twitch"), PTwitch{TwitchData{0n, False{}, 0n}},
      PTwitter{TwitterData{0n}}))

# On-disk JSON
# ------------

def kv(k: String, v: J.Json) -> J.JField:
  J.JF{k, v}

def channel_json(c: YtChannel) -> J.Json:
  match c:
    case YtChannel{name, subs, desc, thumb}:
      J.JObj{[kv("name", J.JStr{name}), kv("subscribers", J.nat(subs)),
        kv("description", J.JStr{desc}), kv("thumbnail", J.JStr{thumb})]}

def video_json(v: YtVideo) -> J.Json:
  match v:
    case YtVideo{id, title, desc, +published, views}:
      J.JObj{[kv("id", J.JStr{id}), kv("title", J.JStr{title}), kv("description", J.JStr{desc}),
        kv("published", J.JStr{C.rfc3339(published)}), kv("views", J.nat(views))]}

def payload_json(p: Payload) -> J.Json:
  match p:
    case PYouTube{YtData{c, v}}:
      J.JObj{[kv("channel", channel_json(c)), kv("video", video_json(v))]}
    case PTwitch{TwitchData{f, live, viewers}}:
      J.JObj{[kv("followers", J.nat(f)), kv("live", J.JBool{live}), kv("viewers", J.nat(viewers))]}
    case PTwitter{TwitterData{f}}:
      J.JObj{[kv("followers", J.nat(f))]}

def time_of(+s: String) -> Nat:
  Maybe.default(&2, Nat, C.parse(s), 0n)

def channel_of(+j: J.Json) -> YtChannel:
  YtChannel{J.get_str(j, "name"), J.get_nat(j, "subscribers"), J.get_str(j, "description"),
    J.get_str(j, "thumbnail")}

def video_of(+j: J.Json) -> YtVideo:
  YtVideo{J.get_str(j, "id"), J.get_str(j, "title"), J.get_str(j, "description"),
    time_of(J.get_str(j, "published")), J.get_nat(j, "views")}

# The `data` object of a cache file, for the source called `name`.
def payload_of(+name: String, +j: J.Json) -> Payload:
  Bool.pick(Payload, String.eq(name, "youtube"),
    PYouTube{YtData{channel_of(J.get_obj(j, "channel")), video_of(J.get_obj(j, "video"))}},
    Bool.pick(Payload, String.eq(name, "twitch"),
      PTwitch{TwitchData{J.get_nat(j, "followers"), J.as_bool(J.get(j, "live")), J.get_nat(j, "viewers")}},
      PTwitter{TwitterData{J.get_nat(j, "followers")}}))

# YouTube
# -------

# The text of the first <tag>…</tag> (no nested markup), entities decoded.
def xml_text(+s: String, +tag: String) -> Maybe<&2, String>:
  Maybe.bind(&2, String, String, T.seek(s, "<" ++ tag ++ ">"), r => Some{T.unescape(T.until(r, '<'))})

def or_empty(m: Maybe<&2, String>) -> String:
  Maybe.default(&2, String, m, "")

def rss_entry(+feed_title: String, +e: String) -> Result<&2, &2, String, RssItem>:
  +id = or_empty(xml_text(e, "yt:videoId"))
  Bool.pick(Result<&2, &2, String, RssItem>, String.is_empty(id), Fail{"feed has no entries"},
    Done{RssItem{YtVideo{id, or_empty(xml_text(e, "title")), or_empty(xml_text(e, "media:description")),
      time_of(or_empty(xml_text(e, "published"))),
      Maybe.default(&2, Nat, Maybe.bind(&2, String, Nat, T.seek(e, "<media:statistics views=\""),
        r => Nat.read(T.until(r, '"'))), 0n)}, feed_title}})

def rss_feed(+feed_title: String, entry: Maybe<&2, String>) -> Result<&2, &2, String, RssItem>:
  match entry:
    case None{}:
      Fail{"feed has no entries"}
    case Some{+e}:
      rss_entry(feed_title, e)

# The newest video and the channel name, from the feed (newest first). The
# feed's own <title> comes before the first <entry>.
def parse_rss(+body: String) -> Result<&2, &2, String, RssItem>:
  rss_feed(or_empty(xml_text(body, "title")), T.seek(body, "<entry>"))

# "687K", "1.2M", "12,345" -> an integer, rounded like Go's int64(f*mult+0.5).
def parse_abbrev.num(+int: String, +frac: String, +mult: Nat) -> Maybe<&2, Nat>:
  +scale = Nat.pow(10n, T.len(frac))
  Maybe.bind(&2, Nat, Nat, Nat.read(int ++ frac),
    n => Some{Nat.div(Nat.add(Nat.mul(Nat.mul(n, mult), 2n), scale), Nat.mul(scale, 2n))})

def parse_abbrev.split(r: String & String, +mult: Nat) -> Maybe<&2, Nat>:
  (+int, +frac) = r
  Bool.pick(Maybe<&2, Nat>, String.is_empty(int), None{}, parse_abbrev.num(int, frac, mult))

def no_commas.go(s: String, acc: String) -> String:
  match s:
    case SNil{}:
      String.reverse(acc)
    case SCon{',', t}:
      no_commas.go(t, acc)
    case SCon{c, t}:
      no_commas.go(t, SCon{c, acc})

def no_commas(s: String) -> String:
  no_commas.go(s, "")

def parse_abbrev(+s: String, +mult: Nat) -> Maybe<&2, Nat>:
  parse_abbrev.split(T.split_once(no_commas(s), '.'), mult)

def mult_of(+c: String) -> Nat:
  Bool.pick(Nat, String.eq(c, "K"), 1000n,
    Bool.pick(Nat, String.eq(c, "M"), 1000000n, Bool.pick(Nat, String.eq(c, "B"), 1000000000n, 1n)))

def is_num_char(+c: Char) -> Bool:
  Bool.or(Char.is_digit(c), Bool.or(Char.is_eq(c, '.'), Char.is_eq(c, ',')))

def num_span.head(+s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{c, t}:
      is_num_char(c)

def num_span(s: String, acc: String, ok: Bool) -> String & String:
  match s ok:
    case SCon{c, +t} True{}:
      num_span(t, SCon{c, acc}, num_span.head(t))
    case rest _:
      (String.reverse(acc), rest)

def subs_tail(+num: String, +rest: String) -> Maybe<&2, Nat>:
  +suffix = T.take(rest, 1n)
  +m = mult_of(suffix)
  +after = Bool.pick(String, Nat.is_eq(m, 1n), rest, T.drop(rest, 1n))
  Bool.pick(Maybe<&2, Nat>,
    Bool.or(T.starts_with(after, " subscribers\""), T.starts_with(after, " subscriber\"")),
    parse_abbrev(num, m), None{})

def subs_num(r: String & String) -> Maybe<&2, Nat>:
  (+num, +rest) = r
  Bool.pick(Maybe<&2, Nat>, T.head_digit(num), subs_tail(num, rest), None{})

# A JSON string body starting right after its opening quote: (raw body, rest
# after the closing quote). `esc`: the previous char was a backslash.
def jstr_span(s: String, acc: String, esc: Bool) -> Maybe<&1, String & String>:
  match s esc:
    case SNil{} _:
      None{}
    case SCon{c, t} True{}:
      jstr_span(t, SCon{c, acc}, False{})
    case SCon{'"', t} False{}:
      Some{(String.reverse(acc), t)}
    case SCon{'\\', t} False{}:
      jstr_span(t, SCon{'\\', acc}, True{})
    case SCon{c, t} False{}:
      jstr_span(t, SCon{c, acc}, False{})

def jstr_decode.go(r: Result<&2, &2, String, J.Json>) -> String:
  match r:
    case Done{J.JStr{s}}:
      s
    case other:
      ""

def jstr_decode(+raw: String) -> String:
  jstr_decode.go(J.parse("\"" ++ raw ++ "\""))

# The channel page
# ----------------
#
# The page is over a megabyte and every pattern sits near its end, so it is
# read in one pass that only looks closer at '"' and '<'. Each pattern keeps
# its first match, as Go's FindSubmatch does. Every check below is a match on
# a computed Bool (not Bool.pick), so the work past a cheap prefix test only
# happens where the prefix is there.

type Meta is Data:
  Meta{name: String, description: String}

type Scan is Data:
  Scan{subs: Maybe<&2, Nat>, meta: Maybe<&2, Meta>, avatar: Maybe<&2, String>}

# `content":"([0-9][0-9.,]*[KMB]?) subscribers?"`, at the head of `t` (just
# past a '"').
def subs_at.go(+t: String, hit: Bool) -> Maybe<&2, Nat>:
  match hit:
    case True{}:
      subs_num(num_span(T.drop(t, 10n), "", num_span.head(T.drop(t, 10n))))
    case False{}:
      None{}

def subs_at(+t: String) -> Maybe<&2, Nat>:
  subs_at.go(t, T.starts_with(t, "content\":\""))

def meta_desc(+name: String, m: Maybe<&1, String & String>) -> Maybe<&2, Meta>:
  match m:
    case Some{(+raw, rest)}:
      Some{Meta{name, jstr_decode(raw)}}
    case None{}:
      None{}

def meta_rest.go(+raw: String, +rest: String, hit: Bool) -> Maybe<&2, Meta>:
  match hit:
    case True{}:
      meta_desc(jstr_decode(raw), jstr_span(T.drop(rest, 16n), "", False{}))
    case False{}:
      None{}

def meta_rest(m: Maybe<&1, String & String>) -> Maybe<&2, Meta>:
  match m:
    case Some{(+raw, +rest)}:
      meta_rest.go(raw, rest, T.starts_with(rest, ",\"description\":\""))
    case None{}:
      None{}

# `channelMetadataRenderer":\{"title":("…"),"description":("…")`, just past a '"'.
def meta_at.go(+t: String, hit: Bool) -> Maybe<&2, Meta>:
  match hit:
    case True{}:
      meta_rest(jstr_span(T.drop(t, 35n), "", False{}))
    case False{}:
      None{}

def meta_at(+t: String) -> Maybe<&2, Meta>:
  meta_at.go(t, T.starts_with(t, "channelMetadataRenderer\":{\"title\":\""))

# `meta property="og:image" content="([^"]+)"`, just past a '<'.
def avatar_at.go(+t: String, hit: Bool) -> Maybe<&2, String>:
  match hit:
    case True{}:
      Some{T.until(T.drop(t, 34n), '"')}
    case False{}:
      None{}

def avatar_at(+t: String) -> Maybe<&2, String>:
  avatar_at.go(t, T.starts_with(t, "meta property=\"og:image\" content=\""))

def keep_subs(m: Maybe<&2, Nat>, +t: String) -> Maybe<&2, Nat>:
  match m:
    case Some{n}:
      Some{n}
    case None{}:
      subs_at(t)

def keep_meta(m: Maybe<&2, Meta>, +t: String) -> Maybe<&2, Meta>:
  match m:
    case Some{x}:
      Some{x}
    case None{}:
      meta_at(t)

def keep_avatar(m: Maybe<&2, String>, +t: String) -> Maybe<&2, String>:
  match m:
    case Some{x}:
      Some{x}
    case None{}:
      avatar_at(t)

def at_quote(+t: String, st: Scan) -> Scan:
  match st:
    case Scan{subs, meta, avatar}:
      Scan{keep_subs(subs, t), keep_meta(meta, t), avatar}

def at_lt(+t: String, st: Scan) -> Scan:
  match st:
    case Scan{subs, meta, avatar}:
      Scan{subs, meta, keep_avatar(avatar, t)}

def scan(s: String, st: Scan) -> Scan:
  match s:
    case SNil{}:
      st
    case SCon{'"', +t}:
      scan(t, at_quote(t, st))
    case SCon{'<', +t}:
      scan(t, at_lt(t, st))
    case SCon{c, t}:
      scan(t, st)

def channel_page.meta(+subs: Nat, m: Maybe<&2, Meta>, +thumb: String) -> YtChannel:
  match m:
    case Some{Meta{+name, desc}}:
      YtChannel{Bool.pick(String, String.is_empty(name), "gamerboy80", name), subs, desc, thumb}
    case None{}:
      YtChannel{"gamerboy80", subs, "", thumb}

def channel_page.fin(st: Scan) -> Result<&2, &2, String, YtChannel>:
  match st:
    case Scan{None{}, meta, avatar}:
      Fail{"subscriber count not found"}
    case Scan{Some{+subs}, meta, avatar}:
      Done{channel_page.meta(subs, meta, Maybe.default(&2, String, avatar, ""))}

# Subscribers (rounded, as YouTube shows them), name, description, avatar.
def parse_channel_page(body: String) -> Result<&2, &2, String, YtChannel>:
  channel_page.fin(scan(body, Scan{None{}, None{}, None{}}))

def rss_url() -> String:
  "https://www.youtube.com/feeds/videos.xml?channel_id=" ++ youtube_channel_id()

def channel_url() -> String:
  "https://www.youtube.com/channel/" ++ youtube_channel_id()

def then_rss(r: Result<&2, &2, String, String>) -> Result<&2, &2, String, RssItem>:
  match r:
    case Done{+b}:
      parse_rss(b)
    case Fail{e}:
      Fail{e}

def then_page(r: Result<&2, &2, String, String>) -> Result<&2, &2, String, YtChannel>:
  match r:
    case Done{+b}:
      parse_channel_page(b)
    case Fail{e}:
      Fail{e}

# Both halves of a YouTube refresh; the state merges them with the last
# good value (fetchYouTube), since either half may fail on its own.
type YtResult is Data:
  YtResult{rss: Result<&2, &2, String, RssItem>, page: Result<&2, &2, String, YtChannel>}

def fetch_youtube(+jobs: String) -> IO(YtResult):
  do IO<YtResult>:
    a : Result<&2, &2, String, String> <- F.get(jobs, "youtube-rss", rss_url(), [])
    b : Result<&2, &2, String, String> <- F.get(jobs, "youtube-page", channel_url(),
      ["-H", "Cookie: CONSENT=YES+1; SOCS=CAI"])
    return YtResult{then_rss(a), then_page(b)}

# Twitch
# ------

def twitch_body() -> String:
  J.stringify(J.JObj{[kv("query", J.JStr{"query{user(login:\"" ++ twitch_login() ++
    "\"){followers{totalCount} stream{id viewersCount}}}"})]})

def twitch_stream(+followers: Nat, s: J.Json) -> TwitchData:
  match s:
    case J.JObj{+fs}:
      TwitchData{followers, True{}, J.get_nat(J.JObj{fs}, "viewersCount")}
    case other:
      TwitchData{followers, False{}, 0n}

def twitch_user(u: J.Json) -> Result<&2, &2, String, TwitchData>:
  match u:
    case J.JObj{+fs}:
      Done{twitch_stream(J.get_nat(J.get_obj(J.JObj{fs}, "followers"), "totalCount"),
        J.get_obj(J.JObj{fs}, "stream"))}
    case other:
      Fail{"gql: user not found"}

def twitch_errors(errs: List<&2, J.Json>, +j: J.Json) -> Result<&2, &2, String, TwitchData>:
  match errs:
    case Con{e, rest}:
      Fail{"gql: " ++ J.get_str(e, "message")}
    case Nil{}:
      twitch_user(J.get_obj(J.get_obj(j, "data"), "user"))

def parse_twitch.go(r: Result<&2, &2, String, J.Json>) -> Result<&2, &2, String, TwitchData>:
  match r:
    case Done{+j}:
      twitch_errors(J.get_list(j, "errors"), j)
    case Fail{e}:
      Fail{e}

def parse_twitch(+body: String) -> Result<&2, &2, String, TwitchData>:
  parse_twitch.go(J.parse(body))

def then_twitch(r: Result<&2, &2, String, String>) -> Result<&2, &2, String, TwitchData>:
  match r:
    case Done{+b}:
      parse_twitch(b)
    case Fail{e}:
      Fail{e}

# One unauthenticated GQL query gets followers and live status.
def fetch_twitch(+jobs: String) -> IO(Result<&2, &2, String, TwitchData>):
  do IO<Result<&2, &2, String, TwitchData>>:
    r : Result<&2, &2, String, String> <- F.get(jobs, "twitch", "https://gql.twitch.tv/gql",
      ["-H", "Client-ID: " ++ twitch_client_id(), "-H", "Content-Type: application/json",
        "--data-binary", twitch_body()])
    return then_twitch(r)

# Twitter / X
# -----------

def parse_fx.go(r: Result<&2, &2, String, J.Json>) -> Result<&2, &2, String, TwitterData>:
  match r:
    case Done{+j}:
      +f = J.get_nat(J.get_obj(j, "user"), "followers")
      Bool.pick(Result<&2, &2, String, TwitterData>, Nat.is_eq(f, 0n), Fail{"no user in response"},
        Done{TwitterData{f}})
    case Fail{e}:
      Fail{e}

def parse_fx(+body: String) -> Result<&2, &2, String, TwitterData>:
  parse_fx.go(J.parse(body))

def then_fx(r: Result<&2, &2, String, String>) -> Result<&2, &2, String, TwitterData>:
  match r:
    case Done{+b}:
      parse_fx(b)
    case Fail{e}:
      Fail{e}

def fx_url() -> String:
  "https://api.fxtwitter.com/" ++ twitter_handle()

def fx_next(r: Result<&2, &2, String, TwitterData>, +attempt: Nat, errs: List<&2, String>,
  more: List<&2, String> -> IO(Result<&2, &2, String, TwitterData>)) -> IO(Result<&2, &2, String, TwitterData>):
  match r:
    case Done{d}:
      IO.pure(Result<&2, &2, String, TwitterData>, Done{d})
    case Fail{e}:
      more(("fxtwitter attempt " ++ Nat.show(attempt) ++ ": " ++ e) <> errs)

# FxTwitter intermittently answers 404 "User not found": up to `left` more tries.
def fx_try(left: Nat, +attempt: Nat, +jobs: String, errs: List<&2, String>) -> IO(Result<&2, &2, String, TwitterData>):
  match left:
    case 0n:
      IO.pure(Result<&2, &2, String, TwitterData>, Fail{T.join(List.reverse(&2, String, errs), "\n")})
    case 1n+l:
      do IO<Result<&2, &2, String, TwitterData>>:
        r : Result<&2, &2, String, String> <- F.get(jobs, "twitter", fx_url(), [])
        out : Result<&2, &2, String, TwitterData> <- fx_next(then_fx(r), attempt, errs,
          es => fx_try(l, 1n+attempt, jobs, es))
        return out

def fetch_twitter(+jobs: String) -> IO(Result<&2, &2, String, TwitterData>):
  fx_try(3n, 1n, jobs, Nil{})
