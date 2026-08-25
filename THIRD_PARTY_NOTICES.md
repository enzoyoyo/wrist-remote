# Third-party notices

Wrist Remote uses Apple system frameworks at build time and runtime. Their use is governed by Apple's platform and developer agreements; those frameworks are not redistributed in this source repository.

The optional relay uses the following direct development dependencies. Transitive dependencies are recorded in `apps/WristRemoteRelay/package-lock.json` and are not vendored.

| Package | Declared license |
|---|---|
| `@cloudflare/vitest-plugin` | MIT |
| `@types/node` | MIT |
| `typescript` | Apache-2.0 |
| `vitest` | MIT |
| `wrangler` | MIT OR Apache-2.0 |

XcodeGen, Node.js, npm, Wrangler, gitleaks, and ripgrep are developer tools and are not redistributed by this repository.

Before distributing compiled binaries or vendored dependencies, regenerate a complete dependency and license inventory for the exact release artifact.
