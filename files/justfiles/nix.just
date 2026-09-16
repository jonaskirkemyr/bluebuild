# Recipes for the Nix half of this workstation: the Home Manager config that
# owns your shell, prompt and dotfiles, and the Nix that per-project dev shells
# need. Run `ujust` with no arguments to list every recipe.
#
# These are baked into the image by the `justfiles` module in recipes/recipe.yml,
# so a freshly-installed machine has them available immediately.

nix_config_repo := "https://github.com/jonaskirkemyr/nix-config.git"
nix_config_dir := "nix-config"
hm_release := "release-25.11"
# no username here: the flake exposes one homeConfiguration per login name and
# these recipes select "$USER" at runtime, so the image is not tied to one user
# must match the `programs.git.includes` path in the nix-config repo
identity_file := ".config/git/identity"

# Where the Determinate installer puts Nix, regardless of what PATH says.
#
# This matters because `just` runs every recipe in a fresh *non-login,
# non-interactive* bash. The installer only makes Nix visible to login shells:
# it appends a line sourcing nix-daemon.sh to the shell profile files
# (`/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`, hardcoded as
# PROFILE_NIX_FILE_SHELL in nix-installer). So `command -v nix` inside a recipe
# reports nothing on a perfectly good install until the login shell has re-read
# its profile — which is what "log out and back in" was working around.
#
# The recipes below source that file themselves instead, so they work the moment
# `setup-nix` finishes and do not care how the terminal was started.
nix_profile := "/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
nix_bin := "/nix/var/nix/profiles/default/bin"

# Install Nix (Determinate Systems installer: handles ostree and SELinux)
setup-nix:
    #!/usr/bin/env bash
    set -euo pipefail
    # test the install location, not PATH. `command -v nix` here would miss an
    # existing install and re-run the installer, which then aborts on its own
    # pre-flight check — with the confusing result that installing "twice" leaves
    # you no better off.
    if [[ -x "{{ nix_bin }}/nix" ]]; then
        echo "Nix is already installed: $("{{ nix_bin }}/nix" --version)"
        echo "If 'nix' is not on your PATH, that is a shell-profile issue, not a"
        echo "missing install — the ujust recipes do not care either way."
        exit 0
    fi
    # nix-installer's ostree planner refuses to run without these two, with
    # "Unable to install on an SELinux system without common SELinux tooling".
    # Checking first turns that into something you can act on.
    for BIN in restorecon semodule; do
        if ! command -v "$BIN" >/dev/null 2>&1; then
            echo "Missing '$BIN', which the installer requires on an SELinux system." >&2
            echo "Add policycoreutils to the dnf module in recipes/recipe.yml." >&2
            exit 1
        fi
    done

    # Download to a file rather than `curl | sh`. Piped, -f suppresses the HTTP
    # error body and -s the progress meter, so a proxy or a TLS middlebox
    # produces *no output at all* — just a bare non-zero exit from the recipe.
    # This is also why the installer gets a real stdin below: piped into `sh -s`
    # it has to prompt for confirmation on a stdin that is already at EOF.
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    echo "Fetching the Determinate Nix installer."
    set +e
    curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/install.sh" \
        https://install.determinate.systems/nix
    RC=$?
    set -e
    if [[ "$RC" -ne 0 ]]; then
        echo >&2
        echo "Could not download the installer: curl exit $RC." >&2
        case "$RC" in
            60) echo "That is a TLS certificate failure, usually a corporate proxy" >&2
                echo "re-signing HTTPS. Install the CA it uses into" >&2
                echo "/etc/pki/ca-trust/source/anchors/ and run 'sudo update-ca-trust'." >&2 ;;
            6)  echo "That is a DNS failure — the hostname did not resolve." >&2 ;;
            7|28) echo "That is a connection failure or timeout — check the network." >&2 ;;
        esac
        exit 1
    fi

    # `install ostree` — naming the planner instead of letting it be detected.
    #
    # nix-installer's auto-detection is a heuristic that has to succeed:
    #
    #     let is_ostree = Command::new("ostree").arg("remote").arg("list")
    #         .output().is_ok_and(|output| output.status.success());
    #     if is_ostree { ... } else { Linux planner }
    #
    # Anything that makes `ostree remote list` exit non-zero — the binary not on
    # PATH, no remotes configured, a bootc-based image — falls through to the
    # planner for *mutable* Linux, which does `mkdir /nix` on the read-only ostree
    # root. That fails with EROFS, and because the rollback path then also tries to
    # write /nix/receipt.json, the last thing on screen is a confusing
    # "Error saving receipt: read-only filesystem".
    #
    # This image is always Fedora Atomic, so the planner is never in doubt. It
    # creates /var/home/nix and bind-mounts it on /nix via a nix.mount unit.
    echo "Installing Nix. You will be asked for your password."
    sh "$TMP/install.sh" install ostree
    echo
    echo "Done. Next:"
    echo "    ujust setup-home-manager"
    echo
    echo "Log out and back in as well, so 'nix' is on your own PATH interactively."

# Clone the Home Manager config and apply it (first run on a new machine)
setup-home-manager:
    #!/usr/bin/env bash
    set -euo pipefail
    # nix-daemon.sh reads variables it has not set, so -u has to come off for it
    if [[ -e "{{ nix_profile }}" ]]; then
        set +u
        . "{{ nix_profile }}"
        set -u
    fi
    export PATH="$HOME/.nix-profile/bin:{{ nix_bin }}:$PATH"
    if ! command -v nix >/dev/null 2>&1; then
        echo "Nix not found at {{ nix_bin }}/nix. Run 'ujust setup-nix' first." >&2
        echo >&2
        echo "If you have already run it, check what the installer left behind:" >&2
        echo "    ls -l {{ nix_bin }}/nix" >&2
        echo "    systemctl status nix.mount nix-daemon.socket" >&2
        exit 1
    fi
    DIR="$HOME/{{ nix_config_dir }}"
    if [[ -d "$DIR/.git" ]]; then
        echo "$DIR already exists; pulling instead of cloning."
        git -C "$DIR" pull --ff-only
    else
        git clone {{ nix_config_repo }} "$DIR"
    fi
    cd "$DIR"
    # The flake has one homeConfiguration per login name. Check ours is among
    # them before switching: otherwise nix fails with a wall of trace, when the
    # fix is one word in flake.nix. attrNames does not force the values, so this
    # is a cheap eval, not a build.
    KNOWN="$(nix eval --raw ".#homeConfigurations" \
        --apply 'a: builtins.concatStringsSep " " (builtins.attrNames a)' 2>/dev/null || true)"
    FOUND=0
    for NAME in $KNOWN; do
        [[ "$NAME" == "$USER" ]] && FOUND=1
    done
    if [[ -n "$KNOWN" && "$FOUND" -eq 0 ]]; then
        echo >&2
        echo "This config has no entry for the user '$USER'." >&2
        echo "It knows about: $KNOWN" >&2
        echo >&2
        echo "Add '$USER' to the 'users' list in $DIR/flake.nix, commit and push," >&2
        echo "then re-run this recipe." >&2
        exit 1
    fi
    # -b bak so a pre-existing ~/.zshrc is moved aside instead of aborting.
    if command -v home-manager >/dev/null 2>&1; then
        home-manager switch --flake ".#$USER" -b bak
    else
        nix run "home-manager/{{ hm_release }}" -- switch --flake ".#$USER" -b bak
    fi
    echo
    echo "Applied. Two things left to do once, if you have not already:"
    echo "    ujust set-git-identity     # name, email and signing key"
    echo "    ujust set-default-shell    # switch your login shell to zsh"

# Pull the latest Home Manager config and re-apply it (day to day)
update-home-manager:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -e "{{ nix_profile }}" ]]; then
        set +u
        . "{{ nix_profile }}"
        set -u
    fi
    export PATH="$HOME/.nix-profile/bin:{{ nix_bin }}:$PATH"
    DIR="$HOME/{{ nix_config_dir }}"
    if [[ ! -d "$DIR/.git" ]]; then
        echo "$DIR not found. Run 'ujust setup-home-manager' first."
        exit 1
    fi
    git -C "$DIR" pull --ff-only
    # home-manager installs itself into the user profile, which the system-wide
    # nix-daemon.sh does not add to PATH in a non-login shell
    if command -v home-manager >/dev/null 2>&1; then
        home-manager switch --flake "$DIR#$USER"
    else
        nix run "home-manager/{{ hm_release }}" -- switch --flake "$DIR#$USER"
    fi

# Make zsh your login shell (the base image ships no chsh)
set-default-shell:
    #!/usr/bin/env bash
    set -euo pipefail
    CURRENT="$(getent passwd "$USER" | cut -d: -f7)"
    if [[ "$CURRENT" == "/usr/bin/zsh" ]]; then
        echo "Login shell is already /usr/bin/zsh."
        exit 0
    fi
    echo "Changing login shell from $CURRENT to /usr/bin/zsh."
    sudo usermod -s /usr/bin/zsh "$USER"
    echo "Done. Log out and back in."

# Write ~/.config/git/identity, reading name/email/key from a GitHub profile
set-git-identity github_user="":
    #!/usr/bin/env bash
    set -euo pipefail

    IDENTITY="$HOME/{{ identity_file }}"

    GH_USER="{{ github_user }}"
    if [[ -z "$GH_USER" ]]; then
        read -r -p "GitHub username: " GH_USER
    fi
    if [[ -z "$GH_USER" ]]; then
        echo "No username given, nothing to do." >&2
        exit 1
    fi

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    # GitHub serves every public key a user has uploaded at <user>.gpg. That is
    # the *public* half only, which is all we need: it carries the fingerprint
    # for user.signingkey plus the name and email from the key's UID.
    echo "Fetching https://github.com/$GH_USER.gpg"
    if ! curl -fsSL "https://github.com/$GH_USER.gpg" -o "$TMP/keys.asc" || [[ ! -s "$TMP/keys.asc" ]]; then
        echo >&2
        echo "No published GPG keys for '$GH_USER' (or the fetch failed)." >&2
        echo "Upload one at https://github.com/settings/keys, or write the file by hand:" >&2
        echo "    $IDENTITY" >&2
        exit 1
    fi

    # --show-keys parses without touching your keyring.
    FPRS=()
    UIDS=()
    WANT_FPR=0
    HAVE_KEY=0
    while IFS= read -r REC; do
        case "${REC%%:*}" in
            pub)
                WANT_FPR=1
                HAVE_KEY=0
                ;;
            fpr)
                if [[ "$WANT_FPR" -eq 1 ]]; then
                    FPRS+=("$(cut -d: -f10 <<<"$REC")")
                    UIDS+=("")
                    WANT_FPR=0
                    HAVE_KEY=1
                fi
                ;;
            uid)
                # Only the first UID of each key; gpg escapes colons as \x3a.
                if [[ "$HAVE_KEY" -eq 1 && -z "${UIDS[-1]}" ]]; then
                    UIDS[-1]="$(cut -d: -f10 <<<"$REC" | sed 's/\\x3a/:/g')"
                fi
                ;;
        esac
    done < <(gpg --show-keys --with-colons "$TMP/keys.asc" 2>/dev/null)

    if [[ "${#FPRS[@]}" -eq 0 ]]; then
        echo "Could not parse any keys out of GitHub's response." >&2
        exit 1
    fi

    PICKED=0
    if [[ "${#FPRS[@]}" -gt 1 ]]; then
        echo
        echo "$GH_USER has ${#FPRS[@]} published keys:"
        for I in "${!FPRS[@]}"; do
            NOTE="no secret key here, signing would fail"
            if gpg --list-secret-keys "${FPRS[$I]}" >/dev/null 2>&1; then
                NOTE="secret key present"
            fi
            printf "  %d) %s  %s\n      %s\n" "$((I + 1))" "${FPRS[$I]:24}" "${UIDS[$I]}" "$NOTE"
        done
        echo
        read -r -p "Use which key? [1-${#FPRS[@]}] " PICK
        if [[ ! "$PICK" =~ ^[0-9]+$ ]] || [[ "$PICK" -lt 1 ]] || [[ "$PICK" -gt "${#FPRS[@]}" ]]; then
            echo "Not a valid choice." >&2
            exit 1
        fi
        PICKED=$((PICK - 1))
    fi

    FPR="${FPRS[$PICKED]}"
    UID_STR="${UIDS[$PICKED]}"
    NAME=""
    EMAIL=""
    if [[ "$UID_STR" == *"<"*">"* ]]; then
        NAME="${UID_STR%% <*}"
        EMAIL="${UID_STR##*<}"
        EMAIL="${EMAIL%>}"
    fi

    echo
    echo "Key ${FPR:24} — press enter to accept each value, or type a new one."
    read -r -p "Name  [$NAME]: " IN && NAME="${IN:-$NAME}"
    read -r -p "Email [$EMAIL]: " IN && EMAIL="${IN:-$EMAIL}"
    if [[ -z "$NAME" || -z "$EMAIL" ]]; then
        echo "Name and email are both required." >&2
        exit 1
    fi

    # Signing needs the *private* key, which GitHub does not and must not have.
    # Enable it only if the matching secret key is actually in this keyring.
    SIGN=true
    if ! gpg --list-secret-keys "$FPR" >/dev/null 2>&1; then
        SIGN=false
    fi

    mkdir -p "$(dirname "$IDENTITY")"
    if [[ -e "$IDENTITY" ]]; then
        cp -f "$IDENTITY" "$IDENTITY.bak"
        echo "Previous identity saved as $IDENTITY.bak"
    fi
    {
        echo "# Written by 'ujust set-git-identity'. Machine-local, never committed."
        echo "[user]"
        printf '\tname = %s\n' "$NAME"
        printf '\temail = %s\n' "$EMAIL"
        printf '\tsigningkey = %s\n' "$FPR"
        echo "[commit]"
        printf '\tgpgsign = %s\n' "$SIGN"
        echo "[tag]"
        printf '\tgpgsign = %s\n' "$SIGN"
    } >"$IDENTITY"
    chmod 600 "$IDENTITY"

    echo
    echo "Wrote $IDENTITY:"
    sed 's/^/    /' "$IDENTITY"
    if [[ "$SIGN" == false ]]; then
        echo
        echo "Commit signing is OFF: no secret key for ${FPR:24} in this keyring."
        echo "GitHub only publishes public keys, so restore the private half from"
        echo "your own backup and re-run this recipe:"
        echo "    gpg --import /path/to/secret-key-backup.asc"
    fi
    echo
    echo "This file only takes effect once the Home Manager config includes it."
    echo "Check with: git config --show-origin --get user.email"
