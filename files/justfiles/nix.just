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

# Nix itself is part of the image (the `nix` and `nix-daemon` RPMs in
# recipes/recipe.yml), so there is no `setup-nix` here and nothing to install on a
# fresh machine: `nix` is /usr/bin/nix and on PATH in every shell, login or not.
#
# What is *not* on PATH in a recipe is the per-user Nix profile, because `just` runs
# every recipe in a fresh non-login, non-interactive bash and /etc/profile.d is only
# read by login shells. home-manager installs itself into that profile, so the
# recipes below source the file themselves rather than making you log out and back
# in. It exports NIX_PROFILES, NIX_SSL_CERT_FILE, XDG_DATA_DIRS and the PATH entries
# for ~/.nix-profile/bin and /nix/var/nix/profiles/default/bin.
nix_env := "/etc/profile.d/nix-daemon.sh"

# Check that the Nix the image ships is actually usable
check-nix:
    #!/usr/bin/env bash
    set -uo pipefail
    RC=0

    if command -v nix >/dev/null 2>&1; then
        echo "nix:        $(nix --version) at $(command -v nix)"
    else
        echo "nix:        MISSING — this image predates Nix being built in." >&2
        echo "            'ujust update && systemctl reboot', then try again." >&2
        RC=1
    fi

    # The store has to live on a writable filesystem. /nix ships inside the image,
    # whose root is read-only under composefs, so nix.mount binds /var/lib/nix over
    # it. Without that mount nix can read but never build.
    if MNT="$(findmnt --noheadings --output SOURCE,TARGET /nix 2>/dev/null)"; then
        echo "store:      writable, mounted from ${MNT}"
    else
        echo "store:      NOT MOUNTED — /nix is still the read-only copy from the" >&2
        echo "            image, so nothing can be built or installed. Look at:" >&2
        echo "              systemctl status nix-store-dir.service nix.mount" >&2
        RC=1
    fi

    # Multi-user mode: builds are handed to the daemon and run as nixbld-*. There is
    # deliberately no socket activation — see the systemd module in recipe.yml — so
    # nix-daemon.service is the unit to look at, and it creates the socket itself.
    STATE="$(systemctl is-active nix-daemon.service 2>/dev/null || true)"
    if [[ "$STATE" == "active" ]]; then
        echo "daemon:     nix-daemon.service active"
    else
        # Don't guess at the cause here: 'inactive' means a Condition skipped it,
        # 'failed' means it tried and could not. Those need different fixes, and
        # only the journal knows which happened.
        echo "daemon:     nix-daemon.service is '${STATE:-unknown}', not active." >&2
        echo "            systemctl status nix-daemon.service" >&2
        echo "            journalctl -b -u nix-daemon.service" >&2
        RC=1
    fi

    # The one check that exercises the whole stack rather than inspecting it: this
    # opens the daemon socket and asks the store to identify itself.
    if INFO="$(nix store info 2>&1)"; then
        echo "store ping: $(echo "$INFO" | tr '\n' ' ')"
    else
        echo "store ping: FAILED — nix cannot talk to the store." >&2
        echo "$INFO" | sed 's/^/            /' >&2
        RC=1
    fi

    if command -v home-manager >/dev/null 2>&1; then
        echo "home-mgr:   $(command -v home-manager)"
    else
        echo "home-mgr:   not installed yet — run 'ujust setup-home-manager'"
    fi

    if [[ "$RC" -eq 0 ]]; then
        echo
        echo "All good. 'nix run nixpkgs#hello' is a quick end-to-end test."
    fi
    exit "$RC"

# Clone the Home Manager config and apply it (first run on a new machine)
setup-home-manager:
    #!/usr/bin/env bash
    set -euo pipefail
    # nix-daemon.sh reads variables it has not set, so -u has to come off for it
    if [[ -e "{{ nix_env }}" ]]; then
        set +u
        . "{{ nix_env }}"
        set -u
    fi
    if ! command -v nix >/dev/null 2>&1; then
        echo "Nix not found, which should not be possible — it is part of the image." >&2
        echo "Run 'ujust check-nix' to see which part is missing." >&2
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
    if [[ -e "{{ nix_env }}" ]]; then
        set +u
        . "{{ nix_env }}"
        set -u
    fi
    DIR="$HOME/{{ nix_config_dir }}"
    if [[ ! -d "$DIR/.git" ]]; then
        echo "$DIR not found. Run 'ujust setup-home-manager' first."
        exit 1
    fi
    git -C "$DIR" pull --ff-only
    # falls back to a one-shot `nix run` if home-manager is not in the user profile
    # yet — which is the case on the very first switch, before it installs itself
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
