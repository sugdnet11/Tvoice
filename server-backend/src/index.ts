import { randomBytes, randomUUID, scrypt, timingSafeEqual } from "node:crypto";
import Fastify, {
  type FastifyReply,
  type FastifyRequest,
} from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import websocket from "@fastify/websocket";
import { SignJWT, jwtVerify } from "jose";
import { AccessToken } from "livekit-server-sdk";
import pg from "pg";
import { z } from "zod";

const envSchema = z.object({
  DATABASE_URL: z.string().min(1),
  JWT_SECRET: z.string().min(32),
  ADMIN_KEY: z.string().min(32),
  FREEPBX_AUTH_URL: z.preprocess(
    (value) => value === "" ? undefined : value,
    z.string().url().optional(),
  ),
  FREEPBX_API_KEY: z.preprocess(
    (value) => value === "" ? undefined : value,
    z.string().min(32).optional(),
  ),
  LIVEKIT_API_KEY: z.preprocess(
    (value) => value === "" ? undefined : value,
    z.string().min(8).optional(),
  ),
  LIVEKIT_API_SECRET: z.preprocess(
    (value) => value === "" ? undefined : value,
    z.string().min(32).optional(),
  ),
  LIVEKIT_WS_URL: z.preprocess(
    (value) => value === "" ? undefined : value,
    z.string().url().startsWith("wss://").optional(),
  ),
  PORT: z.coerce.number().int().positive().default(8080),
  LOG_LEVEL: z.string().default("info"),
}).superRefine((value, context) => {
  if (Boolean(value.FREEPBX_AUTH_URL) !== Boolean(value.FREEPBX_API_KEY)) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "FREEPBX_AUTH_URL and FREEPBX_API_KEY must be configured together",
    });
  }
  const liveKitValues = [
    value.LIVEKIT_API_KEY,
    value.LIVEKIT_API_SECRET,
    value.LIVEKIT_WS_URL,
  ].filter(Boolean).length;
  if (liveKitValues !== 0 && liveKitValues !== 3) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "LIVEKIT_API_KEY, LIVEKIT_API_SECRET and LIVEKIT_WS_URL must be configured together",
    });
  }
});

const env = envSchema.parse(process.env);
const jwtSecret = new TextEncoder().encode(env.JWT_SECRET);
const pool = new pg.Pool({
  connectionString: env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

type AuthUser = {
  id: string;
  sipNumber: string;
  displayName: string;
};

type RequestWithUser = FastifyRequest & {
  authUser?: AuthUser;
};

const app = Fastify({
  logger: { level: env.LOG_LEVEL },
  bodyLimit: 32 * 1024,
  trustProxy: true,
});

await app.register(cors, { origin: false });
await app.register(rateLimit, {
  max: 240,
  timeWindow: "1 minute",
});
await app.register(websocket);

function safeEqual(left: string, right: string): boolean {
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

function scryptPassword(
  password: string,
  salt: Buffer,
  keyLength: number,
  cost: number,
): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(
      password,
      salt,
      keyLength,
      { N: cost, r: 8, p: 1, maxmem: 64 * 1024 * 1024 },
      (error, derivedKey) => {
        if (error) reject(error);
        else resolve(derivedKey);
      },
    );
  });
}

async function hashPassword(password: string): Promise<string> {
  const cost = 16_384;
  const salt = randomBytes(16);
  const hash = await scryptPassword(password, salt, 64, cost);
  return [
    "scrypt",
    cost.toString(),
    "8",
    "1",
    salt.toString("base64"),
    hash.toString("base64"),
  ].join("$");
}

async function verifyPassword(
  password: string,
  encoded: string,
): Promise<boolean> {
  const [algorithm, costText, , , saltText, hashText] = encoded.split("$");
  if (
    algorithm !== "scrypt" ||
    !costText ||
    !saltText ||
    !hashText
  ) {
    return false;
  }

  const expected = Buffer.from(hashText, "base64");
  const actual = await scryptPassword(
    password,
    Buffer.from(saltText, "base64"),
    expected.length,
    Number(costText),
  );
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

async function issueToken(user: AuthUser): Promise<string> {
  return new SignJWT({
    sipNumber: user.sipNumber,
    displayName: user.displayName,
  })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setSubject(user.id)
    .setIssuedAt()
    .setExpirationTime("30d")
    .sign(jwtSecret);
}

async function tokenUser(token: string): Promise<AuthUser | null> {
  try {
    const { payload } = await jwtVerify(token, jwtSecret, {
      algorithms: ["HS256"],
    });
    if (
      !payload.sub ||
      typeof payload.sipNumber !== "string" ||
      typeof payload.displayName !== "string"
    ) {
      return null;
    }
    return {
      id: payload.sub,
      sipNumber: payload.sipNumber,
      displayName: payload.displayName,
    };
  } catch {
    return null;
  }
}

async function requireAuth(
  request: RequestWithUser,
  reply: FastifyReply,
): Promise<void> {
  const authorization = request.headers.authorization;
  if (!authorization?.startsWith("Bearer ")) {
    return reply.code(401).send({ error: "unauthorized" });
  }

  const user = await tokenUser(authorization.slice(7));
  if (!user) {
    return reply.code(401).send({ error: "invalid_token" });
  }

  request.authUser = user;
}

function currentUser(request: RequestWithUser): AuthUser {
  if (!request.authUser) throw new Error("Missing authenticated user");
  return request.authUser;
}

async function requireAdmin(request: FastifyRequest, reply: FastifyReply) {
  const key = request.headers["x-admin-key"];
  if (typeof key !== "string" || !safeEqual(key, env.ADMIN_KEY)) {
    return reply.code(401).send({ error: "unauthorized" });
  }
}

const sockets = new Map<string, Set<{ readyState: number; send: (data: string) => void }>>();

function publish(userIds: string[], event: unknown): Set<string> {
  const payload = JSON.stringify(event);
  const delivered = new Set<string>();
  for (const userId of new Set(userIds)) {
    for (const socket of sockets.get(userId) ?? []) {
      if (socket.readyState === 1) {
        socket.send(payload);
        delivered.add(userId);
      }
    }
  }
  return delivered;
}

type VideoCallSession = {
  id: string;
  room: string;
  caller: AuthUser;
  callee: AuthUser;
  createdAt: number;
  state: "ringing" | "connected";
};

const videoCalls = new Map<string, VideoCallSession>();
const VIDEO_CALL_TTL_MS = 2 * 60_000;

function liveKitConfigured(): boolean {
  return Boolean(env.LIVEKIT_API_KEY && env.LIVEKIT_API_SECRET && env.LIVEKIT_WS_URL);
}

async function issueVideoToken(user: AuthUser, room: string): Promise<string> {
  if (!liveKitConfigured()) throw new Error("LiveKit is not configured");
  const token = new AccessToken(env.LIVEKIT_API_KEY!, env.LIVEKIT_API_SECRET!, {
    identity: user.sipNumber,
    name: user.displayName,
    ttl: "10m",
  });
  token.addGrant({
    roomJoin: true,
    room,
    canPublish: true,
    canSubscribe: true,
  });
  return token.toJwt();
}

function otherVideoParticipant(call: VideoCallSession, user: AuthUser): AuthUser | null {
  if (call.caller.id === user.id) return call.callee;
  if (call.callee.id === user.id) return call.caller;
  return null;
}

function currentVideoCall(callId: string): VideoCallSession | null {
  const call = videoCalls.get(callId);
  if (!call) return null;
  if (Date.now() - call.createdAt <= VIDEO_CALL_TTL_MS) return call;
  videoCalls.delete(callId);
  publish([call.caller.id, call.callee.id], {
    type: "video.call.ended",
    callId,
    reason: "timeout",
  });
  return null;
}

app.get("/health", async (_request, reply) => {
  await pool.query("SELECT 1");
  return reply.send({
    status: "ok",
    service: "tvoice-chat",
    version: "0.4.0",
    video: liveKitConfigured() ? "ready" : "disabled",
  });
});

const freePbxUserSchema = z.object({
  sipNumber: z.string().regex(/^[0-9*#+]{2,32}$/),
  displayName: z.string().min(1).max(120),
});

const freePbxAuthResponseSchema = z.object({ user: freePbxUserSchema });
const freePbxUsersResponseSchema = z.object({ users: z.array(freePbxUserSchema) });

function freePbxConfigured(): boolean {
  return Boolean(env.FREEPBX_AUTH_URL && env.FREEPBX_API_KEY);
}

function freePbxUrl(action: "auth" | "users"): string {
  const url = new URL(env.FREEPBX_AUTH_URL!);
  url.searchParams.set("action", action);
  return url.toString();
}

async function freePbxRequest(
  action: "auth" | "users",
  init?: RequestInit,
): Promise<Response> {
  return fetch(freePbxUrl(action), {
    ...init,
    headers: {
      accept: "application/json",
      "x-tvoice-key": env.FREEPBX_API_KEY!,
      ...(init?.body ? { "content-type": "application/json" } : {}),
      ...init?.headers,
    },
    signal: AbortSignal.timeout(5_000),
  });
}

async function authenticateWithFreePbx(
  sipNumber: string,
  password: string,
): Promise<AuthUser | null> {
  const response = await freePbxRequest("auth", {
    method: "POST",
    body: JSON.stringify({ sipNumber, password }),
  });
  if (response.status === 401) return null;
  if (!response.ok) {
    throw new Error(`FreePBX auth returned HTTP ${response.status}`);
  }
  const parsed = freePbxAuthResponseSchema.parse(await response.json());
  const result = await pool.query<{
    id: string;
    sip_number: string;
    display_name: string;
  }>(
    `INSERT INTO users
       (sip_number, display_name, password_hash, is_active, auth_source)
     VALUES ($1, $2, 'external$freepbx', TRUE, 'freepbx')
     ON CONFLICT (sip_number) DO UPDATE SET
       display_name = EXCLUDED.display_name,
       is_active = TRUE,
       auth_source = 'freepbx'
     RETURNING id, sip_number, display_name`,
    [parsed.user.sipNumber, parsed.user.displayName],
  );
  const row = result.rows[0]!;
  return {
    id: row.id,
    sipNumber: row.sip_number,
    displayName: row.display_name,
  };
}

async function syncFreePbxDirectory(): Promise<number> {
  if (!freePbxConfigured()) return 0;
  const response = await freePbxRequest("users");
  if (!response.ok) {
    throw new Error(`FreePBX directory returned HTTP ${response.status}`);
  }
  const { users } = freePbxUsersResponseSchema.parse(await response.json());
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    for (const user of users) {
      await client.query(
        `INSERT INTO users
           (sip_number, display_name, password_hash, is_active, auth_source)
         VALUES ($1, $2, 'external$freepbx', TRUE, 'freepbx')
         ON CONFLICT (sip_number) DO UPDATE SET
           display_name = EXCLUDED.display_name,
           is_active = TRUE,
           auth_source = 'freepbx'`,
        [user.sipNumber, user.displayName],
      );
    }
    const numbers = users.map((user) => user.sipNumber);
    await client.query(
      `UPDATE users
       SET is_active = FALSE
       WHERE auth_source = 'freepbx'
         AND NOT (sip_number = ANY($1::text[]))`,
      [numbers],
    );
    await client.query("COMMIT");
    return users.length;
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}

const loginSchema = z.object({
  sipNumber: z.string().trim().regex(/^[0-9*#+]{2,32}$/),
  password: z.string().min(1).max(256),
});

app.post(
  "/v1/auth/login",
  {
    config: {
      rateLimit: { max: 10, timeWindow: "1 minute" },
    },
  },
  async (request, reply) => {
    const parsed = loginSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request" });
    }

    if (freePbxConfigured()) {
      try {
        const user = await authenticateWithFreePbx(
          parsed.data.sipNumber,
          parsed.data.password,
        );
        if (!user) {
          return reply.code(401).send({ error: "invalid_credentials" });
        }
        void syncFreePbxDirectory().catch((error: unknown) => {
          app.log.warn({ err: error }, "FreePBX directory sync failed after login");
        });
        return reply.send({
          accessToken: await issueToken(user),
          tokenType: "Bearer",
          expiresIn: 2_592_000,
          user,
        });
      } catch (error) {
        app.log.error({ err: error }, "FreePBX authentication provider failed");
        return reply.code(503).send({ error: "auth_provider_unavailable" });
      }
    }

    const result = await pool.query<{
      id: string;
      sip_number: string;
      display_name: string;
      password_hash: string;
      is_active: boolean;
    }>(
      `SELECT id, sip_number, display_name, password_hash, is_active
       FROM users
       WHERE sip_number = $1`,
      [parsed.data.sipNumber],
    );
    const row = result.rows[0];
    if (
      !row ||
      !row.is_active ||
      !(await verifyPassword(parsed.data.password, row.password_hash))
    ) {
      return reply.code(401).send({ error: "invalid_credentials" });
    }

    const user: AuthUser = {
      id: row.id,
      sipNumber: row.sip_number,
      displayName: row.display_name,
    };
    return reply.send({
      accessToken: await issueToken(user),
      tokenType: "Bearer",
      expiresIn: 2_592_000,
      user,
    });
  },
);

const adminUserSchema = z.object({
  sipNumber: z.string().trim().regex(/^[0-9*#+]{2,32}$/),
  displayName: z.string().trim().min(1).max(120),
  password: z.string().min(1).max(256),
  isActive: z.boolean().default(true),
});

app.post(
  "/v1/admin/users",
  {
    preHandler: requireAdmin,
    config: {
      rateLimit: { max: 30, timeWindow: "1 minute" },
    },
  },
  async (request, reply) => {
    const parsed = adminUserSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({
        error: "invalid_request",
        details: parsed.error.flatten(),
      });
    }

    const passwordHash = await hashPassword(parsed.data.password);
    const result = await pool.query<{
      id: string;
      sip_number: string;
      display_name: string;
      is_active: boolean;
    }>(
      `INSERT INTO users (sip_number, display_name, password_hash, is_active)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (sip_number) DO UPDATE SET
         display_name = EXCLUDED.display_name,
         password_hash = EXCLUDED.password_hash,
         is_active = EXCLUDED.is_active
       RETURNING id, sip_number, display_name, is_active`,
      [
        parsed.data.sipNumber,
        parsed.data.displayName,
        passwordHash,
        parsed.data.isActive,
      ],
    );
    const row = result.rows[0]!;
    return reply.code(201).send({
      id: row.id,
      sipNumber: row.sip_number,
      displayName: row.display_name,
      isActive: row.is_active,
    });
  },
);

app.get(
  "/v1/me",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    return reply.send({ user: currentUser(request) });
  },
);

app.get(
  "/v1/contacts",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    const user = currentUser(request);
    const result = await pool.query<{
      id: string;
      sip_number: string;
      display_name: string;
    }>(
      `SELECT id, sip_number, display_name
       FROM users
       WHERE is_active = TRUE AND id <> $1
       ORDER BY display_name, sip_number`,
      [user.id],
    );
    return reply.send({
      contacts: result.rows.map((row) => ({
        id: row.id,
        sipNumber: row.sip_number,
        displayName: row.display_name,
      })),
    });
  },
);

const videoCallSchema = z.object({
  peerSipNumber: z.string().trim().regex(/^[0-9*#+]{2,32}$/),
});

app.post(
  "/v1/video/calls",
  {
    preHandler: requireAuth,
    config: { rateLimit: { max: 20, timeWindow: "1 minute" } },
  },
  async (request: RequestWithUser, reply) => {
    if (!liveKitConfigured()) {
      return reply.code(503).send({ error: "video_unavailable" });
    }
    const parsed = videoCallSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: "invalid_request" });
    const caller = currentUser(request);
    const result = await pool.query<{
      id: string;
      sip_number: string;
      display_name: string;
    }>(
      `SELECT id, sip_number, display_name FROM users
       WHERE sip_number = $1 AND is_active = TRUE`,
      [parsed.data.peerSipNumber],
    );
    const row = result.rows[0];
    if (!row) return reply.code(404).send({ error: "contact_not_found" });
    if (row.id === caller.id) {
      return reply.code(400).send({ error: "cannot_call_yourself" });
    }
    const callee: AuthUser = {
      id: row.id,
      sipNumber: row.sip_number,
      displayName: row.display_name,
    };
    const id = randomUUID();
    const room = `tvoice-${id}`;
    const call: VideoCallSession = {
      id,
      room,
      caller,
      callee,
      createdAt: Date.now(),
      state: "ringing",
    };
    videoCalls.set(id, call);
    setTimeout(() => {
      const active = videoCalls.get(id);
      if (active !== call || active.state !== "ringing") return;
      videoCalls.delete(id);
      publish([caller.id, callee.id], {
        type: "video.call.ended",
        callId: id,
        reason: "timeout",
      });
    }, VIDEO_CALL_TTL_MS).unref();
    const expiresAt = new Date(call.createdAt + VIDEO_CALL_TTL_MS).toISOString();
    const delivered = publish([callee.id], {
      type: "video.call.incoming",
      callId: id,
      from: caller,
      expiresAt,
    }).has(callee.id);
    return reply.code(201).send({
      callId: id,
      room,
      url: env.LIVEKIT_WS_URL,
      token: await issueVideoToken(caller, room),
      peer: callee,
      expiresAt,
      delivered,
    });
  },
);

app.post(
  "/v1/video/calls/:callId/answer",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    const user = currentUser(request);
    const callId = z.string().uuid().safeParse(
      (request.params as { callId?: string }).callId,
    );
    if (!callId.success) return reply.code(400).send({ error: "invalid_request" });
    const call = currentVideoCall(callId.data);
    if (!call) return reply.code(404).send({ error: "call_not_found" });
    if (call.callee.id !== user.id) return reply.code(403).send({ error: "forbidden" });
    call.state = "connected";
    publish([call.caller.id], { type: "video.call.answered", callId: call.id });
    return reply.send({
      callId: call.id,
      room: call.room,
      url: env.LIVEKIT_WS_URL,
      token: await issueVideoToken(user, call.room),
      peer: call.caller,
    });
  },
);

for (const action of ["reject", "end"] as const) {
  app.post(
    `/v1/video/calls/:callId/${action}`,
    { preHandler: requireAuth },
    async (request: RequestWithUser, reply) => {
      const user = currentUser(request);
      const callId = z.string().uuid().safeParse(
        (request.params as { callId?: string }).callId,
      );
      if (!callId.success) return reply.code(400).send({ error: "invalid_request" });
      const call = currentVideoCall(callId.data);
      if (!call) return reply.code(404).send({ error: "call_not_found" });
      const peer = otherVideoParticipant(call, user);
      if (!peer) return reply.code(403).send({ error: "forbidden" });
      publish([peer.id], {
        type: action === "reject" ? "video.call.rejected" : "video.call.ended",
        callId: call.id,
        by: user.sipNumber,
      });
      videoCalls.delete(call.id);
      return reply.code(204).send();
    },
  );
}

const directSchema = z.object({
  peerSipNumber: z.string().trim().regex(/^[0-9*#+]{2,32}$/),
});

app.post(
  "/v1/conversations/direct",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    const parsed = directSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid_request" });
    }

    const user = currentUser(request);
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      const peerResult = await client.query<{
        id: string;
        sip_number: string;
        display_name: string;
      }>(
        `SELECT id, sip_number, display_name
         FROM users
         WHERE sip_number = $1 AND is_active = TRUE`,
        [parsed.data.peerSipNumber],
      );
      const peer = peerResult.rows[0];
      if (!peer) {
        await client.query("ROLLBACK");
        return reply.code(404).send({ error: "contact_not_found" });
      }
      if (peer.id === user.id) {
        await client.query("ROLLBACK");
        return reply.code(400).send({ error: "cannot_message_yourself" });
      }

      const [low, high] = [user.id, peer.id].sort();
      await client.query("SELECT pg_advisory_xact_lock(hashtext($1))", [
        `${low}:${high}`,
      ]);
      const existing = await client.query<{ conversation_id: string }>(
        `SELECT conversation_id
         FROM direct_conversations
         WHERE user_low = $1 AND user_high = $2`,
        [low, high],
      );

      let conversationId = existing.rows[0]?.conversation_id;
      if (!conversationId) {
        const conversation = await client.query<{ id: string }>(
          "INSERT INTO conversations DEFAULT VALUES RETURNING id",
        );
        conversationId = conversation.rows[0]!.id;
        await client.query(
          `INSERT INTO direct_conversations
             (conversation_id, user_low, user_high)
           VALUES ($1, $2, $3)`,
          [conversationId, low, high],
        );
        await client.query(
          `INSERT INTO conversation_members (conversation_id, user_id)
           VALUES ($1, $2), ($1, $3)`,
          [conversationId, user.id, peer.id],
        );
      }

      await client.query("COMMIT");
      return reply.code(201).send({
        conversation: {
          id: conversationId,
          peer: {
            id: peer.id,
            sipNumber: peer.sip_number,
            displayName: peer.display_name,
          },
        },
      });
    } catch (error) {
      await client.query("ROLLBACK");
      throw error;
    } finally {
      client.release();
    }
  },
);

app.get(
  "/v1/conversations",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    const user = currentUser(request);
    const result = await pool.query<{
      id: string;
      peer_id: string;
      peer_sip_number: string;
      peer_display_name: string;
      last_message_id: string | null;
      last_message_body: string | null;
      last_message_created_at: string | null;
    }>(
      `SELECT
         c.id,
         peer.id AS peer_id,
         peer.sip_number AS peer_sip_number,
         peer.display_name AS peer_display_name,
         last_message.id AS last_message_id,
         last_message.body AS last_message_body,
         last_message.created_at AS last_message_created_at
       FROM conversation_members mine
       JOIN conversations c ON c.id = mine.conversation_id
       JOIN conversation_members other
         ON other.conversation_id = c.id AND other.user_id <> $1
       JOIN users peer ON peer.id = other.user_id
       LEFT JOIN LATERAL (
         SELECT id, body, created_at
         FROM messages
         WHERE conversation_id = c.id
         ORDER BY id DESC
         LIMIT 1
       ) last_message ON TRUE
       WHERE mine.user_id = $1
       ORDER BY COALESCE(last_message.created_at, c.created_at) DESC`,
      [user.id],
    );
    return reply.send({
      conversations: result.rows.map((row) => ({
        id: row.id,
        peer: {
          id: row.peer_id,
          sipNumber: row.peer_sip_number,
          displayName: row.peer_display_name,
        },
        lastMessage: row.last_message_id
          ? {
              id: row.last_message_id,
              body: row.last_message_body,
              createdAt: row.last_message_created_at,
            }
          : null,
      })),
    });
  },
);

const messagesQuerySchema = z.object({
  before: z.coerce.number().int().positive().optional(),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});

app.get(
  "/v1/conversations/:conversationId/messages",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    const user = currentUser(request);
    const conversationId = z.string().uuid().safeParse(
      (request.params as { conversationId?: string }).conversationId,
    );
    const query = messagesQuerySchema.safeParse(request.query);
    if (!conversationId.success || !query.success) {
      return reply.code(400).send({ error: "invalid_request" });
    }

    const membership = await pool.query(
      `SELECT 1 FROM conversation_members
       WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId.data, user.id],
    );
    if (membership.rowCount === 0) {
      return reply.code(404).send({ error: "conversation_not_found" });
    }

    const result = await pool.query<{
      id: string;
      sender_id: string;
      sip_number: string;
      display_name: string;
      body: string;
      created_at: string;
      delivered: boolean;
      read: boolean;
    }>(
      `SELECT
         m.id, m.sender_id, u.sip_number, u.display_name, m.body, m.created_at,
         (peer_member.last_delivered_at IS NOT NULL AND peer_member.last_delivered_at >= m.created_at) AS delivered,
         (peer_member.last_read_at IS NOT NULL AND peer_member.last_read_at >= m.created_at) AS read
       FROM messages m
       JOIN users u ON u.id = m.sender_id
       JOIN conversation_members peer_member
         ON peer_member.conversation_id = m.conversation_id AND peer_member.user_id <> $2
       WHERE m.conversation_id = $1
         AND ($3::BIGINT IS NULL OR m.id < $3)
       ORDER BY m.id DESC
       LIMIT $4`,
      [
        conversationId.data,
        user.id,
        query.data.before ?? null,
        query.data.limit,
      ],
    );
    const newestIncoming = result.rows
      .find((row) => row.sender_id !== user.id);
    if (newestIncoming) {
      await pool.query(
        `UPDATE conversation_members
         SET last_delivered_at = GREATEST(
           COALESCE(last_delivered_at, 'epoch'::timestamptz),
           (SELECT created_at FROM messages WHERE id = $3 AND conversation_id = $1)
         )
         WHERE conversation_id = $1 AND user_id = $2`,
        [conversationId.data, user.id, newestIncoming.id],
      );
      const peers = await pool.query<{ user_id: string }>(
        `SELECT user_id FROM conversation_members
         WHERE conversation_id = $1 AND user_id <> $2`,
        [conversationId.data, user.id],
      );
      publish(peers.rows.map((row) => row.user_id), {
        type: "message.delivered",
        conversationId: conversationId.data,
        throughCreatedAt: newestIncoming.created_at,
      });
    }
    return reply.send({
      messages: result.rows.reverse().map((row) => ({
        id: row.id,
        sender: {
          id: row.sender_id,
          sipNumber: row.sip_number,
          displayName: row.display_name,
        },
        body: row.body,
        createdAt: row.created_at,
        status: row.sender_id !== user.id ? "received" : row.read ? "read" : row.delivered ? "delivered" : "sent",
      })),
    });
  },
);

const messageSchema = z.object({
  body: z.string().trim().min(1).max(4000),
});

app.post(
  "/v1/conversations/:conversationId/messages",
  {
    preHandler: requireAuth,
    config: {
      rateLimit: { max: 60, timeWindow: "1 minute" },
    },
  },
  async (request: RequestWithUser, reply) => {
    const user = currentUser(request);
    const conversationId = z.string().uuid().safeParse(
      (request.params as { conversationId?: string }).conversationId,
    );
    const parsed = messageSchema.safeParse(request.body);
    if (!conversationId.success || !parsed.success) {
      return reply.code(400).send({ error: "invalid_request" });
    }

    const members = await pool.query<{ user_id: string }>(
      `SELECT user_id
       FROM conversation_members
       WHERE conversation_id = $1`,
      [conversationId.data],
    );
    if (!members.rows.some((row) => row.user_id === user.id)) {
      return reply.code(404).send({ error: "conversation_not_found" });
    }

    const result = await pool.query<{
      id: string;
      created_at: string;
    }>(
      `INSERT INTO messages (conversation_id, sender_id, body)
       VALUES ($1, $2, $3)
       RETURNING id, created_at`,
      [conversationId.data, user.id, parsed.data.body],
    );
    const row = result.rows[0]!;
    const message = {
      id: row.id,
      conversationId: conversationId.data,
      sender: user,
      body: parsed.data.body,
      createdAt: row.created_at,
    };
    const recipients = members.rows
      .map((member) => member.user_id)
      .filter((memberId) => memberId !== user.id);
    const onlineRecipients = publish(
      members.rows.map((member) => member.user_id),
      { type: "message.new", message },
    );
    const deliveredNow = recipients.some((recipientId) => onlineRecipients.has(recipientId));
    if (deliveredNow) {
      await pool.query(
        `UPDATE conversation_members
         SET last_delivered_at = GREATEST(
           COALESCE(last_delivered_at, 'epoch'::timestamptz),
           (SELECT created_at FROM messages WHERE id = $3 AND conversation_id = $1)
         )
         WHERE conversation_id = $1 AND user_id = ANY($2::uuid[])`,
        [conversationId.data, recipients, row.id],
      );
      publish([user.id], {
        type: "message.delivered",
        conversationId: conversationId.data,
        throughCreatedAt: row.created_at,
      });
    }
    return reply.code(201).send({
      message: { ...message, status: deliveredNow ? "delivered" : "sent" },
    });
  },
);

app.post(
  "/v1/conversations/:conversationId/read",
  { preHandler: requireAuth },
  async (request: RequestWithUser, reply) => {
    const user = currentUser(request);
    const conversationId = z.string().uuid().safeParse(
      (request.params as { conversationId?: string }).conversationId,
    );
    if (!conversationId.success) {
      return reply.code(400).send({ error: "invalid_request" });
    }
    const membership = await pool.query(
      `SELECT 1 FROM conversation_members
       WHERE conversation_id = $1 AND user_id = $2`,
      [conversationId.data, user.id],
    );
    if (membership.rowCount === 0) {
      return reply.code(404).send({ error: "conversation_not_found" });
    }
    const updated = await pool.query<{ through_created_at: string }>(
      `WITH newest AS (
         SELECT m.created_at
         FROM messages m
         WHERE m.conversation_id = $1 AND m.sender_id <> $2
         ORDER BY m.id DESC LIMIT 1
       )
       UPDATE conversation_members member
       SET last_delivered_at = GREATEST(
             COALESCE(member.last_delivered_at, 'epoch'::timestamptz),
             newest.created_at
           ),
           last_read_at = GREATEST(
             COALESCE(member.last_read_at, 'epoch'::timestamptz),
             newest.created_at
           )
       FROM newest
       WHERE member.conversation_id = $1 AND member.user_id = $2
       RETURNING newest.created_at AS through_created_at`,
      [conversationId.data, user.id],
    );
    const throughCreatedAt = updated.rows[0]?.through_created_at;
    if (!throughCreatedAt) return reply.send({ readThrough: null });
    const peers = await pool.query<{ user_id: string }>(
      `SELECT user_id FROM conversation_members
       WHERE conversation_id = $1 AND user_id <> $2`,
      [conversationId.data, user.id],
    );
    publish(peers.rows.map((row) => row.user_id), {
      type: "message.read",
      conversationId: conversationId.data,
      throughCreatedAt,
    });
    return reply.send({ readThrough: throughCreatedAt });
  },
);

app.get(
  "/v1/ws",
  { websocket: true },
  async (socket, request) => {
    const url = new URL(request.url, "http://localhost");
    const token = url.searchParams.get("token");
    const user = token ? await tokenUser(token) : null;
    if (!user) {
      socket.close(1008, "Unauthorized");
      return;
    }

    const userSockets = sockets.get(user.id) ?? new Set();
    userSockets.add(socket);
    sockets.set(user.id, userSockets);
    socket.send(JSON.stringify({ type: "connected", user }));

    socket.on("message", (raw: unknown) => {
      if (String(raw) === "ping") socket.send("pong");
    });
    socket.on("close", () => {
      userSockets.delete(socket);
      if (userSockets.size === 0) sockets.delete(user.id);
    });
  },
);

app.setErrorHandler((error, request, reply) => {
  request.log.error({ error }, "Request failed");
  if (reply.sent) return;
  reply.code(500).send({ error: "internal_error" });
});

const shutdown = async (signal: string): Promise<void> => {
  app.log.info({ signal }, "Shutting down");
  await app.close();
  await pool.end();
  process.exit(0);
};

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

await app.listen({ host: "0.0.0.0", port: env.PORT });

if (freePbxConfigured()) {
  void syncFreePbxDirectory()
    .then((count) => app.log.info({ count }, "FreePBX directory synchronized"))
    .catch((error: unknown) => app.log.error({ err: error }, "Initial FreePBX directory sync failed"));
  setInterval(() => {
    void syncFreePbxDirectory()
      .then((count) => app.log.debug({ count }, "FreePBX directory synchronized"))
      .catch((error: unknown) => app.log.warn({ err: error }, "Scheduled FreePBX directory sync failed"));
  }, 5 * 60_000).unref();
}
