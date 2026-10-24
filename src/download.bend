# The texture pack link (download.go).
#
# The original site linked http://bit.ly/ShortSwordd18, which 301s to this
# MediaFire file. MediaFire direct-download URLs carry a token that changes on
# every page load, so instead of hard-coding one, /download/shortsword
# resolves a fresh link from the page's download button and redirects to it.
# A resolved link is reused for 5 minutes.

import Base
import ./text.bend as T
import ./fetch.bend as F

def page_url() -> String:
  "https://www.mediafire.com/download/ia8x51jabwy6bka/1.8+AciDicBliTzz+Short+Sword+Pack+By+TBNRnorton.zip"

def link_ttl() -> Nat:
  300000n

def skip_digits(s: String, ok: Bool) -> String:
  match s ok:
    case SCon{c, +t} True{}:
      skip_digits(t, T.head_digit(t))
    case rest _:
      rest

def host_rest.go(+s: String, hit: Bool) -> Bool:
  match hit:
    case True{}:
      T.starts_with(skip_digits(T.drop(s, 8n), T.head_digit(T.drop(s, 8n))), ".mediafire.com/")
    case False{}:
      False{}

# "download[0-9]*.mediafire.com/" at the head of `s`.
def host_ok(+s: String) -> Bool:
  host_rest.go(s, T.starts_with(s, "download"))

def link_at.check(+url: String, ok: Bool) -> Maybe<&2, String>:
  match ok:
    case True{}:
      Some{url}
    case False{}:
      None{}

def link_at.url(+url: String) -> Maybe<&2, String>:
  +after = Bool.pick(String, T.starts_with(url, "https://"), T.drop(url, 8n), T.drop(url, 7n))
  link_at.check(url, Bool.and(Bool.or(T.starts_with(url, "https://"), T.starts_with(url, "http://")),
    Bool.and(host_ok(after), Bool.not(String.is_empty(T.drop(after, 1n))))))

def link_at.go(+t: String, hit: Bool) -> Maybe<&2, String>:
  match hit:
    case True{}:
      link_at.url(T.until(T.drop(t, 5n), '"'))
    case False{}:
      None{}

# `href="(https?://download[0-9]*\.mediafire\.com/[^"]+)"`, just past an 'h'.
def link_at(+t: String) -> Maybe<&2, String>:
  link_at.go(t, T.starts_with(t, "ref=\"http"))

def scan(s: String, found: Maybe<&2, String>) -> Maybe<&2, String>:
  match s found:
    case _ Some{x}:
      Some{x}
    case SNil{} None{}:
      None{}
    case SCon{'h', +t} None{}:
      scan(t, link_at(t))
    case SCon{c, t} None{}:
      scan(t, None{})

def parse_page.go(m: Maybe<&2, String>) -> Result<&2, &2, String, String>:
  match m:
    case Some{+url}:
      Done{T.replace_first(T.unescape(url), "http://", "https://")}
    case None{}:
      Fail{"download button not found on MediaFire page"}

# The download button's link, entities decoded; the page emits http://, and
# the same host serves https.
def parse_page(body: String) -> Result<&2, &2, String, String>:
  parse_page.go(scan(body, None{}))

def then_page(r: Result<&2, &2, String, String>) -> Result<&2, &2, String, String>:
  match r:
    case Done{b}:
      parse_page(b)
    case Fail{e}:
      Fail{e}

def resolve(+jobs: String) -> IO(Result<&2, &2, String, String>):
  do IO<Result<&2, &2, String, String>>:
    r : Result<&2, &2, String, String> <- F.get(jobs, "pack", page_url(), [])
    return then_page(r)
