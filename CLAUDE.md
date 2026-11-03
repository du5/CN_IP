# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A generator and deployer for `CN.txt`, a list of IPv4 CIDR blocks geolocated to China (ISO code `CN`). There are two independent halves:

1. **Generator** (`main.go`): a Go program that walks a GeoLite2 country database and writes the aggregated CIDR list to `CN.txt`.
2. **Deployer** (`cn-firewall.sh`): a root-only bash script for Debian/Ubuntu servers that downloads the published `CN.txt`, loads it into an `ipset`, and wires it into `iptables` in either `accept` or `block` mode.

Only `CN.txt` and the deploy script are tracked in git. The Go sources (`main.go`, `go.mod`, `go.sum`) are currently untracked. Commit messages are written in Chinese.

`README.md` is the user-facing documentation, in Chinese first and English second in the same file. When the script's modes, environment variables, cron behavior, or the generator's refresh rule change, update both language sections.

## Commands

```sh
go build -o CN_IP .      # build the generator binary
go run .                 # regenerate CN.txt (takes ~1s plus the one-time database download)
```

There are no tests and no linter config. Go 1.26+ is required.

## Generator architecture (`main.go`)

- `GeoLite2-Country.mmdb` is downloaded from `github.com/du5/geoip` when it is missing locally or its modification time is older than 6 hours (`geoIPMaxAge`), and is kept afterwards (it is gitignored). Delete the file or `touch` it into the past to force a fresh download. That repo stores the file in Git LFS, so the URL must go through `github.com/.../raw/...`; `raw.githubusercontent.com` returns an LFS pointer, which the download step rejects.
- The generator walks the database's own prefix tree with `db.NetworksWithin(0.0.0.0/0)` (roughly 570k networks) and decodes the country code once per network. It does **not** look up individual addresses; do not reintroduce a per-IP scan.
- Every `CN` network is added to a `netipx.IPSetBuilder`. `IPSet.Prefixes()` does the aggregation, so the output is the minimal set of CIDRs covering the matched networks. Do not hand-aggregate.
- `countryCode` prefers `country.iso_code` and falls back to `registered_country.iso_code` when the first is empty. Changing this fallback changes which addresses count as China.
- Output format is one CIDR per line, newline-terminated, no comments. The deploy scripts parse this format strictly (one field per line, `#` comments and blank lines tolerated).

## Deploy script (`cn-firewall.sh`)

Subcommands: `setup` (once per machine), `accept`, `block`. There is no Linux here, so changes were validated with fake `iptables`/`ipset`/`wget`/`crontab` stubs; test on a real Debian box before relying on a change.

- `setup` installs ipset, iptables, wget, cron, `netfilter-persistent` and `ipset-persistent`. The last one matters: its `10-ipset` plugin restores `/etc/iptables/ipsets` before the iptables rules at boot, so rules that reference the set can load. `accept`/`block` refuse to run if that plugin is missing.
- `accept`/`block` fetch `CN.txt` over HTTPS from `git.affcm.com`, not from this checkout. Pushing a new `CN.txt` to that host is what actually updates servers. The script keeps its last applied copy at `CN.txt` next to itself and compares SHA-256; an unchanged list with the mode already active exits early without touching anything.
- The set is rebuilt into a temporary `hash:net` ipset, the entry count is verified with `ipset list -t`, then `ipset swap` replaces `cn_ipv4_list` atomically. The set is also rebuilt when it is missing (for example after a failed boot restore) even if the list is unchanged.
- Each mode owns one chain (`CN_IPV4_ACCEPT` or `CN_IPV4_BLOCK`). The chain is only rebuilt when `iptables -C` shows a rule is missing or the rule count differs, so routine runs never flush it. Rebuilding still has a brief empty-chain window; it happens on first run and when the rule set changes (for example a new SSH port).
- Mode switches are gap-free: the new chain is built first, its jump is inserted at `INPUT` position 1, and only then are duplicate jumps and the other mode's jump deleted (from the bottom up) and the other chain removed. The `INPUT` default policy is set last (`DROP` for accept, `ACCEPT` for block).
- `accept` always allows loopback, established/related traffic, and TCP to the SSH ports read from `sshd -T` (override with `SSH_PORTS="22 2222"`, fallback 22). `block` has no SSH exception by design.
- Persistence runs through `netfilter-persistent save` only when something changed. An hourly crontab entry is installed for the current mode, pointing at the script's resolved path and logging to `/var/log/cn-firewall.log`; old `accept.sh`/`block.sh` entries are replaced.
- Variables followed directly by a Chinese full-width character must be written as `${VAR}`; bash otherwise swallows the first byte of the character into the variable name.

## Stray files

`2`, `48`, and the `CN_IP` binary in the repo root are untracked local artifacts unrelated to the project logic. Ignore them.
