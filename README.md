# Pterodactyl Zig

Reusable Zig compiler/runtime image for Pterodactyl Wings. Debian 13 slim, official Zig **0.17.0**, Linux **amd64** and **arm64**. Includes Bash, Git (HTTPS), curl, CA certificates and tini; applications supply their own dependencies and configuration.

## Images

After a successful publication from `main`:

| Image | Meaning |
| --- | --- |
| `ghcr.io/trixnew/pterodactyl-zig:0.17.0` | Tested Zig 0.17.0 image; may receive maintenance rebuilds |
| `ghcr.io/trixnew/pterodactyl-zig:sha-<full-commit>` | Image built from that repository commit |
| `ghcr.io/trixnew/pterodactyl-zig@sha256:<digest>` | Immutable multi-architecture image reference |

CI writes the published digest and pull reference to its run summary. Use the digest for reproducible deployments. There is no floating `latest` tag.

## Pterodactyl

Add `ghcr.io/trixnew/pterodactyl-zig:0.17.0` (or its digest reference) to an existing egg's **Docker Images** list, then select it for the server. Configure the application to listen on `0.0.0.0` and its allocated port. This repository does not provide an egg or application installer.

Wings mounts server files at `/home/container` and selects the runtime UID/GID. The default image user is `container` (1000:1000). Mount ownership must match Wings' configured UID/GID; the entrypoint does not run as root or recursively change permissions. `HOME`, the working directory and the persistent Zig global cache are under `/home/container`. `/tmp` must also be writable, as Wings normally provides it.

The egg controls `STARTUP`. For example:

```sh
# Run an already-built application:
exec ./zig-out/bin/server --port "{{SERVER_PORT}}"

# Or explicitly compile and run:
zig build -Doptimize=ReleaseSafe && exec ./zig-out/bin/server --port "{{SERVER_PORT}}"
```

`{{VARIABLE}}` becomes `${VARIABLE}` before Bash interprets the command once. Quote variable placeholders used as arguments. Expanded variable values are not evaluated again. `STARTUP` is trusted executable shell code: restrict who may edit it and avoid variables that contain shell fragments. Bash runs with `errexit` and `pipefail`; normal Bash rules still apply inside conditionals and `&&`/`||` lists. Use `exec` for the final application so its exit status is preserved directly.

tini reaps orphaned processes and forwards SIGTERM/SIGINT to the foreground process group. For shell startup commands, Bash waits for its foreground application to finish before exiting with 143/130 on those signals. Console stdin stays attached; configure the egg's stop command or signal for the application. Applications must handle their own graceful shutdown and stay in the foreground. Startup does not install, fetch, or compile anything automatically. Without a nonempty `STARTUP`, Docker command arguments run directly; the default prints `zig version`.

## Local use

```sh
docker buildx build --load -t pterodactyl-zig:test .
docker run --rm pterodactyl-zig:test

# Own the bind-mounted project as the chosen UID/GID first.
docker run --rm -it --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$PWD,dst=/home/container" \
  --cap-drop ALL --security-opt no-new-privileges \
  pterodactyl-zig:test zig build

bash tests/smoke.sh pterodactyl-zig:test 0.17.0
```

Zig retains its standard library, bundled C toolchain and package manager. `zig build` can fetch dependencies declared in `build.zig.zon` over HTTPS; outbound network access is required on the first fetch. Its global cache lives at `/home/container/.cache/zig`. Native libraries, headers, SSH tools and other application-specific packages belong in a derived image when required. Zig source and build scripts execute as the server user and should be trusted.

## Publishing and maintenance

GitHub Actions builds and tests both architectures on native runners for pull requests and pushes. Successful `main` builds publish to GHCR, then combine the platform digests into the version and commit tags. BuildKit uses a separate GitHub Actions cache for each architecture. Tests check version, startup quoting/failures, stdin, non-root permissions, a read-only root filesystem, compilation, HTTPS dependency fetching and signal forwarding to child processes. They reproduce Wings' container restrictions; they do not start a live Panel/Wings installation.

The workflow's `GITHUB_TOKEN` needs permission to publish packages under **trixnew**. Run the repository in that organization with package creation enabled, or grant the repository write access to the existing GHCR package. Otherwise, set the repository secret `GHCR_TOKEN` to a classic personal access token with `write:packages` and access to that organization; the workflow prefers it over `GITHUB_TOKEN`. Make the package public for unauthenticated Wings pulls. Publishing has not occurred until the workflow succeeds.

The Debian multi-architecture base is digest-pinned. Debian packages, including transitive dependencies and security upgrades, come from a fixed, signed snapshot, with important packages additionally version-pinned. Snapshot expiry checks are disabled only for that historical archive; signature validation stays enabled. Zig archives and minisign signatures come from [ziglang.org](https://ziglang.org/download/), are verified against the pinned official public key **before extraction**, and must report the requested version. Download tools used only for verification stay out of the final image, and the toolchain and entrypoint are root-owned.

Pins also freeze security fixes: periodically update the Debian base digest, snapshot date and package versions together, test both architectures, and rebuild. To add a Zig version, update `ZIG_VERSION` in `Dockerfile` and the workflow, update the smoke test's default version and this README, then rerun CI. Review official signing-key changes independently. Do not disable signature checks to make an update build.

References: [official Pterodactyl yolks](https://github.com/pterodactyl/yolks), [Wings container configuration](https://github.com/pterodactyl/wings/blob/develop/environment/docker/container.go), [other Zig yolks](https://github.com/ddatunashvili/yolks).
