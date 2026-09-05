# V2ray-Bot installer

Public mirror of `install.sh` from the private `x-kevinbro/V2ray-Bot` repository,
so the one-line installer can be fetched without authentication.

## Usage

```bash
bash <(curl -fsSL https://v2raybot-installer.vercel.app/install.sh)
```

While `V2ray-Bot` is private, add a read-only GitHub token so the installer can clone it:

```bash
GITHUB_TOKEN=github_pat_xxxxx bash <(curl -fsSL https://v2raybot-installer.vercel.app/install.sh)
```

## Hosting

Deployed as a static site. Vercel/Cloudflare Pages settings:

- Framework preset: **Other**
- Build command: *(empty)*
- Output directory: **public**

`vercel.json` forces `text/plain` and disables caching, and redirects `/` to `/install.sh`.

This file is a copy. Edit `install.sh` in the main repository, then update it here.
