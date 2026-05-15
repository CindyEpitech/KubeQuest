# WSL2 — Fix DNS Resolution Failure

When `git pull`, `apt`, `curl`, or any hostname lookup fails inside WSL2 with:

```
ssh: Could not resolve hostname github.com: Temporary failure in name resolution
```

…the network itself is fine (you can ping `8.8.8.8`), but DNS is broken. This document explains why and walks through the fix step by step.

---

## Symptoms

| Command | Behaviour |
|---------|-----------|
| `ping 8.8.8.8` | Works (packets returned) |
| `ping github.com` | `Temporary failure in name resolution` |
| `git pull` / `curl https://...` | DNS error |
| `getent hosts github.com` | Empty output (no resolution) |

If all four match, you have the same DNS problem this guide solves.

---

## Root cause

WSL2 runs on a virtual Hyper-V interface (MAC prefix `00:15:5d`, IP usually in the `172.x.x.x` range). It uses **systemd-resolved** to handle DNS, with `/etc/resolv.conf` pointing to the local stub at `127.0.0.53`.

The stub forwards queries to **upstream DNS servers**. Normally those servers arrive via DHCP from the Windows host, but sometimes WSL brings up the interface **without any upstream DNS configured** — so the stub has nowhere to forward queries, and every lookup fails.

You can confirm this with `resolvectl status`:

```
Link 2 (eth0)
    Current Scopes: none        ← no DNS scope
         Protocols: -DefaultRoute ...
                                ← no "DNS Servers:" line
```

`Current Scopes: none` and a missing `DNS Servers:` line is the smoking gun.

---

## Step-by-step fix

### Step 1 — Confirm the diagnosis

```bash
ping -c 2 8.8.8.8           # should work
ping -c 2 github.com         # should fail with DNS error
cat /etc/resolv.conf         # should show "nameserver 127.0.0.53"
resolvectl status            # should show no DNS Servers on eth0
```

If all four match the description above, continue.

### Step 2 — Add DNS servers to eth0 (immediate fix)

Tell systemd-resolved which upstream DNS servers to use on the `eth0` interface, and that this interface handles all domains (`~.`):

```bash
sudo resolvectl dns eth0 8.8.8.8 1.1.1.1
sudo resolvectl domain eth0 '~.'
```

Test:

```bash
getent hosts github.com
# Expected: 140.82.x.x   github.com
```

Once that returns an IP, `git pull` and everything else will work again.

### Step 3 — Persist across systemd-resolved restarts

The `resolvectl` commands above are runtime-only and reset if systemd-resolved restarts. To make them persistent, edit `/etc/systemd/resolved.conf`:

```bash
sudo sed -i 's/^#\?DNS=.*/DNS=8.8.8.8 1.1.1.1/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
```

Verify:

```bash
resolvectl status
```

You should now see `DNS Servers: 8.8.8.8 1.1.1.1` under both **Global** and **Link 2 (eth0)**, with `Current Scopes: DNS` and `+DefaultRoute`.

### Step 4 — Stop WSL from overwriting `/etc/resolv.conf` (final lockdown)

By default, every time WSL starts, it regenerates `/etc/resolv.conf` based on Windows host settings. If those settings are bad again, you're back to square one. Tell WSL to stop touching the file:

```bash
sudo tee /etc/wsl.conf > /dev/null <<EOF
[network]
generateResolvConf = false
EOF
```

Then from **PowerShell on Windows** (not from inside WSL):

```powershell
wsl --shutdown
```

Restart WSL. From now on, systemd-resolved is fully in control and your DNS config survives reboots.

---

## Verification checklist

After all four steps:

```bash
resolvectl status                  # DNS Servers listed on eth0
getent hosts github.com            # returns an IP
ping -c 2 github.com               # works
git pull                           # works
```

All four green → done.

---

## Why this happens

| Layer | Role | What can go wrong |
|-------|------|-------------------|
| Windows host | Provides DNS to WSL via Hyper-V virtual NIC | Host DNS misconfigured / VPN interferes |
| WSL `/etc/resolv.conf` | Auto-generated symlink to systemd-resolved stub | WSL doesn't populate it with usable upstream DNS |
| systemd-resolved | Resolves hostnames, forwards to upstream | Receives no upstream DNS → fails silently |
| Apps (`git`, `curl`, …) | Call `getaddrinfo()` → systemd-resolved | Get `Temporary failure in name resolution` |

The fix above bypasses the broken handoff between Windows → WSL → systemd-resolved by pinning known-good public DNS servers (Google `8.8.8.8`, Cloudflare `1.1.1.1`) at the systemd-resolved layer.

---

## Quick reference — one-shot fix

If you hit this again on a fresh WSL instance and just want the commands:

```bash
sudo resolvectl dns eth0 8.8.8.8 1.1.1.1
sudo resolvectl domain eth0 '~.'
sudo sed -i 's/^#\?DNS=.*/DNS=8.8.8.8 1.1.1.1/' /etc/systemd/resolved.conf
sudo systemctl restart systemd-resolved
sudo tee /etc/wsl.conf > /dev/null <<EOF
[network]
generateResolvConf = false
EOF
# then from PowerShell: wsl --shutdown
```