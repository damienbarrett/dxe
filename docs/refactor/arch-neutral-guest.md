# Architecture-neutral guest: native `x86_64-linux` outputs (Branch 11 / Phase 4, `feat/qnap-arch-neutral`)

Increment 0 design note, written before any code exists (the same discipline
`docker-adapter-mapping.md` and `direct-volume-storage.md` used for Phases 2
and 3). Implements `qnap-dxe-plan.md`'s `## Phase 4` items 1-5 and `### DQ7`'s
"make the guest source tree architecture-neutral rather than duplicating the
Home Manager, NixVim, bootstrap, and scripts trees." Item 6 (the
context-directory rename) is explicitly **not** this phase's job; see
section 9. Developed entirely against `nix flake check --no-build`, `nix
eval`, fixture roots, and fakes -- no live build, no NAS, no `dx-test`/
`dx-host`, per the task.

User decisions recorded 2026-09-27, settled and not reopened: (1) Phase 4
proceeds now as a subagent task; (2) only disposable `dx-qnap-spike*` names
may exist on the NAS until Phase 7, and the exit gate's guest is created and
destroyed by the coordinating session; (3) the QNAP guest is 8 GB / 4 CPU
(`DX_CONTAINER_MEMORY=8G`, `DX_CONTAINER_CPUS=4` in
`tests/profiles/qnap-example.env`, Apple's default unchanged at 12G); (4) the
x86_64 closure is built natively inside the disposable QNAP guest during its
own bootstrap, cache first, building only what is not cached -- no
cross-compilation, no emulation, no separate builder.

## 1. Today's shape (baseline this branch varies from)

- `flake.nix` hardcodes `system = "aarch64-linux"` once at the top of
  `outputs` and derives everything (`pkgs`, `unstable`, `dxPackages`,
  `bootstrapEssentials`, `aiPackages`, `agy`, `nvim`) from that single
  binding. It exposes `devShells.${system}.default`,
  `packages.${system}.{default,ai-tools,bootstrap-essentials}`, and exactly
  one `homeConfigurations.dx`.
- `pins/agy.json` is a flat `{version, url, hash}` object, read once as
  `agyPin` and spliced into the single `agy` derivation.
- `scripts/dx-ai.sh` hardcodes
  `AGY_MANIFEST_URL=".../manifests/linux_arm64.json"` and has no notion of
  "which system am I on."
- No guest-side code anywhere asks `uname -m`. The controller-side
  docker-ssh preflight already does (`bin/lib/dx-runtime-docker.sh` line
  ~194-215, Phase 2/3): it maps the NAS's own `uname -m` and refuses to
  create anything if it disagrees with the configured `DX_GUEST_SYSTEM`.
  That check happens on the controller, before any remote mutation; nothing
  today checks agreement *inside* the guest itself once it is running.
- `bin/dx-create-container` already forwards two Phase 3 env tokens
  unconditionally (`DX_NIX_STORAGE_MODE`, `DX_IMAGE_IDENTITY`);
  `DX_GUEST_SYSTEM` is already a validated host config field
  (`bin/lib/dx-config.sh`: `DXE_CONFIG_FIELDS`, default `aarch64-linux`,
  validated to `aarch64-linux|x86_64-linux`) but is not yet one of the
  tokens passed into the container.
- `bootstrap/activation.sh`'s `run_home_manager_activation` hardcodes
  `"$DX_BOOTSTRAP_ROOT#homeConfigurations.dx.activationPackage"`.
- The docker-ssh adapter's `dx_runtime_docker_label_flags` (DQ6) renders
  exactly four labels (`managed`, `schema`, `profile`, `role`) and is the
  single call site both `dx_runtime_docker_container_create` and
  `dx_runtime_docker_volume_create` use; the lock container
  (`dx_runtime_docker_lock_acquire`) instead spells the same four labels
  out by hand plus a fifth (`owner`), never calling the shared helper.
  `dx_runtime_docker_container_list`'s `--format` is
  `table {{.Names}} {{.Image}} {{.Status}}` -- no label column.

## 2. Per-system flake outputs (design point A, item 1)

Add a small local helper, no new flake input:

```nix
let
  supportedSystems = [ "aarch64-linux" "x86_64-linux" ];
  forEachSystem = f: nixpkgs.lib.genAttrs supportedSystems f;
in
```

Every `system`-dependent `let` binding that exists today
(`pkgs`, `unstable`, `dxPackages`, `bootstrapEssentials`, `aiPackages`, `agy`,
`nvim`) moves inside a per-system function bound by `forEachSystem`, unchanged
in content. `nixvim.nix` already takes `system` as a parameter
(`import ./nixvim.nix { inherit pkgs nixvim system; }`), so it needs no
signature change -- just one call per system instead of one call total.

Outputs become:

```nix
devShells = forEachSystem (system: { default = ...; });
packages = forEachSystem (system: { default = ...; "ai-tools" = ...; bootstrap-essentials = ...; });
homeConfigurations =
  (forEachSystem (system: { "dx-${system}" = home-manager.lib.homeManagerConfiguration { ... }; }))
  // { }  # merged, see below
```

`forEachSystem` produces one attrset PER system
(`{ aarch64-linux = {...}; x86_64-linux = {...}; }`), which is exactly the
shape `packages` and `devShells` need (`packages.<system>.<name>`). For
`homeConfigurations` the shape is different: it is not keyed by system at
the top level today, and the attribute names it wants
(`dx-aarch64-linux`, `dx-x86_64-linux`) are flat siblings, not nested under a
system key. So `homeConfigurations` is built by flattening
`forEachSystem (system: { "dx-${system}" = ...; })` with
`nixpkgs.lib.foldl' (a: b: a // b) {} (builtins.attrValues (forEachSystem (...)))`
(or the equivalent `lib.mergeAttrsList`/manual `//` over
`builtins.attrValues`), then adding the alias:

```nix
homeConfigurations = flattened // {
  dx = flattened."dx-aarch64-linux";  # kept: nothing that still names
                                       # homeConfigurations.dx breaks.
};
```

Two known consumers of the bare `.dx` name today:
`bootstrap/activation.sh`'s `run_home_manager_activation`
(`"$DX_BOOTSTRAP_ROOT#homeConfigurations.dx.activationPackage"`) is changed
in section 4 below to select `dx-<system>` directly instead of relying on
the alias; the alias exists purely as a safety net for anything else
(docs, an operator's muscle memory, a future script) that still types the
bare name, per the task's explicit instruction to keep it.

`packages.<system>.*` references that are resolved as bare `.#name`
(`bootstrap/common.sh`'s `nix profile install "$bootstrap_root#bootstrap-essentials"`,
`dx-ai.sh`'s `#ai-tools`) need **no change**: `nix` resolves a bare
`.#attr` through `packages.<currentSystem>.<attr>` on its own, and
`currentSystem` inside the guest is whatever that guest's own Nix reports --
which is why per-system `packages` alone makes both call sites correct on
either architecture without editing them.

**Validation (G3, required):** `nix flake check --no-build
--no-write-lock-file ./container/dx-nixos-26.05`
in the throwaway `nixos/nix:2.34.8` container (`-m 6g`, brief's G3 recipe),
confirming both systems evaluate and `flake.lock` is byte-identical
afterward. If evaluating any `x86_64-linux` output needs a package that does
not exist for that system, that is a finding for the coordinating session
(task's "Decisions are not yours" list), not something to route around.
Section 5 (`tests/test_section5_nix.sh`) gains the same assertions it
already makes for `aarch64-linux`, parameterised over both systems, plus one
new assertion: `homeConfigurations.dx` and `homeConfigurations."dx-aarch64-linux"`
evaluate to the identical derivation (the alias is real, not a second
definition that could drift).

## 3. Keyed architecture pins (design point B, item 2-3)

### 3.1 New `pins/agy.json` shape

```json
{
  "aarch64-linux": {
    "version": "1.0.5",
    "url": "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.0.5-5009297080451072/linux-arm/cli_linux_arm64.tar.gz",
    "hash": "sha512-j5LtbiYWbdq1lbOXXkfpH90cC/c7OTviUodjHMrgcCpjcuvqJej71Jl6v22budIzaIaKW/oMeifL0hEJgcUBmA=="
  },
  "x86_64-linux": {
    "version": "1.2.12",
    "url": "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.12-5784551402897408/linux-x64/cli_linux_x64.tar.gz",
    "hash": "sha512-<converted from the manifest's hex sha512 in Increment 2, via `nix hash convert --hash-algo sha512 --to sri`, run in the same throwaway nix container -- not computed in this design-only increment>"
  }
}
```

A missing/unsupported architecture's entry is JSON `null` (not an absent
key -- `agyPin.${system} or null` would silently treat a typo the same as
"deliberately unsupported"; an explicit `null` for every key in
`supportedSystems` makes the two cases distinguishable and lets a completeness
check assert every supported system has *some* entry, even if it's `null`).

### 3.2 The amd64 Antigravity finding

**A native x86_64 (amd64) Antigravity CLI artifact exists.** Read-only check
performed for this design note (public HTTPS GET, same upstream host and
manifest-path shape as the existing arm64 pin, no state changed anywhere):

```
GET https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json
-> HTTP 200
{
  "version": "1.2.12",
  "url": "https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.12-5784551402897408/linux-x64/cli_linux_x64.tar.gz",
  "sha512": "d5f0fe7433cb7c43ea878c07627a4fdb82d218f3bef5e6436266f5d9fdd2df145523453b9be0c4250391a64a007f5f42f7faff797bc2b2d502e7efb4874e383a"
}
```

So `x86_64-linux`'s pin is real data, not `null`, in Increment 2 -- but the
`null`/"unsupported" mechanism below is still built and tested generically,
because DQ7 requires it as a standing contract (a *future* architecture, or
an upstream removal, must degrade the same way), not as a workaround only
for today's one gap. Note the two architectures are pinned at **different
upstream versions** (arm64 1.0.5, amd64 1.2.12) because each pin is
refreshed independently against its own manifest, exactly like today's
single-arch refresh -- this is expected, not a defect, and nothing requires
the two to move in lockstep.

### 3.3 `flake.nix`: per-system `agy`, filtered out of `aiPackages` when absent

```nix
agyPin = builtins.fromJSON (builtins.readFile ./pins/agy.json);

agyFor = system:
  let pin = agyPin.${system} or null; in
  if pin == null then null else pkgs.stdenv.mkDerivation rec {
    pname = "antigravity-cli";
    version = pin.version;
    src = pkgs.fetchurl { name = "antigravity-cli-src"; url = pin.url; hash = pin.hash; };
    # ...unchanged installPhase/nativeBuildInputs/buildInputs...
  };

aiPackages = with unstable;
  [ gemini-cli claude-code codex ]
  ++ lib.optional (agyFor system != null) (agyFor system)
  ++ [ herdr opencode pkgs.dbus pkgs.gnome-keyring ];
```

`dx_ai_trivial_build`'s allow-list (`antigravity-cli*`) needs no change: it
already matches by store-path-name prefix, which is identical regardless of
which system's `agy` derivation produced it.

### 3.4 `scripts/dx-ai.sh`: manifest URL per system, refresh keeps the map, unsupported diagnostic

```sh
dx_ai_agy_manifest_url() {
    case "$1" in
        aarch64-linux) printf '%s\n' "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json" ;;
        x86_64-linux)  printf '%s\n' "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json" ;;
        *) return 1 ;;
    esac
}
```

`AGY_MANIFEST_URL` (today a single env-overridable constant) becomes
resolved from the guest's own system (section 4's helper) at call time
instead of a fixed default; an explicit env override, if still wanted for a
test double, would need to name the system it is overriding for -- to be
finalised in Increment 2 against how Section 17's fakes actually intercept
`curl` (see 3.5).

`dx_ai_refresh_pin` gains a `system` parameter and updates only that key of
the map (`jq --arg system "$system" '.[$system] = {version:$version,
url:$url, hash:$hash}'`), leaving every other architecture's entry
untouched -- so refreshing one arch's pin can never perturb another's, and a
refresh run for an architecture whose current entry is `null` *adds* an
entry rather than requiring one to already exist.

The unsupported diagnostic (item 3) fires wherever `dx-ai` would otherwise
expect an `agy` binary for the running guest's system and the resolved pin
entry is `null`: print `agy: no native artifact for x86_64-linux; skipping
(DQ7)` to stderr and continue staging/installing every other tool in
`DX_AI_TOOLS`. This is never reached by an actual foreign-binary install --
the flake-level filter in 3.3 means the `#ai-tools` closure itself does not
contain a mis-arched `agy` to begin with; the diagnostic is dx-ai.sh's own
user-facing echo so "why is agy missing from this generation" is never a
silent surprise, matching the tool-inventory bookkeeping
(`.tools-manifest`/`DX_AI_LEGACY_TOOLS`) that already tracks per-generation
tool lists for the OpenCode-predates-this-generation case.

### 3.5 Test-surface finding (Section 17)

Every current Section 17 fixture writes the OLD flat pin shape directly
(e.g. `printf '%s\n' '{"version":"1","url":"...","hash":"sha512-test"}' >
"$published/pins/agy.json"` -- at least 3 call sites) and calls
`dx_ai_refresh_pin "$published"` with one positional argument. All of these
move to the new keyed shape and the two-argument call
(`dx_ai_refresh_pin "$published" "$system"`) in Increment 2 -- mechanical,
but a real diff across the file, not a one-line change. Flagged here so it
is not mistaken for scope creep when Increment 2's diff is reviewed.

## 4. The guest selects by its NATIVE system (design point C, item 1/3)

New sourceable helper, `container/dx-nixos-26.05/scripts/lib/dx-guest-system.sh`,
matching the existing `scripts/lib/dx-*.sh` naming and shape
(`dx-keyring.sh`, `dx-opencode-persistence.sh`,
`dx-persist-backup-select.sh`):

```sh
# Maps uname -m to a Nix system string. Guest-side; targets the guest's own
# pinned Linux Bash (Invariants: "Guest modules may continue to target
# their pinned Linux Bash"), written in the same conservative, POSIX-leaning
# idiom as its sibling scripts/lib files for consistency, not because this
# file itself needs Bash 3.2.
dx_guest_native_system() {
    case "$(uname -m)" in
        aarch64) printf '%s\n' aarch64-linux ;;
        x86_64)  printf '%s\n' x86_64-linux ;;
        *) echo "Error: unsupported guest architecture: $(uname -m)" >&2; return 1 ;;
    esac
}

# Resolves the system to use: the guest's own native system, cross-checked
# against DX_GUEST_SYSTEM when the host provided it (bin/dx-create-container's
# third env token). Disagreement refuses rather than silently using either
# value -- a wrong host profile must never make a guest quietly run as the
# wrong architecture.
dx_guest_resolve_system() {
    local native
    native="$(dx_guest_native_system)" || return 1
    if [ -n "${DX_GUEST_SYSTEM:-}" ] && [ "$DX_GUEST_SYSTEM" != "$native" ]; then
        echo "Error: host profile says DX_GUEST_SYSTEM=$DX_GUEST_SYSTEM, but this guest is $native." >&2
        return 1
    fi
    printf '%s\n' "$native"
}
```

Loaded two ways, matching the two existing loading patterns already in this
tree:

- **bootstrap.sh**: sourced alongside `bootstrap/common.sh` et al. (its own
  explicit `source` list), since `configure_guest`/`run_home_manager_activation`
  need it before Home Manager activation.
- **dx-ai.sh**: the same three-candidate `dx_ai_load_*` shape already used
  for `dx-opencode-persistence.sh` and `dx-keyring.sh` (script's own
  directory, `$HOME/.local/lib/dx/`, `$DX_AI_BOOTSTRAP_ROOT/scripts/lib/`),
  so a fresh guest's first `dx-ai` run before any AI generation is published
  can still resolve it, same as those two.

**Consumers:**

- `bootstrap/activation.sh`'s `run_home_manager_activation`:
  `activation_flake="$DX_BOOTSTRAP_ROOT#homeConfigurations.dx-$(dx_guest_resolve_system).activationPackage"`
  (selecting the per-system attribute directly, not going through the `dx`
  alias -- the alias is a compatibility net for other callers, not meant to
  be this call's own indirection).
- `scripts/dx-ai.sh`: resolves the system once, uses it both for
  `dx_ai_agy_manifest_url` (3.4) and for indexing `agyPin` when deciding
  whether to print the unsupported diagnostic.

**Refusal cases to test (Section 3, `tests/test_section3_bootstrap.sh`):**
agree (native matches `DX_GUEST_SYSTEM`, or `DX_GUEST_SYSTEM` unset -- Apple's
case today, since Apple never sets it), disagree (host profile says one
system, guest fixture's stubbed `uname -m` says another -- refuses, exit
nonzero, exact error text asserted), unsupported (`uname -m` returns
something in neither branch, e.g. `armv7l` -- refuses per DQ7's "32-bit ARM:
unsupported, stop" disposition, distinct error text).

### 4.1 The third env token

`bin/dx-create-container` adds exactly one more `--env` entry, alongside the
two Phase 3 tokens it already forwards unconditionally:

```sh
CREATE_ARGS=(
    ...
    --env "DX_NIX_STORAGE_MODE=$DX_NIX_STORAGE_MODE"
    --env "DX_IMAGE_IDENTITY=$DX_IMAGE_IDENTITY"
    --env "DX_GUEST_SYSTEM=$DX_GUEST_SYSTEM"
    ...
)
```

`DX_GUEST_SYSTEM` is already a resolved, validated config field (default
`aarch64-linux`), so this needs no new validation -- only the one new line
above. Forwarded unconditionally for `DX_RUNTIME=apple` too (same reasoning
Phase 3 used for the other two tokens): Apple's guest is always
`aarch64-linux` today, so `dx_guest_resolve_system` will see
`DX_GUEST_SYSTEM=aarch64-linux` agree with its own `uname -m`, a no-op
confirmation rather than a behavior change.

**Characterisation update (deliberate, per the task):**
`tests/test_runtime_boundary_characterisation.sh` lines ~656-750 pin the
*exact* Apple `container create` argv, byte for byte, and its own comment
already says the two Phase 3 tokens are the only deliberate deviation from
pre-Phase-2 behavior. This increment adds a third deliberate deviation: the
expected-argv reconstruction (lines 729-744) gains
`-e DX_GUEST_SYSTEM=aarch64-linux` (or whatever value the test's own `env`
invocation sets, matching the file's existing pattern of pinning every
config value explicitly), and the surrounding prose comment is updated to
say "three deliberate env tokens" instead of "two."

## 5. Package availability (design point D, item 4)

Two new checks, both evaluation/inventory-only -- no build, per the task:

1. **`nix eval`-based completeness test** (extends Section 5 or
   `test_refactor_contracts.sh`, whichever the actual authorship in
   Increment 4 finds is the better fit for "reads flake.nix's package
   lists," since `test_refactor_contracts.sh` already parses
   `bootstrapEssentials` line-by-line for the binary-to-package contract):
   for both `aarch64-linux` and `x86_64-linux`, `nix eval
   .#packages.<system>.default`, `.#packages.<system>.bootstrap-essentials`,
   and `.#packages.<system>.ai-tools` all evaluate (not build) without
   error, inside the throwaway `nixos/nix:2.34.8` container. A package that
   fails to evaluate for one system (not present in that system's
   `nixpkgs`) is exactly the "Decisions are not yours" stop condition the
   task names; nothing here silently drops a package to make evaluation
   pass.
2. **Guest-side inventory verifier**, `scripts/dx-verify-inventory` (new;
   nothing existing fits closely enough to extend -- `dx-ai.sh`'s tool list
   is AI-tools-only and the bootstrap essentials contract is pre-sshd only,
   neither covers the full `dxPackages` CLI inventory `docs/guest.md`/
   Section 6 describe): prints present/missing for the required CLI
   inventory by checking `command -v` for each tool `dxPackages` is
   supposed to have put on `PATH` after Home Manager activation, one line
   per tool (`present: git`, `missing: lazygit`), exit status reflects
   whether anything is missing. This is what the coordinating session runs
   via `dx_runtime_exec` against the disposable QNAP guest at the exit
   gate (SSH into the QNAP guest is Phase 5's job, so the gate uses `exec`,
   not `dx-ssh`).

## 6. System in tags and labels (design point E, item 5)

- `dx_runtime_docker_label_flags` (the shared four-label helper both
  `dx_runtime_docker_container_create` and `dx_runtime_docker_volume_create`
  already call) gains a fifth fixed label:
  `--label "io.dxe.system=${DX_GUEST_SYSTEM:?}"`. Because both call sites
  already funnel through this one function, containers and volumes get the
  new label with a one-line change here, no change at either call site.
- The lock container (`dx_runtime_docker_lock_acquire`) currently spells its
  four labels out by hand instead of calling the shared helper (so it could
  add its fifth, `owner`, without changing the helper's arity). It is
  refactored to call `dx_runtime_docker_label_flags lock` first and append
  `--label "io.dxe.owner=$owner"` to that result, so it picks up
  `io.dxe.system` the same way containers and volumes do, and the four
  shared labels stop being duplicated in two places. `dx_runtime_docker_lock_audit`/
  `dx_runtime_docker_lock_release`'s `inspect --format` strings are read-only
  projections of specific label keys and need no change (they do not
  enumerate "all labels").
- `dx_runtime_docker_container_list`'s `--format` gains a column:
  `table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{index .Labels "io.dxe.system"}}`,
  so `dx-status`'s existing `dx_runtime_container_list -a | grep
  "^${DX_CONTAINER_NAME}[[:space:]]"` line keeps working unmodified (still
  column-1-anchored) while the new column is visible in the same output
  `dx-status` already prints. Apple has no labels today and stays that way
  (task: "Apple: no labels today; unchanged").
- Section 33 (`tests/test_docker_runtime_adapter.sh`) gains: the label
  argv for container/volume/lock creation all include `io.dxe.system`;
  `dx_runtime_docker_container_list`'s rendered format string includes the
  new column; a fake-`docker` round trip proving the lock's refactored
  label construction still matches on audit/release (same values as before,
  now via the shared helper).

## 7. What the x86_64 exit gate will run (coordinating session only)

Per the task and brief, no part of this list is a subagent action:

- Create a disposable guest on the NAS named `dx-qnap-spike*` (never a
  default name), `DX_RUNTIME=docker-ssh`, `DX_GUEST_SYSTEM=x86_64-linux`,
  `DX_NIX_STORAGE_MODE=direct-volume`, `DX_CONTAINER_MEMORY=8G`,
  `DX_CONTAINER_CPUS=4` (this branch's `tests/profiles/qnap-example.env`
  addition, section 8).
- Its own bootstrap builds the x86_64 closure natively, cache first
  (`cache.nixos.org`), building only what misses -- the same substitution
  behavior the Apple guest already relies on. No cross-compilation, no
  emulation, no separate builder (user decision 4).
- `nix flake check --no-build` already passed in Increment 1's throwaway
  container before this point; this live step is the one place an actual
  x86_64 build happens, and it happens only inside the disposable guest.
- The guest-side inventory verifier (section 5) runs via `dx_runtime_exec`
  (not `dx-ssh` -- Phase 5's job), present/missing reported for the full CLI
  inventory.
- `io.dxe.system=x86_64-linux` visible on the created container/volumes via
  `dx-status`'s docker-ssh output (section 6).
- Guest destroyed afterward; nothing named `dx-qnap-spike*` survives the
  gate.
- Apple `dx-test` recreate + live tier also re-run (dual-target gate, brief):
  proves the one added env token and the guest-side system-agreement check
  do not regress Apple, which stays `aarch64-linux` end to end.

### 7.1 Live-gate finding: root-level `nix profile install` and `$HOME` (addendum, 2026-09-28)

The first x86_64 bootstrap on the NAS (section 7) failed in
`install_essential_packages` with:

```
An existing package already provides ... dx-bootstrap-essentials/bin/gunzip
... conflicting file from the new package ... gzip-1.14/bin/gunzip
```

Root cause, verified read-only on both runtimes: Docker injects `HOME=/root`
into the container process at runtime (never baked into the image config),
while Apple's `container` runtime leaves `HOME` unset for PID 1. An
unqualified `nix profile install` resolves the *default* profile through
`$HOME/.nix-profile`:

- With `HOME` set (docker-ssh), that resolves to
  `/nix/var/nix/profiles/default`, which the upstream `nixos/nix` base image
  already populates with a legacy `manifest.nix` user environment (`gzip-1.14`,
  `gnutar`, `coreutils-full`, and similar) -- so installing
  `bootstrap-essentials` there conflicts on overlapping file names.
- With `HOME` unset (Apple), the same command falls back to
  `/nix/var/nix/profiles/per-user/root/profile`, a fresh `manifest.json` --
  which is where dx-test's essentials actually live
  (`packages.aarch64-linux.bootstrap-essentials`).

So Apple's working behavior was accidental, not a property of the install
itself: it depended on `$HOME` being unset for the calling process, which is
a runtime accident, not a guarantee. The fix names the target profile
explicitly -- `nix profile install --profile
/nix/var/nix/profiles/per-user/root/profile ...` -- which is exactly the
first candidate `essentials_profile_store_path` (section "Today's shape")
already checks, so Apple's outcome is byte-identical and docker-ssh no
longer depends on `$HOME` being absent. Every other root-level `nix profile`
call site in `bootstrap/` and `scripts/` was audited for the same implicit-
default dependency: `scripts/dx-ai.sh`'s `nix profile add` already names
`--profile "$stage/profile"` explicitly; `bootstrap/activation.sh`'s
`run_as_dx "nix profile list"` runs through `run_as_dx`, which already pins
`HOME=/home/dx` before invoking `nix`, so it never depends on the ambiguous
root-level default; and `bootstrap/base-and-storage.sh`'s
`nix_image_default_profile_store_path` / `capture_nix_image_default_profile`
/ `nix_restore_image_default_profile` read and relink
`/nix/var/nix/profiles/default` directly at the filesystem level
(`readlink`/`ln -s`/`mv`) as a deliberate image-provenance mechanism -- they
never invoke `nix profile install`/`add`, so they are not exposed to this
ambiguity either. `install_essential_packages` was the only call site that
needed the fix.

## 8. Non-code file changes bundled with the nearest matching increment

- `tests/profiles/qnap-example.env` gains, with a comment referencing this
  file and the user decision above:
  ```sh
  # QNAP guest sizing (Phase 4 user decision, 2026-09-27): 8 GB / 4 CPU,
  # smaller than Apple's 12G default -- see docs/refactor/arch-neutral-guest.md.
  export DX_CONTAINER_MEMORY=8G
  export DX_CONTAINER_CPUS=4
  ```
  `tests/test_refactor_state_machines.sh`'s existing
  "`tests/profiles/qnap-example.env` resolves a valid docker-ssh
  configuration" assertion (around its line 195) gains
  `[ "$DX_CONTAINER_MEMORY" = 8G ] && [ "$DX_CONTAINER_CPUS" = 4 ]` to the
  existing conjunction, red before the profile change, green after. Bundled
  into Increment 1 (first increment touching this branch's config surface)
  rather than its own increment, since it is a small, self-contained data
  change with its own tight red/green pair.

## 9. Not in this phase (design point F)

- **The context-directory rename** (DQ7: "The existing
  architecture/runtime-encoded context directory can be renamed only in a
  standalone mechanical commit... do not mix the move with runtime behavior
  changes"). This phase leaves the architecture-encoded context directory
  named exactly as it was, even though its name would read oddly once it
  also holds native x86_64-linux outputs. Increment 6 records in
  `qnap-dxe-plan.md` that this rename is still pending and, for the record,
  what it would touch: every `DX_CONTEXT_DIR`/`DX_BOOTSTRAP_SOURCE` default
  in `bin/lib/dx-config.sh`, every hardcoded path reference across `bin/`,
  `tests/`, and `docs/`, and the directory move itself -- a wide, purely
  mechanical diff that must not be entangled with anything this phase
  changes. **Landed in WP9.4 (Muse B5):** renamed to
  `container/dx-nixos-26.05/`, with a git-tracked compatibility symlink
  left at the old path for one release (`docs/release-maintenance.md`).
- Remote-aware SSH/publish (Phase 5's job entirely).
- Any change to Apple behavior beyond the one new env token in section 4.1.
- Any live build anywhere (subagent constraint; the native x86_64 build only
  ever happens inside the coordinating session's disposable QNAP guest,
  section 7).

## 10. Tests proving `aarch64-linux` behavior is unchanged

- `tests/test_section5_nix.sh`: every existing `aarch64-linux` assertion
  keeps passing unmodified, now alongside the same assertions for
  `x86_64-linux`; the `homeConfigurations.dx` == `homeConfigurations."dx-aarch64-linux"`
  alias check (section 2).
- `tests/test_runtime_boundary_characterisation.sh`: the full pinned Apple
  `container create` argv, byte for byte, updated by exactly the one new
  `-e DX_GUEST_SYSTEM=aarch64-linux` line (section 4.1) -- everything else
  in that comparison stays byte-identical, which is the proof this phase
  changed nothing else observable for `DX_RUNTIME=apple`.
- `tests/test_section3_bootstrap.sh`: the guest-system-helper agree/disagree/
  unsupported cases (section 4), where "agree" specifically covers Apple's
  real-world case (`DX_GUEST_SYSTEM=aarch64-linux` or unset, native
  `uname -m` reporting `aarch64`).
- `tests/test_section17_dx_ai_runtime.sh`: every existing case re-expressed
  against the keyed pin shape (section 3.5) continues to pass for the
  `aarch64-linux` entries; the manifest URL Apple's guest resolves is still
  the `linux_arm64.json` one it uses today.
- `tests/test_docker_runtime_adapter.sh` (Section 33): unaffected by this
  phase for `DX_RUNTIME=apple` (no labels on Apple); its docker-ssh label
  and container-list-format assertions are new coverage, not changed
  coverage, so nothing here is a regression risk for Apple.
- `tests/test_refactor_contracts.sh`: the `bootstrapEssentials`
  binary-to-package contract keeps parsing the same `aarch64-linux`-relevant
  list; the new per-system availability check (section 5) is additive.
- `/bin/bash tests/run-bash32-tests.sh` and both ShellCheck tiers (pinned
  0.10.0 in the `nixos/nix:2.34.8` container, apt 0.9.0 in a throwaway
  `ubuntu:24.04` container) re-run at the end of every increment, per the
  brief -- the new guest-side helper and the two-line `dx-create-container`/
  label-flags changes are the only new shell surface, and none of it touches
  `bin/lib/*.sh`'s Bash-3.2-only contract beyond the one new env-token line.
- Ratchet (`tests/coverage/ratchet.env`) re-measured on a clean export after
  every increment that adds a sourceable module (the new
  `scripts/lib/dx-guest-system.sh` and `scripts/dx-verify-inventory`); ratchet
  moves only if the measured value actually changes, per the brief.

## Open items for the coordinating session (not decisions made here)

None block starting Increment 1. Two things worth flagging on review, not
stop conditions:

1. Section 3.5's fixture-shape migration touches roughly a dozen call sites
   in one test file; it is mechanical but not small, and is called out here
   so it is not mistaken for scope creep when Increment 2 lands.
2. The amd64 Antigravity artifact exists today (section 3.2), so this
   phase's live exit gate will exercise the "real pin, both architectures"
   path, not the "`null`, print the diagnostic" path. The `null` path is
   still built and unit-tested (it is DQ7's actual requirement, and the
   only guard against a future upstream removal), but nothing on the real
   NAS will currently observe it -- confirming that behavior end to end
   would need a synthetic `null` entry in a disposable profile's pin
   override, which is out of scope unless the coordinating session wants it
   added to the exit gate.

No code changes (Increment 0 is a design note only, per the task).
