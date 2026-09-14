# bluebuild &nbsp; [![bluebuild build badge](https://github.com/jonaskirkemyr/bluebuild/actions/workflows/build.yml/badge.svg)](https://github.com/jonaskirkemyr/bluebuild/actions/workflows/build.yml)

My personal KDE Plasma desktop image, built on [Fedora Kinoite](https://fedoraproject.org/kinoite/) via [BlueBuild](https://blue-build.org/).

The image is defined declaratively in [`recipes/recipe.yml`](recipes/recipe.yml) — packages, flatpaks and system files are added there, not installed on the running machine. GitHub Actions rebuilds and publishes the image nightly, and the desktop picks up changes on its next update.

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

To rebase an existing atomic Fedora installation to the latest build:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/jonaskirkemyr/bluebuild:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/jonaskirkemyr/bluebuild:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

## ISO

If build on Fedora Atomic, you can generate an offline ISO with the instructions available [here](https://blue-build.org/how-to/generate-iso/#_top). These ISOs cannot unfortunately be distributed on GitHub for free due to large sizes, so for public projects something else has to be used for hosting.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/jonaskirkemyr/bluebuild
```
