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

# Install Nix (Determinate Systems installer: handles ostree and SELinux)
setup-nix:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v nix >/dev/null 2>&1; then
        echo "Nix is already installed: $(nix --version)"
        exit 0
    fi
    echo "Installing Nix. You will be asked for your password."
    curl -fsSL https://install.determinate.systems/nix | sh -s -- install
    echo
    echo "Done. Log out and back in so the profile script is sourced, then run:"
    echo "    ujust setup-home-manager"

# Clone the Home Manager config and apply it (first run on a new machine)
setup-home-manager:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v nix >/dev/null 2>&1; then
        echo "Nix not found. Run 'ujust setup-nix' first, then log out and back in."
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
    DIR="$HOME/{{ nix_config_dir }}"
    if [[ ! -d "$DIR/.git" ]]; then
        echo "$DIR not found. Run 'ujust setup-home-manager' first."
        exit 1
    fi
    git -C "$DIR" pull --ff-only
    home-manager switch --flake "$DIR#$USER"

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
