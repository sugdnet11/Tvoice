import type { Metadata, Viewport } from "next";
import { headers } from "next/headers";
import "./globals.css";
import { ServiceWorkerRegistrar } from "./ServiceWorkerRegistrar";

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") || requestHeaders.get("host") || "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") || (host.startsWith("localhost") ? "http" : "https");
  const origin = `${protocol}://${host}`;
  const title = "Tvoice — звонки и сообщения";
  const description = "Tvoice для звонков, видеосвязи и общения между абонентами.";
  const image = new URL("/og-1200x630.png", origin).href;
  return {
    metadataBase: new URL(origin),
    title,
    description,
    applicationName: "Tvoice",
    manifest: "/manifest.webmanifest",
    appleWebApp: {
      capable: true,
      title: "Tvoice",
      statusBarStyle: "black-translucent",
    },
    icons: {
      icon: "/tvoice-icon.png",
      apple: "/tvoice-icon.png",
    },
    openGraph: {
      type: "website",
      title,
      description,
      images: [{ url: image, width: 1200, height: 630, alt: "Tvoice — звонки, видео и чаты" }],
    },
    twitter: {
      card: "summary_large_image",
      title,
      description,
      images: [image],
    },
  };
}

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#f4f7fb",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="ru">
      <body>
        {children}
        <ServiceWorkerRegistrar />
      </body>
    </html>
  );
}
