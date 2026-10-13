#!/bin/bash
# shellcheck disable=SC2034 # every constant here is read by the sourcing suites
# tier: unit
# bash32: yes
# Import-only (functions and constants; no output, no shell-option or trap
# changes, no I/O at import time). Bash 3.2 compatible. Needs
# tests/lib/persist-live.sh sourced first (its guard, confinement and names).
#
# The guard and helpers of the /persist MIGRATION live suite
# (tests/test_persist_migrate_live.sh, plans/do WP7.2; spec section 9 W4,
# R31-R37), kept out of the suite so tests/test_persist_migrate_live_guard.sh
# can unit-test every refusal, every pinned argv and every script without a
# NAS.
#
# Contract (pinned by tests/test_persist_migrate_live_guard.sh):
#
# persist_migrate_live_guard
#   persist_live_guard (every WP7.1 rule, on the profile as installed: it is a
#   host-path canary profile; the suite itself switches DX_PERSIST_STORAGE and
#   DX_PERSIST_VOLUME per phase), plus one `Refusing: ...` line on stderr for
#   each of these it breaks, status 1; silent status 0 when all hold. No
#   command, remote or file-system call.
#     - DX_PERSIST_HOST_ROOT holds no "," (the suite's own --mount options);
#     - the rollback volume (persist_migrate_live_rollback_volume) is a canary
#       volume name (contains "canary", only [a-z0-9-], starts dx-) and is none
#       of DX_NIX_VOLUME, DX_PERSIST_VOLUME, DX_BOOTSTRAP_VOLUME;
#     - DXE_PERSIST_LIVE_BULK_MIB is empty or a whole number 64..16384;
#     - DXE_PERSIST_LIVE_MIN_FREE_INODES is empty or a whole number
#       700000..99999999 (no leading zero), and
#       DXE_PERSIST_LIVE_INODE_STOP_FLOOR is empty or a whole number
#       100000..500000: the production guest's volumes share the NAS's Docker
#       data root, whose inode count is fixed;
#     - when both are valid, the preflight minimum leaves at least 600000
#       inodes (PERSIST_MIGRATE_LIVE_BRINGUP_INODES, what a canary bring-up
#       takes: about 550,000-600,000 measured) above the stop floor, so a
#       run that starts is not expected to be stopped by its own watcher
#       (with the defaults: 800000 - 150000 = 650000);
#     - DXE_PERSIST_LIVE_INVENTORY_REAL is empty or exactly dx-qnap, and is
#       never combined with DXE_PERSIST_LIVE_CLEANUP_ONLY=1.
#
# persist_migrate_live_rollback_volume
#   DXE_PERSIST_LIVE_ROLLBACK_VOLUME, or <DX_PERSIST_VOLUME>-rollback.
# persist_migrate_live_bulk_mib
#   DXE_PERSIST_LIVE_BULK_MIB, or 2048 (the guard validates it).
# persist_migrate_live_min_free_inodes
#   DXE_PERSIST_LIVE_MIN_FREE_INODES, or 800000 (the guard validates it).
# persist_migrate_live_inode_stop_floor
#   DXE_PERSIST_LIVE_INODE_STOP_FLOOR, or 150000 (the guard validates it).
#
# Inode preflight (WP7.2b; run 1 on 2026-10-12 stopped when the NAS's Docker
# data root, an ext4 filesystem with a fixed inode count that the production
# guest shares, ran out of inodes with 61 GB of blocks free):
# persist_migrate_live_docker_root
#   Exactly one call, read-only:
#     dxe_runtime_call dx_runtime_docker_cli info --format {{.DockerRootDir}}
#   Prints the answer's last non-empty line (CR dropped) when it is a
#   normalised absolute path other than / (persist_live_root_ok); otherwise
#   one `Refusing:` line and status 1. A failed call returns its status.
# persist_migrate_live_inodes ROOT
#   Refuses (status 2, one `Refusing:` line, no call) unless ROOT passes
#   persist_live_root_ok. Otherwise one call, read-only:
#     dxe_runtime_call dx_runtime_docker_ssh_exec df -P -i ROOT
#   and, only when that call fails (a df without -P), one more:
#     dxe_runtime_call dx_runtime_docker_ssh_exec df -i ROOT
#   and prints `<total> <used> <free>` from the answer
#   (persist_migrate_live_df_inodes); status 1 when the calls fail or the
#   answer does not parse.
# persist_migrate_live_df_inodes  (stdin: `df -P -i` output)
#   `<total> <used> <free>` from the one data line (GNU and busybox: fields 2,
#   3 and 4, all whole numbers, total above 0); status 1 for no data line,
#   more than one, or a field that is not a number.
#
# The bring-up's inode watcher (WP7.2c; Fable's review of WP7.2b: a canary
# bring-up takes about 550,000-600,000 inodes of the filesystem the production
# guest shares, and run 1 ran it down to 43 free):
# persist_migrate_live_inode_watch DOCKER_BIN ROOT FLOOR DEADLINE
#   Refuses (status 2, one `Refusing:` line, no call) unless DOCKER_BIN is an
#   absolute path without blanks, DX_CONTAINER_NAME is a canary name
#   (persist_live_name_is_canary), ROOT passes persist_live_root_ok, FLOOR is
#   a whole number 100000..500000 and DEADLINE a whole number of seconds
#   20..86400 (no leading zeros). Otherwise exactly one call, the NAS shell
#   running PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INODE_WATCH:
#     dxe_runtime_call dx_runtime_docker_ssh_exec sh -c SCRIPT dxe-live-inode-watch
#       DOCKER_BIN DX_CONTAINER_NAME ROOT FLOOR DEADLINE
# persist_migrate_live_inode_watch_start DOCKER_BIN ROOT FLOOR DEADLINE OUT ERR [TRIES]
#   Only in the shell that runs the bring-up (refuses, status 2, in a
#   subshell, whose exit would orphan the watcher, and while a watcher of its
#   own still runs). Starts persist_migrate_live_inode_watch in the
#   background as the leader of a process group of its own (set -m for the
#   one launch, so stopping it ends its local ssh client too), stdout to OUT,
#   stderr to ERR, stdin /dev/null; its pid in PERSIST_MIGRATE_LIVE_WATCH_PID.
#   Chains persist_migrate_live_inode_watch_stop in front of the caller's
#   EXIT trap (kept and restored by the stop), so the watcher also ends when
#   the suite is aborted (INT, TERM, HUP; a SIGKILLed suite leaves it to its
#   DEADLINE). Then waits, up to TRIES (default 300) checks 0.2 s apart, for
#   the watcher's first `free=` line: 0 once it is there; 1 when the watcher
#   ends first or never reports (it is stopped then, and nothing else ran).
# persist_migrate_live_inode_watch_stop
#   Ends the watcher started above, if any: when it still runs, SIGKILLs its
#   process group through persist_migrate_live_kill_group (every check of
#   that function applies) and sets PERSIST_MIGRATE_LIVE_WATCH_KILLED=1;
#   then collects its status into PERSIST_MIGRATE_LIVE_WATCH_RC (never waits
#   on a process the kill refused), clears PERSIST_MIGRATE_LIVE_WATCH_PID and
#   restores the caller's EXIT trap. The NAS side then ends at its next
#   heartbeat (its write to the closed session fails), within 20 s.
# persist_migrate_live_inode_watch_verdict OUT RC KILLED
#   One line from the watcher's output file OUT, its status RC and whether
#   the stop killed it (KILLED 1):
#     floor-hit <free> <floor> stopped|not-stopped  (any floor-hit line; the
#       last one's numbers; stopped when a stopped= line follows)
#     watched <polls> <lowest free>   (KILLED 1, at least one free= line)
#     deadline <seconds>              (a deadline= line: it ended at its deadline)
#     blind                           (RC 4: df gave no free-inode count)
#     ended <RC>                      (anything else: it ended on its own)
# persist_migrate_live_bringup_watched LOGDIR DOCKER_BIN ROOT FLOOR DEADLINE FREE0 -- COMMAND [ARG...]
#   The bring-up, watched. Through the caller's lv_run, lv_ok, lv_bad and
#   lv_result (LV_RC, LV_OUT, LV_ERR): starts the watcher (LOGDIR/inode-watch.
#   {out,err}); if it does not report, lv_bad and status 1 with COMMAND never
#   run. Otherwise lv_ok, then `lv_run dx-bring-up -- COMMAND...`, then the
#   stop (whatever COMMAND's status), then the verdict:
#     floor-hit: results inode_floor_hit=free=<n> floor=<f> canary=<stopped|
#       not-stopped>, PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT=<n>, one lv_bad
#       starting `INODE FLOOR HIT:` and status 1;
#     watched: results bringup_inodes_min_free=<n>, one lv_ok, status 0;
#     anything else: results inode_watch=<verdict>; when COMMAND itself exited
#       0, first persist_migrate_live_inodes_after_bringup ROOT FREE0 FLOOR
#       (FREE0: the preflight's free count), so the results still hold the
#       bring-up's cost (its own floor hit ends it there); then lv_bad, status 1.
#   LV_RC, LV_OUT and LV_ERR are COMMAND's on return (after the start).
# persist_migrate_live_inodes_after_bringup ROOT FREE0 FLOOR
#   After a bring-up that passed: `lv_run inodes-after-bring-up --
#   persist_migrate_live_inodes ROOT`. When it answers and FREE0 (the
#   preflight's free count) is a number: results
#   docker_root_inodes_free_after_bringup=<free> and canary_inodes_used=
#   <FREE0 - free>; fewer than FLOOR free is
#   PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT=<free>, results inode_floor_hit=
#   after-bringup free=<free> floor=<FLOOR>, one lv_bad starting `INODE FLOOR
#   HIT after the bring-up:` and status 1 (the run stops before seeding);
#   else one lv_ok, status 0. No answer: results canary_inodes_used=unknown,
#   status 0 (the watcher saw the whole bring-up above the floor).
#
# persist_migrate_live_dir_read SCRIPT [ARG...]
#   Read-only twin of persist_live_root_sh for bash scripts: refuses (status 2,
#   one `Refusing:` line, no call) unless persist_live_share_path_ok accepts
#   the canary directory and the root holds no ","; otherwise exactly one call:
#     dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0
#       --pull never --label dxe.role=persist-live
#       --mount type=bind,source=<canary dir>,target=/canary,readonly
#       --entrypoint bash <DX_IMAGE> -c SCRIPT bash /canary [ARG...]
#
# persist_migrate_live_volume_read VOLUME SCRIPT [ARG...]
#   Refuses (status 2, one `Refusing:` line, no call) unless VOLUME contains
#   "canary", is a plain volume name, equals DX_PERSIST_VOLUME (so its DQ6 role
#   is persist) and is neither DX_NIX_VOLUME nor DX_BOOTSTRAP_VOLUME, and
#   DX_IMAGE contains "canary". Then the DQ6 check, and only if it passes the
#   read, each exactly one call:
#     dxe_runtime_call dx_runtime_volume_owned VOLUME "read (live suite)"
#     dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0
#       --pull never --label dxe.role=persist-live -v VOLUME:/v:ro
#       --entrypoint bash <DX_IMAGE> -c SCRIPT bash /v [ARG...]
#   A failed ownership check (an absent volume included: docker run -v would
#   create it) returns its status with no run.
#
# persist_migrate_live_interrupt DOCKER_BIN CANON_LEAF DEADLINE FULL_BYTES
#   Refuses (status 2, one `Refusing:` line, no call) unless DOCKER_BIN is an
#   absolute path without spaces, DX_IMAGE and DX_PERSIST_VOLUME contain
#   "canary", CANON_LEAF is a normalised absolute path without "," that ends in
#   /dxe/<DX_CONTAINER_NAME>/persist with a canary name, DEADLINE is a
#   whole number 10..3600 and FULL_BYTES (the bulk file's full size) a whole
#   number above 0. Otherwise exactly one call, the NAS shell running
#   PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT:
#     dxe_runtime_call dx_runtime_docker_ssh_exec sh -c SCRIPT dxe-live-interrupt
#       DOCKER_BIN dxe-persist-copy-<DX_REMOTE_HOST>__<DX_CONTAINER_NAME>
#       DX_PERSIST_VOLUME CANON_LEAF dxe-live-bulk dxe-live-blob.bin DEADLINE
#       FULL_BYTES
#   (the copy container's name is WP6.4c's: dxe-persist-copy-<DQ6 profile id>,
#   from persist_migrate_live_copy_name; DX_REMOTE_HOST must be [A-Za-z0-9_.-]).
#
# persist_migrate_live_partial_record RECORD FULL_BYTES
#   0 only when RECORD (one LIST record) is a regular file (type f) whose size
#   is a whole number below FULL_BYTES: the bulk file stopped part-way under
#   its own name (rsync --inplace).
# persist_migrate_live_temp_count FILE
#   How many records of the LIST output FILE are rsync temp files of the bulk
#   file: regular files (type f) whose PATH is exactly
#   ./.dxe-live-blob.bin.XXXXXX (six characters).
#
# The controller-drop case (WP7.2b; the constitution's rule that a stub
# standing in for a trust boundary is validated once against the real one:
# WP6.4c's refusal while a copy container of an earlier run is on the NAS,
# and its `docker run --name/--label`).
# persist_migrate_live_copy_name copy|verify
#   dxe-persist-<copy|verify>-<DX_REMOTE_HOST>__<DX_CONTAINER_NAME> (WP6.4c's
#   names, the DQ6 profile id); refuses (status 2, one `Refusing:` line)
#   another role, a DX_REMOTE_HOST outside [A-Za-z0-9_.-] or empty, and a
#   container name that is not a canary name.
# persist_migrate_live_copy_watch DOCKER_BIN running|gone DEADLINE
#   Read-only. Refuses (status 2, one `Refusing:` line, no call) unless
#   DOCKER_BIN is an absolute path without blanks, the mode is running or
#   gone, DEADLINE is 0 or a whole number up to 3600 (no leading zero), and
#   both container names form. Otherwise exactly one call, the NAS shell
#   running PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH:
#     dxe_runtime_call dx_runtime_docker_ssh_exec sh -c SCRIPT dxe-live-copy-watch
#       DOCKER_BIN MODE <copy name> <verify name> DEADLINE
# persist_migrate_live_labels_ok LABELS PROFILE_ID ROLE
#   0 only when LABELS (k=v;k=v;... as the COPY_WATCH script prints them)
#   holds io.dxe.managed=true, io.dxe.profile=PROFILE_ID and io.dxe.role=ROLE
#   as whole entries.
# persist_migrate_live_mount_ok MOUNTS DESTINATION SOURCE
#   0 only when MOUNTS (dest=source;... as COPY_WATCH prints them) holds the
#   whole entry DESTINATION=SOURCE.
# persist_migrate_live_lock_owner_is FILE PID
#   0 only when FILE (dx-lock's output) holds a `held by <host>:PID:...` line:
#   the lock's owner token (host:pid:random:UTC, bin/lib/dx-runtime-docker-lock.sh)
#   names exactly PID.
# persist_migrate_live_own_group COMMAND [ARG...]
#   Only inside a subshell or background job (refuses, status 2, at the top
#   level, where it would replace the caller): execs COMMAND through perl as
#   the leader of a new process group, so its PID is its process group id.
# persist_migrate_live_kill_group PID
#   Sends SIGKILL to the process group PID (`kill -KILL -- -PID`) only when PID
#   is a whole number above 1, is not this shell ($$), leads its own process
#   group (ps -o pgid=) and that group is not this shell's, and PID is a
#   direct child of this shell (ps -o ppid= is $$: the job lv_run_bg or the
#   watcher start forked, which own_group's exec chain keeps -- never a
#   reused pid that happens to lead a group); otherwise one `Refusing:` line,
#   status 2, nothing sent.
# persist_migrate_live_group_gone PID [TRIES]
#   0 once no process of group PID is left (kill -0 -- -PID fails), checking
#   up to TRIES times (default 25) 0.2 s apart; 1 otherwise.
# persist_migrate_live_drop_classify RC ERR_FILE COPY_NAME VERIFY_NAME
#   The rerun's outcome, on stdout: `completed` (RC 0); `refused-running
#   <name>` (RC 1, exactly one Error line, WP6.4c's running refusal for the
#   copy or verify container, word for word up to the end); `refused-left
#   paused` and `refused-left removing` (RC 1, one Error line, WP6.7's own
#   refusals for a paused container and one Docker is removing, word for word
#   up to the end, for either name); `refused-left <state>` (RC 1, one Error
#   line, WP6.4c's refusal for a container left in any other state, word
#   for word up to the end, its docker inspect/logs/rm hint included);
#   `copy-conflict` (RC 1, one Error line: the copy stopped with rsync exit
#   125, Docker's name conflict); else `unexpected`. A refused-left outcome
#   is the drop case's `missed` (a FINDING: the rerun did not meet the copy
#   running).
# persist_migrate_live_drop_bulk_hint BULK_MIB COPY_SECONDS
#   The DXE_PERSIST_LIVE_BULK_MIB that makes a full copy last about 60 s at
#   the measured rate, rounded up to a multiple of 1024, at most 16384.
# persist_migrate_live_controller_drop DOCKER_BIN MIGRATE LOCK CANON_LEAF DEADLINE
#   The case's orchestration. MIGRATE and LOCK are dx-persist-migrate and
#   dx-lock. It runs through the CALLER's step helpers (the live suite's, or
#   the guard suite's stand-ins): lv_run, lv_run_bg, lv_bg_wait, lv_check,
#   lv_ok, lv_bad, lv_finding, lv_show_logs, lv_rc_zero, lv_rc_is,
#   lv_out_line, with LV_RC, LV_OUT, LV_ERR and LV_BG_PID. In order:
#     1. lv_run_bg: MIGRATE in its own process group (persist_migrate_live_own_group);
#     2. copy_watch running, in slices of PERSIST_MIGRATE_LIVE_DROP_WATCH_SLICE
#        (20) seconds that add up to DEADLINE (the last one shorter): one
#        running container with the copy container's name. Between slices,
#        a controller that has already ended (kill -0 of the background pid
#        fails: it refused or failed early) is collected (lv_bg_wait) and is
#        a FAIL at once, instead of waiting out the whole DEADLINE. Checks: it
#        was seen within DEADLINE, its labels (role persist-copy, this
#        profile id, managed) and its /dst bind on CANON_LEAF;
#     3. kill_group on the background PID; lv_bg_wait: status 137; the group
#        is gone (group_gone): the controller and its ssh clients are dead,
#        no EXIT trap ran, so its lock is left behind;
#     4. LOCK status: exit 0, its audit names the dropped controller's PID
#        (lock_owner_is) -- only then LOCK unlock --force: exit 0,
#        `Lock released.` (a lock held by anyone else is never forced);
#     5. MIGRATE again (foreground), at once: drop_classify decides --
#          refused-running: PASS; then copy_watch running 0 (one look): the
#            same container still running is a PASS (untouched), a container
#            that has just ended is only noted;
#          refused-left, copy-conflict, completed: a FINDING (the copy ended
#            before the rerun's check: the refusal was not met running);
#          unexpected: FAIL (status 1);
#     6. copy_watch gone DEADLINE: no copy or verify container is left.
#   Any failed check returns 1 at once (step 1's process is then still in
#   LV_BG_PID if step 3 was not reached). Sets PERSIST_MIGRATE_LIVE_DROP_OUTCOME
#   (refused | missed | completed), _ID (the copy container's id), _OUT and _ERR
#   (the rerun's output files), _WINDOW (whole seconds from the kill to the
#   rerun's end), _GONE_AFTER (whole seconds from the kill until step 6 saw
#   the copy gone: the orphan's longest possible life), _PID (the dropped
#   controller's), _ORPHAN (1 from the kill until the copy container is seen
#   gone) and _LOCK_LEFT (1 from the kill until the unlock is confirmed).
# persist_migrate_live_drop_directory LISTINGS SEED_REF BULK_REF
#   After the drop: is the directory the orphaned copy filled complete? Lists
#   persist/<seed> and persist/<bulk> of the canary directory read-only
#   (lv_run list-dir2-orphan-seed|bulk -- persist_migrate_live_dir_read LIST)
#   into LISTINGS/dir2-orphan-seed and -bulk, and compares their records with
#   the listings SEED_REF and BULK_REF. Complete (both listed whole and
#   equal): two lv_ok, PERSIST_MIGRATE_LIVE_DROP_DIRECTORY=complete, status 0.
#   Otherwise PERSIST_MIGRATE_LIVE_DROP_DIRECTORY=incomplete and, when
#   PERSIST_MIGRATE_LIVE_DROP_OUTCOME is missed (the copy was not met
#   running: it may have ended before it finished), one lv_finding "the
#   orphaned copy ended within <_GONE_AFTER> s of the drop, before it
#   finished: ..." and status 0 -- the next migration resumes the directory;
#   for any other outcome one lv_bad and status 1. Uses the caller's lv_run,
#   lv_ok, lv_bad and lv_finding.
#
# The left copy container, planted (WP7.2g; run 3: the NAS copies the
# largest allowed seed in about 22 s, so the controller drop cannot race a
# copy there). A deterministic check of WP6.4c's refusals:
# persist_migrate_live_plant_copy
#   Refuses (status 2, one `Refusing:` line, no call) unless
#   persist_migrate_live_copy_name copy forms (a canary DX_CONTAINER_NAME, a
#   DX_REMOTE_HOST of [A-Za-z0-9_.-]) and DX_IMAGE contains "canary".
#   Otherwise exactly one call:
#     dxe_runtime_call dx_runtime_run_ephemeral -d --name <copy name> --network none
#       --pull never --label dxe.role=persist-live --label dxe.live=planted-copy
#       --entrypoint sleep <DX_IMAGE> 600
#   (detached, no --rm, no mount: it only holds the product's name).
# persist_migrate_live_planted_owned
#   0 only when `dxe_runtime_call dx_runtime_docker_cli inspect --format
#   {{index .Config.Labels "dxe.live"}} <copy name>` answers planted-copy.
# persist_migrate_live_planted_stop, persist_migrate_live_planted_rm [-f]
#   The same name refusal (status 2, no call); then planted_owned (not the
#   suite's own: one `Refusing:` line, status 2, nothing stopped or removed);
#   then exactly one call: dx_runtime_docker_cli stop -t 1 <copy name>, or
#   dx_runtime_docker_cli rm [-f] <copy name>.
# persist_migrate_live_left_container DOCKER_BIN MIGRATE LOCK
#   Through the caller's lv_run, lv_check, lv_result, lv_rc_zero, lv_out_line,
#   lv_show_logs, lv_state and lv_state_unchanged, in order:
#     0. copy_watch gone 0: no copy or verify container of the canary yet
#        (else a FAIL, and nothing is planted, stopped or removed); lv_state;
#     1. plant_copy; copy_watch running 0 (it runs);
#     2. MIGRATE: drop_classify must say refused-running <copy name>; the
#        state unchanged; `LOCK status` says `not held`; copy_watch running 0
#        (still running); results left_container_running=refused;
#     3. planted_stop; MIGRATE: refused-left exited (the whole line word for
#        word); unchanged; `not held`; results left_container_exited=refused;
#     4. planted_rm; copy_watch gone 0.
#   PERSIST_MIGRATE_LIVE_PLANTED is 1 from the plant until the container is
#   seen gone; _PLANTED_DOCKER is DOCKER_BIN. Every failure after the plant
#   runs persist_migrate_live_planted_cleanup (planted_rm -f, or the name
#   seen gone, clears _PLANTED) and returns 1.
# persist_migrate_live_planted_hint
#   While _PLANTED is set: three lines naming the container and the exact
#   `ssh <DX_REMOTE_HOST> "<docker> rm -f <copy name>"` (lv_stop prints them).
#
# The canary's cleanup (WP7.2d; Fable's re-check of WP7.2c: the cleanup after
# a floor hit during the image build must not build the image first):
# persist_migrate_live_cleanup normal|emergency BIN_DIR ORIG ROLLBACK DEADLINE STAMP
#   Through the caller's lv_run, lv_check, lv_rc_zero and lv_bg_wait, in
#   host-path mode (it exports DX_PERSIST_STORAGE=host-path and
#   DX_PERSIST_VOLUME=ORIG, so dx-factory-reset keeps every persist volume):
#     normal only: lv_bg_wait; the docker CLI path (dx_runtime_docker_require_bin;
#       PERSIST_MIGRATE_LIVE_CLEANUP_DOCKER_BIN); copy_watch gone DEADLINE;
#     BIN_DIR/dx-stop-container when the canary runs;
#     the plain-ssh probe (dx_runtime_host_dir_probe): it must answer. State
#       absent: no image call and no share call at all ("nothing to move
#       aside"). Any other state: in emergency mode nothing either (it says so;
#       PERSIST_MIGRATE_LIVE_CLEANUP_LEAF_LEFT=<state>); in normal mode
#       BIN_DIR/dx-create-image only when dx_runtime_image_exists fails, then
#       persist_live_root_sh rw PERSIST_LIVE_SCRIPT_RETIRE STAMP
#       (PERSIST_MIGRATE_LIVE_CLEANUP_RETIRED=1) and the probe again: absent;
#     BIN_DIR/dx-factory-reset --force; each of ORIG and ROLLBACK that is
#       present deleted through persist_migrate_live_volume_delete; rm -f of
#       the D-7 record (persist_live_record_path); then no canary container,
#       image or volume (nix, ORIG, bootstrap, ROLLBACK) is left.
#   Any failed check returns 1 at once.
# persist_migrate_live_volume_delete VOLUME
#   Refuses (status 2, one `Refusing:` line, no call) a name that is not a
#   canary volume name, or is DX_NIX_VOLUME or DX_BOOTSTRAP_VOLUME; otherwise
#   exactly one call, with DX_PERSIST_VOLUME=VOLUME (so DQ6 checks role
#   persist): dxe_runtime_call dx_runtime_volume_delete VOLUME.
# persist_migrate_live_volume_state VOLUME, persist_migrate_live_container_absent,
# persist_migrate_live_image_absent: read-only facts (dx_runtime_volume_state,
#   dx_runtime_container_list -a, dx_runtime_image_list).
# persist_migrate_live_auto_cleanup_due
#   0 only when PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT is set and neither
#   DXE_PERSIST_LIVE_NO_AUTO_CLEANUP=1 nor DXE_PERSIST_LIVE_KEEP_RUNNING=1.
# persist_migrate_live_emergency_cleanup BIN_DIR LOGDIR ORIG ROLLBACK ROOT PROFILE [TRIES PAUSE]
#   After an INODE FLOOR HIT (the caller has stopped the canary): the canary's
#   docker logs (dx_runtime_logs) into LOGDIR/canary-docker.log; one
#   persist_migrate_live_inodes ROOT (results inodes_free_at_floor_hit); then
#   `BIN_DIR/dx-lock status` up to TRIES (default 12) times, PAUSE (default 5)
#   seconds apart, until it exits 0 with the line `not held`. Still held (or
#   unreadable) at the bound: results emergency_cleanup=skipped..., the
#   dx-lock status and unlock lines for PROFILE printed, one lv_bad, status 1,
#   and nothing destructive ran -- the lock is never forced here. Otherwise
#   persist_migrate_live_cleanup emergency (results emergency_cleanup=done, or
#   failed (status N)), then persist_migrate_live_inodes ROOT again (results
#   inodes_free_after_emergency_cleanup); its status is the cleanup's.
#
# persist_migrate_live_real_inventory PROFILE ROOT COMMAND
#   The opt-in read-only inventory of the production guest. Resolves PROFILE's
#   file like bin/dx-profile (DX_PROFILES_DIR, else ~/.config/dxe/profiles,
#   then tests/profiles), parses it with the repository's own parser, and
#   refuses (status 2, one `Refusing:` line, nothing run) unless it resolves
#   and parses, names DX_CONTAINER_NAME=dx-qnap (and DXE_PERSIST_LIVE_INVENTORY_REAL
#   says dx-qnap), DX_RUNTIME=docker-ssh and a DX_PERSIST_VOLUME, COMMAND's
#   file name is dx-persist-inventory and XDG_STATE_HOME is set. Then it execs
#   COMMAND under `env -i` with HOME, PATH, XDG_STATE_HOME, TMPDIR (and
#   SSH_AUTH_SOCK when set), every field the profile sets EXCEPT
#   DX_PROFILE_ROOT (the production profile pins the main checkout, which has
#   no dx-persist-inventory), and DX_PERSIST_HOST_ROOT=ROOT when the profile
#   sets none. Nothing of the canary's configuration reaches it.
#
# Scripts. Container and NAS-shell scripts are ONE line with no single quote
# (as tests/lib/persist-live.sh's); guest scripts run in the guest's bash 5
# through dx-ssh and may span lines (still no single quote).
#   PERSIST_MIGRATE_LIVE_SCRIPT_LIST (bash; $1 base, $2 a relative subtree
#     without ".."): a manifest-like listing, one TAB-separated record per
#     entry in bytewise path order, then `end<TAB><count>`:
#       TYPE MODE OWNER SIZE MTIME NLINK CKSUM GROUP TARGET PATH
#     TYPE f d l p s b c; MODE as stat prints it, but "-" for a symlink
#     (WP6.1b: Linux cannot set a symlink's mode and filesystems disagree on
#     it -- 777 on the ext4 volume, 755 on the NAS's ZFS share -- so neither
#     the manifest nor this listing compares it); OWNER numeric, as stat
#     prints it;
#     SIZE for f and l, else -; MTIME whole seconds; NLINK for non-directories,
#     else -; CKSUM the POSIX cksum CRC for f, else -; GROUP for a
#     non-directory sharing its inode with an earlier entry of the listing, the
#     first such path, for any other multiply linked non-directory its own
#     path, else -; TARGET a symlink's target, else -; PATH "." or "./...".
#     GROUP, TARGET and PATH escape "\" as "\\", TAB as "\t", newline as
#     "\n". Uses only bash, find, sort, stat, cksum and readlink (the bare
#     image has them all; GNU or BSD stat). Any failure: non-zero status.
#   PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE (sh, through persist_live_root_sh
#     rw; $2 guest, $3 a UTC stamp): the runbook's "move the retired directory
#     aside": mv persist persist.retired-$3, only when persist is a real
#     directory whose regular marker has exactly one guest=$2 line, no other
#     guest= line, exactly one state=retired line and no other state= line,
#     and the target is free. Deletes nothing.
#   PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT (sh in the NAS shell; see
#     persist_migrate_live_interrupt): waits (sleep 1 between docker ps calls,
#     DEADLINE seconds in all) for exactly one RUNNING container named $2
#     (WP6.4c's dxe-persist-copy-<profile id>, a canary name) that mounts the
#     volume $3, runs the guest-volume rsync with
#     "-aH --numeric-ids ... /src/ /dst/" and binds $4 at /dst; a copy whose
#     argv lacks --inplace is status 8 with nothing killed (WP6.4c is not in
#     effect, and the trigger below would never fire). Then it waits
#     for the blob itself, $4/$5/$6, to be a regular file (not a symlink)
#     holding more than 0 and fewer than $8 (its full size) bytes: the copy
#     runs rsync --inplace (WP6.4c), so the blob grows under its final name
#     and there is no temp file. It polls every 0.05 s and checks the
#     container every 20 polls when the NAS's sleep takes fractions, else
#     every second (never a busy loop against the Docker daemon), and sends
#     that one container `docker kill` (SIGKILL) at once, then waits until
#     --rm has removed it. The size comes from `ls -ln` (POSIX). Prints
#     copy=<id12>, interrupted=<id12> bytes=<size seen>, gone=<id12>. Status:
#     0 done; 1 bad arguments; 2 no copy container before the deadline; 3 the
#     copy container ended before the blob was seen part-way; 4 a docker call
#     failed; 5 the killed container did not go away; 6 more than one
#     container matched (none is touched); 7 this account cannot list $4/$5
#     (nothing is killed); 8 the copy runs without --inplace (nothing is
#     killed). `set -f` throughout: no word is ever globbed.
#   PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH (sh in the NAS shell; see
#     persist_migrate_live_copy_watch; read-only: docker ps and docker inspect
#     only, never kill, stop or rm). $1 docker CLI, $2 mode, $3 the copy
#     container's name (dxe-persist-copy-?*), $4 the verify container's
#     (dxe-persist-verify-?*), $5 the deadline in seconds (0: look once).
#     running: polls `ps -q --no-trunc --filter name=^/$3$ --filter
#       status=running` once a second until exactly one container answers,
#       then prints copy=<full id>, labels=<k=v;...> and mounts=<dest=source;...>
#       from one docker inspect; status 2 none before the deadline, 4 a docker
#       call failed, 6 more than one answered.
#     gone: polls `ps -a -q --no-trunc --filter name=^/$3$` and the same for
#       $4 once a second until neither answers, then prints `gone=$3 $4`;
#       status 2 one is still there at the deadline, 4 a docker call failed.
#     Status 1 for bad arguments, before any docker call. `set -f` throughout.
#   PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INODE_WATCH (sh in the NAS shell; see
#     persist_migrate_live_inode_watch). $1 docker CLI (absolute), $2 the
#     canary container's name (dx-...canary..., only [a-z0-9-]), $3 the
#     Docker data root (absolute, not /), $4 the floor (a whole number above
#     0), $5 the deadline in seconds. Polls at once and then every 20 s
#     (sleep 20): `set -- $(df -P -i ROOT | tail -n 1)` (a plain `df -i` when
#     -P fails), takes IFree (field 4) and prints the heartbeat free=<n>
#     FIRST -- when that write fails (the ssh session is gone) it exits 0,
#     touching nothing. When n < FLOOR it prints floor-hit free=<n>
#     floor=<FLOOR> and runs exactly `docker stop -t 10 <name>`: stopped=<name>
#     and status 3; when that stop fails (the container may not exist yet,
#     e.g. while the image builds) stop-failed=<name> and it keeps polling,
#     trying again at each poll still below the floor. Status 2 (and
#     deadline=<s>) once the deadline has passed; 4 when df gives no
#     free-inode count (nothing stopped); 1 for bad arguments, before any df
#     or docker call. `set -f` throughout; docker stop is its only docker
#     call.
# persist_migrate_live_listing_ok FILE
#   0 only when FILE (a LIST output) ends with `end<TAB>N` and holds exactly N
#   records before it, N > 0: a listing cut short is never compared.
# persist_migrate_live_records FILE
#   The records of FILE (every line but the `end` line).
# persist_migrate_live_records_without_apple FILE
#   The records whose PATH has no component starting with "._" (what rsync's
#   --exclude='._*' and the manifest drop, at any depth).
#
#   PERSIST_MIGRATE_LIVE_GUEST_SEED (bash; $1 /persist, $2 token, $3 MiB):
#     the seeded tree (below) and the bulk blob; prints
#     `seeded=ok socket=yes|no bulk_bytes=<n>`; refuses an existing tree.
#   PERSIST_MIGRATE_LIVE_GUEST_CHANGES (bash; $1 /persist, $2 token): write,
#     overwrite, delete (one file and one hard link), rename (a file and a
#     directory), and a new ._* file; prints `changed=ok`.
#   PERSIST_MIGRATE_LIVE_GUEST_CHECK (bash; $1 /persist, $2 seeded | migrated
#     | changed-dir | changed-volume, $3 token, $4 changes token, $5 socket
#     yes|no, $6 bulk bytes): one `ok <name>` or `bad <name>` line per check,
#     then `checks=<n> bad=<m>`; status 0 only when m is 0.

PERSIST_MIGRATE_LIVE_REAL_GUEST=dx-qnap
PERSIST_MIGRATE_LIVE_REAL_PROFILE=qnap
PERSIST_MIGRATE_LIVE_SEED=dxe-live-seed
PERSIST_MIGRATE_LIVE_BULK=dxe-live-bulk
PERSIST_MIGRATE_LIVE_BLOB=dxe-live-blob.bin
PERSIST_MIGRATE_LIVE_RETIRED_PREFIX=persist.retired-
PERSIST_MIGRATE_LIVE_BULK_MIB_DEFAULT=2048
# Inodes on the NAS's Docker data root (WP7.2b/c). A canary bring-up takes
# about 550,000-600,000 of them (run 1 took 296,444 and was still in its
# first Home Manager build); a production nix rebuild 50,000-150,000.
PERSIST_MIGRATE_LIVE_MIN_FREE_INODES_DEFAULT=800000
PERSIST_MIGRATE_LIVE_MIN_FREE_INODES_FLOOR=700000
PERSIST_MIGRATE_LIVE_BRINGUP_INODES=600000
PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_DEFAULT=150000
PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MIN=100000
PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MAX=500000
# The bring-up watcher's NAS-side lifetime: its bound when the suite is
# SIGKILLed (any other abort ends it through the EXIT trap).
PERSIST_MIGRATE_LIVE_INODE_WATCH_SECONDS=7200
# The controller-drop case looks for the copy container in slices this long,
# so a controller that ended early is noticed within one slice.
PERSIST_MIGRATE_LIVE_DROP_WATCH_SLICE=20
# The left-container check (WP7.2g): the label that marks the container the
# suite plants (it stops and removes nothing without it) and its lifetime.
PERSIST_MIGRATE_LIVE_PLANT_LABEL=dxe.live=planted-copy
PERSIST_MIGRATE_LIVE_PLANT_SECONDS=600
# A full copy of the seed must last at least this long for the controller-drop
# case to meet the copy container still running after the drop, the unlock
# and the rerun's first checks (about a dozen ssh round trips).
PERSIST_MIGRATE_LIVE_DROP_MIN_COPY_SECONDS=30
PERSIST_MIGRATE_LIVE_RSYNC_BIN=/nix/var/nix/profiles/per-user/root/profile/bin/rsync
# The two ._* files the seed drops in, as the inventory and the reports name
# them (paths below the volume or directory root, in sorted order).
PERSIST_MIGRATE_LIVE_SEED_APPLE="dxe-live-seed/._dxe-live-meta dxe-live-seed/nested/deeper/._deep-meta"
PERSIST_MIGRATE_LIVE_CHANGES_APPLE=dxe-live-seed/._rollback-meta

PERSIST_MIGRATE_LIVE_SCRIPT_LIST='export LC_ALL=C; set -o pipefail; '\
'case "$2" in "" | /* | .. | ../* | */.. | */../*) echo "dxe-live-list: bad subtree $2" >&2; exit 2 ;; esac; '\
'cd -P -- "$1" || exit 1; cd -P -- "$2" || exit 1; '\
'nl=$(printf "\nx"); nl=${nl%x}; tb=$(printf "\tx"); tb=${tb%x}; bs=\\; '\
'esc() { local v=${1//"$bs"/"$bs$bs"}; v=${v//"$tb"/"${bs}t"}; E=${v//"$nl"/"${bs}n"}; }; '\
'st() { stat -c "%a %u:%g %s %Y %h %d:%i" -- "$1" 2>/dev/null || stat -f "%Lp %u:%g %z %m %l %d:%i" -- "$1"; }; '\
'find . -print0 | sort -z | { seen=$nl; n=0; while IFS= read -r -d "" p; do '\
'if [ -L "$p" ]; then t=l; elif [ -d "$p" ]; then t=d; elif [ -f "$p" ]; then t=f; elif [ -p "$p" ]; then t=p; elif [ -S "$p" ]; then t=s; elif [ -b "$p" ]; then t=b; elif [ -c "$p" ]; then t=c; else echo "dxe-live-list: unknown type: $p" >&2; exit 1; fi; '\
's=$(st "$p") || exit 1; set -- $s; [ "$#" -eq 6 ] || exit 1; '\
'md=$1; sz=-; lk=-; ck=-; gr=-; tg=-; '\
'case "$t" in f | l) sz=$3 ;; esac; '\
'[ "$t" != l ] || md=-; '\
'[ "$t" = d ] || lk=$5; '\
'if [ "$t" = f ]; then ck=$(cksum < "$p") || exit 1; ck=${ck%% *}; fi; '\
'if [ "$t" = l ]; then tg=$(readlink -- "$p") || exit 1; esc "$tg"; tg=$E; fi; '\
'esc "$p"; '\
'if [ "$t" != d ] && [ "$5" -gt 1 ]; then case "$seen" in *"$nl$6$tb"*) r=${seen#*"$nl$6$tb"}; gr=${r%%"$nl"*} ;; *) seen="$seen$6$tb$E$nl"; gr=$E ;; esac; fi; '\
'printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$t" "$md" "$2" "$sz" "$4" "$lk" "$ck" "$gr" "$tg" "$E"; n=$((n + 1)); '\
'done; printf "end\t%s\n" "$n"; } || exit 1'

PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE="$PERSIST_LIVE_SCRIPT_PRELUDE"\
'case "$3" in "" | *[!0-9TZ]*) echo "dxe-live: bad stamp $3" >&2; exit 2 ;; esac; '\
'if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; '\
'm=persist/.dxe-persist-dir; if [ -L "$m" ] || [ ! -f "$m" ]; then echo "dxe-live: no regular marker in persist" >&2; exit 1; fi; '\
'g=0; s=0; while IFS= read -r l || [ -n "$l" ]; do case "$l" in "guest=$2") g=$((g + 1)) ;; guest=*) g=9 ;; state=retired) s=$((s + 1)) ;; state=*) s=9 ;; esac; done < "$m"; '\
'if [ "$g" -ne 1 ] || [ "$s" -ne 1 ]; then echo "dxe-live: persist is not marked retired for $2; it stays where it is" >&2; exit 1; fi; '\
't="persist.retired-$3"; if [ -e "$t" ] || [ -L "$t" ]; then echo "dxe-live: $t already exists" >&2; exit 1; fi; '\
'mv -- persist "$t"'

# The trigger below is the bulk file itself, part-way: the copy runs rsync
# --inplace (WP6.4c), so it grows under its final name and there is no temp
# file. The copy container is found by its WP6.4c name.
PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT='set -f; d=$1; nm=$2; vol=$3; dst=$4; blob="$4/$5/$6"; full=$8; '\
'rs=/nix/var/nix/profiles/per-user/root/profile/bin/rsync; '\
'case "$1" in /*) : ;; *) echo "dxe-live-interrupt: the docker CLI path must be absolute" >&2; exit 1 ;; esac; '\
'case "$7" in "" | *[!0-9]*) echo "dxe-live-interrupt: bad deadline $7" >&2; exit 1 ;; esac; '\
'case "$8" in "" | *[!0-9]* | 0) echo "dxe-live-interrupt: bad full size $8" >&2; exit 1 ;; esac; '\
'case "$2" in dxe-persist-copy-?*) : ;; *) echo "dxe-live-interrupt: bad copy container name $2" >&2; exit 1 ;; esac; '\
'if [ -z "$3" ] || [ -z "$5" ] || [ -z "$6" ]; then echo "dxe-live-interrupt: missing arguments" >&2; exit 1; fi; '\
'case "$4" in /*/persist) : ;; *) echo "dxe-live-interrupt: bad destination $4" >&2; exit 1 ;; esac; '\
'now() { date +%s; }; size() { set -- $(ls -ln -- "$1" 2>/dev/null); case "${5:-}" in "" | *[!0-9]*) echo 0 ;; *) echo "$5" ;; esac; }; '\
'end=$(( $(now) + $7 )); fs=0; ev=1; if sleep 0.05 2>/dev/null; then fs=1; ev=20; fi; '\
'id=""; while [ -z "$id" ]; do '\
'ids=$("$d" ps -q --no-trunc --filter "name=^/$nm\$" --filter "volume=$vol" --filter status=running) || { echo "dxe-live-interrupt: docker ps failed" >&2; exit 4; }; '\
'n=0; c=""; cx=""; for i in $ids; do '\
'x=$("$d" inspect --format "{{.Path}}|{{range .Args}}{{.}} {{end}}|{{range .Mounts}}{{.Destination}}={{.Source}};{{end}}" "$i" 2>/dev/null) || continue; '\
'case "$x" in "$rs|-aH --numeric-ids "*" /src/ /dst/ |"*) : ;; *) continue ;; esac; '\
'case "$x" in *"|/dst=$dst;"* | *";/dst=$dst;"*) : ;; *) continue ;; esac; '\
'n=$((n + 1)); c=$i; cx=$x; done; '\
'if [ "$n" -gt 1 ]; then echo "dxe-live-interrupt: $n copy containers match; touching none" >&2; exit 6; fi; '\
'if [ "$n" -eq 1 ]; then id=$c; echo "copy=$(printf "%.12s" "$id")"; case "$cx" in *" --inplace "*) : ;; *) echo "dxe-live-interrupt: the copy runs rsync without --inplace (WP6.4c is not in effect), so the bulk file would never be seen part-way; nothing was killed" >&2; exit 8 ;; esac; break; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "dxe-live-interrupt: no copy container appeared within $7 s" >&2; exit 2; fi; '\
'sleep 1; done; '\
'hit=""; k=0; while [ -z "$hit" ]; do '\
'if [ -f "$blob" ] && [ ! -L "$blob" ]; then s=$(size "$blob"); if [ "$s" -gt 0 ] && [ "$s" -lt "$full" ]; then hit=$s; fi; fi; '\
'if [ -n "$hit" ]; then break; fi; k=$((k + 1)); '\
'if [ $((k % ev)) -eq 0 ]; then if [ -d "$4/$5" ] && { [ ! -r "$4/$5" ] || [ ! -x "$4/$5" ]; }; then echo "dxe-live-interrupt: this account cannot list $4/$5, so it cannot see the copy progress; nothing was killed" >&2; exit 7; fi; '\
'r=$("$d" inspect --format "{{.State.Running}}" "$id" 2>/dev/null) || r=gone; '\
'if [ "$r" != true ]; then echo "dxe-live-interrupt: the copy container ended before $6 was seen part-way" >&2; exit 3; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "dxe-live-interrupt: $6 was not seen part-way within $7 s" >&2; exit 2; fi; fi; '\
'if [ "$fs" = 1 ]; then sleep 0.05; else sleep 1; fi; done; '\
'"$d" kill "$id" >/dev/null || { echo "dxe-live-interrupt: docker kill failed" >&2; exit 4; }; '\
'echo "interrupted=$(printf "%.12s" "$id") bytes=$hit"; '\
'while "$d" inspect "$id" >/dev/null 2>&1; do if [ "$(now)" -ge "$end" ]; then echo "dxe-live-interrupt: the killed container did not go away" >&2; exit 5; fi; sleep 1; done; '\
'echo "gone=$(printf "%.12s" "$id")"'

# Read-only: docker ps and docker inspect only. The copy and verify containers
# are found by their WP6.4c names alone (Docker keeps names unique).
PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH='set -f; d=$1; m=$2; cn=$3; vn=$4; '\
'case "$1" in /*) : ;; *) echo "dxe-live-copy-watch: the docker CLI path must be absolute" >&2; exit 1 ;; esac; '\
'case "$2" in running | gone) : ;; *) echo "dxe-live-copy-watch: bad mode $2" >&2; exit 1 ;; esac; '\
'case "$3" in dxe-persist-copy-?*) : ;; *) echo "dxe-live-copy-watch: bad copy container name $3" >&2; exit 1 ;; esac; '\
'case "$4" in dxe-persist-verify-?*) : ;; *) echo "dxe-live-copy-watch: bad verify container name $4" >&2; exit 1 ;; esac; '\
'case "$5" in "" | *[!0-9]*) echo "dxe-live-copy-watch: bad deadline $5" >&2; exit 1 ;; esac; '\
'now() { date +%s; }; end=$(( $(now) + $5 )); '\
'if [ "$m" = running ]; then while :; do '\
'ids=$("$d" ps -q --no-trunc --filter "name=^/$cn\$" --filter status=running) || { echo "dxe-live-copy-watch: docker ps failed" >&2; exit 4; }; '\
'n=0; id=""; for i in $ids; do n=$((n + 1)); id=$i; done; '\
'if [ "$n" -gt 1 ]; then echo "dxe-live-copy-watch: $n running containers answer to the name $cn" >&2; exit 6; fi; '\
'if [ "$n" -eq 1 ]; then '\
'x=$("$d" inspect --format "{{range \$k, \$v := .Config.Labels}}{{\$k}}={{\$v}};{{end}}|{{range .Mounts}}{{.Destination}}={{.Source}};{{end}}" "$id") || { echo "dxe-live-copy-watch: docker inspect failed" >&2; exit 4; }; '\
'echo "copy=$id"; echo "labels=${x%%|*}"; echo "mounts=${x#*|}"; exit 0; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "dxe-live-copy-watch: no running container named $cn within $5 s" >&2; exit 2; fi; '\
'sleep 1; done; fi; '\
'while :; do '\
'a=$("$d" ps -a -q --no-trunc --filter "name=^/$cn\$") || { echo "dxe-live-copy-watch: docker ps failed" >&2; exit 4; }; '\
'b=$("$d" ps -a -q --no-trunc --filter "name=^/$vn\$") || { echo "dxe-live-copy-watch: docker ps failed" >&2; exit 4; }; '\
'if [ -z "$a$b" ]; then echo "gone=$cn $vn"; exit 0; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "dxe-live-copy-watch: $cn or $vn is still on the NAS after $5 s" >&2; exit 2; fi; '\
'sleep 1; done'

# The heartbeat comes before the floor check: once the ssh session is gone
# (the bring-up ended, or the suite was aborted) the next write fails and the
# watcher ends before it could stop anything.
PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INODE_WATCH='set -f; d=$1; cn=$2; r=$3; fl=$4; dl=$5; '\
'case "$1" in /*) : ;; *) echo "dxe-live-inode-watch: the docker CLI path must be absolute" >&2; exit 1 ;; esac; '\
'case "$2" in dx-*canary*) : ;; *) echo "dxe-live-inode-watch: $2 is not a canary container name" >&2; exit 1 ;; esac; '\
'case "$2" in *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) echo "dxe-live-inode-watch: $2 is not a canary container name" >&2; exit 1 ;; esac; '\
'case "$3" in /?*) : ;; *) echo "dxe-live-inode-watch: bad Docker data root $3" >&2; exit 1 ;; esac; '\
'case "$4" in "" | *[!0-9]* | 0*) echo "dxe-live-inode-watch: bad floor $4" >&2; exit 1 ;; esac; '\
'case "$5" in "" | *[!0-9]*) echo "dxe-live-inode-watch: bad deadline $5" >&2; exit 1 ;; esac; '\
'now() { date +%s; }; end=$(( $(now) + $5 )); '\
'while :; do '\
'o=$(df -P -i "$r" 2>/dev/null) || o=$(df -i "$r" 2>/dev/null) || o=""; '\
'set -- $(printf "%s\n" "$o" | tail -n 1); '\
'case "${4:-}" in "" | *[!0-9]*) echo "dxe-live-inode-watch: df -P -i $r gave no free-inode count" >&2; exit 4 ;; esac; '\
'f=$4; echo "free=$f" || exit 0; '\
'if [ "$f" -lt "$fl" ]; then echo "floor-hit free=$f floor=$fl" || exit 0; '\
'if "$d" stop -t 10 "$cn" >/dev/null; then echo "stopped=$cn"; exit 3; fi; echo "stop-failed=$cn" || exit 0; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "deadline=$dl"; exit 2; fi; '\
'sleep 20; done'

PERSIST_MIGRATE_LIVE_GUEST_SEED='set -eu
r=$1; s="$r/dxe-live-seed"; b="$r/dxe-live-bulk"
case "$3" in "" | *[!0-9]*) echo "dxe-live-seed: bad MiB $3" >&2; exit 2 ;; esac
if [ -e "$s" ] || [ -L "$s" ] || [ -e "$b" ] || [ -L "$b" ]; then echo "dxe-live-seed: $s or $b already exists" >&2; exit 1; fi
umask 022
nl=$(printf "\nx"); nl=${nl%x}; tb=$(printf "\tx"); tb=${tb%x}; q=$(printf "\047"); u=$(printf "\303\274n\303\257c\303\270d\303\251")
mkdir -p "$s/nested/deeper" "$s/odd names" "$s/private" "$s/dir-to-rename/inner" "$b"
printf "%s\n" "$2" > "$s/app-state.txt"
printf "alpha\n" > "$s/hardlink-a"
ln "$s/hardlink-a" "$s/hardlink-b"
ln "$s/hardlink-a" "$s/nested/hardlink-c"
printf "mac metadata\n" > "$s/._dxe-live-meta"
printf "deep mac metadata\n" > "$s/nested/deeper/._deep-meta"
mkfifo "$s/fifo"
ln -s hardlink-a "$s/link-to-a"
ln -s does-not-exist "$s/dangling"
ln -s nested "$s/link-to-dir"
ln -s "$s/app-state.txt" "$s/absolute-link"
printf "secret\n" > "$s/private/key"
chmod 0600 "$s/private/key"
chmod 0700 "$s/private"
printf "#!/bin/sh\necho run\n" > "$s/run.sh"
chmod 0755 "$s/run.sh"
: > "$s/empty-file"
printf "to delete\n" > "$s/nested/to-delete.txt"
printf "to rename\n" > "$s/to-rename.txt"
printf "before\n" > "$s/nested/modified.txt"
printf "inner\n" > "$s/dir-to-rename/inner/file.txt"
for n in "with space.txt" "-leading-dash" "tab${tb}name" "quote${q}single" "quote\"double" "back\\slash" "star*glob?" "dollar\$HOME" "$u" "new${nl}line"; do
  printf "odd\n" > "$s/odd names/$n"
done
sock=no
if command -v tmux >/dev/null 2>&1; then
  tmux -S "$s/dxe-live.sock" -f /dev/null new-session -d -s dxe-live-seed true >/dev/null 2>&1 || :
  if [ -S "$s/dxe-live.sock" ]; then sock=yes; fi
fi
bytes=$(( $3 * 1048576 ))
head -c "$bytes" /dev/urandom > "$b/dxe-live-blob.bin"
echo "seeded=ok socket=$sock bulk_bytes=$bytes"'

PERSIST_MIGRATE_LIVE_GUEST_CHANGES='set -eu
s="$1/dxe-live-seed"
[ -d "$s" ] || { echo "dxe-live-changes: no $s" >&2; exit 1; }
printf "%s\n" "$2" > "$s/written-after-switch.txt"
printf "after\n" > "$s/nested/modified.txt"
rm -f -- "$s/nested/to-delete.txt" "$s/hardlink-b"
mv -- "$s/to-rename.txt" "$s/renamed.txt"
mv -- "$s/dir-to-rename" "$s/dir-renamed"
printf "mac metadata after the switch\n" > "$s/._rollback-meta"
echo "changed=ok"'

PERSIST_MIGRATE_LIVE_GUEST_CHECK='s="$1/dxe-live-seed"; blob="$1/dxe-live-bulk/dxe-live-blob.bin"; n=0; bad=0
yes_() { n=$((n + 1)); echo "ok $1"; }
no_() { n=$((n + 1)); bad=$((bad + 1)); echo "bad $1"; }
chk() { local name=$1; shift; if "$@"; then yes_ "$name"; else no_ "$name"; fi; }
nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l -- "$1"; }
mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1"; }
size() { stat -c %s -- "$1" 2>/dev/null || stat -f %z -- "$1"; }
has() { [ "$(cat -- "$1" 2>/dev/null)" = "$2" ]; }
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
link_is() { [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ]; }
dangling() { [ -L "$1" ] && [ ! -e "$1" ] && [ "$(readlink -- "$1")" = does-not-exist ]; }
empty() { [ -f "$1" ] && [ ! -s "$1" ]; }
nl=$(printf "\nx"); nl=${nl%x}; tb=$(printf "\tx"); tb=${tb%x}; q=$(printf "\047"); u=$(printf "\303\274n\303\257c\303\270d\303\251")
case "$2" in seeded | migrated | changed-dir | changed-volume) : ;; *) echo "dxe-live-check: unknown state $2" >&2; exit 2 ;; esac
chk app-state has "$s/app-state.txt" "$3"
chk fifo test -p "$s/fifo"
if [ "$5" = yes ]; then chk socket test -S "$s/dxe-live.sock"; fi
chk link-to-a link_is "$s/link-to-a" hardlink-a
chk dangling dangling "$s/dangling"
chk link-to-dir link_is "$s/link-to-dir" nested
chk absolute-link link_is "$s/absolute-link" "$s/app-state.txt"
chk private-key-mode test "$(mode "$s/private/key")" = 600
chk private-dir-mode test "$(mode "$s/private")" = 700
chk run-mode test "$(mode "$s/run.sh")" = 755
chk empty-file empty "$s/empty-file"
for o in "with space.txt" "-leading-dash" "tab${tb}name" "quote${q}single" "quote\"double" "back\\slash" "star*glob?" "dollar\$HOME" "$u" "new${nl}line"; do
  chk "odd-name" has "$s/odd names/$o" odd
done
chk bulk-size test "$(size "$blob" 2>/dev/null)" = "$6"
case "$2" in
  seeded | migrated)
    chk hardlink-count test "$(nlink "$s/hardlink-a")" = 3
    chk hardlink-b test "$s/hardlink-a" -ef "$s/hardlink-b"
    chk hardlink-c test "$s/hardlink-a" -ef "$s/nested/hardlink-c"
    chk modified-before has "$s/nested/modified.txt" before
    chk to-delete-present has "$s/nested/to-delete.txt" "to delete"
    chk to-rename-present has "$s/to-rename.txt" "to rename"
    chk dir-to-rename-present has "$s/dir-to-rename/inner/file.txt" inner
    chk not-yet-written gone "$s/written-after-switch.txt" ;;
  *)
    chk hardlink-count test "$(nlink "$s/hardlink-a")" = 2
    chk hardlink-b-deleted gone "$s/hardlink-b"
    chk hardlink-c test "$s/hardlink-a" -ef "$s/nested/hardlink-c"
    chk written has "$s/written-after-switch.txt" "$4"
    chk modified-after has "$s/nested/modified.txt" after
    chk deleted gone "$s/nested/to-delete.txt"
    chk renamed has "$s/renamed.txt" "to rename"
    chk rename-source-gone gone "$s/to-rename.txt"
    chk dir-renamed has "$s/dir-renamed/inner/file.txt" inner
    chk dir-rename-source-gone gone "$s/dir-to-rename" ;;
esac
case "$2" in
  seeded)
    chk apple-top has "$s/._dxe-live-meta" "mac metadata"
    chk apple-deep has "$s/nested/deeper/._deep-meta" "deep mac metadata" ;;
  migrated)
    chk apple-top-dropped gone "$s/._dxe-live-meta"
    chk apple-deep-dropped gone "$s/nested/deeper/._deep-meta" ;;
  changed-dir)
    chk apple-top-dropped gone "$s/._dxe-live-meta"
    chk apple-deep-dropped gone "$s/nested/deeper/._deep-meta"
    chk apple-new-present has "$s/._rollback-meta" "mac metadata after the switch" ;;
  *)
    chk apple-top-dropped gone "$s/._dxe-live-meta"
    chk apple-deep-dropped gone "$s/nested/deeper/._deep-meta"
    chk apple-new-dropped gone "$s/._rollback-meta" ;;
esac
echo "checks=$n bad=$bad"
[ "$bad" -eq 0 ]'

persist_migrate_live_listing_ok() {
    local last count
    [ -f "$1" ] || return 1
    last="$(sed -n '$p' "$1")"
    count=$(($(wc -l <"$1") - 1))
    [ "$count" -gt 0 ] && [ "$last" = "$(printf 'end\t%s' "$count")" ]
}

persist_migrate_live_records() {
    sed '$d' "$1"
}

persist_migrate_live_records_without_apple() {
    persist_migrate_live_records "$1" | awk -F'\t' 'index($NF, "/._") == 0'
}

# persist_migrate_live_rollback_volume
persist_migrate_live_rollback_volume() {
    if [ -n "${DXE_PERSIST_LIVE_ROLLBACK_VOLUME:-}" ]; then
        printf '%s\n' "$DXE_PERSIST_LIVE_ROLLBACK_VOLUME"
    else
        printf '%s-rollback\n' "${DX_PERSIST_VOLUME:-}"
    fi
}

# persist_migrate_live_bulk_mib
persist_migrate_live_bulk_mib() {
    printf '%s\n' "${DXE_PERSIST_LIVE_BULK_MIB:-$PERSIST_MIGRATE_LIVE_BULK_MIB_DEFAULT}"
}

# persist_migrate_live_min_free_inodes
persist_migrate_live_min_free_inodes() {
    printf '%s\n' "${DXE_PERSIST_LIVE_MIN_FREE_INODES:-$PERSIST_MIGRATE_LIVE_MIN_FREE_INODES_DEFAULT}"
}

# persist_migrate_live_inode_stop_floor
persist_migrate_live_inode_stop_floor() {
    printf '%s\n' "${DXE_PERSIST_LIVE_INODE_STOP_FLOOR:-$PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_DEFAULT}"
}

# persist_migrate_live_docker_root
persist_migrate_live_docker_root() {
    local out rc=0 root
    out="$(dxe_runtime_call dx_runtime_docker_cli info --format '{{.DockerRootDir}}')" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    root="$(printf '%s\n' "$out" | tr -d '\r' | awk 'NF { last = $0 } END { print last }')"
    if ! persist_live_root_ok "$root"; then
        _persist_live_refuse "persist_migrate_live_docker_root: docker info names no usable Docker data root ('$root')."
        return 1
    fi
    printf '%s\n' "$root"
}

# persist_migrate_live_inodes ROOT
persist_migrate_live_inodes() {
    local root="$1" out rc=0
    if ! persist_live_root_ok "$root"; then
        _persist_live_refuse "persist_migrate_live_inodes: '$root' is not a normalised absolute path; nothing was run on the NAS."
        return 2
    fi
    out="$(dxe_runtime_call dx_runtime_docker_ssh_exec df -P -i "$root")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rc=0
        out="$(dxe_runtime_call dx_runtime_docker_ssh_exec df -i "$root")" || rc=$?
    fi
    [ "$rc" -eq 0 ] || return 1
    printf '%s\n' "$out" | persist_migrate_live_df_inodes
}

# persist_migrate_live_df_inodes < DF_OUTPUT
persist_migrate_live_df_inodes() {
    tr -d '\r' | awk '
        NF >= 6 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ { t = $2; u = $3; f = $4; n++ }
        END { if (n != 1 || t + 0 == 0) exit 1; print t, u, f }'
}

# --- The bring-up's inode watcher (WP7.2c) -----------------------------------------

# persist_migrate_live_inode_watch DOCKER_BIN ROOT FLOOR DEADLINE
persist_migrate_live_inode_watch() {
    local docker_bin="${1:-}" root="${2:-}" floor="${3:-}" deadline="${4:-}" why=""
    case "$docker_bin" in
        /*[[:space:]]*) why="the docker CLI path '$docker_bin' holds blanks" ;;
        /*) : ;;
        *) why="the docker CLI path '$docker_bin' is not absolute" ;;
    esac
    persist_live_name_is_canary "${DX_CONTAINER_NAME:-}" || why="${why:-DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} is not a canary name}"
    persist_live_root_ok "$root" || why="${why:-the Docker data root '$root' is not a normalised absolute path}"
    case "$floor" in
        '' | *[!0-9]* | 0*) why="${why:-the floor '$floor' is not a whole number from $PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MIN to $PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MAX}" ;;
        *) if [ "${#floor}" -gt 6 ] || [ "$floor" -lt "$PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MIN" ] || [ "$floor" -gt "$PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MAX" ]; then
               why="${why:-the floor '$floor' is not a whole number from $PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MIN to $PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MAX}"
           fi ;;
    esac
    case "$deadline" in
        '' | *[!0-9]* | 0*) why="${why:-the deadline '$deadline' is not a whole number of seconds from 20 to 86400}" ;;
        *) if [ "${#deadline}" -gt 5 ] || [ "$deadline" -lt 20 ] || [ "$deadline" -gt 86400 ]; then
               why="${why:-the deadline '$deadline' is not a whole number of seconds from 20 to 86400}"
           fi ;;
    esac
    if [ -n "$why" ]; then
        _persist_live_refuse "persist_migrate_live_inode_watch: $why; nothing was run on the NAS."
        return 2
    fi
    dxe_runtime_call dx_runtime_docker_ssh_exec sh -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INODE_WATCH" dxe-live-inode-watch \
        "$docker_bin" "$DX_CONTAINER_NAME" "$root" "$floor" "$deadline"
}

# persist_migrate_live_inode_watch_start DOCKER_BIN ROOT FLOOR DEADLINE OUT ERR [TRIES]
persist_migrate_live_inode_watch_start() {
    local docker_bin="$1" root="$2" floor="$3" deadline="$4" out="$5" err="$6" tries="${7:-300}" n=0 had_m=0 old cmd
    if [ "${BASH_SUBSHELL:-0}" -ne 0 ]; then
        _persist_live_refuse "persist_migrate_live_inode_watch_start: called in a subshell, whose end would orphan the watcher; nothing was started."
        return 2
    fi
    if [ -n "${PERSIST_MIGRATE_LIVE_WATCH_PID:-}" ]; then
        _persist_live_refuse "persist_migrate_live_inode_watch_start: a watcher (pid $PERSIST_MIGRATE_LIVE_WATCH_PID) still runs; nothing was started."
        return 2
    fi
    case "$tries" in '' | *[!0-9]* | 0*) tries=300 ;; esac
    PERSIST_MIGRATE_LIVE_WATCH_RC=""
    PERSIST_MIGRATE_LIVE_WATCH_KILLED=""
    old="$(trap -p EXIT)"
    PERSIST_MIGRATE_LIVE_WATCH_TRAP="$old"
    cmd="$(eval "set -- $old"; printf '%s' "${3:-}")"
    case "$-" in *m*) had_m=1 ;; esac
    # Job control for this one launch only: the job leads a process group of
    # its own, so the stop ends its local ssh client with it.
    set -m
    (persist_migrate_live_inode_watch "$docker_bin" "$root" "$floor" "$deadline") >"$out" 2>"$err" </dev/null &
    PERSIST_MIGRATE_LIVE_WATCH_PID=$!
    [ "$had_m" = 1 ] || set +m
    # shellcheck disable=SC2064 # the caller's own trap, expanded now on purpose
    trap "persist_migrate_live_inode_watch_stop >/dev/null 2>&1${cmd:+; $cmd}" EXIT
    while ! grep -q '^free=' "$out" 2>/dev/null; do
        n=$((n + 1))
        if ! kill -0 "$PERSIST_MIGRATE_LIVE_WATCH_PID" 2>/dev/null || [ "$n" -gt "$tries" ]; then
            persist_migrate_live_inode_watch_stop
            return 1
        fi
        sleep 0.2
    done
    return 0
}

# persist_migrate_live_inode_watch_stop
persist_migrate_live_inode_watch_stop() {
    local pid="${PERSIST_MIGRATE_LIVE_WATCH_PID:-}" rc=0
    [ -n "$pid" ] || return 0
    if kill -0 "$pid" 2>/dev/null; then
        if persist_migrate_live_kill_group "$pid"; then
            PERSIST_MIGRATE_LIVE_WATCH_KILLED=1
        else
            PERSIST_MIGRATE_LIVE_WATCH_KILLED=refused
        fi
    fi
    if [ "${PERSIST_MIGRATE_LIVE_WATCH_KILLED:-}" = refused ]; then
        rc=unknown
    else
        wait "$pid" 2>/dev/null || rc=$?
    fi
    PERSIST_MIGRATE_LIVE_WATCH_RC="$rc"
    PERSIST_MIGRATE_LIVE_WATCH_PID=""
    if [ -n "${PERSIST_MIGRATE_LIVE_WATCH_TRAP:-}" ]; then
        eval "$PERSIST_MIGRATE_LIVE_WATCH_TRAP"
    else
        trap - EXIT
    fi
    PERSIST_MIGRATE_LIVE_WATCH_TRAP=""
    return 0
}

# persist_migrate_live_inode_watch_verdict OUT RC KILLED
persist_migrate_live_inode_watch_verdict() {
    local verdict
    verdict="$(LV_RC_="${2:-}" LV_KILLED="${3:-}" awk '
        /^free=[0-9]+$/ { v = substr($0, 6) + 0; if (n == 0 || v < low) low = v; n++ }
        /^floor-hit free=[0-9]+ floor=[0-9]+$/ { split($0, a, /[ =]/); hf = a[3]; hl = a[5]; st = 0 }
        /^stopped=/ { if (hf != "") st = 1 }
        /^deadline=[0-9]+$/ { dl = substr($0, 10) }
        END {
            if (hf != "") print "floor-hit", hf, hl, (st ? "stopped" : "not-stopped")
            else if (dl != "") print "deadline", dl
            else if (ENVIRON["LV_KILLED"] == "1" && n > 0) print "watched", n, low
            else if (ENVIRON["LV_RC_"] == "4") print "blind"
        }' "$1" 2>/dev/null)"
    printf '%s\n' "${verdict:-ended ${2:-}}"
}

# persist_migrate_live_bringup_watched LOGDIR DOCKER_BIN ROOT FLOOR DEADLINE FREE0 -- COMMAND [ARG...]
persist_migrate_live_bringup_watched() {
    local logdir="$1" docker_bin="$2" root="$3" floor="$4" deadline="$5" free0="$6" rc out err verdict word free at state
    shift 6
    [ "${1:-}" != -- ] || shift
    PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT=""
    if ! persist_migrate_live_inode_watch_start "$docker_bin" "$root" "$floor" "$deadline" "$logdir/inode-watch.out" "$logdir/inode-watch.err"; then
        verdict="$(persist_migrate_live_inode_watch_verdict "$logdir/inode-watch.out" "${PERSIST_MIGRATE_LIVE_WATCH_RC:-}" "${PERSIST_MIGRATE_LIVE_WATCH_KILLED:-}")"
        lv_result inode_watch "not started ($verdict)"
        sed 's/^/    | /' "$logdir/inode-watch.out" "$logdir/inode-watch.err" 2>/dev/null
        lv_bad "the NAS inode watcher reports the Docker data root's free inodes before the bring-up starts (it did not: $verdict); nothing was brought up"
        return 1
    fi
    lv_ok "the NAS inode watcher runs: below $floor free inodes on $root it runs docker stop -t 10 $DX_CONTAINER_NAME"
    lv_run dx-bring-up -- "$@"
    rc="$LV_RC"
    out="$LV_OUT"
    err="$LV_ERR"
    persist_migrate_live_inode_watch_stop
    verdict="$(persist_migrate_live_inode_watch_verdict "$logdir/inode-watch.out" "$PERSIST_MIGRATE_LIVE_WATCH_RC" "$PERSIST_MIGRATE_LIVE_WATCH_KILLED")"
    LV_RC="$rc"
    LV_OUT="$out"
    LV_ERR="$err"
    read -r word free at state <<<"$verdict"
    case "$word" in
        floor-hit)
            PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT="$free"
            lv_result inode_floor_hit "free=$free floor=$at canary=$state"
            lv_bad "INODE FLOOR HIT: only $free inodes were free on the NAS's Docker data root (floor $at; the production guest shares it); the watcher ran docker stop -t 10 $DX_CONTAINER_NAME ($state) and the bring-up is abandoned (dx exited $rc)"
            return 1
            ;;
        watched)
            lv_result bringup_inodes_min_free "$at"
            lv_ok "the NAS inode watcher watched the whole bring-up: $free polls, lowest free count $at (floor $floor)"
            return 0
            ;;
    esac
    lv_result inode_watch "$verdict"
    sed 's/^/    | /' "$logdir/inode-watch.out" "$logdir/inode-watch.err" 2>/dev/null
    if [ "$rc" -eq 0 ]; then
        # dx came up: what it took still goes to the results.
        persist_migrate_live_inodes_after_bringup "$root" "$free0" "$floor" || return 1
        LV_RC="$rc"
        LV_OUT="$out"
        LV_ERR="$err"
    fi
    lv_bad "the NAS inode watcher watches until the bring-up ends (it stopped early: $verdict; dx exited $rc)"
    return 1
}

# persist_migrate_live_inodes_after_bringup ROOT FREE0 FLOOR
persist_migrate_live_inodes_after_bringup() {
    local root="$1" free0="$2" floor="$3" free measured=1
    lv_run inodes-after-bring-up -- persist_migrate_live_inodes "$root"
    free="$(awk 'NR == 1 { print $3 }' "$LV_OUT" 2>/dev/null)"
    [ "$LV_RC" -eq 0 ] || measured=0
    case "$free" in '' | *[!0-9]*) measured=0 ;; esac
    case "$free0" in '' | *[!0-9]*) measured=0 ;; esac
    if [ "$measured" = 0 ]; then
        lv_result canary_inodes_used unknown
        echo "    (df -P -i of the Docker data root did not answer after the bring-up; the canary's inode cost is not measured)"
        return 0
    fi
    lv_result docker_root_inodes_free_after_bringup "$free"
    lv_result canary_inodes_used "$((free0 - free))"
    echo "    the bring-up took $((free0 - free)) inodes of the Docker data root ($free free now)"
    if [ "$free" -lt "$floor" ]; then
        PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT="$free"
        lv_result inode_floor_hit "after-bringup free=$free floor=$floor"
        lv_bad "INODE FLOOR HIT after the bring-up: only $free inodes are free on the NAS's Docker data root (floor $floor; the production guest shares it); nothing is seeded"
        return 1
    fi
    lv_ok "at least $floor inodes are still free on the NAS's Docker data root after the bring-up ($free)"
}

# persist_migrate_live_volume_name_ok NAME: a canary volume name the suite may
# create, read or delete (dx-..., only lower-case letters, digits and "-").
persist_migrate_live_volume_name_ok() {
    case "$1" in
        dx-*canary*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    esac
    return 0
}

persist_migrate_live_guard() {
    local refused=0 rollback field mib inodes bad_inodes=0 stop bad_stop=0
    persist_live_guard || refused=1
    case "${DX_PERSIST_HOST_ROOT:-}" in
        *,*)
            _persist_live_refuse "DX_PERSIST_HOST_ROOT=${DX_PERSIST_HOST_ROOT:-} holds a comma; the suite's --mount options would split on it."
            refused=1
            ;;
    esac
    rollback="$(persist_migrate_live_rollback_volume)"
    if ! persist_migrate_live_volume_name_ok "$rollback"; then
        _persist_live_refuse "the rollback volume '$rollback' is not a canary volume name (dx-..., containing \"canary\", only [a-z0-9-]); set DXE_PERSIST_LIVE_ROLLBACK_VOLUME or rename DX_PERSIST_VOLUME."
        refused=1
    fi
    for field in DX_NIX_VOLUME DX_PERSIST_VOLUME DX_BOOTSTRAP_VOLUME; do
        if [ "$rollback" = "${!field:-}" ]; then
            _persist_live_refuse "the rollback volume '$rollback' is $field; it must be a new volume no profile setting names."
            refused=1
        fi
    done
    mib="${DXE_PERSIST_LIVE_BULK_MIB:-}"
    case "$mib" in
        '') : ;;
        *[!0-9]* | 0*)
            _persist_live_refuse "DXE_PERSIST_LIVE_BULK_MIB=$mib is not a whole number from 64 to 16384."
            refused=1
            ;;
        *)
            if [ "${#mib}" -gt 5 ] || [ "$mib" -lt 64 ] || [ "$mib" -gt 16384 ]; then
                _persist_live_refuse "DXE_PERSIST_LIVE_BULK_MIB=$mib is not a whole number from 64 to 16384."
                refused=1
            fi
            ;;
    esac
    inodes="${DXE_PERSIST_LIVE_MIN_FREE_INODES:-}"
    case "$inodes" in
        '') : ;;
        *[!0-9]* | 0*) bad_inodes=1 ;;
        *) if [ "${#inodes}" -gt 8 ] || [ "$inodes" -lt "$PERSIST_MIGRATE_LIVE_MIN_FREE_INODES_FLOOR" ]; then bad_inodes=1; fi ;;
    esac
    if [ "$bad_inodes" = 1 ]; then
        _persist_live_refuse "DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes is not a whole number from $PERSIST_MIGRATE_LIVE_MIN_FREE_INODES_FLOOR to 99999999 (a canary bring-up takes about 550,000-600,000 inodes of the filesystem the production guest shares)."
        refused=1
    fi
    stop="${DXE_PERSIST_LIVE_INODE_STOP_FLOOR:-}"
    case "$stop" in
        '') : ;;
        *[!0-9]* | 0*) bad_stop=1 ;;
        *) if [ "${#stop}" -gt 6 ] || [ "$stop" -lt "$PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MIN" ] \
               || [ "$stop" -gt "$PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MAX" ]; then bad_stop=1; fi ;;
    esac
    if [ "$bad_stop" = 1 ]; then
        _persist_live_refuse "DXE_PERSIST_LIVE_INODE_STOP_FLOOR=$stop is not a whole number from $PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MIN to $PERSIST_MIGRATE_LIVE_INODE_STOP_FLOOR_MAX (the free-inode count on the NAS's Docker data root below which the bring-up's watcher stops the canary; a production nix rebuild takes 50,000-150,000)."
        refused=1
    fi
    if [ "$bad_inodes" = 0 ] && [ "$bad_stop" = 0 ]; then
        inodes="$(persist_migrate_live_min_free_inodes)"
        stop="$(persist_migrate_live_inode_stop_floor)"
        if [ $((inodes - stop)) -lt "$PERSIST_MIGRATE_LIVE_BRINGUP_INODES" ]; then
            _persist_live_refuse "DXE_PERSIST_LIVE_MIN_FREE_INODES=$inodes leaves only $((inodes - stop)) inodes above the bring-up's stop floor $stop; a canary bring-up takes about $PERSIST_MIGRATE_LIVE_BRINGUP_INODES, so set the minimum to at least $((stop + PERSIST_MIGRATE_LIVE_BRINGUP_INODES)) (or lower DXE_PERSIST_LIVE_INODE_STOP_FLOOR)."
            refused=1
        fi
    fi
    case "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" in
        '' | "$PERSIST_MIGRATE_LIVE_REAL_GUEST") : ;;
        *)
            _persist_live_refuse "DXE_PERSIST_LIVE_INVENTORY_REAL=${DXE_PERSIST_LIVE_INVENTORY_REAL:-} is not $PERSIST_MIGRATE_LIVE_REAL_GUEST, the only production guest whose inventory the suite may read."
            refused=1
            ;;
    esac
    if [ -n "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" ] && [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" = 1 ]; then
        _persist_live_refuse "DXE_PERSIST_LIVE_INVENTORY_REAL and DXE_PERSIST_LIVE_CLEANUP_ONLY=1 are separate runs; set one."
        refused=1
    fi
    return "$refused"
}

# persist_migrate_live_dir_read SCRIPT [ARG...]
persist_migrate_live_dir_read() {
    local script="$1" dir
    shift
    dir="$(persist_live_canary_dir)"
    case "$dir" in
        *,*)
            _persist_live_refuse "persist_migrate_live_dir_read: '$dir' holds a comma; no container started."
            return 2
            ;;
    esac
    if ! persist_live_share_path_ok "$dir"; then
        _persist_live_refuse "persist_migrate_live_dir_read: '$dir' is not the canary's own directory; no container started."
        return 2
    fi
    dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0 --pull never \
        --label dxe.role=persist-live --mount "type=bind,source=$dir,target=/canary,readonly" \
        --entrypoint bash "${DX_IMAGE:-}" -c "$script" bash /canary "$@"
}

# persist_migrate_live_volume_read VOLUME SCRIPT [ARG...]
persist_migrate_live_volume_read() {
    local volume="$1" script="$2" rc=0
    shift 2
    if ! persist_migrate_live_volume_name_ok "$volume" || [ "$volume" != "${DX_PERSIST_VOLUME:-}" ] \
        || [ "$volume" = "${DX_NIX_VOLUME:-}" ] || [ "$volume" = "${DX_BOOTSTRAP_VOLUME:-}" ]; then
        _persist_live_refuse "persist_migrate_live_volume_read: '$volume' is not the configured canary persist volume (DX_PERSIST_VOLUME=${DX_PERSIST_VOLUME:-}); no container started."
        return 2
    fi
    case "${DX_IMAGE:-}" in
        *canary*) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_volume_read: DX_IMAGE=${DX_IMAGE:-} is not a canary image; no container started."
            return 2
            ;;
    esac
    dxe_runtime_call dx_runtime_volume_owned "$volume" "read (live suite)" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0 --pull never \
        --label dxe.role=persist-live -v "$volume:/v:ro" \
        --entrypoint bash "$DX_IMAGE" -c "$script" bash /v "$@"
}

# persist_migrate_live_interrupt DOCKER_BIN CANON_LEAF DEADLINE FULL_BYTES
persist_migrate_live_interrupt() {
    local docker_bin="$1" leaf="$2" deadline="$3" full="${4:-}" why="" name
    case "$docker_bin" in
        /*[[:space:]]*) why="the docker CLI path '$docker_bin' holds blanks" ;;
        /*) : ;;
        *) why="the docker CLI path '$docker_bin' is not absolute" ;;
    esac
    case "${DX_IMAGE:-}" in *canary*) : ;; *) why="${why:-DX_IMAGE=${DX_IMAGE:-} is not a canary image}" ;; esac
    persist_migrate_live_volume_name_ok "${DX_PERSIST_VOLUME:-}" || why="${why:-DX_PERSIST_VOLUME=${DX_PERSIST_VOLUME:-} is not a canary volume}"
    persist_live_name_is_canary "${DX_CONTAINER_NAME:-}" || why="${why:-DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} is not a canary name}"
    case "$leaf" in
        *,*) why="${why:-the destination '$leaf' holds a comma}" ;;
        */dxe/"${DX_CONTAINER_NAME:-}"/persist) persist_live_root_ok "$leaf" || why="${why:-the destination '$leaf' is not a normalised absolute path}" ;;
        *) why="${why:-the destination '$leaf' is not <root>/dxe/${DX_CONTAINER_NAME:-}/persist}" ;;
    esac
    case "$deadline" in
        '' | *[!0-9]* | 0*) why="${why:-the deadline '$deadline' is not a whole number of seconds from 10 to 3600}" ;;
        *) if [ "${#deadline}" -gt 4 ] || [ "$deadline" -lt 10 ] || [ "$deadline" -gt 3600 ]; then
               why="${why:-the deadline '$deadline' is not a whole number of seconds from 10 to 3600}"
           fi ;;
    esac
    case "$full" in
        '' | *[!0-9]* | 0*) why="${why:-the full size of the bulk file ('$full') is not a whole number of bytes above 0}" ;;
    esac
    # The copy container's WP6.4c name: dxe-persist-copy-<DQ6 profile id>.
    name="$(persist_migrate_live_copy_name copy 2>/dev/null)" || why="${why:-DX_REMOTE_HOST=${DX_REMOTE_HOST:-} cannot name the copy container}"
    if [ -n "$why" ]; then
        _persist_live_refuse "persist_migrate_live_interrupt: $why; nothing was run on the NAS."
        return 2
    fi
    dxe_runtime_call dx_runtime_docker_ssh_exec sh -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" dxe-live-interrupt \
        "$docker_bin" "$name" "$DX_PERSIST_VOLUME" "$leaf" \
        "$PERSIST_MIGRATE_LIVE_BULK" "$PERSIST_MIGRATE_LIVE_BLOB" "$deadline" "$full"
}

# persist_migrate_live_partial_record RECORD FULL_BYTES
persist_migrate_live_partial_record() {
    local type size
    [ -n "$1" ] || return 1
    type="$(printf '%s\n' "$1" | awk -F'\t' 'NR == 1 { print $1 }')"
    size="$(printf '%s\n' "$1" | awk -F'\t' 'NR == 1 { print $4 }')"
    [ "$type" = f ] || return 1
    case "$size" in '' | *[!0-9]*) return 1 ;; esac
    [ "$size" -lt "$2" ]
}

# persist_migrate_live_temp_count FILE
persist_migrate_live_temp_count() {
    persist_migrate_live_records "$1" | LV_P="./.$PERSIST_MIGRATE_LIVE_BLOB." awk -F'\t' '
        $1 == "f" && index($NF, ENVIRON["LV_P"]) == 1 && length($NF) == length(ENVIRON["LV_P"]) + 6 { n++ }
        END { print n + 0 }'
}

# --- The controller-drop case (WP7.2b) -------------------------------------------

# persist_migrate_live_copy_name copy|verify
persist_migrate_live_copy_name() {
    case "$1" in
        copy | verify) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_copy_name: '$1' is not copy or verify."
            return 2
            ;;
    esac
    case "${DX_REMOTE_HOST:-}" in
        '' | *[!A-Za-z0-9_.-]*)
            _persist_live_refuse "persist_migrate_live_copy_name: DX_REMOTE_HOST=${DX_REMOTE_HOST:-} cannot be part of a Docker container name ([A-Za-z0-9_.-])."
            return 2
            ;;
    esac
    if ! persist_live_name_is_canary "${DX_CONTAINER_NAME:-}"; then
        _persist_live_refuse "persist_migrate_live_copy_name: DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} is not a canary name."
        return 2
    fi
    printf 'dxe-persist-%s-%s__%s\n' "$1" "$DX_REMOTE_HOST" "$DX_CONTAINER_NAME"
}

# persist_migrate_live_copy_watch DOCKER_BIN running|gone DEADLINE
persist_migrate_live_copy_watch() {
    local docker_bin="${1:-}" mode="${2:-}" deadline="${3:-}" why="" copy verify
    case "$docker_bin" in
        /*[[:space:]]*) why="the docker CLI path '$docker_bin' holds blanks" ;;
        /*) : ;;
        *) why="the docker CLI path '$docker_bin' is not absolute" ;;
    esac
    case "$mode" in
        running | gone) : ;;
        *) why="${why:-the mode '$mode' is not running or gone}" ;;
    esac
    case "$deadline" in
        0) : ;;
        '' | *[!0-9]* | 0*) why="${why:-the deadline '$deadline' is not 0 or a whole number of seconds up to 3600}" ;;
        *) if [ "${#deadline}" -gt 4 ] || [ "$deadline" -gt 3600 ]; then
               why="${why:-the deadline '$deadline' is not 0 or a whole number of seconds up to 3600}"
           fi ;;
    esac
    copy="$(persist_migrate_live_copy_name copy 2>/dev/null)" || why="${why:-DX_REMOTE_HOST and DX_CONTAINER_NAME do not name the canary copy container}"
    verify="$(persist_migrate_live_copy_name verify 2>/dev/null)" || why="${why:-DX_REMOTE_HOST and DX_CONTAINER_NAME do not name the canary verify container}"
    if [ -n "$why" ]; then
        _persist_live_refuse "persist_migrate_live_copy_watch: $why; nothing was run on the NAS."
        return 2
    fi
    dxe_runtime_call dx_runtime_docker_ssh_exec sh -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_COPY_WATCH" dxe-live-copy-watch \
        "$docker_bin" "$mode" "$copy" "$verify" "$deadline"
}

# persist_migrate_live_labels_ok LABELS PROFILE_ID ROLE
persist_migrate_live_labels_ok() {
    case ";$1" in *";io.dxe.managed=true;"*) : ;; *) return 1 ;; esac
    case ";$1" in *";io.dxe.profile=$2;"*) : ;; *) return 1 ;; esac
    case ";$1" in *";io.dxe.role=$3;"*) : ;; *) return 1 ;; esac
}

# persist_migrate_live_mount_ok MOUNTS DESTINATION SOURCE
persist_migrate_live_mount_ok() {
    case ";$1" in *";$2=$3;"*) return 0 ;; esac
    return 1
}

# persist_migrate_live_lock_owner_is FILE PID
persist_migrate_live_lock_owner_is() {
    LV_P="$2" awk '
        index($0, "held by ") == 1 {
            n = split(substr($0, 9), part, ":")
            if (n >= 4 && part[2] == ENVIRON["LV_P"]) found = 1
        }
        END { exit !found }' "$1" 2>/dev/null
}

# persist_migrate_live_own_group COMMAND [ARG...]: replaces the calling
# (sub)shell, so only a subshell or a background job may call it.
persist_migrate_live_own_group() {
    if [ "${BASH_SUBSHELL:-0}" -eq 0 ]; then
        _persist_live_refuse "persist_migrate_live_own_group: called outside a subshell, where it would replace the caller; nothing was run."
        return 2
    fi
    # shellcheck disable=SC2016 # perl code, not shell
    exec perl -e 'setpgrp(0, 0) or die "dxe-live: setpgrp failed: $!\n"; exec { $ARGV[0] } @ARGV or die "dxe-live: cannot run $ARGV[0]: $!\n";' -- "$@"
}

# persist_migrate_live_kill_group PID
persist_migrate_live_kill_group() {
    local pid="$1" pgid own parent
    case "$pid" in
        '' | *[!0-9]* | 0*)
            _persist_live_refuse "persist_migrate_live_kill_group: '$pid' is not a process id; nothing was sent."
            return 2
            ;;
    esac
    if [ "$pid" -le 1 ] || [ "$pid" = "$$" ]; then
        _persist_live_refuse "persist_migrate_live_kill_group: $pid is init or this shell; nothing was sent."
        return 2
    fi
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
    own="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')"
    if [ "$pgid" != "$pid" ] || [ -z "$own" ] || [ "$pgid" = "$own" ]; then
        _persist_live_refuse "persist_migrate_live_kill_group: $pid does not lead a process group of its own apart from this shell's (pgid '$pgid', this shell's '$own'); nothing was sent."
        return 2
    fi
    # The background job this shell forked keeps its pid and its parent
    # through own_group's exec chain (subshell -> perl -> the command); a
    # reused pid that happens to lead a group has another parent.
    parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    if [ "$parent" != "$$" ]; then
        _persist_live_refuse "persist_migrate_live_kill_group: $pid is not a child of this shell ($$; its parent is '$parent'), so it is not the job this suite started; nothing was sent."
        return 2
    fi
    kill -KILL -- "-$pid"
}

# persist_migrate_live_group_gone PID [TRIES]
persist_migrate_live_group_gone() {
    local pid="$1" tries="${2:-25}" n=0
    case "$pid" in '' | *[!0-9]* | 0*) return 1 ;; esac
    while kill -0 -- "-$pid" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -lt "$tries" ] || return 1
        sleep 0.2
    done
    return 0
}

# persist_migrate_live_drop_classify RC ERR_FILE COPY_NAME VERIFY_NAME
persist_migrate_live_drop_classify() {
    local rc="$1" err="$2" n line name state
    if [ "$rc" = 0 ]; then
        echo completed
        return 0
    fi
    n="$(grep -c '^Error:' "$err" 2>/dev/null)" || n=0
    if [ "$rc" != 1 ] || [ "$n" != 1 ]; then
        echo unexpected
        return 0
    fi
    line="$(grep '^Error:' "$err")"
    for name in "$3" "$4"; do
        case "$line" in
            "Error: the container $name of an earlier migration or rollback is still running on "*"; wait for it to finish, or stop it there with docker stop $name, then run dx-persist-migrate again. Nothing was changed.")
                echo "refused-running $name"
                return 0
                ;;
            "Error: the container $name of an earlier migration or rollback is paused on "*"; resume it there with docker unpause $name (it then finishes and removes itself), or end it with docker stop $name, then run dx-persist-migrate again. Nothing was changed.")
                echo "refused-left paused"
                return 0
                ;;
            "Error: Docker is removing the container $name of an earlier migration or rollback on "*"; wait until docker ps -a no longer lists it, then run dx-persist-migrate again. Nothing was changed.")
                echo "refused-left removing"
                return 0
                ;;
            "Error: the container $name of an earlier migration or rollback is left on "*" in state "*"; inspect it there (docker inspect $name, docker logs $name), then remove it with docker rm $name and run dx-persist-migrate again. Nothing was changed.")
                state="${line#* in state }"
                echo "refused-left ${state%%;*}"
                return 0
                ;;
        esac
    done
    case "$line" in
        "Error: the copy into "*" stopped before it finished (rsync exit 125)"*) echo copy-conflict ;;
        *) echo unexpected ;;
    esac
}

# persist_migrate_live_drop_bulk_hint BULK_MIB COPY_SECONDS
persist_migrate_live_drop_bulk_hint() {
    local mib="$1" seconds="$2" want
    [ "$seconds" -ge 1 ] 2>/dev/null || seconds=1
    want=$(( (mib * 60 + seconds - 1) / seconds ))
    want=$(( (want + 1023) / 1024 * 1024 ))
    [ "$want" -le 16384 ] || want=16384
    printf '%s\n' "$want"
}

# persist_migrate_live_controller_drop DOCKER_BIN MIGRATE LOCK CANON_LEAF DEADLINE
persist_migrate_live_controller_drop() {
    local docker_bin="$1" migrate="$2" lock="$3" leaf="$4" deadline="$5"
    local copy verify profile pid t_kill outcome seen budget slice
    PERSIST_MIGRATE_LIVE_DROP_OUTCOME=""
    PERSIST_MIGRATE_LIVE_DROP_ID=""
    PERSIST_MIGRATE_LIVE_DROP_OUT=""
    PERSIST_MIGRATE_LIVE_DROP_ERR=""
    PERSIST_MIGRATE_LIVE_DROP_WINDOW=""
    PERSIST_MIGRATE_LIVE_DROP_GONE_AFTER=""
    PERSIST_MIGRATE_LIVE_DROP_ORPHAN=""
    PERSIST_MIGRATE_LIVE_DROP_LOCK_LEFT=""
    PERSIST_MIGRATE_LIVE_DROP_PID=""
    copy="$(persist_migrate_live_copy_name copy)" || return 1
    verify="$(persist_migrate_live_copy_name verify)" || return 1
    profile="${DX_REMOTE_HOST}__$DX_CONTAINER_NAME"

    # 1. The controller, in a process group of its own.
    lv_run_bg migrate-dropped -- persist_migrate_live_own_group "$migrate"
    pid="$LV_BG_PID"
    PERSIST_MIGRATE_LIVE_DROP_PID="$pid"
    # 2. Its copy container, running, found by its name (read-only), looked
    # for in slices: a controller that has already ended (it refused or
    # failed before copying) is noticed within one slice, not after the
    # whole deadline.
    budget="$deadline"
    while :; do
        slice="$PERSIST_MIGRATE_LIVE_DROP_WATCH_SLICE"
        [ "$budget" -ge "$slice" ] || slice="$budget"
        lv_run copy-running -- persist_migrate_live_copy_watch "$docker_bin" running "$slice"
        [ "$LV_RC" -eq 2 ] || break
        budget=$((budget - slice))
        if ! kill -0 "$pid" 2>/dev/null; then
            lv_bg_wait
            lv_show_logs
            lv_bad "the dropped run's dx-persist-migrate still runs while its copy container is awaited (it exited $LV_RC before a running container named $copy was seen, so there is nothing to drop; see its log)"
            return 1
        fi
        [ "$budget" -gt 0 ] || break
    done
    lv_check "a running container named $copy appears on the NAS within $deadline s (the dropped run's copy)" lv_rc_zero || return 1
    PERSIST_MIGRATE_LIVE_DROP_ID="$(sed -n 's/^copy=//p' "$LV_OUT" | sed -n '1p')"
    lv_check "it carries this profile's DQ6 labels: io.dxe.managed=true, io.dxe.profile=$profile, io.dxe.role=persist-copy (docker run --name/--label on the NAS)" \
        persist_migrate_live_labels_ok "$(sed -n 's/^labels=//p' "$LV_OUT" | sed -n '1p')" "$profile" persist-copy || { lv_show_logs; return 1; }
    lv_check "it binds $leaf at /dst" \
        persist_migrate_live_mount_ok "$(sed -n 's/^mounts=//p' "$LV_OUT" | sed -n '1p')" /dst "$leaf" || { lv_show_logs; return 1; }
    # 3. Drop the controller: SIGKILL its whole process group (no EXIT trap).
    lv_run controller-kill -- persist_migrate_live_kill_group "$pid"
    lv_check "the controller's process group ($pid) is sent SIGKILL" lv_rc_zero || return 1
    t_kill="$(date +%s)"
    PERSIST_MIGRATE_LIVE_DROP_ORPHAN=1
    PERSIST_MIGRATE_LIVE_DROP_LOCK_LEFT=1
    lv_bg_wait
    lv_check "the dropped controller died of SIGKILL (status 137)" lv_rc_is 137 || return 1
    lv_check "no process of its group is left (its ssh clients included)" persist_migrate_live_group_gone "$pid" || return 1
    # 4. The lock it left, cleared the documented way: status first, and the
    # force only for the dropped controller's own lock.
    lv_run lock-status -- "$lock" status
    lv_check "dx-lock status exits 0" lv_rc_zero || return 1
    lv_check "it shows the lock still held by the dropped controller (pid $pid)" persist_migrate_live_lock_owner_is "$LV_OUT" "$pid" || { lv_show_logs; return 1; }
    lv_run lock-unlock -- "$lock" unlock --force
    lv_check "dx-lock unlock --force exits 0" lv_rc_zero || return 1
    lv_check "and releases it" lv_out_line "Lock released." || return 1
    PERSIST_MIGRATE_LIVE_DROP_LOCK_LEFT=""
    # 5. The rerun, at once, while the copy container still runs.
    lv_run migrate-while-copy-runs -- "$migrate"
    PERSIST_MIGRATE_LIVE_DROP_WINDOW=$(( $(date +%s) - t_kill ))
    PERSIST_MIGRATE_LIVE_DROP_OUT="$LV_OUT"
    PERSIST_MIGRATE_LIVE_DROP_ERR="$LV_ERR"
    outcome="$(persist_migrate_live_drop_classify "$LV_RC" "$LV_ERR" "$copy" "$verify")"
    case "$outcome" in
        refused-running\ *)
            PERSIST_MIGRATE_LIVE_DROP_OUTCOME=refused
            lv_ok "the rerun refuses ${PERSIST_MIGRATE_LIVE_DROP_WINDOW} s after the drop: exit 1, exactly one Error line naming ${outcome#refused-running } and running, with the fix (wait, or docker stop)"
            lv_run copy-still-running -- persist_migrate_live_copy_watch "$docker_bin" running 0
            seen="$(sed -n 's/^copy=//p' "$LV_OUT" | sed -n '1p')"
            if [ "$LV_RC" -eq 0 ] && [ -n "$seen" ] && [ "$seen" = "$PERSIST_MIGRATE_LIVE_DROP_ID" ]; then
                lv_ok "the refusal left the copy container alone: the same container still runs"
            else
                echo "    (the copy container is no longer running: it ended right after the refusal; whether it ran to its end is checked on the directory)"
            fi
            ;;
        refused-left\ * | copy-conflict | completed)
            PERSIST_MIGRATE_LIVE_DROP_OUTCOME=missed
            [ "$outcome" != completed ] || PERSIST_MIGRATE_LIVE_DROP_OUTCOME=completed
            lv_finding "NOT VALIDATED: the rerun ${PERSIST_MIGRATE_LIVE_DROP_WINDOW} s after the drop did not meet the copy container running (outcome: $outcome); the copy ended too soon -- raise DXE_PERSIST_LIVE_BULK_MIB"
            ;;
        *)
            lv_show_logs
            lv_bad "the rerun while $copy runs refuses with exactly one Error line naming it (outcome: $outcome)"
            return 1
            ;;
    esac
    # 6. The orphaned copy (and any verify) ends and removes itself.
    lv_run copy-gone -- persist_migrate_live_copy_watch "$docker_bin" gone "$deadline"
    PERSIST_MIGRATE_LIVE_DROP_GONE_AFTER=$(( $(date +%s) - t_kill ))
    lv_check "the orphaned copy ends and removes itself (--rm) within $deadline s, and no verify container is left" lv_rc_zero || return 1
    PERSIST_MIGRATE_LIVE_DROP_ORPHAN=""
    return 0
}

# persist_migrate_live_drop_directory LISTINGS SEED_REF BULK_REF
persist_migrate_live_drop_directory() {
    local listings="$1" why="" name ref sub file
    PERSIST_MIGRATE_LIVE_DROP_DIRECTORY=""
    for name in seed bulk; do
        if [ "$name" = seed ]; then
            ref="$2"
            sub="$PERSIST_MIGRATE_LIVE_SEED"
        else
            ref="$3"
            sub="$PERSIST_MIGRATE_LIVE_BULK"
        fi
        file="$listings/dir2-orphan-$name"
        lv_run "list-dir2-orphan-$name" -- persist_migrate_live_dir_read "$PERSIST_MIGRATE_LIVE_SCRIPT_LIST" "persist/$sub"
        cp "$LV_OUT" "$file" 2>/dev/null || : >"$file"
        if [ "$LV_RC" -ne 0 ] || ! persist_migrate_live_listing_ok "$file"; then
            why="${why:+$why; }its $sub could not be listed whole (exit $LV_RC)"
        elif ! persist_migrate_live_listing_ok "$ref" \
            || [ "$(persist_migrate_live_records "$ref")" != "$(persist_migrate_live_records "$file")" ]; then
            why="${why:+$why; }its $sub differs from the source's"
            diff <(persist_migrate_live_records "$ref" 2>/dev/null) <(persist_migrate_live_records "$file") | sed -n '1,30p' | sed 's/^/    /'
        fi
    done
    if [ -z "$why" ]; then
        PERSIST_MIGRATE_LIVE_DROP_DIRECTORY=complete
        lv_ok "the orphaned copy ran to its end on its own: the directory's tree equals the rollback volume's"
        lv_ok "and its bulk file is whole"
        return 0
    fi
    PERSIST_MIGRATE_LIVE_DROP_DIRECTORY=incomplete
    if [ "${PERSIST_MIGRATE_LIVE_DROP_OUTCOME:-}" = missed ]; then
        lv_finding "the orphaned copy ended within ${PERSIST_MIGRATE_LIVE_DROP_GONE_AFTER:-?} s of the drop, before it finished ($why); the next migration resumes the directory"
        return 0
    fi
    lv_bad "the orphaned copy ran to its end on its own: the directory equals the rollback volume ($why)"
    return 1
}

# --- The left copy container, planted (WP7.2g) ------------------------------------------
# A deterministic live check of WP6.4c's refusal while a copy container of an
# earlier run is on the NAS: the suite plants one itself, with the product's
# copy-container name, instead of racing a real copy (run 3: the NAS copies
# the largest allowed seed in about 22 s).

# persist_migrate_live_plant_copy
persist_migrate_live_plant_copy() {
    local name
    name="$(persist_migrate_live_copy_name copy 2>/dev/null)" || {
        _persist_live_refuse "persist_migrate_live_plant_copy: DX_REMOTE_HOST=${DX_REMOTE_HOST:-} and DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} do not name the canary's copy container; nothing was started."
        return 2
    }
    case "${DX_IMAGE:-}" in
        *canary*) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_plant_copy: DX_IMAGE=${DX_IMAGE:-} is not a canary image; nothing was started."
            return 2
            ;;
    esac
    dxe_runtime_call dx_runtime_run_ephemeral -d --name "$name" --network none --pull never \
        --label dxe.role=persist-live --label "$PERSIST_MIGRATE_LIVE_PLANT_LABEL" \
        --entrypoint sleep "$DX_IMAGE" "$PERSIST_MIGRATE_LIVE_PLANT_SECONDS"
}

# persist_migrate_live_planted_owned
persist_migrate_live_planted_owned() {
    local name label
    name="$(persist_migrate_live_copy_name copy 2>/dev/null)" || return 2
    label="$(dxe_runtime_call dx_runtime_docker_cli inspect --format '{{index .Config.Labels "dxe.live"}}' "$name" 2>/dev/null)" || return 1
    label="$(printf '%s\n' "$label" | tr -d '\r' | awk 'NF { last = $0 } END { print last }')"
    [ "$label" = "${PERSIST_MIGRATE_LIVE_PLANT_LABEL#*=}" ]
}

# persist_migrate_live_planted_stop
persist_migrate_live_planted_stop() {
    local name
    name="$(persist_migrate_live_copy_name copy 2>/dev/null)" || {
        _persist_live_refuse "persist_migrate_live_planted_stop: DX_REMOTE_HOST and DX_CONTAINER_NAME do not name the canary's copy container; nothing was stopped."
        return 2
    }
    if ! persist_migrate_live_planted_owned; then
        _persist_live_refuse "persist_migrate_live_planted_stop: $name is not the container this suite planted (no label $PERSIST_MIGRATE_LIVE_PLANT_LABEL); nothing was stopped."
        return 2
    fi
    dxe_runtime_call dx_runtime_docker_cli stop -t 1 "$name"
}

# persist_migrate_live_planted_rm [-f]
persist_migrate_live_planted_rm() {
    local name force=""
    [ "${1:-}" != -f ] || force=-f
    name="$(persist_migrate_live_copy_name copy 2>/dev/null)" || {
        _persist_live_refuse "persist_migrate_live_planted_rm: DX_REMOTE_HOST and DX_CONTAINER_NAME do not name the canary's copy container; nothing was removed."
        return 2
    }
    if ! persist_migrate_live_planted_owned; then
        _persist_live_refuse "persist_migrate_live_planted_rm: $name is not the container this suite planted (no label $PERSIST_MIGRATE_LIVE_PLANT_LABEL); nothing was removed."
        return 2
    fi
    dxe_runtime_call dx_runtime_docker_cli rm ${force:+"$force"} "$name"
}

# persist_migrate_live_planted_cleanup: after a failure inside the check.
persist_migrate_live_planted_cleanup() {
    [ -n "${PERSIST_MIGRATE_LIVE_PLANTED:-}" ] || return 0
    lv_run planted-cleanup -- persist_migrate_live_planted_rm -f
    if [ "$LV_RC" -ne 0 ]; then
        lv_run planted-cleanup-gone -- persist_migrate_live_copy_watch "${PERSIST_MIGRATE_LIVE_PLANTED_DOCKER:-}" gone 0
        if [ "$LV_RC" -ne 0 ]; then
            echo "    (the planted container could not be removed; see the command below)"
            return 1
        fi
    fi
    PERSIST_MIGRATE_LIVE_PLANTED=""
    echo "    (the planted container is gone: removed by its exact name after its label was checked)"
    return 0
}

# persist_migrate_live_planted_hint: lv_stop's lines while one may be left.
persist_migrate_live_planted_hint() {
    local name
    [ -n "${PERSIST_MIGRATE_LIVE_PLANTED:-}" ] || return 0
    name="$(persist_migrate_live_copy_name copy 2>/dev/null)" || return 0
    echo "  The left-container check's planted container $name may still be on the NAS (label"
    echo "  $PERSIST_MIGRATE_LIVE_PLANT_LABEL; dx-persist-migrate refuses while it exists). After a look, remove it by its exact name:"
    echo "    ssh ${DX_REMOTE_HOST:-<NAS>} \"${PERSIST_MIGRATE_LIVE_PLANTED_DOCKER:-docker} rm -f $name\""
}

# persist_migrate_live_left_rerun STATE EXPECTED MIGRATE LOCK BEFORE COPY VERIFY
persist_migrate_live_left_rerun() {
    local outcome
    lv_run "migrate-left-$1" -- "$3"
    outcome="$(persist_migrate_live_drop_classify "$LV_RC" "$LV_ERR" "$6" "$7")"
    lv_check "dx-persist-migrate refuses while $6 is $1: exit 1 and exactly one Error line, WP6.4c's refusal word for word ($outcome)" \
        test "$outcome" = "$2" || { lv_show_logs; return 1; }
    lv_check "and changes nothing (the probe, the canary directory, the volumes, the guest stopped, the record)" lv_state_unchanged "$5" || return 1
    lv_run "lock-after-left-$1" -- "$4" status
    lv_check "it took and released the lifecycle lock: dx-lock status says not held" lv_out_line "not held"
}

# persist_migrate_live_left_container DOCKER_BIN MIGRATE LOCK
persist_migrate_live_left_container() {
    local docker_bin="$1" migrate="$2" lock="$3" copy verify before
    PERSIST_MIGRATE_LIVE_PLANTED=""
    PERSIST_MIGRATE_LIVE_PLANTED_DOCKER="$docker_bin"
    copy="$(persist_migrate_live_copy_name copy)" || return 1
    verify="$(persist_migrate_live_copy_name verify)" || return 1
    lv_run left-none-before -- persist_migrate_live_copy_watch "$docker_bin" gone 0
    lv_check "no copy or verify container of the canary is on the NAS yet (nothing that is not the suite's is ever stopped or removed)" lv_rc_zero || return 1
    before="$(lv_state)"
    # 1. The plant: the product's copy-container name, a container of the suite's own.
    PERSIST_MIGRATE_LIVE_PLANTED=1
    lv_run plant-copy-container -- persist_migrate_live_plant_copy
    lv_check "a container named $copy is planted (the canary image, --network none, label $PERSIST_MIGRATE_LIVE_PLANT_LABEL, sleep $PERSIST_MIGRATE_LIVE_PLANT_SECONDS, no --rm)" \
        lv_rc_zero || { persist_migrate_live_planted_cleanup; return 1; }
    lv_run planted-running -- persist_migrate_live_copy_watch "$docker_bin" running 0
    lv_check "it runs" lv_rc_zero || { persist_migrate_live_planted_cleanup; return 1; }
    # 2. Running: WP6.4c's "still running" refusal, nothing changed.
    persist_migrate_live_left_rerun running "refused-running $copy" "$migrate" "$lock" "$before" "$copy" "$verify" \
        || { persist_migrate_live_planted_cleanup; return 1; }
    lv_run planted-still-running -- persist_migrate_live_copy_watch "$docker_bin" running 0
    lv_check "the refusal left the planted container running, untouched" lv_rc_zero || { persist_migrate_live_planted_cleanup; return 1; }
    lv_result left_container_running refused
    # 3. Stopped: the "left in state exited" refusal, nothing changed.
    lv_run planted-stop -- persist_migrate_live_planted_stop
    lv_check "docker stop -t 1 $copy (the suite's own, by its exact name, its label checked first)" lv_rc_zero \
        || { persist_migrate_live_planted_cleanup; return 1; }
    persist_migrate_live_left_rerun exited "refused-left exited" "$migrate" "$lock" "$before" "$copy" "$verify" \
        || { persist_migrate_live_planted_cleanup; return 1; }
    lv_result left_container_exited refused
    # 4. Removed, and gone: the next migration may start.
    lv_run planted-rm -- persist_migrate_live_planted_rm
    lv_check "docker rm $copy removes the planted container (by its exact name, its label checked first)" lv_rc_zero || { persist_migrate_live_planted_cleanup; return 1; }
    lv_run planted-gone -- persist_migrate_live_copy_watch "$docker_bin" gone 0
    lv_check "no copy or verify container of the canary is left" lv_rc_zero || { persist_migrate_live_planted_cleanup; return 1; }
    PERSIST_MIGRATE_LIVE_PLANTED=""
    return 0
}

# --- The canary's cleanup, normal and after an INODE FLOOR HIT (WP7.2d) ----------------

# persist_migrate_live_volume_state VOLUME: present | absent | unknown (one line).
persist_migrate_live_volume_state() {
    local state
    state="$(dxe_runtime_call dx_runtime_volume_state "$1" 2>/dev/null)" || :
    printf '%s\n' "${state:-unknown}" | sed -n '1p'
}

persist_migrate_live_container_absent() {
    local list
    list="$(dxe_runtime_call dx_runtime_container_list -a 2>/dev/null)" || return 1
    ! printf '%s\n' "$list" | awk -v n="${DX_CONTAINER_NAME:-}" '$1 == n { found = 1 } END { exit !found }'
}

persist_migrate_live_image_absent() {
    local list
    list="$(dxe_runtime_call dx_runtime_image_list 2>/dev/null)" || return 1
    ! printf '%s\n' "$list" | awk -v n="${DX_IMAGE:-}" '$1 == n { found = 1 } END { exit !found }'
}

# persist_migrate_live_volume_delete VOLUME
persist_migrate_live_volume_delete() {
    if ! persist_migrate_live_volume_name_ok "$1" || [ "$1" = "${DX_NIX_VOLUME:-}" ] || [ "$1" = "${DX_BOOTSTRAP_VOLUME:-}" ]; then
        _persist_live_refuse "persist_migrate_live_volume_delete: '$1' is not a canary persist volume; nothing was deleted."
        return 2
    fi
    (
        DX_PERSIST_VOLUME="$1"
        export DX_PERSIST_VOLUME
        dxe_runtime_call dx_runtime_volume_delete "$1"
    )
}

# persist_migrate_live_cleanup normal|emergency BIN_DIR ORIG ROLLBACK DEADLINE STAMP
persist_migrate_live_cleanup() {
    local mode="$1" bin="$2" orig="$3" rollback="$4" deadline="$5" stamp="$6" docker_bin report state vol record
    PERSIST_MIGRATE_LIVE_CLEANUP_DOCKER_BIN=""
    PERSIST_MIGRATE_LIVE_CLEANUP_RETIRED=""
    PERSIST_MIGRATE_LIVE_CLEANUP_LEAF_LEFT=""
    case "$mode" in
        normal | emergency) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_cleanup: '$mode' is not normal or emergency; nothing was run."
            return 2
            ;;
    esac
    record="$(persist_live_record_path)"
    # In host-path mode dx-factory-reset keeps every persist volume; they are
    # deleted below, one by one, by exact name.
    DX_PERSIST_STORAGE=host-path
    DX_PERSIST_VOLUME="$orig"
    export DX_PERSIST_STORAGE DX_PERSIST_VOLUME
    if [ "$mode" = normal ]; then
        lv_bg_wait
        docker_bin="$(dxe_runtime_call dx_runtime_docker_require_bin 2>/dev/null)" || docker_bin=""
        lv_check "the NAS's docker CLI path is known" test -n "$docker_bin" || return 1
        PERSIST_MIGRATE_LIVE_CLEANUP_DOCKER_BIN="$docker_bin"
        lv_run copy-gone-before-cleanup -- persist_migrate_live_copy_watch "$docker_bin" gone "$deadline"
        lv_check "no copy or verify container of the canary is left on the NAS (one still running is waited for, up to $deadline s)" lv_rc_zero || return 1
    fi
    if dxe_runtime_call dx_runtime_container_running "${DX_CONTAINER_NAME:-}" >/dev/null 2>&1; then
        lv_run stop-for-cleanup -- "$bin/dx-stop-container"
        lv_check "dx-stop-container stops the guest" lv_rc_zero || return 1
    fi
    # The plain-ssh probe first: only a leaf that is there needs the image
    # (for the root one-off container that moves it aside). An image build
    # is the last thing to start on a filesystem short of inodes.
    report="$(dxe_runtime_call dx_runtime_host_dir_probe "${DX_PERSIST_HOST_ROOT:-}" "${DX_CONTAINER_NAME:-}" 2>/dev/null)" || report=""
    lv_check "the share root answers the probe" test -n "$report" || return 1
    state="$(persist_live_kv state "$report")"
    if [ "$state" = absent ]; then
        echo "    no persist directory in $(persist_live_canary_dir) (state absent): nothing to move aside, so no image is built and no one-off container is started"
    elif [ "$mode" = emergency ]; then
        PERSIST_MIGRATE_LIVE_CLEANUP_LEAF_LEFT="$state"
        echo "    $(persist_live_leaf) is there (state $state): the emergency cleanup builds no image to move it aside and leaves it to the cleanup by hand"
    else
        if ! dxe_runtime_call dx_runtime_image_exists "${DX_IMAGE:-}" >/dev/null 2>&1; then
            lv_run create-image -- "$bin/dx-create-image"
            lv_check "dx-create-image provides $DX_IMAGE for the one-off container that moves the leaf aside" lv_rc_zero || return 1
        fi
        lv_run "share-leaf-retire-$stamp" -- persist_live_root_sh rw "$PERSIST_LIVE_SCRIPT_RETIRE" "$stamp"
        lv_check "share change: leaf-retire-$stamp" lv_rc_zero || return 1
        PERSIST_MIGRATE_LIVE_CLEANUP_RETIRED=1
        report="$(dxe_runtime_call dx_runtime_host_dir_probe "${DX_PERSIST_HOST_ROOT:-}" "${DX_CONTAINER_NAME:-}" 2>/dev/null)" || report=""
        lv_check "no canary directory is left where the tooling looks" test "$(persist_live_kv state "$report")" = absent || return 1
    fi
    lv_run factory-reset-cleanup -- "$bin/dx-factory-reset" --force
    lv_check "dx-factory-reset --force removes the canary's container, image, nix and bootstrap volumes and keys" lv_rc_zero || return 1
    for vol in "$orig" "$rollback"; do
        if [ "$(persist_migrate_live_volume_state "$vol")" = present ]; then
            lv_run "volume-delete-$vol" -- persist_migrate_live_volume_delete "$vol"
            lv_check "the canary volume $vol is deleted by exact name (DQ6 ownership checked)" lv_rc_zero || return 1
        fi
    done
    rm -f -- "$record"
    lv_check "the canary's D-7 record is deleted" test ! -e "$record" || return 1
    lv_check "no canary container is left" persist_migrate_live_container_absent || return 1
    lv_check "no canary image is left" persist_migrate_live_image_absent || return 1
    for vol in "${DX_NIX_VOLUME:-}" "$orig" "${DX_BOOTSTRAP_VOLUME:-}" "$rollback"; do
        lv_check "no volume $vol is left" test "$(persist_migrate_live_volume_state "$vol")" = absent || return 1
    done
}

# persist_migrate_live_auto_cleanup_due
persist_migrate_live_auto_cleanup_due() {
    [ -n "${PERSIST_MIGRATE_LIVE_INODE_FLOOR_HIT:-}" ] || return 1
    [ "${DXE_PERSIST_LIVE_NO_AUTO_CLEANUP:-}" != 1 ] || return 1
    [ "${DXE_PERSIST_LIVE_KEEP_RUNNING:-}" != 1 ]
}

# persist_migrate_live_emergency_cleanup BIN_DIR LOGDIR ORIG ROLLBACK ROOT PROFILE [TRIES PAUSE]
persist_migrate_live_emergency_cleanup() {
    local bin="$1" logdir="$2" orig="$3" rollback="$4" root="$5" profile="$6" tries="${7:-12}" pause="${8:-5}" n=0 free rc=0
    case "$tries" in '' | *[!0-9]* | 0*) tries=12 ;; esac
    case "$pause" in '' | *[!0-9.]*) pause=5 ;; esac
    echo "  Emergency cleanup after the INODE FLOOR HIT (DXE_PERSIST_LIVE_NO_AUTO_CLEANUP=1 turns it off):"
    # Evidence first, cheaply: the guest's own log and the count left.
    if dxe_runtime_call dx_runtime_logs "${DX_CONTAINER_NAME:-}" >"$logdir/canary-docker.log" 2>&1; then
        echo "    the canary's docker logs: $logdir/canary-docker.log"
    else
        echo "    (the canary's docker logs could not be read; see $logdir/canary-docker.log)"
    fi
    lv_run inodes-at-floor-hit -- persist_migrate_live_inodes "$root"
    free="$(awk 'NR == 1 { print $3 }' "$LV_OUT" 2>/dev/null)"
    lv_result inodes_free_at_floor_hit "${free:-unknown}"
    # dx releases the lifecycle lock when it fails; the cleanup's own commands
    # need it. Never forced here.
    while :; do
        lv_run lock-status-before-cleanup -- "$bin/dx-lock" status
        if [ "$LV_RC" -eq 0 ] && grep -Fqx 'not held' "$LV_OUT" 2>/dev/null; then break; fi
        n=$((n + 1))
        if [ "$n" -ge "$tries" ]; then
            lv_result emergency_cleanup "skipped: the lifecycle lock is still held"
            echo "    The canary's lifecycle lock is still held (or its status cannot be read) after $tries checks, so nothing was removed:"
            sed 's/^/      | /' "$LV_OUT" "$LV_ERR" 2>/dev/null
            echo "    Once nothing of the canary runs any more: ./bin/dx-profile $profile ./bin/dx-lock status"
            echo "    and only for a lock that is stale: ./bin/dx-profile $profile ./bin/dx-lock unlock --force; then the cleanup by hand."
            lv_bad "the emergency cleanup finds the canary's lifecycle lock free (it is still held; nothing was removed)"
            return 1
        fi
        sleep "$pause"
    done
    persist_migrate_live_cleanup emergency "$bin" "$orig" "$rollback" 0 "$(date -u +%Y%m%dT%H%M%SZ)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        lv_result emergency_cleanup "done"
    else
        lv_result emergency_cleanup "failed (status $rc)"
    fi
    lv_run inodes-after-emergency-cleanup -- persist_migrate_live_inodes "$root"
    free="$(awk 'NR == 1 { print $3 }' "$LV_OUT" 2>/dev/null)"
    lv_result inodes_free_after_emergency_cleanup "${free:-unknown}"
    echo "    free inodes on the Docker data root after the emergency cleanup: ${free:-unknown}"
    return "$rc"
}

# persist_migrate_live_real_inventory PROFILE ROOT COMMAND
persist_migrate_live_real_inventory() {
    local profile="$1" root="$2" command="$3"
    case "${command##*/}" in
        dx-persist-inventory) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_real_inventory: '$command' is not dx-persist-inventory; nothing was run."
            return 2
            ;;
    esac
    if [ "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" != "$PERSIST_MIGRATE_LIVE_REAL_GUEST" ]; then
        _persist_live_refuse "persist_migrate_live_real_inventory: DXE_PERSIST_LIVE_INVENTORY_REAL is not $PERSIST_MIGRATE_LIVE_REAL_GUEST; nothing was run."
        return 2
    fi
    if [ -z "${XDG_STATE_HOME:-}" ]; then
        _persist_live_refuse "persist_migrate_live_real_inventory: XDG_STATE_HOME is not set (the run directory's state); nothing was run."
        return 2
    fi
    (
        # shellcheck disable=SC2030 # this subshell's own resolution root
        DX_PROJECT_ROOT="${BASE_DIR:?}"
        # shellcheck source=../../bin/lib/dx-config.sh
        source "$BASE_DIR/bin/lib/dx-config.sh" >/dev/null 2>&1 || exit 2
        file="$(dx_profile_resolve_file "$profile" 2>/dev/null)" || {
            _persist_live_refuse "persist_migrate_live_real_inventory: no profile '$profile' was found; nothing was run."
            exit 2
        }
        if ! dx_parse_config_file "$file" >/dev/null 2>&1; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' does not parse; nothing was run."
            exit 2
        fi
        if [ "${DXE_PARSED_DX_CONTAINER_NAME:-}" != "$PERSIST_MIGRATE_LIVE_REAL_GUEST" ]; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' names DX_CONTAINER_NAME=${DXE_PARSED_DX_CONTAINER_NAME:-}, not $PERSIST_MIGRATE_LIVE_REAL_GUEST; nothing was run."
            exit 2
        fi
        if [ "${DXE_PARSED_DX_RUNTIME:-}" != docker-ssh ]; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' is not a docker-ssh profile; nothing was run."
            exit 2
        fi
        if [ -z "${DXE_PARSED_DX_PERSIST_VOLUME:-}" ]; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' names no DX_PERSIST_VOLUME; nothing was run."
            exit 2
        fi
        set -- HOME="${HOME:-}" PATH="${PATH:-}" XDG_STATE_HOME="$XDG_STATE_HOME" TMPDIR="${TMPDIR:-/tmp}"
        [ -z "${SSH_AUTH_SOCK:-}" ] || set -- "$@" SSH_AUTH_SOCK="$SSH_AUTH_SOCK"
        for name in $DXE_CONFIG_FIELDS; do
            parsed="DXE_PARSED_$name"
            [ "${!parsed+x}" = x ] || continue
            [ "$name" != DX_PROFILE_ROOT ] || continue
            set -- "$@" "$name=${!parsed}"
        done
        [ "${DXE_PARSED_DX_PERSIST_HOST_ROOT+x}" = x ] || set -- "$@" DX_PERSIST_HOST_ROOT="$root"
        exec env -i "$@" "$command"
    )
}
