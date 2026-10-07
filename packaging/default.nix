# Packaged port: the prebuilt game binaries (build.sh first), the start-up scripts and the GTK4
# launcher, with their whole Nix closure and Mesa's Vulkan drivers. `bash packaging/appimage.sh`
# turns it into an AppImage (Steam Deck); `nix-build packaging` alone gives result/bin/bbport.
{ pkgs ? import <nixpkgs> { }
  # Store paths the prebuilt binaries load libraries from (their RUNPATHs), written by
  # appimage.sh. Nix only finds references to its inputs, and the binaries were built outside.
, runtimePaths ? (if builtins.pathExists ./runtime-paths.nix then import ./runtime-paths.nix else [ ])
}:
let
  lib = pkgs.lib;
  # aarch64 hosts: the game's x86-64 code runs in FEXCore (out/fex/libbbcpu.so, build.sh).
  arm = pkgs.stdenv.hostPlatform.isAarch64;
  root = ./..;
  # FSR 4.1.1 models are extracted from AMD's DLLs: never in a public package. BB_PACKAGE_FSR411=1
  # (appimage.sh runs nix with --impure) bundles the local fsr4_411 for one's own devices.
  fsr411 = builtins.getEnv "BB_PACKAGE_FSR411" == "1";
  assetDirs = [ "scripts" "patches" "fsr4_shaders" "launcher" ] ++ lib.optional fsr411 "fsr4_411";
  # Only what the package needs (the tree also holds builds, profiles and captures).
  wanted = [
    "run.sh" "out" "out/bb-probe" "out/bb-gpu-capabilities" "out/gpu" "out/gpu/libbbgpu.so"
  ] ++ lib.optionals arm [ "out/fex" "out/fex/libbbcpu.so" ] ++ assetDirs;
  src = builtins.path {
    name = "bbport-src";
    path = root;
    filter = path: type:
      let rel = lib.removePrefix (toString root + "/") (toString path);
      in builtins.elem rel wanted
        || lib.any (dir: lib.hasPrefix (dir + "/") rel) assetDirs;
  };
  python = pkgs.python3.withPackages (ps: [ ps.pygobject3 ]);
  # Mesa comes with the package. bbport_vulkan.py adds the host NVIDIA ICD and
  # only its vendor libraries (matching the host's kernel module).
  # aarch64: Adreno (Turnip), Mali (Panfrost), Raspberry Pi (V3DV), Apple (Asahi), AMD.
  icdArch = pkgs.stdenv.hostPlatform.parsed.cpu.name;
  icdNames = if arm then [ "freedreno" "panfrost" "broadcom" "asahi" "radeon" ] else [ "radeon" "intel" ];
  # Mesa 26's Turnip loses the device on the Adreno 740 (SM8550) without these patches. Only
  # freedreno is rebuilt; the other drivers stay the binary cache's Mesa.
  turnip = (pkgs.mesa.override {
    galliumDrivers = [ "freedreno" ];
    vulkanDrivers = [ "freedreno" ];
    vulkanLayers = [ ];
    enablePatentEncumberedCodecs = false;
  }).overrideAttrs (old: {
    patches = old.patches ++ [
      ./mesa-sm8550/0001-add-a830-chip-id.patch
      ./mesa-sm8550/0001-freedreno-ir3-vulkan-disable-bindless-ubo-const-lowering.patch
      ./mesa-sm8550/001-fix-freedreno-vulkan.patch
    ];
    mesonFlags = map (flag: if lib.hasPrefix "-Dtools=" flag then "-Dtools=" else flag) old.mesonFlags
      ++ [ "-Dgallium-va=disabled" ];
    postInstall = old.postInstall + ''
      mkdir -p $opencl $spirv2dxil
    '';
  });
  icdMesa = name: if arm && name == "freedreno" then turnip else pkgs.mesa;
  # BB_MANGOHUD_SRC: a MangoHud 0.8.4 tree with its subprojects already fetched (meson setup),
  # replacing nixpkgs' release, e.g. one that reads the Adreno's load and the Snapdragon sensors.
  # Only its Vulkan layer is bundled.
  mangohudSrc = builtins.getEnv "BB_MANGOHUD_SRC";
  mangohud = if mangohudSrc == "" then pkgs.mangohud else
    (pkgs.mangohud.override { gamescopeSupport = false; nvidiaSupport = false; }).overrideAttrs (old: {
      src = builtins.path {
        name = "mangohud-src";
        path = mangohudSrc;
        filter = path: type:
          !(builtins.elem (lib.removePrefix (mangohudSrc + "/") (toString path))
            [ ".git" "build" "subprojects/packagecache" ])
          && baseNameOf path != "__pycache__";
      };
      postUnpack = "";
      # Its LD_PRELOAD script differs from the release's; the game loads the Vulkan layer.
      patches = lib.filter (patch: !(lib.hasSuffix "preload-nix-workaround.patch" (toString patch)))
        old.patches;
      postPatch = "";
      mesonFlags = old.mesonFlags ++ [ "-Dwith_mangohud_next=false" ];
      buildInputs = old.buildInputs ++ [ pkgs.vulkan-loader pkgs.libdrm pkgs.libGL ];
    });
  icds = lib.concatMapStringsSep ":"
    (name: "${icdMesa name}/share/vulkan/icd.d/${name}_icd.${icdArch}.json") icdNames;
  # Fonts: bundled DejaVu and Adwaita plus the host's usual font directories, but not the host's
  # /etc/fonts: on NixOS it names fonts in the host's /nix/store, which the AppImage hides behind
  # its own store in some environments (Steam's FHS sandbox), and the launcher showed boxes.
  fontsConf = pkgs.writeText "bbport-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <dir>${pkgs.dejavu_fonts}/share/fonts</dir>
      <dir>${pkgs.adwaita-fonts}/share/fonts</dir>
      <dir>/usr/share/fonts</dir>
      <dir>/usr/local/share/fonts</dir>
      <dir prefix="xdg">fonts</dir>
      <cachedir prefix="xdg">bbport/fontconfig</cachedir>
      <include ignore_missing="yes">${pkgs.fontconfig.out}/etc/fonts/conf.d</include>
    </fontconfig>
  '';
  # Environment the closure needs on any host: icon themes, SVG icon loader, fonts (above) and
  # a UTF-8 locale built into glibc.
  common = ''
      --prefix XDG_DATA_DIRS : ${mangohud}/share:${pkgs.adwaita-icon-theme}/share:${pkgs.hicolor-icon-theme}/share:${pkgs.gtk4}/share/gsettings-schemas/${pkgs.gtk4.name} \
      --set-default GDK_PIXBUF_MODULE_FILE ${pkgs.librsvg}/${pkgs.gdk-pixbuf.moduleDir}.cache \
      --set-default FONTCONFIG_FILE ${fontsConf} \
      --set-default LC_ALL C.UTF-8 \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libglvnd pkgs.libx11 pkgs.libxext ]} \
      --set BB_VULKANINFO ${pkgs.vulkan-tools}/bin/vulkaninfo \
  '';
in
pkgs.stdenv.mkDerivation {
  pname = "bbport";
  version = "0.1";
  inherit src;
  nativeBuildInputs = [ pkgs.makeShellWrapper pkgs.wrapGAppsHook4 pkgs.gobject-introspection ];
  buildInputs = [ pkgs.gtk4 pkgs.libadwaita pkgs.adwaita-icon-theme pkgs.librsvg ]
    ++ map builtins.storePath runtimePaths;
  dontBuild = true;
  dontConfigure = true;
  # The binaries live under share/ (next to the scripts run.sh expects): strip them too, which
  # also drops the compiler and header paths their debug info would keep in the closure.
  stripDebugList = [ "share/bbport/bin/gpu" ] ++ lib.optional arm "share/bbport/bin/cpu";
  # patchelf (RPATH shrinking) corrupts the non-PIE game binary's symbol versions; it finds
  # its library through $ORIGIN/gpu and its other libraries through the build's RUNPATH.
  dontPatchELF = true;
  dontWrapGApps = true; # wrapped once below, together with the launcher's own variables
  installPhase = ''
    runHook preInstall
    d=$out/share/bbport
    mkdir -p $d/bin $out/bin
    cp run.sh $d/
    cp -r scripts patches fsr4_shaders launcher $d/
    # FSR 4.1.1 models only with BB_PACKAGE_FSR411=1 (see above); otherwise run.sh finds them in
    # the data directory (~/.local/share/bbport/fsr4_411).
    if [ -d fsr4_411 ]; then
      ${pkgs.python3}/bin/python3 - <<'PY'
    import sys
    from pathlib import Path
    sys.path.insert(0, 'launcher')
    from bbport_assets import fsr411_problem
    for output in ('1920x1080', '3840x2160'):
        for preset in (0, 4):
            problem = fsr411_problem(Path('fsr4_411'), output, preset)
            if problem:
                raise SystemExit(problem)
    PY
      cp -r fsr4_411 $d/
    fi
    install -m755 out/bb-probe $d/bin/bb-probe
    install -m755 out/bb-gpu-capabilities $d/bin/bb-gpu-capabilities
    install -Dm755 out/gpu/libbbgpu.so $d/bin/gpu/libbbgpu.so
    ${lib.optionalString arm "install -Dm755 out/fex/libbbcpu.so $d/bin/cpu/libbbcpu.so"}
    ${lib.optionalString (mangohudSrc != "") ''
      if [ -f ${mangohud.src}/MangoHud/MangoHud.conf ]; then
        install -Dm644 ${mangohud.src}/MangoHud/MangoHud.conf $d/mangohud/MangoHud.conf
      fi
    ''}
    runHook postInstall
  '';
  postFixup = ''
    # bin/bbport is a static program (bbport-entry.c) that clears the host's LD_PRELOAD (Steam's
    # overlay) and similar before the wrapper's own dynamic programs start.
    mkdir -p $out/libexec
    gcc -O2 -Wall -Werror -static -L${pkgs.glibc.static}/lib -DTARGET="\"$out/libexec/bbport\"" \
      ${./bbport-entry.c} -o $out/bin/bbport
    makeShellWrapper ${python}/bin/python3 $out/libexec/bbport \
      "''${gappsWrapperArgs[@]}" \
      ${common}      --add-flags "$out/share/bbport/launcher/bbport_vulkan.py ${python}/bin/python3 $out/share/bbport/launcher/bbport_launcher.py" \
      --set BB_PREBUILT 1 \
      --set PYTHON ${pkgs.python3}/bin/python3 \
      --set BB_BUNDLED_VK_DRIVER_FILES ${icds} \
      --prefix PATH : ${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.util-linux pkgs.procps ]} \
      --run 'export BB_DATA_DIR=''${BB_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/bbport}; mkdir -p "$BB_DATA_DIR"'
    # The game alone, without the launcher (settings from the data directory's bbport.ini).
    makeShellWrapper ${pkgs.python3}/bin/python3 $out/bin/bbport-game \
      ${common}      --add-flags "$out/share/bbport/launcher/bbport_vulkan.py ${pkgs.bash}/bin/bash $out/share/bbport/run.sh" \
      --set BB_PREBUILT 1 \
      --set PYTHON ${pkgs.python3}/bin/python3 \
      --set BB_BUNDLED_VK_DRIVER_FILES ${icds} \
      --prefix PATH : ${lib.makeBinPath [ pkgs.bash pkgs.coreutils pkgs.procps ]} \
      --run 'export BB_DATA_DIR=''${BB_DATA_DIR:-''${XDG_DATA_HOME:-$HOME/.local/share}/bbport}; mkdir -p "$BB_DATA_DIR"'
  '';
  passthru = { inherit mangohud turnip; };
  meta.mainProgram = "bbport";
}
