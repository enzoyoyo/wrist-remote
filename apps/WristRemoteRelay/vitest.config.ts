import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    testTimeout: 25_000,
  },
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          ALLOWED_ROOM_ID: "11111111-1111-4111-8111-111111111111",
          BOOTSTRAP_MAC_TOKEN: "A".repeat(43),
        },
      },
    }),
  ],
});
