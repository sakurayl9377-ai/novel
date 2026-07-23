# Game service control

The backend exposes a read-only game catalog and authenticated administrator
operations for the fixed `bailian` and `modao` service groups.

## API

- `GET /games/catalog` is read-only and returns only visible, fixed catalog
  entries. A controllable game is returned only while its complete service
  group reports `running` and active; status errors and timeouts fail closed.
  The public response never returns service names, commands, or launch URLs.
- `GET /admin/games/control` requires an active administrator bearer session
  and returns the fixed catalog plus live aggregate systemd state.
- `PATCH /admin/games/control/:id/visibility` accepts
  `{"visible":true|false}`. An external game cannot be shown unless every
  service unit is running.
- `POST /admin/games/control/:id/action` accepts only
  `{"action":"start"|"stop"|"restart"}`.

The initial catalog shows `horse-race` and `modao`; `bailian` starts hidden.
Unknown game IDs, routes, service names, and actions are rejected.

## Installation

Install the root-owned helper on the same host as the game services:

```bash
sudo NOVEL_BACKEND_USER=ubuntu \
  bash backend/scripts/install-game-service-control.sh
```

The installer creates:

- `/usr/local/sbin/novel-game-service-control`, owned by `root:root`, mode
  `0755`;
- `/etc/sudoers.d/ubuntu-novel-game-service-control`, owned by `root:root`,
  mode `0440`.

The installer stages both files, backs up any existing installation, and
validates status access for both fixed service groups. A failed validation or
interrupted install restores the previous helper and sudoers file; a failed
first install removes the new files.

The Node process never supplies a systemd unit name or shell command. It can
only invoke the helper with one fixed game ID and one of `status`, `start`,
`stop`, or `restart`. The helper repeats both whitelist checks and maps the
game ID to fixed systemd units.

Before enabling the administrator UI, verify:

```bash
sudo -u ubuntu sudo -n \
  /usr/local/sbin/novel-game-service-control modao status
sudo -u ubuntu sudo -n \
  /usr/local/sbin/novel-game-service-control bailian status
```

Stopping a game through the API also hides it from the App catalog. Starting a
game does not publish it automatically; an administrator must verify the
service and explicitly enable its visibility. The API rejects attempts to show
an external game unless every unit in its fixed service group is running.
Mutating service actions are serialized by a root-owned lock under `/run/lock`.
`start` enables the fixed units and starts them immediately; `stop` stops and
disables them so a host reboot cannot silently reopen a game that remains
under maintenance. `restart` preserves the existing boot policy.

`deploy-production.sh` installs the helper before switching the active backend
release and includes both files in its normal tool rollback. When adding this
support to a server whose installed `/usr/local/sbin/novel-backend-deploy` is
older, bootstrap the new deploy helper first: a running old deploy script only
self-updates near the end of that deployment and cannot execute logic that was
added to the new copy during the same run.
