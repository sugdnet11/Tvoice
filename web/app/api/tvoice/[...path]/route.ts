import type { NextRequest } from "next/server";

const DEFAULT_API = "https://chat.185-177-2-115.sslip.io/v1";

type RouteContext = { params: Promise<{ path: string[] }> };

async function proxy(request: NextRequest, context: RouteContext) {
  const { path } = await context.params;
  const base = (process.env.TVOICE_API_BASE_URL || DEFAULT_API).replace(/\/$/, "");
  const incomingUrl = new URL(request.url);
  const target = new URL(`${base}/${path.map(encodeURIComponent).join("/")}`);
  target.search = incomingUrl.search;

  const headers = new Headers();
  for (const name of ["accept", "authorization", "content-type", "content-length"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }

  const body = request.method === "GET" || request.method === "HEAD"
    ? undefined
    : await request.arrayBuffer();

  const upstream = await fetch(target, {
    method: request.method,
    headers,
    body,
    redirect: "manual",
  });

  const responseHeaders = new Headers();
  for (const name of ["content-type", "content-length", "content-disposition", "etag", "last-modified"]) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders.set(name, value);
  }
  responseHeaders.set("cache-control", "no-store");
  return new Response(upstream.body, {
    status: upstream.status,
    headers: responseHeaders,
  });
}

export const GET = proxy;
export const POST = proxy;
export const PUT = proxy;
export const PATCH = proxy;
export const DELETE = proxy;
