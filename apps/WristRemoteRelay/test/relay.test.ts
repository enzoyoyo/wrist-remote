import { env, exports } from "cloudflare:workers";
import { evictDurableObject, reset, runInDurableObject } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  MAX_CIPHERTEXT_BYTES,
  MAX_FRAME_LIFETIME_MS,
  PROTOCOL_VERSION,
  RATE_LIMIT_MAX_REQUESTS,
  RESPONSE_TIMEOUT_MS,
  isValidRelayToken,
} from "../src/config";
import {
  type PairRelayRoom,
  type RelayFrame,
} from "../src/index";

const ORIGIN = "https://relay.example.invalid";
const PRIVATE_ROOM_ID = "11111111-1111-4111-8111-111111111111";
const MAC_TOKEN = "A".repeat(43);
const DEVICE_TOKEN = `${"B".repeat(42)}Q`;
const WRONG_TOKEN = `${"C".repeat(42)}g`;

interface ErrorBody {
  error: { code: string; message: string };
}

interface RelayRequestMessage {
  type: "relayRequest";
  requestID: string;
  frame: RelayFrame;
}

function roomID(): string {
  return PRIVATE_ROOM_ID;
}

function roomURL(room: string, action: "init" | "bridge" | "command"): string {
  return `${ORIGIN}/v1/rooms/${room}/${action}`;
}

function bearer(token: string): HeadersInit {
  return { Authorization: `Bearer ${token}` };
}

async function initializeRoom(
  room: string,
  options: { macToken?: string; deviceToken?: string; deviceID?: string } = {},
): Promise<Response> {
  return exports.default.fetch(roomURL(room, "init"), {
    method: "POST",
    headers: {
      ...bearer(options.macToken ?? MAC_TOKEN),
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      deviceID: options.deviceID ?? crypto.randomUUID(),
      deviceToken: options.deviceToken ?? DEVICE_TOKEN,
    }),
  });
}

async function connectBridge(room: string, token = MAC_TOKEN): Promise<WebSocket> {
  const response = await exports.default.fetch(roomURL(room, "bridge"), {
    headers: {
      ...bearer(token),
      Upgrade: "websocket",
    },
  });
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  const socket = response.webSocket;
  if (socket === null) throw new Error("Missing upgraded WebSocket");
  socket.accept();
  return socket;
}

async function connectBridgeDirectlyToRoom(room: string, token = MAC_TOKEN): Promise<WebSocket> {
  const response = await stubFor(room).fetch("https://room.example.invalid/bridge", {
    headers: {
      ...bearer(token),
      Upgrade: "websocket",
    },
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket;
  if (socket === null) throw new Error("Missing upgraded WebSocket");
  socket.accept();
  return socket;
}

function frame(
  direction: RelayFrame["direction"],
  options: Partial<RelayFrame> = {},
): RelayFrame {
  const now = Date.now();
  return {
    protocolVersion: PROTOCOL_VERSION,
    operationID: crypto.randomUUID(),
    senderID: crypto.randomUUID(),
    sequence: 1,
    issuedAtEpochMilliseconds: now,
    expiresAtEpochMilliseconds: now + 10_000,
    direction,
    ciphertext: btoa("opaque ciphertext"),
    ...options,
  };
}

function postCommand(room: string, commandFrame: RelayFrame, token = DEVICE_TOKEN): Promise<Response> {
  return exports.default.fetch(roomURL(room, "command"), {
    method: "POST",
    headers: {
      ...bearer(token),
      "Content-Type": "application/json",
    },
    body: JSON.stringify(commandFrame),
  });
}

function nextTextMessage(socket: WebSocket): Promise<string> {
  return new Promise((resolve, reject) => {
    const onMessage = (event: MessageEvent): void => {
      cleanup();
      if (typeof event.data === "string") resolve(event.data);
      else reject(new Error("Expected a text WebSocket message"));
    };
    const onError = (): void => {
      cleanup();
      reject(new Error("WebSocket failed before receiving a message"));
    };
    const cleanup = (): void => {
      socket.removeEventListener("message", onMessage);
      socket.removeEventListener("error", onError);
    };
    socket.addEventListener("message", onMessage);
    socket.addEventListener("error", onError);
  });
}

function nextClose(socket: WebSocket): Promise<CloseEvent> {
  return new Promise((resolve) => {
    socket.addEventListener("close", (event) => resolve(event), { once: true });
  });
}

async function relayAndReply(
  room: string,
  bridge: WebSocket,
  commandFrame: RelayFrame,
  responseOverrides: Partial<RelayFrame> = {},
): Promise<{ response: Response; relayRequest: RelayRequestMessage; responseFrame: RelayFrame }> {
  const messagePromise = nextTextMessage(bridge);
  const responsePromise = postCommand(room, commandFrame);
  const relayRequest = JSON.parse(await messagePromise) as RelayRequestMessage;
  const responseFrame = frame("macToDevice", {
    operationID: commandFrame.operationID,
    ...responseOverrides,
  });
  bridge.send(JSON.stringify({
    type: "relayResponse",
    requestID: relayRequest.requestID,
    frame: responseFrame,
  }));
  return { response: await responsePromise, relayRequest, responseFrame };
}

function stubFor(room: string): DurableObjectStub<PairRelayRoom> {
  return env.ROOMS.get(env.ROOMS.idFromName(room.toLowerCase()));
}

async function errorCode(response: Response): Promise<string> {
  return ((await response.json()) as ErrorBody).error.code;
}

describe("WristRemote internet relay", () => {
  beforeEach(async () => {
    await reset();
  });

  it("serves a no-store health check and rejects unsupported methods", async () => {
    const health = await exports.default.fetch(`${ORIGIN}/healthz`);
    expect(health.status).toBe(200);
    expect(health.headers.get("Cache-Control")).toBe("no-store");
    expect(await health.json()).toEqual({
      ok: true,
      configured: true,
      service: "wrist-remote-relay",
      protocolVersion: PROTOCOL_VERSION,
    });

    const wrongMethod = await exports.default.fetch(`${ORIGIN}/healthz`, { method: "POST" });
    expect(wrongMethod.status).toBe(405);
    expect(wrongMethod.headers.get("Allow")).toBe("GET");

    const prefixedHealth = await exports.default.fetch(`${ORIGIN}/wristrelay/healthz`);
    expect(prefixedHealth.status).toBe(200);
    expect(await prefixedHealth.json()).toMatchObject({
      ok: true,
      configured: true,
      protocolVersion: PROTOCOL_VERSION,
    });
  });

  it("rejects malformed room IDs and credentials placed in URLs", async () => {
    const malformed = await exports.default.fetch(`${ORIGIN}/v1/rooms/not-a-uuid/bridge`);
    expect(malformed.status).toBe(400);
    expect(await errorCode(malformed)).toBe("invalid_room_id");

    const leaked = await exports.default.fetch(
      `${roomURL(roomID(), "bridge")}?macToken=${MAC_TOKEN}`,
      { headers: { Upgrade: "websocket" } },
    );
    expect(leaked.status).toBe(400);
    expect(await errorCode(leaked)).toBe("credentials_in_url_forbidden");
  });

  it("initializes once, stores only SHA-256 token hashes, and is idempotent", async () => {
    const room = roomID();
    const deviceID = crypto.randomUUID();
    const initialized = await initializeRoom(room, { deviceID });
    expect(initialized.status).toBe(201);
    expect(await initialized.json()).toMatchObject({
      initialized: true,
      idempotent: false,
      protocolVersion: PROTOCOL_VERSION,
    });

    const rows = await runInDurableObject(stubFor(room), (_instance, state) => [
      ...state.storage.sql.exec<Record<string, SqlStorageValue>>(
        "SELECT mac_token_hash, device_token_hash, device_id FROM room",
      ),
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0]?.mac_token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(rows[0]?.device_token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(rows)).not.toContain(MAC_TOKEN);
    expect(JSON.stringify(rows)).not.toContain(DEVICE_TOKEN);
    expect(rows[0]?.device_id).toBe(deviceID.toLowerCase());

    const repeated = await initializeRoom(room, { deviceID });
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toMatchObject({
      initialized: true,
      idempotent: true,
      protocolVersion: PROTOCOL_VERSION,
    });

    const unauthorizedReinitialization = await initializeRoom(room, {
      macToken: WRONG_TOKEN,
      deviceID,
    });
    expect(unauthorizedReinitialization.status).toBe(401);
    expect(await errorCode(unauthorizedReinitialization)).toBe("unauthorized");

    const conflicting = await initializeRoom(room, { deviceID: crypto.randomUUID() });
    expect(conflicting.status).toBe(409);
    expect(await errorCode(conflicting)).toBe("room_already_initialized");
  });

  it("serializes concurrent first initialization into one create and one idempotent reply", async () => {
    const room = roomID();
    const deviceID = crypto.randomUUID();
    const responses = await Promise.all([
      initializeRoom(room, { deviceID }),
      initializeRoom(room, { deviceID }),
    ]);
    const bodies = await Promise.all(responses.map(async (response) => ({
      status: response.status,
      body: await response.json() as { idempotent: boolean },
    })));
    expect(bodies.map((value) => value.status).sort()).toEqual([200, 201]);
    expect(bodies.map((value) => value.body.idempotent).sort()).toEqual([false, true]);
  });

  it("accepts the complete 32-byte unpadded base64url token alphabet", async () => {
    const validFinalCharacters = "AEIMQUYcgkosw048";
    for (const finalCharacter of validFinalCharacters) {
      expect(isValidRelayToken(`${"D".repeat(42)}${finalCharacter}`)).toBe(true);
    }
    expect(isValidRelayToken(`${"D".repeat(42)}B`)).toBe(false);
  });

  it("rejects initialization that reuses one credential for both roles", async () => {
    const response = await initializeRoom(roomID(), { deviceToken: MAC_TOKEN });
    expect(response.status).toBe(400);
    expect(await errorCode(response)).toBe("invalid_init");
  });

  it("keeps Mac and device bearer roles separate", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);

    const deviceAsBridge = await exports.default.fetch(roomURL(room, "bridge"), {
      headers: { ...bearer(DEVICE_TOKEN), Upgrade: "websocket" },
    });
    expect(deviceAsBridge.status).toBe(401);
    expect(deviceAsBridge.headers.get("WWW-Authenticate")).toBe("Bearer");

    const macAsDevice = await postCommand(room, frame("deviceToMac"), MAC_TOKEN);
    expect(macAsDevice.status).toBe(401);
    expect(await errorCode(macAsDevice)).toBe("unauthorized");

    const wrong = await postCommand(room, frame("deviceToMac"), WRONG_TOKEN);
    expect(wrong.status).toBe(401);
  });

  it("fails immediately while the Mac is offline and never queues payloads", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const commandFrame = frame("deviceToMac");
    const startedAt = Date.now();
    const response = await postCommand(room, commandFrame);
    expect(response.status).toBe(503);
    expect(Date.now() - startedAt).toBeLessThan(1_000);
    expect(await errorCode(response)).toBe("mac_offline");

    const counts = await runInDurableObject(stubFor(room), (_instance, state) => {
      const operationCount = [
        ...state.storage.sql.exec<{ count: number; [key: string]: SqlStorageValue }>(
          "SELECT COUNT(*) AS count FROM recent_operations",
        ),
      ][0]?.count;
      return { operationCount };
    });
    expect(counts.operationCount).toBe(0);
  });

  it("round-trips opaque frames and preserves operationID and requestID", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const bridge = await connectBridge(room);
    const commandFrame = frame("deviceToMac", { ciphertext: btoa("watch secret") });

    const { response, relayRequest, responseFrame } = await relayAndReply(
      room,
      bridge,
      commandFrame,
    );
    expect(relayRequest.type).toBe("relayRequest");
    expect(relayRequest.requestID).toMatch(UUIDPatternForTest);
    expect(relayRequest.frame).toEqual(commandFrame);
    expect(relayRequest.frame.operationID).toBe(commandFrame.operationID);
    expect(relayRequest.frame.ciphertext).toBe(btoa("watch secret"));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      requestID: relayRequest.requestID,
      frame: responseFrame,
    });
    bridge.close(1000, "done");
  });

  it("rejects stale, wrong-direction, invalid, and oversized frames", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);

    const wrongDirection = await postCommand(room, frame("macToDevice"));
    expect(wrongDirection.status).toBe(400);
    expect(await errorCode(wrongDirection)).toBe("invalid_frame");

    const now = Date.now();
    const excessiveTTL = await postCommand(
      room,
      frame("deviceToMac", {
        issuedAtEpochMilliseconds: now,
        expiresAtEpochMilliseconds: now + MAX_FRAME_LIFETIME_MS + 1,
      }),
    );
    expect(excessiveTTL.status).toBe(400);

    const invalidCiphertext = await postCommand(
      room,
      frame("deviceToMac", { ciphertext: "not base64" }),
    );
    expect(invalidCiphertext.status).toBe(413);

    const oversizedCiphertext = btoa("x".repeat(MAX_CIPHERTEXT_BYTES + 1));
    const oversized = await postCommand(
      room,
      frame("deviceToMac", { ciphertext: oversizedCiphertext }),
    );
    expect(oversized.status).toBe(413);
    expect(await errorCode(oversized)).toBe("ciphertext_too_large_or_invalid");
  });

  it("persists operation and sender-sequence replay protection", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const bridge = await connectBridge(room);
    const senderID = crypto.randomUUID();
    const commandFrame = frame("deviceToMac", { senderID, sequence: 7 });
    expect((await relayAndReply(room, bridge, commandFrame)).response.status).toBe(200);

    const duplicateOperation = await postCommand(room, commandFrame);
    expect(duplicateOperation.status).toBe(409);
    expect(await errorCode(duplicateOperation)).toBe("replay_detected");

    const duplicateSequence = await postCommand(
      room,
      frame("deviceToMac", { senderID, sequence: 7 }),
    );
    expect(duplicateSequence.status).toBe(409);
    expect(await errorCode(duplicateSequence)).toBe("replay_detected");
    bridge.close(1000, "done");
  });

  it("partitions sender sequences by direction even when both roles use the same UUID", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const bridge = await connectBridge(room);
    const sharedSenderID = crypto.randomUUID();
    const commandFrame = frame("deviceToMac", {
      senderID: sharedSenderID,
      sequence: Number.MAX_SAFE_INTEGER,
    });

    const first = await relayAndReply(room, bridge, commandFrame, {
      senderID: sharedSenderID,
      sequence: 1,
    });
    expect(first.response.status).toBe(200);

    const repeatedDeviceSequence = await postCommand(
      room,
      frame("deviceToMac", { senderID: sharedSenderID, sequence: 1 }),
    );
    expect(repeatedDeviceSequence.status).toBe(409);
    expect(await errorCode(repeatedDeviceSequence)).toBe("replay_detected");

    const repeatedMacSequence = await relayAndReply(
      room,
      bridge,
      frame("deviceToMac"),
      { senderID: sharedSenderID, sequence: 1 },
    );
    expect(repeatedMacSequence.response.status).toBe(409);
    expect(await errorCode(repeatedMacSequence.response)).toBe("replay_detected");
    bridge.close(1000, "done");
  });

  it("drops ambiguous legacy sender rows during the direction-key migration", async () => {
    const room = roomID();
    const initialization = await initializeRoom(room);
    expect(initialization.status).toBe(201);
    await initialization.text();
    const senderID = crypto.randomUUID();
    const stub = stubFor(room);
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec(
        "INSERT INTO sender_sequences (sender_id, highest_sequence) VALUES (?, ?)",
        senderID.toLowerCase(),
        Number.MAX_SAFE_INTEGER,
      );
    });
    await evictDurableObject(stub);

    const sequenceRows = await runInDurableObject(stubFor(room), (_instance, state) => [
      ...state.storage.sql.exec<{ sender_id: string; [key: string]: SqlStorageValue }>(
        "SELECT sender_id FROM sender_sequences ORDER BY sender_id",
      ),
    ]);
    expect(sequenceRows).toEqual([]);
  });

  it("rejects a bridge response whose operationID does not match", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const bridge = await connectBridge(room);
    const result = await relayAndReply(
      room,
      bridge,
      frame("deviceToMac"),
      { operationID: crypto.randomUUID() },
    );
    expect(result.response.status).toBe(502);
    expect(await errorCode(result.response)).toBe("invalid_bridge_response");
    bridge.close(1000, "done");
  });

  it("fails an in-flight command immediately when the bridge disconnects", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const bridge = await connectBridge(room);
    const messagePromise = nextTextMessage(bridge);
    const responsePromise = postCommand(room, frame("deviceToMac"));
    await messagePromise;
    bridge.close(1000, "test_disconnect");

    const response = await responsePromise;
    expect(response.status).toBe(502);
    expect(await errorCode(response)).toBe("bridge_disconnected");
  });

  it("times out an unanswered bridge request without persisting a payload queue", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const bridge = await connectBridge(room);
    const messagePromise = nextTextMessage(bridge);
    const startedAt = Date.now();
    const responsePromise = postCommand(room, frame("deviceToMac"));
    await messagePromise;

    const response = await responsePromise;
    expect(response.status).toBe(504);
    expect(Date.now() - startedAt).toBeGreaterThanOrEqual(RESPONSE_TIMEOUT_MS - 100);
    expect(await errorCode(response)).toBe("relay_timeout");
    bridge.close(1000, "done");
  });

  it("keeps rate-limit state across Durable Object eviction", async () => {
    const room = roomID();
    const initialization = await initializeRoom(room);
    expect(initialization.status).toBe(201);
    await initialization.text();
    const stub = stubFor(room);
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec(
        `INSERT INTO rate_limits (principal, window_started_at, count)
         VALUES ('device', ?, ?)
         ON CONFLICT(principal) DO UPDATE SET
           window_started_at = excluded.window_started_at,
           count = excluded.count`,
        Date.now(),
        RATE_LIMIT_MAX_REQUESTS,
      );
    });
    await evictDurableObject(stub);

    const limited = await postCommand(room, frame("deviceToMac"));
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toMatch(/^\d+$/);
    expect(await errorCode(limited)).toBe("rate_limited");
  });

  it("resumes the Mac WebSocket after hibernation eviction", async () => {
    const room = roomID();
    const initialization = await initializeRoom(room);
    expect(initialization.status).toBe(201);
    await initialization.text();
    const bridge = await connectBridgeDirectlyToRoom(room);
    await evictDurableObject(stubFor(room));

    const commandFrame = frame("deviceToMac");
    const result = await relayAndReply(room, bridge, commandFrame);
    expect(result.response.status).toBe(200);
    expect(result.relayRequest.frame.operationID).toBe(commandFrame.operationID);
    bridge.close(1000, "done");
  });

  it("replaces an old Mac bridge and sends commands only to the new bridge", async () => {
    const room = roomID();
    expect((await initializeRoom(room)).status).toBe(201);
    const first = await connectBridge(room);
    const firstClosed = nextClose(first);
    const second = await connectBridge(room);
    const closeEvent = await firstClosed;
    expect(closeEvent.code).toBe(4001);
    expect(closeEvent.reason).toBe("bridge_replaced");

    const result = await relayAndReply(room, second, frame("deviceToMac"));
    expect(result.response.status).toBe(200);
    second.close(1000, "done");
  });

  it("rejects every non-private room before creating a Durable Object", async () => {
    const otherRoom = crypto.randomUUID();
    const initialization = await initializeRoom(otherRoom);
    expect(initialization.status).toBe(404);
    expect(await errorCode(initialization)).toBe("room_not_found");

    const command = await postCommand(otherRoom, frame("deviceToMac"));
    expect(command.status).toBe(404);
    expect(await errorCode(command)).toBe("room_not_found");
  });

  it("requires the deployment bootstrap credential before room initialization", async () => {
    const response = await initializeRoom(roomID(), { macToken: WRONG_TOKEN });
    expect(response.status).toBe(401);
    expect(await errorCode(response)).toBe("unauthorized");
  });
});

const UUIDPatternForTest =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
