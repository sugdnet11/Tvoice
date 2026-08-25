export async function GET() {
  return Response.json(
    {
      wsUrl: process.env.TVOICE_WS_URL || "wss://chat.185-177-2-115.sslip.io/v1/ws",
      sipWssUrl: process.env.TVOICE_SIP_WSS_URL || "",
      pushPublicKey: process.env.TVOICE_PUSH_PUBLIC_KEY || "",
    },
    { headers: { "cache-control": "no-store" } },
  );
}
