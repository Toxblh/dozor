# LLM.md — for an AI assistant helping debug or fix Dozor

You are an AI assistant running on the machine of someone who **installed Dozor**
(a polkit authentication agent) and hit a problem. This file tells you how Dozor
works, how to diagnose it, and how to report or fix it **without leaking the
user's data**. Read the Privacy contract first — it is not optional.

## Privacy contract (read before doing anything that leaves the machine)

Dozor authenticates the user to run commands as root. Its logs therefore contain
sensitive data: **usernames, hostname, the exact commands run under sudo, process
trees, file paths.** Treat every log line as private until proven otherwise.

1. **Nothing leaves this machine without the human reading it first.** No auto-post.
2. Collect diagnostics only via `./contrib/dozor-report.sh` — it redacts username,
   hostname and home path by default and writes a single local file. Never paste
   raw `journalctl` output into an issue.
3. Command lines in the report are kept for debugging but tagged `>>> REVIEW`.
   Ask the human to read those lines and confirm they are safe to share.
4. Do the reporting/PR step **only after the human explicitly approves** the exact
   file contents. If they decline, stop — the fix can still be applied locally.
5. `ru.toxblh.*` (the polkit action id, the extension uuid `dozor@toxblh.ru`) is a
   **public, fixed** identifier — if the redactor rewrote it to `ru.USER.*` that is
   only because the user's login name collides with the maintainer's; harmless.

## What Dozor is

A GTK4 + libadwaita polkit agent (Python) that replaces GNOME Shell's built-in
authentication dialog and shows *who* is asking for privileges (app icon, command,
process chain), plus a PAM hook that routes terminal `sudo` through the same window.

```
sudo → PAM(pam_exec: dozor-sudo.sh) → pkcheck(ru.toxblh.dozor.sudo) → polkitd
                                                                         │ BeginAuthentication (D-Bus)
                                                                         ▼
                                              agent.py draws the window
                                                                         │ PolkitAgent.Session
                                                                         ▼
                                       polkit-agent-helper-1 (setuid) → PAM → ok
```

The agent implements the `org.freedesktop.PolicyKit1.AuthenticationAgent` D-Bus
interface directly (the `PolkitAgent.Listener` Python binding segfaults) and
registers on the Authority in place of GNOME Shell's agent. A Shell extension
disables the built-in agent and exposes a window-focus helper.

## File map

Repo (this checkout) → installed location:

| Repo | Installed | Role |
|------|-----------|------|
| `agent.py` | run by the unit | the agent + auth dialog |
| `dozor-sudo.sh` | `/etc/security/dozor-sudo.sh` | PAM hook: writes ctx, calls pkcheck |
| `lid-open.sh` | `/etc/security/lid-open.sh` | gate: skip fingerprint if lid closed / skip-flag set |
| `ru.toxblh.dozor.policy` | `/etc/polkit-1/actions/` | the polkit action (auth_self) |
| `extension/dozor@toxblh.ru/` | `~/.local/share/gnome-shell/extensions/` | disables Shell agent, `FocusApp` |
| `dozor.service` | `~/.config/systemd/user/` | autostarts the agent |
| `install.sh` | — | installs all of the above, migrates old names |

Runtime: agent D-Bus path `/ru/toxblh/DozorAgent`; per-request context (display
only) `/run/user/$UID/dozor.ctx`; fingerprint skip flag `/run/user/$UID/dozor-skip-fp`.

## Diagnose

Run the collector, then read it with the human:

```sh
./contrib/dozor-report.sh          # -> ./dozor-report.txt (redacted)
less ./dozor-report.txt            # read the >>> REVIEW lines together
```

Common failures and where they show:

- **No Dozor window, got the plain GNOME dialog** → the extension isn't enabled.
  `gnome-extensions info dozor@toxblh.ru` (State/Enabled). Wayland loads new
  extensions **only at login** — enabling needs a re-login, or the uuid in
  `gsettings get org.gnome.shell enabled-extensions`. Until the extension disables
  Shell's agent, `journalctl --user -u dozor.service` shows
  `An authentication agent already exists`.
- **`sudo` still asks in the terminal** → PAM hook not first in `/etc/pam.d/sudo`,
  or `dozor.service` not running, or no user D-Bus. Check the unit is `active`.
- **Agent crashes / no window on request** → `journalctl --user -u dozor.service`
  for a Python traceback. Reproduce UI in isolation: `python3 agent.py --demo`
  (fake data, no polkit) or `python3 agent.py --demo --demo-state fingerprint`.
- **Auth never succeeds** → `journalctl -u polkit` (needs privilege) around the
  attempt; `polkit-agent-helper-1` lines carry the PAM result.
- Test the real path without touching your login session:
  `python3 agent.py --test-pid $$` in one shell, then `sudo -k; sudo true` in it.
  (`sudo` caches credentials ~5 min — `sudo -k` before each retry.)

## Report a bug (Path A)

Only after the human approves the contents of `dozor-report.txt`. Pick **one**
destination the reporter has an account on (don't double-post) — the issue is
filed under *their* identity, which is the safe form of "no maintainer needed".
Prepend a sentence describing the symptom to the body.

**GitHub** (primary) — needs `gh` authenticated:

```sh
gh issue create --repo Toxblh/dozor --title "<short symptom>" \
  --body-file dozor-report.txt
```

**altlinux.space** (Forgejo mirror) — needs an ALS account and a Personal Access
Token with issue-write scope (https://altlinux.space/user/settings/applications):

```sh
ALS_TOKEN=...   # paste the PAT; do not commit it or echo it into shell history
python3 -c 'import json,sys; print(json.dumps({"title":sys.argv[1],"body":open(sys.argv[2]).read()}))' \
  "<short symptom>" dozor-report.txt |
curl --fail-with-body -sS -X POST \
  -H "Authorization: token $ALS_TOKEN" -H 'Content-Type: application/json' \
  --data @- https://altlinux.space/api/v1/repos/toxblh/dozor/issues
```

No account on either? **Do not** upload the logs anywhere anonymously. Hand the
human the reviewed `dozor-report.txt` and an issue URL
(https://github.com/Toxblh/dozor/issues or https://altlinux.space/toxblh/dozor/issues)
and let them submit it themselves.

## Fix it and open a PR (Path B)

Preferred when you can reproduce and the fix is small.

1. Reproduce, then read the code you're about to touch — the whole flow, not just
   the line in the trace. Fix at the root (one guard in the shared function beats
   one per caller).
2. Verify without a full auth cycle:
   - `python3 -c "import ast; ast.parse(open('agent.py').read())"` — it parses.
   - `python3 agent.py --demo[ --demo-state ...]` — the window renders.
   - `python3 agent.py --test-pid $$` + `sudo -k; sudo true` — the real path works.
3. Keep the diff minimal; match the surrounding style; comments/docstrings in the
   repo's language (mixed EN/RU is fine).
4. Fork, branch, commit, push, and:
   `gh pr create --repo Toxblh/dozor --title "..." --body "what & why, repro"`.
   Put only redacted, human-approved details in the PR description.

Remotes: `origin` = github.com/Toxblh/dozor, `als` =
altlinux.space/toxblh/dozor (Forgejo mirror). Prefer GitHub for PRs.
