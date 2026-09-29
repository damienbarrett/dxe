# Agent design notes saved at the 2026-09-30 host shutdown

Two subagents finished their research but wrote no code before the host was
shut down. Their designs are recorded here verbatim in substance so the next
session implements rather than re-derives. Plan: `findings.md` WP5.1 and the
bootstrap coverage item under WP1.5/WP3.2.

## Bootstrap storage coverage cases (base-and-storage.sh 347-349, 656-662, 675-679, 914-916, 948-957, 974-980)

Critical finding, verified empirically on Bash 3.2: when a compound command or
subshell is the left side of `|| true` or the condition of `if`, errexit is
suspended for its entire nested execution. A stub returning non-zero inside
such a wrapper does not stop the rest of the function; only an explicit
`return N` in production source (e.g. `nix_verify_no_bootstrap_path_collision
… || return 1` at line 661) or a `${VAR:?}` failure stops it. Consequence: any
safe (wrapped) call of `populate_prepared_nix_volume` runs to the `/etc/fstab`
append tail (671-681) regardless of stubs, unless the branch under test ends
in an explicit return.

Hazard: the kcov image runs `test_section3_bootstrap.sh` as root, so a case
reaching the bare `>> /etc/fstab` append would mutate the container's
`/etc/fstab` (on the dev Mac it fails with permission denied). Mitigation for
cases that do not target the fstab block: shadow `grep` so the presence check
at line 674 reports "already present":

```
grep() { if [ "$*" = "-q /nix $DX_NIX_VOLUME_FS_TYPE /etc/fstab" ]; then return 0; fi; command grep "$@"; }
```

with `DX_NIX_VOLUME_FS_TYPE=dxe-cov-probe` (never present in a real fstab).

Cases (insert as a P13 block after P12, ~line 1953; subshell-isolated, no
`unset -f`, matching the file):

- (a) successful sparse-image prepare via `prepare_nix_volume`: `DX_NIX_RAW_PATH`
  at a writable temp dir, `DX_NIX_DISK_SIZE=8G`, `grep` making the btrfs probe
  succeed, `findmnt`/`blkid` miss, `mkdir(){ :; }` (`/mnt` is read-only on the
  Mac), recording `truncate`/`mkfs.btrfs`/`mount` (MUST-NOT `mkfs.ext4`),
  `record_durable_nix_identity` recording its argument. Assert phase text,
  exact argvs (`truncate -s 8G <raw>/nix-store.btrfs`; `mkfs.btrfs -f -L dx-nix
  -m single -d single …`; `mount -t btrfs -o compress=zstd:3,noatime,
  space_cache=v2,discard=async … /mnt/tmp-nix`), the five exported
  `DX_NIX_VOLUME_*` values, identity log `/mnt/tmp-nix`. Closes 974-980.
- (b) btrfs unsupported: `grep` returns 1 for the btrfs probe; call
  `prepare_nix_volume_impl`; assert the exact warning, `ext4` type and
  `noatime,errors=remount-ro` opts, `mkfs.ext4 -F -L dx-nix <raw>/nix-store.ext4`,
  MUST-NOT `mkfs.btrfs`. Closes 914-916.
- (c) block device: `is_block_device(){ [ "$1" = /dev/fake-block ]; }`,
  `findmnt` dispatched on argv (`-n -o SOURCE <raw>` prints `/dev/fake-block`).
  (c1) `blkid` misses → "Detected block device backing", "Formatting
  /dev/fake-block with btrfs", `mkfs.btrfs … /dev/fake-block`. (c2) `umount`
  fails → `Error: failed to umount`, the CAP_SYS_ADMIN text, return 1, no mkfs.
  Closes 948-957.
- (d) `populate_prepared_nix_volume` call order, all with the grep shadow:
  (d1) fresh root (no `store/`): recording `nix_image_store_identity`,
  `nix_seed_volume`, `nix_install_image_essentials_root`; MUST-NOT the import
  trio; assert order `IDENTITY`, `SEED /nix <root> 0 0`, `ROOTS <root> 0 0`
  (owner falls back to 0 0 when `id -u dx` fails). (d2) reuse root with
  `store/`: recording `nix_image_store_import_required` (0),
  `nix_verify_no_bootstrap_path_collision` (0), `nix_store_import_registered`;
  MUST-NOT the seed trio; assert order. (d3) reuse with collision returning 1:
  rc 1, MUST-NOT `nix_store_import_registered`/`umount`/`mount`; no grep shadow
  needed (explicit return). Closes 656-662.
- (e) the fstab block: snapshot `/etc/fstab`; branch on `id -u`: non-root
  expects "Adding /nix to /etc/fstab..." plus permission denied and an
  unchanged file; root expects the `LABEL=dx-nix /nix dxe-cov-probe …` line
  (e1, `blkid -L dx-nix` succeeds) or the device line (e2, blkid misses) to be
  present, then restore the snapshot after each sub-case. Use a third volume
  root with `store/`, `nix_image_store_import_required(){ return 1; }`, no grep
  shadow. Closes 675-679. Better long-term: give the fstab path a
  positional-with-production-default parameter (Fable B11) so no test touches
  the real file.
- (f) enumeration failure: `nix_image_registered_paths(){ return 1; }` then
  `! nix_image_store_identity` captured with the `!` idiom already used at
  ~987-990; assert "could not enumerate registered image Nix paths". Closes
  347-349.

## WP5.1 sync→start result file

See the design note under WP5.1 in `findings.md`.
