# Recipes for the Nix half of this workstation: the Home Manager config that
# owns your shell, prompt and dotfiles, and the Nix that per-project dev shells
# need. Run `ujust` with no arguments to list every recipe.
#
# These are baked into the image by the `justfiles` module in recipes/recipe.yml,
# so a freshly-installed machine has them available immediately.

nix_config_repo := "https://github.com/jonaskirkemyr/nix-config.git"
nix_config_dir := "nix-config"
hm_release := "release-25.11"
hm_config := "jonask"

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
    # -b bak so a pre-existing ~/.zshrc is moved aside instead of aborting.
    if command -v home-manager >/dev/null 2>&1; then
        home-manager switch --flake ".#{{ hm_config }}" -b bak
    else
        nix run "home-manager/{{ hm_release }}" -- switch --flake ".#{{ hm_config }}" -b bak
    fi
    echo
    echo "Applied. If you have not set your login shell yet, run:"
    echo "    ujust set-default-shell"

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
    home-manager switch --flake "$DIR#{{ hm_config }}"

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
