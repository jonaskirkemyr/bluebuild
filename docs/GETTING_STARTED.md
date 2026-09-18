# Getting started

A practical guide to this repo for someone who has never used BlueBuild before.

- [The idea in one minute](#the-idea-in-one-minute)
- [What this repo does not do](#what-this-repo-does-not-do)
- [What's in this repo](#whats-in-this-repo)
- [The everyday loop: changing your OS](#the-everyday-loop-changing-your-os)
- [How and when the image gets built](#how-and-when-the-image-gets-built)
- [Installing the image on your machine](#installing-the-image-on-your-machine)
- [Staying updated, and rolling back](#staying-updated-and-rolling-back)
- [Testing locally before you push](#testing-locally-before-you-push)
- [When a build fails](#when-a-build-fails)
- [Signing keys](#signing-keys)
- [Gotchas](#gotchas)
- [Cheat sheet](#cheat-sheet)

## The idea in one minute

Your operating system is a **container image**, described by one file: [`recipes/recipe.yml`](../recipes/recipe.yml).

You never install software on the running machine. You edit the recipe, push it, GitHub Actions bakes a new image, and your machine pulls that image on its next update. If a build is broken, your machine keeps running the last good image. If an update is bad, you reboot into the previous one.

```
  edit recipes/recipe.yml
           │
           ▼
      git push ────► GitHub Actions build ────► ghcr.io/jonaskirkemyr/bluebuild:latest
                     (also nightly, 06:00 UTC)                    │
                                                                  ▼
                                                     your PC pulls it and stages it
                                                        (applied on next reboot)
```

Coming from Nix, the mental model maps closely: the recipe is your `configuration.nix`, GitHub Actions is your build, and the published image is your system closure. The differences that matter:

| Nix | Here |
|---|---|
| `nixos-rebuild switch` builds locally | GitHub builds for you; your PC only downloads |
| Generations, rollback via bootloader | Image deployments, rollback via `rpm-ostree rollback` |
| Per-user declarative home config | Still Home Manager's job, in a separate repo — see below |
| Per-directory `flake.nix` dev shells | Still flakes' job, in each project — `ujust create-flake <language>` writes the starter, see below |
| Fine-grained pinning of everything | You pin the base image; package versions come from Fedora repos |

That last row is the biggest adjustment. This setup is declarative about *what is installed*, not about *exact versions of everything*. Two builds of the same recipe a week apart will differ.

## What this repo does not do

This repo is **the system, and only the system**. Coming from Nix, where one config handled everything, the useful thing to internalise is that the setup now has four layers living in three places:

| Layer | Examples | Lives in | Changes |
|---|---|---|---|
| 1. System | kernel, KDE, RPMs, Flatpaks, fonts, `/etc` | **this repo** (`recipe.yml`) | rarely; on reboot |
| 2. User environment | `.zshrc`, prompt, git config, `kitty.conf`, CLI tools | `nix-config` repo (Home Manager) | often; on `home-manager switch` |
| 3. Per-project tools | "Node 18 here, Node 24 there" | a `flake.nix` + `.envrc` per project | constantly; on `cd` |
| 4. Data | `/home`, databases | a real backup tool | constantly |

Layers 2 and 3 cannot be done here, and pushing them in anyway is the main way people get frustrated with this model. An image is one image for the whole machine; there is no per-user or per-directory concept anywhere in it. Anything in `recipe.yml` is installed globally and present in every shell, always.

The image does, however, **bootstrap** layers 2 and 3 for you. Nix itself is layer 1 — it's installed from Fedora's RPMs in `recipe.yml`, because layer 2 cannot install the thing that runs layer 2 — and `ujust setup-home-manager` is baked in to do the rest. See [SETUP.md](SETUP.md) for the exact commands, and its bottom table for deciding which layer a given thing belongs to.

## What's in this repo

| Path | What it's for |
|---|---|
| `recipes/recipe.yml` | **The one file you'll edit most.** Base image, packages, flatpaks, modules. |
| `files/system/` | Files copied into the image's root filesystem. `files/system/etc/foo` lands at `/etc/foo`. |
| `files/dnf/` | `.repo` files and local `.rpm`s the `dnf` module can reference by filename. |
| `files/justfiles/` | `.just` files. The `justfiles` module bakes these in as `ujust` commands. |
| `files/scripts/` | Scripts you can invoke from the recipe's `script` module. |
| `modules/` | Only needed if you write your own custom BlueBuild module. Usually stays empty. |
| `.github/workflows/build.yml` | The CI build. Triggers, and which recipes to build. |
| `cosign.pub` | Public half of the image signing key. Committed on purpose. |
| `cosign.key` | **Private** half. Git-ignored. Never commit it. |

## The everyday loop: changing your OS

Edit the recipe, commit, push, wait for the build, then update your machine. Three examples covering nearly everything you'll want.

### Add a package from Fedora's repos

In the `dnf` module's `install.packages` list:

```yaml
  - type: dnf
    install:
      packages:
        - micro
        - zsh
        - ripgrep      # ← added
```

Package names are Fedora RPM names. Check one exists before pushing — a typo fails the whole build:

```bash
podman run --rm fedora:44 dnf -q info ripgrep
```

### Add a package from a third-party repo

VS Code is the worked example. Drop a `.repo` file in `files/dnf/`, add its signing key, then install the package by name:

```yaml
  - type: dnf
    repos:
      keys:
        - https://packages.microsoft.com/keys/microsoft.asc
      files:
        - vscode.repo        # resolves to files/dnf/vscode.repo
    install:
      packages:
        - code
```

Write the `.repo` file yourself rather than using a vendor-supplied one where you can — Microsoft's own `config.repo` ships `gpgcheck=0`, and [`files/dnf/vscode.repo`](../files/dnf/vscode.repo) turns it back on. For COPRs there's a shortcut: `repos.copr: [user/project]`, no file needed.

### Add a graphical app

Prefer Flatpaks for GUI apps — they update independently of the OS image and don't bloat it:

```yaml
  - type: default-flatpaks
    configurations:
      - notify: true
        scope: system
        install:
          - org.mozilla.firefox
          - org.kde.kdenlive     # ← added
```

These are Flathub application IDs. Find them on [flathub.org](https://flathub.org) — the ID is in the URL.

> Note: `default-flatpaks` installs these on first boot, not at build time. They appear a few minutes after you first boot a new image, not instantly.

The exception is apps that need to see the host: `kitty` and `code` are RPMs, not Flatpaks, because a sandboxed editor or terminal can't reach the Nix store or a project's direnv environment.

### Add a `ujust` command

Anything you'd otherwise write down as "run these commands after installing" belongs here instead. Add a recipe to a `.just` file in `files/justfiles/`:

```just
# Show what a new image would change
preview-update:
    rpm-ostree upgrade --preview
```

The `justfiles` module (already in the recipe) finds every `.just` file under that directory and imports it, so it becomes `ujust preview-update` on the machine. `validate: true` in the recipe fails the build on a syntax error, which is worth having. Check yours locally first:

```bash
podman run --rm -v "$PWD/files/justfiles":/w:Z fedora:44 \
  bash -c 'dnf -yq install just && just --justfile /w/nix.just --fmt --check --unstable'
```

[`files/justfiles/nix.just`](../files/justfiles/nix.just) is the real example: it's what makes `ujust setup-home-manager`, `ujust check-nix` and `ujust create-flake` work.

One trap worth knowing before writing a recipe that touches files: `ujust` only sets `JUST_JUSTFILE`, and `just` given a justfile but no `--working-directory` runs recipes from *the justfile's* directory. So `$PWD` in a recipe is `/usr/share/ublue-os`, not where the user typed the command, and this `just` doesn't export `INVOCATION_DIRECTORY` either. Use `{{ invocation_directory() }}` — that's what `create-flake` does.

### Ship a config file

Drop the file into `files/system/` mirroring its real path, e.g. `files/system/etc/sysctl.d/99-custom.conf` becomes `/etc/sysctl.d/99-custom.conf`. The `files` module at the top of the recipe already copies everything under `files/system/`, so no recipe change is needed.

Only for **system** config. Your own dotfiles (`~/.zshrc`, `~/.config/...`) are layer 2 and don't belong in the image — they live in the `nix-config` repo, see [SETUP.md](SETUP.md).

### Other modules

There's a module for most things: `rpm-ostree`, `brew`, `fonts`, `kargs` (kernel arguments), `justfiles`, `systemd`, `chezmoi`, and `containerfile` as an escape hatch for raw Dockerfile lines. Full list: [blue-build.org/reference/module](https://blue-build.org/reference/module/).

Modules run **in the order listed** in the recipe.

## How and when the image gets built

Yes — it really does rebuild every night. Four triggers, all in `.github/workflows/build.yml`:

| Trigger | When | Why |
|---|---|---|
| `schedule` | `00 06 * * *` — 06:00 UTC daily | Picks up upstream Fedora/Universal Blue updates. The base image is rebuilt daily too; this fires ~20 min later. |
| `push` | Any push except `**.md`-only changes | Your recipe changes get built. |
| `pull_request` | PRs | Validates a change without publishing to `latest`. |
| `workflow_dispatch` | Manual button in the Actions tab | Force a rebuild whenever. |

The nightly build is the point of the whole setup: **you get security updates without touching the recipe.** Your recipe pins Fedora 44, so nightly builds bring updated packages within F44, never a jump to F45.

Two things about GitHub's scheduler worth knowing up front:

- **Scheduled workflows are disabled after 60 days of repository inactivity.** GitHub emails you first. If nightly builds silently stop, this is usually why — push any commit, or press the manual button, to re-enable.
- Scheduled runs are best-effort and only run on the **default branch**. A 06:00 job can land noticeably late during GitHub's peak load.

Watch builds in the repo's **Actions** tab. A green run publishes to `ghcr.io/jonaskirkemyr/bluebuild`; see the repo's **Packages** section for the exact tags produced.

## Installing the image on your machine

One-time, from an existing Fedora Atomic (Kinoite/Silverblue) install. Full commands are in the [README](../README.md#installation); the shape is:

1. Rebase to the **unsigned** ref first. This is not optional — it's what installs the signing policy that makes step 2 possible.
2. Reboot.
3. Rebase to the **signed** ref.
4. Reboot.

If you're not on Fedora Atomic yet, install [Fedora Kinoite](https://fedoraproject.org/kinoite/) first, or generate an installer ISO ([docs](https://blue-build.org/how-to/generate-iso/)).

> This base image is `bootc`-based, so the newer `bootc` commands work alongside `rpm-ostree`. `rpm-ostree` is what the README uses and is still fully supported; run `bootc --help` if you want to explore the newer path.

## Staying updated, and rolling back

**Updates are already automatic.** The Universal Blue base enables these for you — no setup:

- `rpm-ostreed-automatic.timer` — downloads and *stages* new OS images
- `flatpak-system-update.timer` and the per-user equivalent — update Flatpaks

Staged means the new image is downloaded and ready, but **applied on your next reboot**. So a recipe change reaches you after: CI build (~5–15 min) → your machine's next update check → your next reboot.

To not wait:

```bash
rpm-ostree upgrade        # fetch now
systemctl reboot          # apply
rpm-ostree status         # what's booted, what's staged
```

Broke something? Reboot into the previous deployment:

```bash
rpm-ostree rollback
systemctl reboot
```

The previous image stays on disk, so this works even with no network. This is your safety net — it's why an adventurous recipe change is low-risk.

The base image also ships `ujust`, a collection of maintenance shortcuts. Run `ujust` with no arguments to list what's available on your system.

## Testing locally before you push

A CI round-trip is 5–15 minutes, so for anything non-trivial, build locally first. Install the CLI:

```bash
podman run --pull always --rm ghcr.io/blue-build/cli:latest-installer | bash
```

Then:

```bash
bluebuild generate ./recipes/recipe.yml -o Containerfile   # inspect what it would do
bluebuild build ./recipes/recipe.yml                       # actually build it
bluebuild switch ./recipes/recipe.yml                      # build + rebase this machine onto it
```

`bluebuild build` is the same command CI runs, so if it passes locally it will almost certainly pass in CI. This is the fastest way to catch a mistyped package name.

## When a build fails

1. Open the **Actions** tab, click the red run, expand the failed step.
2. Scroll to the **first** error, not the last. Later errors are usually fallout.

The failures you're most likely to hit:

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to find private/public key pair` | `SIGNING_SECRET` missing, or added as an *environment* secret instead of a *repository* secret | See [Signing keys](#signing-keys) |
| `No match for argument: <package>` | Package name typo, or it isn't in Fedora's repos | Verify with the `dnf info` command above |
| Error removing a package | The recipe removes a package the base image doesn't have | Check with `rpm -q <package>` on a booted image before adding it to `remove:` |
| Flatpak ID not found | Wrong application ID | Copy the exact ID from flathub.org |
| Nightly builds stopped happening | 60-day inactivity rule | Push a commit or run the workflow manually |

A failed build publishes nothing, so your machine is unaffected. Fix and push again.

## Signing keys

Images are signed so your machine can verify it's pulling *your* image and not something substituted. Two pieces must agree:

- `cosign.pub` — committed to this repo
- `SIGNING_SECRET` — a **repository** secret in GitHub Settings → Secrets and variables → Actions, containing the contents of `cosign.key`

> GitHub only exposes *environment* secrets to jobs that declare `environment:` in the workflow. This workflow doesn't, so the key must be a **repository** secret or the build fails with the key-pair error.

If they ever get out of sync, or the private key leaks, regenerate both:

```bash
podman run --rm --user 0 -e COSIGN_PASSWORD="" -v "$PWD":/workdir:Z -w /workdir \
  gcr.io/projectsigstore/cosign:latest generate-key-pair
gh secret set SIGNING_SECRET --repo jonaskirkemyr/bluebuild < cosign.key
git add cosign.pub && git commit -m "Rotate cosign key"
```

Both halves must ship together — a new secret with an old committed `cosign.pub` won't verify.

Keep a backup of `cosign.key` somewhere safe (a password manager). It's git-ignored via `.gitignore` and must stay that way.

## Gotchas

- **GHCR packages start private, even on a public repo.** After your first successful build, open the package in the repo's Packages section and set its visibility to public — otherwise your machine can't pull it without credentials.
- **Removing a package that isn't installed fails the build.** Always `rpm -q` it first.
- **The recipe is not a full system description.** User-level config, `~/.config`, and anything in `/var` (including `/home`) are outside the image. Don't expect Nix-level totality.
- **Don't layer packages with `rpm-ostree install` on the running machine.** It works, but it's exactly the drift this setup exists to prevent. Put it in the recipe instead.
- **Changes only take effect after a reboot.** There's no `switch`-without-reboot equivalent.
- **A `.md`-only change won't trigger a build** (`paths-ignore` in the workflow). That's deliberate.

## Cheat sheet

```bash
# --- on your machine ---
rpm-ostree status                 # what's booted and what's staged
rpm-ostree upgrade                # pull the newest image now
systemctl reboot                  # apply a staged update
rpm-ostree rollback               # go back to the previous image
rpm -q <package>                  # is this package in my image?
ujust                             # list every shortcut, mine and Universal Blue's
ujust check-nix                   # is the image's Nix healthy? (store mount, daemon)
ujust setup-home-manager          # clone + apply the nix-config repo (once)
ujust update-home-manager         # pull + re-apply it (day to day)
ujust create-flake <language>     # drop a dev shell into this project (csharp/java/kotlin/nodejs)
ujust set-git-identity <username> # write ~/.config/git/identity from GitHub
ujust set-default-shell           # switch login shell to zsh

# --- in this repo ---
bluebuild build ./recipes/recipe.yml     # test the recipe locally
bluebuild generate ./recipes/recipe.yml  # preview the generated Containerfile
gh run list                              # recent CI builds
gh run watch                             # follow the current build
```

## Where to read more

- [BlueBuild docs](https://blue-build.org/) — especially [Mindset](https://blue-build.org/learn/mindset/) and [Troubleshooting](https://blue-build.org/learn/troubleshooting/)
- [Module reference](https://blue-build.org/reference/module/) — every available module
- [Universal Blue](https://universal-blue.org/) — the project behind the base image
