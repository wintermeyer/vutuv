# Server status

`/system/status` (`VutuvWeb.ServerStatusLive`) shows how the servers behind an
installation are doing: one card per machine with its processor and a cell per
core, memory, disks, uptime and graphics cards. It is public and linked from
the footer of every page. Operator settings are in [ADMINS.md](../ADMINS.md)
(`SERVER_STATUS`, `SERVER_STATUS_HOSTS`, `SERVER_STATUS_GPU_HOSTS`).

## Where the numbers come from

`Vutuv.ServerStatus.Sampler` reads every configured source every ten seconds
and writes one reading per server into an ETS table. The LiveView reads only
that table, on the same beat, so a crowd of viewers costs the servers what one
does.

- **This machine** (`Vutuv.ServerStatus.Local`): `/proc/stat`, `/proc/meminfo`,
  `/proc/loadavg`, `/proc/uptime`, `/proc/cpuinfo`, `/etc/os-release` and
  `df -kP`. No exporter needed, so a one-server installation has a working page
  with no setup. On a Mac the `/proc` half is missing and the card shows cores
  and disks only.
- **Other machines** (`Vutuv.ServerStatus.Remote`): the text page of their
  Prometheus `node_exporter`, plus `nvidia_gpu_exporter` for graphics cards.

Both produce the same raw reading. CPU time is a counter, so a percentage
needs two readings; the first has none, and the second follows a second later.
The sparkline history lives in the sampler's memory only: a deploy starts it
empty and it refills within its fifteen minutes.

## What it never shows

Servers are named by number, never by host or address, and disks are one total
per server rather than a list of mount points. The kernel version is not read
either. All three would tell an attacker where to look, and none of them helps
a visitor. Tests assert that the host name in an exporter's `node_uname_info`
and the mount points never reach the page.
