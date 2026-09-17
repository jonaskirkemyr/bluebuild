# Setup and everyday tasks

Commands, in order. For *why* the setup is split the way it is, see [GETTING_STARTED.md](GETTING_STARTED.md).

## Set up a freshly installed machine

The image ships `ujust` recipes for all of this ([`files/justfiles/nix.just`](../files/justfiles/nix.just)), so there is nothing to copy-paste from a browser.

```bash
ujust setup-home-manager                 # clones nix-config, applies shell/prompt/dotfiles
ujust set-git-identity <username>        # name, email and signing key
ujust set-default-shell                  # switches your login shell to zsh
# log out and back in
```

That's it. After logging back in you have your zsh, starship prompt, aliases, git config, kitty config and CLI tools.

Run `ujust` with no arguments to see every recipe the image provides.

### There is no `setup-nix`

Nix is part of the image, from Fedora's own `nix` and `nix-daemon` RPMs. Nothing to install, no installer to download on first boot, and `nix` is `/usr/bin/nix` so it's on `PATH` in every shell without logging out and back in. `ujust check-nix` reports whether it's healthy.

The one piece that isn't obvious: `/nix` ships *inside* the image, and the image root is read-only ([composefs](https://github.com/containers/composefs)), so the store would be unwritable as shipped. A [`nix.mount`](../files/system/usr/lib/systemd/system/nix.mount) unit bind-mounts `/var/lib/nix` over it. Two consequences worth knowing:

- **The store survives `rpm-ostree rollback`.** `/var` is outside the image. Rolling the system back doesn't roll your Nix packages back — use `home-manager generations` for that.
- **`/var/lib/nix` is where the disk space goes.** `nix store gc` if it gets large.

### About `set-git-identity`

The `nix-config` repo is public and contains nothing identifying — no name, email or signing key. Those go in an untracked `~/.config/git/identity`, which this recipe writes for you from a GitHub username: it fetches `https://github.com/<username>.gpg` (the *public* half of your uploaded keys) and pulls the fingerprint, name and email out of it. Nothing is imported into your keyring.

It only enables `commit.gpgsign` if the matching **private** key is actually present — GitHub can't hand you one of those. So on a genuinely fresh machine:

```bash
gpg --import /path/to/your-secret-key-backup.asc
ujust set-git-identity <username>         # re-run; signing now turns on
```

## Everyday tasks

| I want to... | Do this |
|---|---|
| add/remove a system package, Flatpak or font | edit [`recipes/recipe.yml`](../recipes/recipe.yml), push, then `ujust update` on the machine |
| change my `.zshrc`, aliases, prompt, git config | edit `~/nix-config/home/home.nix`, then `home-manager switch --flake ~/nix-config#$USER` |
| change the KDE panel, its widgets, the clock, wallpaper or virtual desktops | edit `~/nix-config/home/plasma.nix`, `home-manager switch`, then log out and back in |
| pull my config changes from another machine | `ujust update-home-manager` |
| change my git name/email/signing key | `ujust set-git-identity <username>` |
| undo a bad Home Manager change | `home-manager generations`, then run the `activate` path of an older one |
| undo a bad image update | `rpm-ostree rollback && systemctl reboot` |
| give one project its own toolchain | see below |
| know whether something belongs in the image or in Nix | see the table at the bottom |

## Give a project its own toolchain

Two files in the project directory, then one command. Nothing global changes.

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { nixpkgs, ... }:
    let pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.nodejs_20 ];
      };
    };
}
```

```bash
# .envrc
use flake
```

```bash
direnv allow    # once per project
```

From then on, `cd` into the directory and `node` is 20; `cd` out and it's gone. A sibling project pinning `pkgs.nodejs_18` gets 18. Same for `pkgs.jdk21`, `pkgs.python312`, `pkgs.dotnet-sdk_9`, and so on — search names at [search.nixos.org/packages](https://search.nixos.org/packages).

`direnv` and `nix-direnv` (which caches the shells so activation is instant after the first build) come from your Home Manager config, so this works with no extra setup.

**VS Code:** launch it as `code .` from a terminal that's already inside the directory, so it inherits the dev shell. If you launch it from the KDE menu instead, install the [direnv extension](https://marketplace.visualstudio.com/items?itemName=mkhl.direnv) so it picks the environment up itself.

## Where does a given thing go?

| Thing | Goes in | Why |
|---|---|---|
| login shell binary (`zsh`) | `recipe.yml` (`dnf`) | `/etc/passwd` needs a system path, and Home Manager's zsh module installs no package |
| Nix itself, and the nix daemon | `recipe.yml` (`dnf`) | layer 2 can't bootstrap itself; and a shared store needs a system mount unit and system build users, which are not things a user config can create |
| `.zshrc`, aliases, prompt, git config, `kitty.conf` | `nix-config` (Home Manager) | changes often; no rebuild, no reboot |
| GUI apps that need GL or host toolchains (`kitty`, `code`) | `recipe.yml` (`dnf`) | must see the real drivers and the Nix store; a Flatpak sandbox can't |
| other GUI apps (Firefox, IntelliJ) | `recipe.yml` (`default-flatpaks`) | updates independently of the image, doesn't bloat it |
| CLI tools | `nix-config` (`home.packages`) | unless it needs a system path or GL, then `recipe.yml` |
| fonts | `recipe.yml` (`fonts`) | fontconfig should serve them to Flatpaks too |
| KDE panel layout, widgets (plasmoids), themes, shortcuts | `nix-config` (Home Manager + [plasma-manager](https://github.com/nix-community/plasma-manager)) | it's all `~/.config/plasma*` — per-user and changes often, so no rebuild and no reboot |
| a KDE widget or theme that must exist for *all* users, or on the SDDM login screen | `recipe.yml` (`dnf`) | plasma-manager is per-user and explicitly won't touch the login screen (that needs root) |
| Node 18 here, Node 24 there | `flake.nix` + `.envrc` in the project | the image has no per-directory concept; the recipe is global, always |
| a systemd unit or `/etc` file | `files/system/` in this repo | |
| system locale, keyboard layout, timezone | `recipe.yml` (`script` → [`system-defaults.sh`](../files/scripts/system-defaults.sh)) | otherwise `systemd-firstboot` asks for all three on the first boot of every fresh install |
| your actual data, backed up | a real backup tool | nothing here backs up `/home` |

## When something goes wrong

| Symptom | Fix |
|---|---|
| `home-manager switch` aborts: "would be clobbered" | it's refusing to overwrite an existing file — re-run with `-b bak` (the `ujust` recipe already does) |
| anything Nix-related | `ujust check-nix` first — it names which of the four parts (binary, store mount, daemon, home-manager) is missing |
| `ujust setup-nix`: unknown recipe | it's gone; Nix is built into the image. See ["There is no `setup-nix`"](#there-is-no-setup-nix) |
| `nix: command not found` | your image predates Nix being built in: `ujust update && systemctl reboot`. Unlike the old installer-based setup, logging out and back in is *not* part of the fix — `nix` is `/usr/bin/nix` |
| nix fails to build or install anything, "read-only file system" | the store mount didn't come up, so `/nix` is still the read-only copy from the image. `systemctl status nix-store-dir.service nix.mount` — the first creates `/var/lib/nix`, the second binds it onto `/nix` |
| `nix-daemon` won't start, or "cannot connect to socket" | it has `ConditionPathIsReadWrite=/nix/var/nix/daemon-socket`, so it *skips itself* when the store mount is missing rather than failing loudly. Fix the mount first, per the row above |
| `warning: 'nix' is not owned by nixbld` / permission errors in the store | `ls -land /nix/store` should be `1775 0 <nixbld gid>`. It's created by [`nix-store.conf`](../files/system/usr/lib/tmpfiles.d/nix-store.conf); `sudo systemd-tmpfiles --create --prefix=/nix` re-applies it |
| SELinux denials mentioning the store | store paths should be `default_t`, the same as on an ordinary Fedora install. Check with `ls -Zd /nix/store`; the equivalency that makes that work is set up by [`nix-store.sh`](../files/scripts/nix-store.sh) and lives in `/etc/selinux/targeted/contexts/files/file_contexts.subs` |
| `/var` is filling up | that's the Nix store at `/var/lib/nix`. `nix store gc` |
| edits to `~/.zshrc` keep vanishing | expected — Home Manager owns that file now. Edit `home/home.nix` and switch |
| new shell has no prompt/aliases | your login shell is still bash: `ujust set-default-shell` |
| git says "please tell me who you are" | `~/.config/git/identity` is missing: `ujust set-git-identity <username>` |
| `git commit` fails: "secret key not available" | the signing key in your identity file isn't in this keyring — `gpg --import` your backup, then re-run `set-git-identity` |
| Flatpaks missing after a fresh install | `default-flatpaks` installs on first boot, not at build time; give it a few minutes |
| first boot still asks for language/keyboard/timezone | the image is older than [`system-defaults.sh`](../files/scripts/system-defaults.sh), or one of `/etc/locale.conf`, `/etc/vconsole.conf`, `/etc/localtime` is missing — `systemd-firstboot` prompts for exactly the ones that aren't already set |
| want a different locale/layout/timezone on new installs | edit the three variables at the top of [`system-defaults.sh`](../files/scripts/system-defaults.sh) and push. On a machine that's already installed, use System Settings or `localectl`/`timedatectl` — `/etc` is a 3-way merge, so your local value wins over the image's |
| image update didn't take | `rpm-ostree status` — an update is *staged*, it applies on reboot |
| a rolled-back image still has broken tools | the Nix store lives outside the image, so `rpm-ostree rollback` doesn't touch it; use `home-manager generations` |
