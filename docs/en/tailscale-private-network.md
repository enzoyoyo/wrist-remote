# Tailscale private-network mode

[简体中文](../zh-CN/tailscale-private-network.md)

Tailscale mode gives Wrist Remote a private, direct candidate path from the companion iPhone to the Mac when Bonjour LAN is unavailable or is not ready within its head-start window. It does not publish the Mac to the Internet and it does not replace Wrist Remote's own pairing, identity verification, or encrypted session.

## Connection order

```text
Apple Watch
    │ WatchConnectivity
    ▼
paired iPhone
    ├─ 0.9 s head start: Bonjour LAN discovery → encrypted TCP → Mac Bridge
    └─ delayed candidate: official Tailscale IP → TCP 60927 → Mac Bridge
```

The iPhone gives Bonjour a 0.9-second head start. If no LAN candidate has become ready and been adopted by then, it also starts the configured Tailscale candidate. The first candidate to become ready is adopted and the other is cancelled. An adopted or connected route is not preempted; the next reconnect cycle starts LAN-first again. A LAN failure or timeout starts Tailscale immediately. Tailscale and LAN use the same mutual identity handshake, two-ended six-digit first approval, and application-layer encryption.

The Watch app itself does not join the tailnet. Live Watch actions still require its paired iPhone to be reachable through [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity). A Watch operating independently over cellular, with no reachable companion iPhone, is intentionally unsupported by the current private-only build. It does not fall back to a public Relay.

## Security properties

- The Mac's Tailscale listener is off by default and is separate from the LAN listener.
- When enabled, it binds one concrete `utun` address in Tailscale's documented `100.64.0.0/10` or `fd7a:115c:a1e0::/48` range, on fixed TCP port `60927`.
- Accepted peers must also have a Tailscale-range source address. The listener does not bind `0.0.0.0`, `::`, a physical public address, or an arbitrary tunnel address.
- The iPhone accepts only a literal IP in Tailscale's official IPv4 or IPv6 range. DNS names, including MagicDNS names, URLs, embedded credentials, paths, arbitrary ports, public IPs, and unrelated private IPs are rejected.
- The private endpoint is stored in the iPhone Keychain and revalidated when loaded.
- The Mac and iPhone keep their long-term P-256 installation identities in their own Keychains and create them only when the dedicated item is absent. A locked, unavailable, unreadable, or corrupt identity store stops connection instead of silently rotating that identity.
- The iPhone verifies the Mac signature and uses trust on first use (TOFU): before storing the Mac fingerprint, it shows the six-digit code and truncated fingerprint and requires explicit iPhone approval. The Mac separately requires approval of the same code before storing the iPhone fingerprint.
- Subsequent connections require both pinned identities. A changed Mac fingerprint, unreadable iPhone trust or identity store, invalid signature, incomplete handshake, or failure to persist the approved iPhone fingerprint on the Mac fails closed before the session becomes ready or application data is accepted.
- Tailnet access is only a network-access layer. Wrist Remote still binds both installation identities to the current key exchange, negotiates a transcript-bound session key, and encrypts frames.
- There is no offline command queue. An action that cannot be delivered while the Watch, iPhone, and Mac are reachable fails instead of executing later.

Tailscale documents its [reserved address ranges](https://tailscale.com/docs/reference/reserved-ip-addresses) and [Grants](https://tailscale.com/docs/features/access-control/grants). Review those documents against your current tailnet policy. Wrist Remote intentionally requires the literal official-range IP instead of DNS.

## Prerequisites

1. Install Tailscale on the Mac and paired iPhone and sign both into the same tailnet.
2. Confirm both devices appear in the Tailscale admin console and can reach each other.
3. Copy the Mac's Tailscale IPv4 or IPv6 address and confirm that it is inside `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
4. Keep the iPhone available to the Watch for live `WatchConnectivity` messages.
5. Install the same Wrist Remote version on the Mac, iPhone, and Watch.

Enter only the literal address, for example:

```text
<MAC_TAILSCALE_IP>
```

The value is illustrative, not a default. Do not put a DNS name, scheme, port, path, username, or password in this field.

## Configure the Mac

1. Open **Wrist Remote Bridge**.
2. In **Private Network**, enable **Allow Tailscale private-network connections**.
3. Wait for **Private listener ready**.

The setting is deliberately independent from the LAN service. If Tailscale is stopped or no approved tunnel address exists, the private listener waits while the existing Bonjour LAN listener continues normally.

## Configure the iPhone

1. Open the Wrist Remote companion app.
2. In **Private Network**, enable **Tailscale private direct connection**.
3. Enter the Mac's official Tailscale IP.
4. Tap **Save and reconnect**.
5. On first use, or after upgrading from a version without Mac identity pinning, compare the six-digit code and approve the identity on the iPhone and Mac separately. The application session is not accepted until both approvals complete.

The status shows whether the active direct route is **LAN** or **Tailscale private network**. The saved endpoint contains no port because Wrist Remote always uses TCP `60927`.

## Identity recovery and upgrades

An upgrade from an older direct protocol requires one explicit two-ended pairing so the iPhone can pin the Mac's new long-term identity. This is expected and should not be automated.

After that pairing, an unexpected **Mac identity does not match the trusted record** error is a security stop, not a connectivity error. Do not work around it by editing the saved endpoint or repeatedly reconnecting. First determine whether the intended Bridge was reinstalled under a new Bundle ID, its Keychain was intentionally reset, or a different Mac is answering.

Only after confirming that identity replacement was intentional:

1. Open the iPhone companion app.
2. Under the connection status, choose **Forget trusted Mac**.
3. Reconnect, compare the new six-digit code on both ends, and approve both prompts.

This action deletes only the iPhone's pinned Mac fingerprint. It does not change the Tailscale endpoint, expose a listener, delete mappings, or modify another remote control. If the warning was not caused by a change you made, keep the connection blocked and investigate the Mac and tailnet instead.

**Reset this iPhone's pairing identity** is a separate destructive recovery action. Use it only after confirming that the iPhone identity item is damaged or when deliberately creating a new client identity. The app requires another confirmation, does not change endpoints, mappings, or other remotes, and the Mac must treat the replacement as a new iPhone: compare the six-digit code again and approve it on the Mac. A damaged or unreadable identity is never replaced automatically.

## Recommended VPN On Demand setup

[Tailscale VPN On Demand](https://tailscale.com/docs/features/client/ios-vpn-on-demand) can keep or start the iPhone tunnel when the network changes. Select **Always** for the interfaces on which Tailscale should remain connected. Hostname-triggered rules are not used because Wrist Remote rejects DNS endpoints.

Tailscale notes that only one VPN app can have On Demand enabled at a time on iOS. If another VPN takes over, reconnect Tailscale before testing Wrist Remote. After an iPhone restart, unlock it once before relying on the live Watch path: Wrist Remote stores its direct identity and private endpoint with `AfterFirstUnlockThisDeviceOnly` Keychain accessibility, and the Watch/iPhone session must still be reachable.

## Recommended least-privilege Grant

Restrict the source identity to the intended user or device and the destination to the Mac on TCP `60927`. The following is synthetic policy input; replace every placeholder in the Tailscale admin console, not in this repository:

```json
{
  "groups": {
    "group:wristremote-clients": ["user@example.invalid"]
  },
  "tagOwners": {
    "tag:wristremote-mac": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["group:wristremote-clients"],
      "dst": ["tag:wristremote-mac"],
      "ip": ["tcp:60927"]
    }
  ]
}
```

Apply `tag:wristremote-mac` only to the intended Mac. A narrow Grant does not cancel a broader allow rule because matching Grants are additive; review the entire policy and remove unintended broad access only after confirming that doing so will not lock out other services. Tailscale's [Grant examples](https://tailscale.com/docs/reference/examples/grants) describe the current syntax.

## What not to enable

- Do not use router port forwarding, UPnP/NAT-PMP exposure, a public reverse proxy, or a wildcard listener for TCP `60927`.
- Do not use [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel). Funnel is designed to make a service reachable from the broader Internet, which is outside this mode's threat model.
- Tailscale Serve is not required because Wrist Remote connects directly to its raw TCP listener.
- Do not disable Wrist Remote pairing or application encryption because the devices share a tailnet.

## Termius

[Termius](https://termius.com/download/ios) is an optional SSH client for maintenance and diagnostics. It is not Wrist Remote's transport, does not create the tailnet, and should not receive Wrist Remote pairing or encryption credentials. If you use Termius through Tailscale, authorize SSH (`tcp:22`) with a separate least-privilege Grant and keep SSH credentials outside this repository.

## Verify without exposing the Mac

1. With iPhone and Mac on the same Wi-Fi, confirm the app reports **Connected via LAN**.
2. Move the iPhone to cellular, keep Tailscale connected, and confirm **Connected via Tailscale private network**.
3. Confirm the Mac Bridge shows **Private listener ready** and not a public-listener address.
4. Disable Tailscale on the iPhone. The private route must fail; it must not fall back to a public IP or execute queued actions later.
5. Verify that a public IP, arbitrary private IP, DNS name, and URL are rejected by endpoint validation; no public listener or Relay fallback may appear.
6. On a test installation only, verify that a substituted Mac identity is rejected. Then use **Forget trusted Mac**, re-pair with two-ended confirmation, and verify that reconnect succeeds only after the new identity is pinned.
7. Confirm the existing LAN remote or other input device still has its original mappings. Wrist Remote uses separate identifiers, preferences, Keychain services, protocol, and action profile.

These steps are real-device acceptance gates. Passing automated tests or simulator builds is not evidence that VPN wake-up, Watch reachability, haptics, or network handoff works on a particular device pair.

## Troubleshooting

| Symptom | Check |
|---|---|
| Mac shows **Waiting for Tailscale** | Start Tailscale on the Mac and confirm it owns an official Tailscale IPv4 or IPv6 address on a `utun` interface. |
| iPhone rejects the host | Use a literal IP in Tailscale's official range; remove DNS names, `https://`, ports, slashes, credentials, and whitespace. |
| Works on Wi-Fi but not cellular | Check iPhone Tailscale status, VPN On Demand rules, tailnet Grant, and cellular permission. |
| Other VPN is active | iOS permits only one On Demand VPN at a time; reconnect Tailscale and retry. |
| Watch says the iPhone is unavailable | Open the companion app, unlock the iPhone once after reboot, and confirm the Watch/iPhone session is reachable. |
| A cellular Watch cannot control with the iPhone absent | This is the expected private-only boundary. Bring the paired iPhone back within Watch Connectivity reach; there is no public fallback. |
| Mac identity does not match the trusted record | Stop. Confirm whether the intended Bridge identity was intentionally replaced. Only then use **Forget trusted Mac** and complete two-ended pairing again. |
