# Building and updating the Docker image

This covers the day-to-day workflow for this fork: pulling in upstream changes, rebuilding the image, tagging it for rollback, and redeploying. `docker compose build`/`up` always act against whatever Docker host your active [`docker context`](https://docs.docker.com/engine/manage-resources/contexts/) points at — there's no registry involved, so a build only exists on the host it was built on.

See the "Run with Docker" section in [README.md](../README.md) for the first-time setup (`.env`, `docker compose up -d --build`). This file is the repeatable *update* procedure and a config/troubleshooting reference.

## One-time setup

**1. Add the upstream remote**, so this fork can pull in changes from the original project:

```bash
git remote add upstream https://github.com/teamducro/gloomhaven-storyline.git
git fetch upstream
```

**2. Point the Docker CLI at the deploy host.** List available contexts and switch to whichever one targets the host you want to build/deploy on:

```bash
docker context ls
docker context use <context-name>
```

Everything below (`docker compose build`, `docker tag`, `docker compose up`) runs against that host until you switch again. If the host is new (an SSH-based context you haven't used before), make sure it's reachable and its SSH host key is trusted first.

**3. Create a local `.env`** with the build-time config (gitignored, never commit this):

```bash
MIX_MAIN_GAME=fh
MIX_WEB_URL=https://your-public-url
MIX_APP_URL=https://your-public-url/tracker
# optional: MIX_API_URL, MIX_CDN_URL, MIX_VIRTUAL_BOARD_URL
```

`MIX_WEB_URL`/`MIX_APP_URL` must be set correctly or the marketing site's links won't navigate anywhere — see [Troubleshooting](#troubleshooting).

## Updating from upstream

```bash
git fetch upstream
git checkout master
git merge upstream/master        # or upstream/develop, whichever you track
```

Resolve any conflicts, then push to `origin` (your fork) as usual. Once `master` has the changes you want deployed, rebuild.

## Rebuild, tag, and deploy

Every build is tagged twice: `fh` always points at whatever is currently deployed, and a dated+commit tag is kept alongside it so you can roll back.

```bash
# 1. Rebuild the image from the current working tree
docker compose build

# 2. Tag this build for rollback before it becomes "current"
TAG="fh-$(date +%Y-%m-%d)-$(git rev-parse --short HEAD)"
docker tag gloomhaven-storyline:fh "gloomhaven-storyline:$TAG"

# 3. Redeploy the container from the freshly built :fh image
docker compose up -d --force-recreate
```

`docker compose build` always rewrites the `:fh` tag, so step 2 must run **before** you're happy calling this the deployed version — once you build again, the previous `:fh` layer is only reachable through whatever dated tag you gave it.

The dated tag is keyed off `git rev-parse --short HEAD`, so it only distinguishes builds that came from different commits. Rebuilding with **uncommitted** changes (e.g. iterating on the `Dockerfile` or nginx config) reuses the same tag and silently overwrites it, losing that rollback point. Commit before tagging if you want the tag to mean something.

### Verify

```bash
curl -I http://<host>:8080/                    # 200
curl -I http://<host>:8080/tracker              # 301 -> Location: /tracker/
curl -I http://<host>:8080/tracker/index.html   # Cache-Control: no-cache
curl -I http://<host>:8080/css/app.css          # Cache-Control: public, max-age=2592000, immutable
```

Then load the site in a browser and click through from the marketing home page into the tracker — curl can't exercise the client-side redirect, so this is the real check.

### Rollback

List the tagged builds and re-point `:fh` at an older one:

```bash
docker images gloomhaven-storyline
docker tag gloomhaven-storyline:fh-2026-08-10-abc1234 gloomhaven-storyline:fh
docker compose up -d --force-recreate
```

### Housekeeping

Dated tags accumulate (~900 MB each, since `resources/img` is baked into every build). Prune old ones periodically:

```bash
docker images gloomhaven-storyline --format '{{.Tag}}'   # review, then:
docker rmi gloomhaven-storyline:fh-2026-07-01-abc1234
```

## Config reference

All values are **compiled into the JS bundle at build time** by Laravel Mix — changing any of them requires `docker compose build`, not just a container restart.

| Variable | Purpose | Required for a working deploy? |
|---|---|---|
| `MIX_MAIN_GAME` | `gh` or `fh` — selects branding/skeleton (`resources/public-{game}`) | Set via `docker-compose.yml` build arg, defaults to `fh` |
| `MIX_WEB_URL` | Public URL of the marketing site (`/`) | **Yes** — see Troubleshooting |
| `MIX_APP_URL` | Public URL of the tracker (`/tracker`) | **Yes** — see Troubleshooting |
| `MIX_API_URL` | Backend API base URL | No — omit for offline-only (no cloud sync/login) |
| `MIX_CDN_URL` | Prefix for image URLs (points at an S3/CDN host instead of local `/img`) | No — omit to serve images from the container |
| `MIX_SENTRY_DSN`, `MIX_GA_ID` | Error tracking / analytics | No — guarded, silently no-op if blank |
| `MIX_STRIPE_KEY`, `MIX_PUSHER_KEY`, `MIX_PUSHER_APP_CLUSTER`, `MIX_VIRTUAL_BOARD_URL` | Donations / cloud sync / virtual board link | No — features are inert if blank |

## Troubleshooting

**Marketing site loads, but every link just reloads the same page / nothing navigates into `/tracker`.**
`MIX_WEB_URL` and/or `MIX_APP_URL` were blank at build time. The marketing router (`resources/js/website.js`) maps every hash route to the same `Home` component — real navigation into the tracker happens via a full-page redirect (`location.href.replace(MIX_WEB_URL, MIX_APP_URL)`), and the various "Play now" links bind their `href` to `MIX_APP_URL` directly. With both blank, links resolve to bare hash fragments (`#/story`) on the current page. Fix: set both in `.env` and rebuild.

**Recurring "Offline, changes are only stored locally" toast.**
The app polls `HEAD /ping` every 60s. The bundled nginx config (`docker/nginx/default.conf`) stubs `/ping` with a 200 — confirm that route is present if you've customized the nginx config.

**Image is ~900 MB.**
`resources/img` (855 MB / ~11k files) is copied into every build by `webpack.mix.js`. This is intentional for this fork (self-contained, no CDN dependency) — see the CDN row above if you'd rather serve images externally via `MIX_CDN_URL` and shrink the image.

**Service worker doesn't seem to register / offline caching doesn't work.**
`navigator.serviceWorker` requires a secure context — HTTPS, or `http://localhost`/`127.0.0.1`. Plain HTTP on any other hostname (a LAN IP, an internal hostname, etc.) silently skips registration; the app still works, just without offline asset caching. This resolves itself once the load balancer terminates HTTPS in front of the container.

**Build seems to hang around "transferring context".**
Expected on an SSH-based `docker context` — the ~850 MB build context (dominated by `resources/img`) has to transfer to the remote host on every build, regardless of layer caching. Layer caching still speeds up everything after that (typically only `npm ci` and `npm run production` need to actually re-run, and only if `package-lock.json` or source files changed). A `docker context` backed by a local Docker Engine skips this transfer entirely.

## Switching to a different Docker host

Since there's no registry, an image built on one host doesn't exist on any other — `docker context use <other-context>` followed by the same build/tag/deploy commands works, but it's a **full rebuild** there (no cached layers, full context transfer).

Before rebuilding on a new host, update `.env`'s `MIX_WEB_URL`/`MIX_APP_URL` to that host's actual reachable address. These are baked into the JS bundle at build time — if they still point at the old host, you'll hit the "links go nowhere" issue described above, just aimed at a host nobody can reach.
