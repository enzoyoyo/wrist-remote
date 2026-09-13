# Phone and Watch remote connections

[简体中文](../zh-CN/phone-watch-connection.md)

Version 0.6.0 adds an iPhone remote panel and foreground Apple Watch LAN control. Validate behavior on your target devices; simulator results do not establish real-device acceptance.

## Pairing

1. Install the same version of Wrist Remote on Mac, iPhone, and Apple Watch using your own signing identity.
2. Connect the devices to a mutually reachable local network. Guest-network isolation can prevent discovery or communication.
3. Choose the iPhone connection button in the Mac bridge and scan its QR code with the iPhone system camera. Automatic discovery and pairing-link import are also available.
4. Compare the six-digit code and approve the connection on both iPhone and Mac. A QR code does not authorize a device by itself.
5. Configure mappings on iPhone. The phone remote has 12 buttons, each supporting single, double, and long press.
6. Open the Watch remote connection settings and enable direct Mac connection. Its independent device identity requires separate code comparison and approval on Mac.

Phone and Watch can connect simultaneously. The Mac shows separate device states; an available pairing service does not mean a device is connected.

## Connection boundaries

- Direct Watch buttons require the Watch app in the foreground and access to the same LAN. Backgrounding stops polling; reopening establishes a new secure session.
- The original WatchConnectivity/iPhone relay remains available. Watch voice still requires iPhone; this version does not add virtual-microphone output.
- The existing optional iPhone Tailscale route remains separate. Watch HTTP direct control does not use Tailscale addresses.
- After a LAN address change, the Mac reconciles its listeners and iPhone rediscovers the pinned Mac. Watch receives refreshed direct configuration through the authenticated iPhone.
- Other remote tools, audio devices, and system input/output settings remain independent. No public relay, Funnel, port forwarding, or public listener is enabled.

## Action receipts

Phone and direct Watch buttons wait for an authenticated Mac receipt. No receipt means unconfirmed, not executed, and requests are not resent after reconnect. Stale mapping revisions, expired requests, duplicates, and unauthorized devices cannot execute buttons. A receipt confirms bridge dispatch; observing the intended target is still necessary for end-to-end acceptance.

## Transport and authorization

iPhone uses private TCP `60927`. Watch sends `URLSession` messages to `/v1/bridge` on HTTP `60929`, bound to a concrete LAN address. Task hooks remain on loopback `60928`.

HTTP carries the protocol; it is not HTTPS. The handshake verifies the Mac's P256 identity and uses X25519 key agreement, followed by ChaChaPoly authenticated encryption and sequence-based replay protection. The QR contains only public endpoint/identity data. An authenticated iPhone passes the configuration to Watch without copying its private device key.

## Troubleshooting

- No QR: check the Mac LAN connection and listener status.
- Scanning does not open the app: install an iPhone version supporting the `wristremote` pairing-link scheme.
- No Watch direct configuration: connect the iPhone app to Mac first, then open the Watch app.
- Codes or Mac identity differ: reject the connection; do not clear trust automatically to recover.
- Mapping not ready: synchronize iPhone mappings, then reconnect Watch.
- Device installation fails: unlock both devices, keep Watch worn, and check Developer Mode and development connectivity. Do not uninstall unrelated apps to bypass installation limits.
