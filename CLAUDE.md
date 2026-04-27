# BakerOS — CLAUDE.md

## What this repo is

Personal Arch Linux fleet tooling for the "baker" family of machines. Every machine starts from a live ISO and runs through three scripts in sequence to reach a fully configured desktop.

GitHub: `github.com/Dequavis-Fitzgerald-III/baker`

---

## The Fleet

All machines run Arch Linux. Tailnet name: **circus-tent**.

| Hostname | Role |
|---|---|
| nomadbaker | Laptop |
| pearlybaker | Desktop (full GPU) |
| ringbaker | Future home server (USA) — not yet built |

---

## Script Flow

```
install.sh  →  (reboot)  →  post-install.sh  →  (reboot)  →  post-reboot.sh
```

### `install.sh`
Run from the Arch live ISO as root. Interactive questions upfront (profile, hostname, CPU/GPU, timezone, disk, dual boot, LUKS, dotfiles repo), then fully unattended from the confirmation onwards.

Sections:
1. Interactive questions
2. Partitioning (GPT, EFI + root, LUKS optional)
3. LUKS setup (luks2, opens as `cryptroot`)
4. Format + mount
5. `pacstrap` — base packages, profile-specific packages (workstation/laptop), GPU drivers
6. `fstab` generation (+ optional secondary HDD entry)
7. `arch-chroot` configuration: timezone, locale, hostname, users, sudo, mkinitcpio hooks, GRUB, systemd services, sshd hardening drop-in
8. Downloads `post-install.sh` + `post-reboot.sh` from the repo and writes `.install-config`

Key design decisions:
- EFI mounted at `/boot` (single boot) or `/boot/efi` (dual boot) to avoid clobbering the Windows bootloader
- `kms` hook excluded from mkinitcpio when GPU is Nvidia (avoids black screen)
- `sshd` hardened from first boot via `/etc/ssh/sshd_config.d/99-baker.conf` (key-only auth, no passwords)

### `post-install.sh`
Run as the regular user after first boot. Reads `.install-config` written by `install.sh`.

Sections:
1. Network check (auto-wifi on laptop using saved credentials)
2. Install `yay` (AUR helper)
3. AUR packages: `google-chrome`, `nordvpn-bin`, `jetbrains-toolbox`
4. Chrome flags (disable keyring prompt)
5. Flatpak packages: `com.spotify.Client`
6. Home directory setup: clone `baker` + dotfiles repos over HTTPS, symlink dotfiles
7. NordVPN group + service setup
8. Locale/timezone confirmation via `localectl`/`timedatectl`
9. Services: NetworkManager, sddm, ufw, pipewire (user), laptop extras
10. SSH: generate ed25519 keypair, add to GitHub, configure git SSH rewrite, register key in `baker/keys/`, rebuild `authorized_keys` + `~/.ssh/config`, commit + push key to repo

Self-deletes on completion, then reboots.

### `post-reboot.sh`
Short final script run after the post-install reboot.

1. Tailscale login (`tailscale up`, browser flow) — must happen before NordVPN connects, otherwise NordLynx captures the default route and breaks the Tailscale auth browser flow.
2. NordVPN login (browser flow) + set autoconnect (us). No killswitch — NordLynx (WireGuard) + Tailscale (WireGuard) conflict at the routing level and the killswitch breaks Tailscale entirely.
3. `.bashrc` additions: `WORKON_HOME`, todo checklist hook
4. Writes `~/.todo` with remaining manual steps

Self-deletes on completion.

---

## Key Registry — `keys/`

`keys/` is the fleet's SSH public key registry. Each install copies `~/.ssh/id_ed25519.pub` to `keys/<hostname>.pub` and commits + pushes it.

`authorized_keys` and `~/.ssh/config` are rebuilt from whatever `.pub` files exist in the directory — the machine list is derived from the repo, not hardcoded anywhere.

`~/.ssh/config` uses Tailscale MagicDNS short names (`Hostname nomadbaker`) so SSH across the fleet works once Tailscale is up, without any further config.

### `sync-baker-keys.sh`
Run on existing machines when a new machine joins. Pulls the repo and rebuilds `authorized_keys` + `~/.ssh/config`.

---

## Stack

| Tool | Purpose |
|---|---|
| Hyprland | Wayland compositor |
| sddm | Display manager |
| waybar | Status bar |
| kitty | Terminal |
| rofi-wayland | App launcher |
| pipewire | Audio |
| NetworkManager | Networking |
| Tailscale | VPN mesh / MagicDNS (circus-tent tailnet) |
| NordVPN | Privacy VPN (killswitch + autoconnect us) |
| ufw | Firewall (deny incoming, allow outgoing) |
| ollama | Local LLM inference (workstation only) |
| yay | AUR helper |

---

## Known Issues / Future Work

- **ringbaker** — home server not yet built. When it joins the fleet it will need its own profile in `install.sh` (server profile: no desktop packages, no NordVPN — Tailscale-only).
- **`TEMP_JARVIS_DEV_SETUP.md`** — temporary file for Jarvis AI project dev environment setup on nomadbaker. Delete when Jarvis moves to the server.

## Network DNS Notes

Some networks (confirmed: Newcastle University) block Tailscale's domains (`login.tailscale.com`, `controlplane.tailscale.com`) at the DNS level. Symptoms:
- `tailscale up` browser auth page fails to load (`ERR_NAME_NOT_RESOLVED`)
- Tailscale health warning: "hasn't received a network map from the coordination server"
- Chicken-and-egg on machines already using Tailscale MagicDNS (`100.100.100.100`) as their DNS — Tailscale DNS goes down when Tailscale loses the control server

`post-reboot.sh` handles this automatically by testing DNS resolution before `tailscale up` and overriding to `8.8.8.8` if needed. On an existing machine, manual fix: `echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf && sudo systemctl restart tailscaled`.

---

## Conventions

- Explain everything: before running any command or making any change, explain what it does in plain terms. Never assume prior knowledge of a tool, flag, or concept.
- One section at a time: explain the change, then write it, so each step can be reviewed before continuing.
- No co-author lines in git commits.
- Commit messages: conventional commits style (`feat:`, `fix:`, `refactor:` etc.).
- All scripts use `set -e` and the same colour/logging helpers (`info`, `success`, `warn`, `error`, `section`).
- HTTPS for all clones in `post-install.sh` (no SSH key needed yet); git URL rewrite configured at the end of Section 10 so everything switches to SSH after that.

## Fix Workflow

When making a fix, follow this sequence:

1. **Read the docs** — understand the relevant man pages, upstream docs, or Arch Wiki before touching anything.
2. **Explain the fix** — describe what's changing and why before writing it, so it can be reviewed and understood fully.
3. **Make the fix** — same rules as always: `set -e`, colour helpers, conventional commit style, one section at a time.
4. **Commit and push** — descriptive conventional commit message; no co-author lines.
5. **Update context** — if the fix changes how something works, update `CLAUDE.md` to reflect it. If the session surfaced useful context that doesn't belong in `CLAUDE.md`, capture it in a dev notes file.
