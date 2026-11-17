{
  description = "ibeatkids — archived gamerboy80 fan site rebuild + live JSON API (Bend 2)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

      # Prebuilt Bend 2.0.40 (bundled JS runner). The vendored ELF hardcodes
      # /lib64/ld-linux-x86-64.so.2 as its interpreter and references bare
      # glibc sonames; fixupPhase rewrites both for NixOS.
      bend = pkgs.stdenv.mkDerivation {
        pname = "bend";
        version = "2.0.40";

        src = pkgs.fetchurl {
          url = "https://github.com/bendlang/bend/releases/download/v2.0.40/bend-2.0.40-linux-x64.tar.gz";
          hash = "sha256-yf+NZ72QP7atmia0PYpiwBAh3oKkTVXOSj3NRzIRPWs=";
        };

        dontConfigure = true;
        dontBuild = true;
        dontStrip = true;

        nativeBuildInputs = [ pkgs.patchelf ];

        phases = [ "unpackPhase" "installPhase" "fixupPhase" ];

        installPhase = ''
          mkdir -p $out
          cp -r . $out/
        '';

        fixupPhase = ''
          patchelf --set-interpreter ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 $out/bin/bend
          patchelf --set-rpath ${pkgs.glibc}/lib $out/bin/bend
        '';
      };
      # `bend main.bend` from the repo root; curl and sh are runtime deps
      # (src/fetch.bend shells out to them for HTTPS). For memory checks skip
      # LD_PRELOAD profilers: the bundled Bun runtime carves arenas outside
      # glibc malloc, so heaptrack only sees the glibc sliver. Read the truth
      # instead: awk '/VmRSS|VmHWM/{print}' /proc/$(pgrep -f main.bend)/status
      #
      # `bend main.bend -o ibeatkids` compiles a standalone native binary
      # (needs clang); it replaces the ~1 GiB bundled Bun runner with a
      # clang-linked ELF.
    in
    {
      devShell.${system} = pkgs.mkShell {
        buildInputs = [ bend ];
        nativeBuildInputs = [ pkgs.curl pkgs.clang ];
      };
      packages.${system} = {
        inherit bend;
        default = bend;
      };
    };
}
