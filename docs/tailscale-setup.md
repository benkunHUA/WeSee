# Tailscale Setup for WeSee Mobile Access

## Overview

WeSee's HTTP server listens on `127.0.0.1:8080`. Tailscale creates a secure WireGuard tunnel so your phone can reach this port from anywhere.

## Mac Setup

1. Install Tailscale:
   ```bash
   brew install tailscale
   ```
   Or download from https://tailscale.com

2. Start and authenticate:
   ```bash
   tailscale up
   ```

3. Verify connection and note your Mac's Tailscale IP:
   ```bash
   tailscale status
   ```
   Look for a `100.x.x.x` address.

## Phone Setup

1. Install Tailscale from App Store / Google Play
2. Sign in with the same account
3. Verify both devices show as connected in the Tailscale admin console

## Usage

Open your phone's browser and go to:

```
http://<mac-tailscale-ip>:8080
```

Example: `http://100.123.45.67:8080`

## How It Works

```
Phone Browser → Tailscale VPN (WireGuard encrypted) → Mac 127.0.0.1:8080 → WeSee HTTP Server
```

- The HTTP server only binds to `127.0.0.1`, so it's NOT visible on your local network
- Tailscale routes traffic from your phone to the Mac's loopback interface
- All traffic is encrypted by WireGuard
- No firewall rules needed

## Troubleshooting

| Problem | Check |
|---------|-------|
| Can't connect | Verify `tailscale status` shows both devices connected |
| Connection refused | WeSee app must be running (server starts with app) |
| Port conflict | Change `httpPort` in `~/.config/wesee/config.json` |
| Slow connection | Tailscale uses direct connections when possible; check NAT type |
