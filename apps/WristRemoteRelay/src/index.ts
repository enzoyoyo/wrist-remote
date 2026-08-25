import { DurableObject } from "cloudflare:workers";
import {
  MAX_CIPHERTEXT_BYTES,
  MAX_CLOCK_SKEW_MS,
  MAX_FRAME_LIFETIME_MS,
  MAX_JSON_BYTES,
  PROTOCOL_VERSION,
  RATE_LIMIT_MAX_REQUESTS,
  RATE_LIMIT_WINDOW_MS,
  RESPONSE_TIMEOUT_MS,
  TOKEN_PATTERN,
  isValidRelayToken,
} from "./config";

const ROOM_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const BASE64_PATTERN = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;
const MAC_SOCKET_TAG = "role:mac";

type RelayDirection = "deviceToMac" | "macToDevice";

export interface RelayFrame {
  protocolVersion: number;
  operationID: string;
  senderID: string;
  sequence: number;
  issuedAtEpochMilliseconds: number;
  expiresAtEpochMilliseconds: number;
  direction: RelayDirection;
  ciphertext: string;
}

interface RoomRow extends Record<string, SqlStorageValue> {
  mac_token_hash: string;
  device_token_hash: string;
  device_id: string;
}

interface RateLimitRow extends Record<string, SqlStorageValue> {
  window_started_at: number;
  count: number;
}

interface SequenceRow extends Record<string, SqlStorageValue> {
  highest_sequence: number;
}

interface SocketAttachment {
  role: "mac";
  connectionID: string;
  connectedAtEpochMilliseconds: number;
}

interface PendingRelay {
  operationID: string;
  bridgeConnectionID: string;
  timeoutID: ReturnType<typeof setTimeout>;
  resolve: (frame: RelayFrame) => void;
  reject: (failure: RelayHTTPError) => void;
}

interface InitRequest {
  deviceID: string;
  deviceToken: string;
}

type PrivateRelayEnv = Env & {
  ALLOWED_ROOM_ID?: string;
  BOOTSTRAP_MAC_TOKEN?: string;
};

interface BridgeResponseMessage {
  type: "relayResponse";
  requestID: string;
  frame: RelayFrame;
}

class RelayHTTPError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers?: HeadersInit,
  ) {
    super(message);
  }
}

export default {
  async fetch(request: Request, env: PrivateRelayEnv): Promise<Response> {
    try {
      const url = new URL(request.url);
      const publicPath = stripPublicPrefix(url.pathname);
      if (url.searchParams.has("macToken") || url.searchParams.has("deviceToken")) {
        throw new RelayHTTPError(
          400,
          "credentials_in_url_forbidden",
          "Credentials must be sent in Authorization headers, never in URLs.",
        );
      }

      if (publicPath === "/healthz") {
        if (request.method !== "GET") {
          return methodNotAllowed(["GET"]);
        }
        const configured = privateRelayConfigured(env);
        return jsonResponse({
          ok: configured,
          configured,
          service: "wrist-remote-relay",
          protocolVersion: PROTOCOL_VERSION,
        }, configured ? 200 : 503);
      }

      const route = parseRoomRoute(publicPath);
      if (route === null) {
        throw new RelayHTTPError(404, "not_found", "Route not found.");
      }

      const allowedMethod = route.action === "command" || route.action === "init" ? "POST" : "GET";
      if (request.method !== allowedMethod) {
        return methodNotAllowed([allowedMethod]);
      }

      await enforcePrivateRoom(request, env, route);

      const id = env.ROOMS.idFromName(route.roomID.toLowerCase());
      const stub = env.ROOMS.get(id);
      const internalURL = new URL(`https://room.example.invalid/${route.action}`);
      return stub.fetch(new Request(internalURL, request));
    } catch (error) {
      return errorResponse(error);
    }
  },
} satisfies ExportedHandler<PrivateRelayEnv>;

function stripPublicPrefix(pathname: string): string {
  if (pathname === "/wristrelay") return "/";
  if (pathname.startsWith("/wristrelay/")) {
    return pathname.slice("/wristrelay".length);
  }
  return pathname;
}

async function enforcePrivateRoom(
  request: Request,
  env: PrivateRelayEnv,
  route: { roomID: string; action: "init" | "bridge" | "command" },
): Promise<void> {
  const allowedRoomID = env.ALLOWED_ROOM_ID?.trim().toLowerCase();
  if (allowedRoomID === undefined || !ROOM_ID_PATTERN.test(allowedRoomID)) {
    throw new RelayHTTPError(503, "private_relay_not_configured", "Private relay room is not configured.");
  }
  if (route.roomID.toLowerCase() !== allowedRoomID) {
    throw new RelayHTTPError(404, "room_not_found", "Room not found.");
  }
  if (route.action !== "init") return;

  const bootstrapMacToken = env.BOOTSTRAP_MAC_TOKEN;
  if (bootstrapMacToken === undefined || !isValidRelayToken(bootstrapMacToken)) {
    throw new RelayHTTPError(503, "private_relay_not_configured", "Private relay bootstrap is not configured.");
  }
  const suppliedMacToken = requireBearerToken(request);
  const [expectedHash, suppliedHash] = await Promise.all([
    sha256Hex(bootstrapMacToken),
    sha256Hex(suppliedMacToken),
  ]);
  if (!timingSafeEqualHex(expectedHash, suppliedHash)) throw unauthorized();
}

function privateRelayConfigured(env: PrivateRelayEnv): boolean {
  const allowedRoomID = env.ALLOWED_ROOM_ID?.trim().toLowerCase();
  const bootstrapMacToken = env.BOOTSTRAP_MAC_TOKEN;
  return allowedRoomID !== undefined
    && ROOM_ID_PATTERN.test(allowedRoomID)
    && bootstrapMacToken !== undefined
    && isValidRelayToken(bootstrapMacToken);
}

export class PairRelayRoom extends DurableObject<Env> {
  private readonly pending = new Map<string, PendingRelay>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.ctx.blockConcurrencyWhile(async () => {
      this.ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS room (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          mac_token_hash TEXT NOT NULL,
          device_token_hash TEXT NOT NULL,
          device_id TEXT NOT NULL,
          initialized_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rate_limits (
          principal TEXT PRIMARY KEY,
          window_started_at INTEGER NOT NULL,
          count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS recent_operations (
          operation_id TEXT PRIMARY KEY,
          retain_until INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS recent_operations_expiry
          ON recent_operations(retain_until);
        CREATE TABLE IF NOT EXISTS sender_sequences (
          sender_id TEXT PRIMARY KEY,
          highest_sequence INTEGER NOT NULL
        );
        DELETE FROM sender_sequences WHERE instr(sender_id, ':') = 0;
      `);
      this.ctx.setWebSocketAutoResponse(
        new WebSocketRequestResponsePair("ping", "pong"),
      );
    });
  }

  override async fetch(request: Request): Promise<Response> {
    try {
      const pathname = new URL(request.url).pathname;
      switch (pathname) {
        case "/init":
          return await this.initialize(request);
        case "/bridge":
          return await this.connectBridge(request);
        case "/command":
          return await this.relayCommand(request);
        default:
          throw new RelayHTTPError(404, "not_found", "Route not found.");
      }
    } catch (error) {
      return errorResponse(error);
    }
  }

  override webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    const attachment = readSocketAttachment(socket);
    if (attachment === null || attachment.role !== "mac") {
      socket.close(1008, "invalid_socket_role");
      return;
    }

    if (typeof message !== "string" || utf8ByteLength(message) > MAX_JSON_BYTES) {
      this.failPendingForConnection(
        attachment.connectionID,
        new RelayHTTPError(502, "invalid_bridge_response", "Bridge sent an invalid response."),
      );
      socket.close(1009, "message_too_large_or_binary");
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(message);
    } catch {
      socket.close(1008, "invalid_json");
      return;
    }

    const response = parseBridgeResponse(parsed);
    if (response === null) {
      socket.close(1008, "invalid_response_shape");
      return;
    }

    const pending = this.pending.get(response.requestID);
    if (pending === undefined || pending.bridgeConnectionID !== attachment.connectionID) {
      return;
    }
    if (
      response.frame.direction !== "macToDevice" ||
      response.frame.operationID.toLowerCase() !== pending.operationID.toLowerCase() ||
      !isFreshFrame(response.frame, Date.now())
    ) {
      this.rejectPending(
        response.requestID,
        new RelayHTTPError(502, "invalid_bridge_response", "Bridge response did not match the request."),
      );
      return;
    }
    if (!this.acceptSequence("macToDevice", response.frame.senderID, response.frame.sequence)) {
      this.rejectPending(
        response.requestID,
        new RelayHTTPError(409, "replay_detected", "Bridge response sequence was already seen."),
      );
      return;
    }

    this.resolvePending(response.requestID, response.frame);
  }

  override webSocketClose(
    socket: WebSocket,
    _code: number,
    _reason: string,
    _wasClean: boolean,
  ): void {
    const attachment = readSocketAttachment(socket);
    if (attachment !== null) {
      this.failPendingForConnection(
        attachment.connectionID,
        new RelayHTTPError(502, "bridge_disconnected", "Bridge disconnected before replying."),
      );
    }
  }

  override webSocketError(socket: WebSocket, _error: unknown): void {
    const attachment = readSocketAttachment(socket);
    if (attachment !== null) {
      this.failPendingForConnection(
        attachment.connectionID,
        new RelayHTTPError(502, "bridge_disconnected", "Bridge disconnected before replying."),
      );
    }
  }

  private async initialize(request: Request): Promise<Response> {
    const macToken = requireBearerToken(request);
    const macTokenHash = await sha256Hex(macToken);
    const initialRoom = this.room();
    if (initialRoom !== null && !timingSafeEqualHex(initialRoom.mac_token_hash, macTokenHash)) {
      throw unauthorized();
    }

    const body = parseInitRequest(await readBoundedJSON(request, 2_048));
    const deviceTokenHash = await sha256Hex(body.deviceToken);
    if (timingSafeEqualHex(macTokenHash, deviceTokenHash)) {
      throw new RelayHTTPError(
        400,
        "invalid_init",
        "Mac and device credentials must be independently generated.",
      );
    }
    // readBoundedJSON and digesting yield to the Durable Object event loop. A
    // concurrent first initialization may have committed while this request
    // was suspended, so re-check immediately before the synchronous insert.
    const existing = this.room();
    if (existing !== null && !timingSafeEqualHex(existing.mac_token_hash, macTokenHash)) {
      throw unauthorized();
    }
    if (existing === null) {
      this.ctx.storage.sql.exec(
        `INSERT INTO room (
           singleton, mac_token_hash, device_token_hash, device_id, initialized_at
         ) VALUES (1, ?, ?, ?, ?)`,
        macTokenHash,
        deviceTokenHash,
        body.deviceID.toLowerCase(),
        Date.now(),
      );
      return jsonResponse(
        {
          initialized: true,
          idempotent: false,
          protocolVersion: PROTOCOL_VERSION,
        },
        201,
      );
    }

    const matches =
      timingSafeEqualHex(existing.device_token_hash, deviceTokenHash) &&
      existing.device_id === body.deviceID.toLowerCase();
    if (!matches) {
      throw new RelayHTTPError(
        409,
        "room_already_initialized",
        "Room initialization is write-once and the supplied credentials differ.",
      );
    }
    return jsonResponse({
      initialized: true,
      idempotent: true,
      protocolVersion: PROTOCOL_VERSION,
    });
  }

  private async connectBridge(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      throw new RelayHTTPError(
        426,
        "websocket_upgrade_required",
        "Bridge endpoint requires a WebSocket upgrade.",
        { Upgrade: "websocket" },
      );
    }
    await this.authorize(request, "mac");

    const connectionID = crypto.randomUUID();
    const existingSockets = this.liveMacSockets();
    for (const existingSocket of existingSockets) {
      const attachment = readSocketAttachment(existingSocket);
      if (attachment !== null) {
        this.failPendingForConnection(
          attachment.connectionID,
          new RelayHTTPError(502, "bridge_replaced", "Bridge connection was replaced."),
        );
      }
      existingSocket.close(4001, "bridge_replaced");
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    this.ctx.acceptWebSocket(server, [MAC_SOCKET_TAG]);
    server.serializeAttachment({
      role: "mac",
      connectionID,
      connectedAtEpochMilliseconds: Date.now(),
    } satisfies SocketAttachment);

    return new Response(null, { status: 101, webSocket: client });
  }

  private async relayCommand(request: Request): Promise<Response> {
    await this.authorize(request, "device");
    const frame = parseFrame(await readBoundedJSON(request, MAX_JSON_BYTES));
    if (frame.direction !== "deviceToMac" || !isFreshFrame(frame, Date.now())) {
      throw new RelayHTTPError(400, "invalid_frame", "Command frame is stale or has the wrong direction.");
    }

    this.consumeRateLimit("device", Date.now());
    const bridge = this.currentMacSocket();
    if (bridge === null) {
      throw new RelayHTTPError(503, "mac_offline", "Mac bridge is not connected; nothing was queued.");
    }

    this.acceptOperation(frame);
    if (!this.acceptSequence("deviceToMac", frame.senderID, frame.sequence)) {
      throw new RelayHTTPError(409, "replay_detected", "Command sequence was already seen.");
    }

    const attachment = readSocketAttachment(bridge);
    if (attachment === null) {
      throw new RelayHTTPError(503, "mac_offline", "Mac bridge is not connected; nothing was queued.");
    }
    const requestID = crypto.randomUUID();
    const responsePromise = new Promise<RelayFrame>((resolve, reject) => {
      const timeoutID = setTimeout(() => {
        this.rejectPending(
          requestID,
          new RelayHTTPError(504, "relay_timeout", "Mac bridge did not reply before the relay timeout."),
        );
      }, RESPONSE_TIMEOUT_MS);
      this.pending.set(requestID, {
        operationID: frame.operationID,
        bridgeConnectionID: attachment.connectionID,
        timeoutID,
        resolve,
        reject,
      });
    });

    try {
      bridge.send(JSON.stringify({ type: "relayRequest", requestID, frame }));
    } catch {
      this.rejectPending(
        requestID,
        new RelayHTTPError(502, "bridge_disconnected", "Bridge disconnected before the command was sent."),
      );
    }

    const responseFrame = await responsePromise;
    return jsonResponse({ requestID, frame: responseFrame });
  }

  private room(): RoomRow | null {
    const rows = [...this.ctx.storage.sql.exec<RoomRow>(
      `SELECT mac_token_hash, device_token_hash, device_id
       FROM room WHERE singleton = 1`,
    )];
    return rows[0] ?? null;
  }

  private async authorize(request: Request, role: "mac" | "device"): Promise<void> {
    const room = this.room();
    if (room === null) {
      throw new RelayHTTPError(404, "room_not_initialized", "Room has not been initialized.");
    }
    const suppliedHash = await sha256Hex(requireBearerToken(request));
    const expectedHash = role === "mac" ? room.mac_token_hash : room.device_token_hash;
    if (!timingSafeEqualHex(expectedHash, suppliedHash)) {
      throw unauthorized();
    }
  }

  private consumeRateLimit(principal: string, now: number): void {
    const rows = [...this.ctx.storage.sql.exec<RateLimitRow>(
      `SELECT window_started_at, count FROM rate_limits WHERE principal = ?`,
      principal,
    )];
    const existing = rows[0];
    if (existing === undefined || now - existing.window_started_at >= RATE_LIMIT_WINDOW_MS) {
      this.ctx.storage.sql.exec(
        `INSERT INTO rate_limits (principal, window_started_at, count)
         VALUES (?, ?, 1)
         ON CONFLICT(principal) DO UPDATE SET
           window_started_at = excluded.window_started_at,
           count = 1`,
        principal,
        now,
      );
      return;
    }
    if (existing.count >= RATE_LIMIT_MAX_REQUESTS) {
      const retryAfterSeconds = Math.max(
        1,
        Math.ceil((RATE_LIMIT_WINDOW_MS - (now - existing.window_started_at)) / 1_000),
      );
      throw new RelayHTTPError(429, "rate_limited", "Room command rate limit exceeded.", {
        "Retry-After": String(retryAfterSeconds),
      });
    }
    this.ctx.storage.sql.exec(
      `UPDATE rate_limits SET count = count + 1 WHERE principal = ?`,
      principal,
    );
  }

  private acceptOperation(frame: RelayFrame): void {
    const now = Date.now();
    this.ctx.storage.sql.exec(
      `DELETE FROM recent_operations WHERE retain_until < ?`,
      now,
    );
    const cursor = this.ctx.storage.sql.exec(
      `INSERT OR IGNORE INTO recent_operations (operation_id, retain_until)
       VALUES (?, ?)`,
      frame.operationID.toLowerCase(),
      Math.max(frame.expiresAtEpochMilliseconds, now) + MAX_CLOCK_SKEW_MS,
    );
    if (cursor.rowsWritten === 0) {
      throw new RelayHTTPError(409, "replay_detected", "Operation was already relayed.");
    }
  }

  private acceptSequence(
    direction: RelayDirection,
    senderID: string,
    sequence: number,
  ): boolean {
    // Legacy rows used only senderID, so the two independently generated
    // sequence streams could poison one another when their UUIDs matched.
    // UUID validation excludes ':', making this scoped key unambiguous.
    const scopedSenderID = `${direction}:${senderID.toLowerCase()}`;
    const rows = [...this.ctx.storage.sql.exec<SequenceRow>(
      `SELECT highest_sequence FROM sender_sequences WHERE sender_id = ?`,
      scopedSenderID,
    )];
    const existing = rows[0];
    if (existing !== undefined && sequence <= existing.highest_sequence) {
      return false;
    }
    this.ctx.storage.sql.exec(
      `INSERT INTO sender_sequences (sender_id, highest_sequence)
       VALUES (?, ?)
       ON CONFLICT(sender_id) DO UPDATE SET highest_sequence = excluded.highest_sequence`,
      scopedSenderID,
      sequence,
    );
    return true;
  }

  private liveMacSockets(): WebSocket[] {
    return this.ctx
      .getWebSockets(MAC_SOCKET_TAG)
      .filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  private currentMacSocket(): WebSocket | null {
    const sockets = this.liveMacSockets();
    if (sockets.length === 0) return null;
    sockets.sort((left, right) => {
      const leftAt = readSocketAttachment(left)?.connectedAtEpochMilliseconds ?? 0;
      const rightAt = readSocketAttachment(right)?.connectedAtEpochMilliseconds ?? 0;
      return rightAt - leftAt;
    });
    const [current, ...stale] = sockets;
    for (const socket of stale) socket.close(4001, "bridge_replaced");
    return current ?? null;
  }

  private resolvePending(requestID: string, frame: RelayFrame): void {
    const pending = this.pending.get(requestID);
    if (pending === undefined) return;
    this.pending.delete(requestID);
    clearTimeout(pending.timeoutID);
    pending.resolve(frame);
  }

  private rejectPending(requestID: string, failure: RelayHTTPError): void {
    const pending = this.pending.get(requestID);
    if (pending === undefined) return;
    this.pending.delete(requestID);
    clearTimeout(pending.timeoutID);
    pending.reject(failure);
  }

  private failPendingForConnection(connectionID: string, failure: RelayHTTPError): void {
    for (const [requestID, pending] of this.pending) {
      if (pending.bridgeConnectionID === connectionID) {
        this.rejectPending(requestID, failure);
      }
    }
  }
}

function parseRoomRoute(
  pathname: string,
): { roomID: string; action: "init" | "bridge" | "command" } | null {
  const segments = pathname.split("/");
  if (
    segments.length !== 5 ||
    segments[0] !== "" ||
    segments[1] !== "v1" ||
    segments[2] !== "rooms"
  ) {
    return null;
  }
  const roomID = segments[3];
  const action = segments[4];
  if (roomID === undefined || action === undefined) {
    return null;
  }
  if (!ROOM_ID_PATTERN.test(roomID)) {
    throw new RelayHTTPError(400, "invalid_room_id", "Room ID must be a UUID.");
  }
  if (action !== "init" && action !== "bridge" && action !== "command") {
    return null;
  }
  return { roomID, action };
}

function parseInitRequest(value: unknown): InitRequest {
  if (!isRecord(value) || Object.keys(value).length !== 2) {
    throw new RelayHTTPError(400, "invalid_init", "Initialization body has an invalid shape.");
  }
  const { deviceID, deviceToken } = value;
  if (typeof deviceID !== "string" || !UUID_PATTERN.test(deviceID)) {
    throw new RelayHTTPError(400, "invalid_device_id", "Device ID must be a UUID.");
  }
  if (typeof deviceToken !== "string" || !TOKEN_PATTERN.test(deviceToken)) {
    throw new RelayHTTPError(400, "invalid_device_token", "Device token must be 32-byte base64url.");
  }
  return { deviceID, deviceToken };
}

function parseBridgeResponse(value: unknown): BridgeResponseMessage | null {
  if (!isRecord(value) || value.type !== "relayResponse") return null;
  if (typeof value.requestID !== "string" || !UUID_PATTERN.test(value.requestID)) return null;
  try {
    return {
      type: "relayResponse",
      requestID: value.requestID,
      frame: parseFrame(value.frame),
    };
  } catch {
    return null;
  }
}

function parseFrame(value: unknown): RelayFrame {
  if (!isRecord(value) || Object.keys(value).length !== 8) {
    throw new RelayHTTPError(400, "invalid_frame", "Relay frame has an invalid shape.");
  }
  const {
    protocolVersion,
    operationID,
    senderID,
    sequence,
    issuedAtEpochMilliseconds,
    expiresAtEpochMilliseconds,
    direction,
    ciphertext,
  } = value;
  if (protocolVersion !== PROTOCOL_VERSION) {
    throw new RelayHTTPError(400, "unsupported_protocol", "Relay protocol version is unsupported.");
  }
  if (typeof operationID !== "string" || !UUID_PATTERN.test(operationID)) {
    throw new RelayHTTPError(400, "invalid_frame", "Operation ID must be a UUID.");
  }
  if (typeof senderID !== "string" || !UUID_PATTERN.test(senderID)) {
    throw new RelayHTTPError(400, "invalid_frame", "Sender ID must be a UUID.");
  }
  if (!Number.isSafeInteger(sequence) || (sequence as number) < 0) {
    throw new RelayHTTPError(400, "invalid_frame", "Sequence must be a non-negative integer.");
  }
  if (!Number.isSafeInteger(issuedAtEpochMilliseconds)) {
    throw new RelayHTTPError(400, "invalid_frame", "Issued-at timestamp is invalid.");
  }
  if (!Number.isSafeInteger(expiresAtEpochMilliseconds)) {
    throw new RelayHTTPError(400, "invalid_frame", "Expiry timestamp is invalid.");
  }
  if (direction !== "deviceToMac" && direction !== "macToDevice") {
    throw new RelayHTTPError(400, "invalid_frame", "Relay direction is invalid.");
  }
  if (
    typeof ciphertext !== "string" ||
    ciphertext.length === 0 ||
    !BASE64_PATTERN.test(ciphertext) ||
    decodedBase64Length(ciphertext) > MAX_CIPHERTEXT_BYTES
  ) {
    throw new RelayHTTPError(413, "ciphertext_too_large_or_invalid", "Ciphertext is invalid or too large.");
  }
  return {
    protocolVersion,
    operationID,
    senderID,
    sequence: sequence as number,
    issuedAtEpochMilliseconds: issuedAtEpochMilliseconds as number,
    expiresAtEpochMilliseconds: expiresAtEpochMilliseconds as number,
    direction,
    ciphertext,
  };
}

function isFreshFrame(frame: RelayFrame, now: number): boolean {
  const lifetime = frame.expiresAtEpochMilliseconds - frame.issuedAtEpochMilliseconds;
  return (
    lifetime > 0 &&
    lifetime <= MAX_FRAME_LIFETIME_MS &&
    frame.issuedAtEpochMilliseconds <= now + MAX_CLOCK_SKEW_MS &&
    frame.expiresAtEpochMilliseconds >= now - MAX_CLOCK_SKEW_MS
  );
}

async function readBoundedJSON(request: Request, maximumBytes: number): Promise<unknown> {
  const contentType = request.headers.get("Content-Type")?.split(";", 1)[0]?.trim().toLowerCase();
  if (contentType !== "application/json") {
    throw new RelayHTTPError(415, "unsupported_media_type", "Content-Type must be application/json.");
  }
  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null) {
    const parsed = Number(contentLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0) {
      throw new RelayHTTPError(400, "invalid_content_length", "Content-Length is invalid.");
    }
    if (parsed > maximumBytes) {
      throw new RelayHTTPError(413, "payload_too_large", "JSON payload exceeds the relay limit.");
    }
  }
  if (request.body === null) {
    throw new RelayHTTPError(400, "missing_body", "JSON request body is required.");
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maximumBytes) {
      await reader.cancel();
      throw new RelayHTTPError(413, "payload_too_large", "JSON payload exceeds the relay limit.");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(body);
  } catch {
    throw new RelayHTTPError(400, "invalid_utf8", "JSON body must be valid UTF-8.");
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new RelayHTTPError(400, "invalid_json", "Request body is not valid JSON.");
  }
}

function requireBearerToken(request: Request): string {
  const authorization = request.headers.get("Authorization");
  if (authorization === null || !authorization.startsWith("Bearer ")) {
    throw unauthorized();
  }
  const token = authorization.slice("Bearer ".length);
  if (!TOKEN_PATTERN.test(token)) {
    throw unauthorized();
  }
  return token;
}

function unauthorized(): RelayHTTPError {
  return new RelayHTTPError(401, "unauthorized", "Bearer credentials are missing or invalid.", {
    "WWW-Authenticate": "Bearer",
  });
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqualHex(left: string, right: string): boolean {
  const leftBytes = hexBytes(left);
  const rightBytes = hexBytes(right);
  if (leftBytes === null || rightBytes === null || leftBytes.byteLength !== rightBytes.byteLength) {
    return false;
  }
  return crypto.subtle.timingSafeEqual(leftBytes, rightBytes);
}

function hexBytes(value: string): Uint8Array | null {
  if (!/^[0-9a-f]+$/i.test(value) || value.length % 2 !== 0) return null;
  const bytes = new Uint8Array(value.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    const pair = value.slice(index * 2, index * 2 + 2);
    bytes[index] = Number.parseInt(pair, 16);
  }
  return bytes;
}

function decodedBase64Length(value: string): number {
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return (value.length / 4) * 3 - padding;
}

function readSocketAttachment(socket: WebSocket): SocketAttachment | null {
  const attachment = socket.deserializeAttachment() as unknown;
  if (!isRecord(attachment)) return null;
  const { role, connectionID, connectedAtEpochMilliseconds } = attachment;
  if (
    role !== "mac" ||
    typeof connectionID !== "string" ||
    !UUID_PATTERN.test(connectionID) ||
    typeof connectedAtEpochMilliseconds !== "number"
  ) {
    return null;
  }
  return { role, connectionID, connectedAtEpochMilliseconds };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function utf8ByteLength(value: string): number {
  return new TextEncoder().encode(value).byteLength;
}

function jsonResponse(body: unknown, status = 200, extraHeaders?: HeadersInit): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(JSON.stringify(body), { status, headers });
}

function methodNotAllowed(methods: string[]): Response {
  return jsonResponse(
    { error: { code: "method_not_allowed", message: "HTTP method is not allowed for this route." } },
    405,
    { Allow: methods.join(", ") },
  );
}

function errorResponse(error: unknown): Response {
  if (error instanceof RelayHTTPError) {
    return jsonResponse(
      { error: { code: error.code, message: error.message } },
      error.status,
      error.headers,
    );
  }
  console.error(
    "Unhandled relay failure",
    error instanceof Error ? error.name : typeof error,
  );
  return jsonResponse(
    { error: { code: "internal_error", message: "Unexpected relay failure." } },
    500,
  );
}
