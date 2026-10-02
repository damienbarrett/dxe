# Guest hostname parity on docker-ssh (`fix/docker-hostname`) — evidence

The user noticed on 2026-10-03 that the Apple guest calls itself `dx-host`
while the QNAP canary called itself by a short container ID that changed on
every recreate. Apple's `container create --name` sets the guest hostname;
Docker defaults it to the container ID unless `--hostname` is given, and
the docker-ssh adapter never gave it. The create translation now passes
`--hostname` equal to `--name`; the lifecycle lock container (never
started) deliberately gets none.

Red: the Docker adapter lifecycle suite's create-argv case failed on the
unchanged code ("passes --hostname equal to the container name", 45/1) and
passes after (46/0; bite re-checked by stashing the fix). A guard case
proves the lock's `docker create` carries no `--hostname`.

| Gate | Result |
| --- | --- |
| Docker adapter suites (health, identity, lifecycle, lock, transport, runtime adapter), Sections 10 and 27 | green |
| bash 3.2 | all passed |
| pinned ShellCheck 0.10.0, CI file set | clean |
| fresh clone in Ubuntu 24.04, no state directory (lint section ran) | all passed |
| `nix flake check --all-systems` | passed; `flake.lock` unchanged |
| kcov coverage | 100%; scope 4,194 ≥ 3,935; unscoped 2,629 ≤ 2,635 (ratchet untouched) |
| Apple live tier on `dx-test` (regression; Apple unchanged) | live tier: 45 suites, 2580 passed, 0 failed, 94 skipped |
| docker-ssh live proof | proven on a disposable `dx-qnap-spike4`: `/etc/hostname` equals the container name on first boot and after a Docker restart; the spike was factory-reset (spike4 up in 157 s) |
