import Base
import ../src/clock.bend as C

def big(s: String) -> Nat:
  Maybe.default(&2, Nat, Nat.read(s), 0n)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(C.rfc3339(big("1792828246003")))
    IO.print(C.rfc3339_ms(big("1792828246003")))
    IO.print(C.rfc3339_ms(big("1792828246700")))
    IO.print(C.rfc3339_ms(big("1792828246000")))
    IO.print(C.http_date(big("1792828246003")))
    IO.print(Nat.show(Maybe.default(&2, Nat, C.parse("2024-12-21T18:00:17+00:00"), 7n)))
    IO.print(C.rfc3339(Maybe.default(&2, Nat, C.parse("2024-12-21T18:00:17+00:00"), 7n)))
    IO.print(C.rfc3339_ms(Maybe.default(&2, Nat, C.parse("2026-10-24T07:42:50.743519479Z"), 7n)))
    IO.print(C.rfc3339(Maybe.default(&2, Nat, C.parse("2024-03-04T13:00:30-05:00"), 7n)))
    IO.print(Nat.show(Maybe.default(&2, Nat, C.parse("0001-01-01T00:00:00Z"), 7n)))
    IO.print(C.rfc3339(Maybe.default(&2, Nat, C.parse("2000-02-29T23:59:59Z"), 7n)))
    IO.print(C.ago(Maybe.default(&2, Nat, C.parse("2024-12-21T18:00:17Z"), 7n), big("1792828246003")))
    IO.print(C.ago(big("1792828200000"), big("1792828246003")))
    IO.print(C.ago(big("1792828246003"), big("1792828246003")))
    IO.print(C.abbrev(687000n) ++ " " ++ C.abbrev(163777n) ++ " " ++ C.abbrev(46571n) ++ " " ++ C.abbrev(1550000n) ++ " " ++ C.abbrev(999n) ++ " " ++ C.abbrev(999999n))
    IO.print(C.commas(163777n) ++ " " ++ C.commas(1234567n) ++ " " ++ C.commas(12n) ++ " " ++ C.commas(0n) ++ " " ++ C.commas(100n) ++ " " ++ C.commas(1000n))
