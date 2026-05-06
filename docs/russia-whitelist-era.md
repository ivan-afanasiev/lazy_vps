# Surviving the Russian "whitelist" era

Working notes on why the current `lazy-vps` setup likely no longer works well
for users in Russia as of 2026, and a prioritized list of changes to try.
Nothing here is implemented yet — this doc is a backlog / decision record.

Last updated: 2026-05-02.

---

## Context: what changed on the Russian side

Through 2024–2026 Roskomnadzor / TSPU shifted from a pure blacklist model
("block known-bad IPs / SNIs") toward a much stricter posture that behaves
closer to a protocol allow-list. The things that matter for us:

1. **Protocol allow-listing on TSPU.** Flows that don't cleanly match a known
   protocol signature (plain HTTP, TLS with a realistic ClientHello to a
   reachable SNI, QUIC to the same, a few messenger protocols) get
   rate-limited to uselessness or dropped. "Unknown-looking" TCP/UDP is the
   main casualty.
2. **Active probing + TLS fingerprint heuristics.** High-entropy flows to a
   random foreign IP on :443 that don't match a real browser's ClientHello
   are degraded. Reality is *designed* to pass this check, but only when the
   chosen cover SNI is actually reachable from the client's ISP.
3. **Foreign-hoster IP range throttling.** Whole AWS / Hetzner / OVH /
   DigitalOcean ranges get heavily rate-limited on :443 and :8443 regardless
   of protocol. This is the single biggest issue for `lazy-vps` as currently
   deployed, because an AWS `eu-central-1` Elastic IP sits in a
   well-known range.
4. **Port policy.** Non-standard ports (8443, high custom ports) get sampled
   much more aggressively than :443. MTProto on :8443 is a flagged
   signature.
5. **Regional rollouts.** Enforcement is uneven: Moscow / SPb are usually
   lighter than border regions or the North Caucasus; mobile operators vary
   region-by-region and hour-by-hour.

## How each of our two tunnels fares

### VLESS + XTLS-Reality on :443 (Xray)

- In principle still *the* protocol that works in Russia in 2026 — it
  mimics a legitimate TLS handshake to a real domain.
- Breaks in practice when:
  - The `camouflage_domain` isn't reliably reachable from the user's ISP.
  - Our AWS egress IP is in a throttled range.
  - Regional TSPU is in "aggressive mode" and dropping non-whitelisted :443
    flows despite Reality.
- Typical failure signal: handshake completes, throughput collapses to
  ~50–200 kbit/s, or the session works for 10–30 s and stalls. That's
  rate-limiting, not protocol detection.

### Telegram MTProto (Telemt) on :8443

- Substantially worse off than VLESS under the new regime.
- MTProto is a well-documented signature, :8443 is a flagged port, and
  Telegram itself is partially throttled in Russia anyway.
- Still useful as a silent fallback inside the Telegram app, but not
  realistic for sustained voice/video.

---

## Suggestions, in order of bang-for-buck

### 1. Quick win — swap region + camouflage domain (~30 min, no code)

> **Status (2026-05): implemented as new defaults.** `camouflage_domain`
> is now `dzen.ru` (in-RU reachable, typical TLS 1.3 handshake) and
> `aws_region` is now `eu-north-1` (Stockholm, lighter TSPU throttling
> than Frankfurt) in `variables.tf`. Existing deployments with a pinned
> region in `terraform/terraform.tfvars` are unaffected; running
> deployments where the region was on the default and the state still
> says `eu-central-1` will diff against the new default — `make plan`
> first to see exactly what Terraform wants to do (changing `aws_region`
> destroys + recreates the EC2 + EIP, so every VLESS link breaks).

Edit `terraform/terraform.tfvars`, then `make destroy && make deploy`, then
retest from a real RU client.

- `aws_region`: move off `eu-central-1` (one of the most throttled AWS
  regions for RU right now). Better candidates:
  - `eu-north-1` (Stockholm) — often lighter throttling than Frankfurt.
  - `me-central-1` (UAE) — geographically reasonable, different IP reputation.
- `camouflage_domain`: stop using `www.vk.com` (its TLS handshake is
  atypical, which actually hurts Reality's mimicry). Good 2026 picks:
  - CDN-backed, hard to block without collateral damage:
    `www.microsoft.com`, `www.bing.com`, `www.apple.com`,
    `swcdn.apple.com`.
  - Domestic, always reachable from inside RU:
    `dzen.ru`, `www.kinopoisk.ru`, `lenta.ru`.

Fixes maybe half of current breakage reports on its own.

### 2. Medium — add a UDP fallback transport (Hysteria2 or VLESS over QUIC)

Add a second inbound next to Xray on UDP/443, regenerate client links so
each client has both TCP-Reality and UDP-QUIC configured. The client picks
whichever works.

Rationale: TCP/443 and UDP/443 are throttled independently on TSPU. When
one path is degraded, the other often still works.

Files touched:
- `terraform/scripts/setup-xray.sh` — second inbound block, listen UDP/443.
- `terraform/main.tf` — add UDP/443 to the security group (TCP/443 stays).
- `terraform/scripts/bot.py` and `Makefile` — extend `vless-link` / `/vless`
  to emit a second link, or bundle both into a single subscription.

### 3. Medium — retire or relocate MTProto

As-is on :8443 it's mostly dead weight. Two realistic options:

- **Drop it.** Telegram works fine through VLESS; remove Telemt, free up
  RAM, simplify the security group.
- **Move it to :443 on a separate VPS.** If we really want a dedicated
  Telegram proxy, run Telemt on :443 of a second cheap host (a second
  `t3.micro`, or a $3/mo box elsewhere). Don't collide it with Xray.

Default recommendation: drop it when we do the next redeploy, keep the code
around in git history in case we want it back.

### 4. Larger — port off AWS to a provider with better RU reachability (a weekend)

AWS `eu-central-1` IPs are throttled independently of what we run on them.
Moving providers removes that as a variable permanently.

Candidates (personal experience + recent RU community reports):

- **Aeza** — RU-friendly provider, €3–5/mo, generally unthrottled.
- **Vultr Tokyo / Osaka** — holding up well for RU users, ~$5/mo.
- **Hetzner Helsinki** — €4/mo, good latency to European RU, uneven
  throttling (sometimes great, sometimes bad).
- **Scaleway Paris / Amsterdam** — €4/mo, different IP reputation from AWS.
- **Kamatera** — flexible region list, pay-as-you-go.

Refactor impact:
- `terraform/main.tf` — swap AWS provider for the target (Vultr and
  Hetzner both have decent Terraform providers).
- Drop IAM role / instance profile / EIP (provider-specific).
- `make traffic` → stop querying CloudWatch, either call the provider's
  billing API or just read `vnstat` on the host. Easiest is to install
  `vnstat` at boot and have the bot shell out to it.
- `.envrc.example` — swap `TF_VAR_*` for provider-specific tokens.

Loses the "free tier" story but gains reliability. Probably worth it.

### 5. Largest — Cloudflare-fronted VLESS-WS as a last-resort transport

> **Status (2026-05): implemented as `cloudflare_enabled` feature flag.**
> Off by default. Enable with `TF_VAR_cloudflare_enabled=true` plus
> `TF_VAR_cloudflare_domain` pointing at a Cloudflare-Proxied subdomain.
> See README "Cloudflare-fronted VLESS (optional)" for the one-time
> Cloudflare dashboard setup.

The most reliable path when direct :443 to any foreign host is throttled,
because blocking it requires blocking Cloudflare itself.

Requirements:
- We own a real domain (cheap, ~$10/yr).
- Point the domain at Cloudflare, enable the orange cloud (proxied).
- Run Xray with a VLESS-over-WebSocket inbound on an internal port,
  terminate TLS at Cloudflare.
- Add the WS transport as an additional entry in the client subscription
  alongside Reality and Hysteria2.

Slower than direct Reality (extra hop through Cloudflare) but extremely
hard for TSPU to degrade without collateral damage. Good emergency fallback.

---

## Decision matrix

| Option | Effort | Ongoing cost delta | Reliability gain |
|--------|--------|--------------------|------------------|
| 1. Region + SNI swap | 30 min | $0 | Moderate, temporary |
| 2. UDP/HY2 fallback | half a day | $0 | High |
| 3. Drop MTProto | 1 hour | $0 (small RAM freed) | N/A (cleanup) |
| 4. Off-AWS | weekend | +$3–5/mo (leaves free tier) | High, durable |
| 5. Cloudflare-fronted WS | weekend | +$10/yr domain | Very high (emergency path) |

Best single-change-for-time-spent: **option 2** (add a UDP transport
alongside Reality). Best durable fix: **option 4** (leave AWS).

---

## What we are NOT changing, and why

- **Not moving to OpenVPN / WireGuard.** Both are trivially fingerprinted
  and rate-limited on TSPU in 2026; they only work on networks that still
  let unknown UDP through, which is a shrinking set. Obfuscation wrappers
  (`wstunnel`, `udp2raw`, etc.) help but are less effective than Reality.
  > Note (2026-05): we *do* now ship optional **AmneziaWG** support behind
  > the `amnezia_enabled` feature flag. AmneziaWG is the obfuscated fork
  > of WireGuard from the Amnezia VPN project — it adds packet-shape
  > randomisation (Jc / Jmin / Jmax / S1 / S2 magic-byte rewrites) that
  > defeats current WG fingerprints on TSPU. It's still UDP, so it shares
  > WG's "needs unknown UDP to reach the VPS" exposure, but the
  > fingerprinting half of the objection no longer applies. Off by default;
  > Reality remains the recommended primary transport.
- **Not self-signing a Reality with a domain we control.** The whole point
  of Reality is mimicking a *third-party* domain; using our own domain
  throws away the cover story.
- **Not writing our own protocol.** Xray-core is maintained by a community
  that tracks TSPU changes in near-real-time. Our job is picking the right
  knobs, not reinventing the wheel.

---

## Open questions to answer before picking an option

- Which regions / ISPs are the actual users on? (Options 1 and 4 depend on
  this — Moscow Rostelecom vs. Makhachkala MTS behave very differently.)
- Are we willing to pay $3–5/mo to leave the AWS free tier? (Gates option 4.)
- Do we already own a domain? (Lowers cost of option 5.)
- Is Telegram-specific proxying still a goal, or can we drop Telemt entirely?
  (Gates option 3.)

Once these are answered, the right sequence is usually:
**1 → test → 2 → test → 4 if 1+2 still aren't enough.**
