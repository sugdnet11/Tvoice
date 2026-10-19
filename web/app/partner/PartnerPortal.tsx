"use client";

import { useEffect, useMemo, useState } from "react";

type Company = {
  code: string;
  name: string;
  logoUrl?: string | null;
  sip: { host: string; port: number; transport: string };
};

export function PartnerPortal() {
  const [code, setCode] = useState("");
  const [key, setKey] = useState("");
  const [company, setCompany] = useState<Company | null>(null);
  const [directory, setDirectory] = useState("");
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    setCode(sessionStorage.getItem("tvoice.partner.code") || "");
    setKey(sessionStorage.getItem("tvoice.partner.key") || "");
  }, []);

  const headers = useMemo(() => ({
    "content-type": "application/json",
    "x-tenant-code": code.trim().toUpperCase(),
    "x-tenant-key": key.trim(),
  }), [code, key]);

  async function connect() {
    setBusy(true);
    setStatus("");
    try {
      const response = await fetch("/api/tvoice/partner/tenant", { headers });
      const data = await response.json();
      if (!response.ok) throw new Error(data.error === "unauthorized" ? "Неверный код или ключ" : "Не удалось подключиться");
      setCompany(data.company);
      sessionStorage.setItem("tvoice.partner.code", code.trim().toUpperCase());
      sessionStorage.setItem("tvoice.partner.key", key.trim());
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Ошибка подключения");
    } finally {
      setBusy(false);
    }
  }

  async function importDirectory() {
    const users = directory.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).map((line) => {
      const [sipNumber, ...nameParts] = line.split(/[;,\t]/);
      return { sipNumber: sipNumber?.trim(), displayName: nameParts.join(" ").trim(), isActive: true };
    });
    if (users.some((user) => !user.sipNumber || !user.displayName)) {
      setStatus("Формат строки: SIP-номер;Имя сотрудника");
      return;
    }
    setBusy(true);
    setStatus("");
    try {
      const response = await fetch("/api/tvoice/partner/directory", {
        method: "PUT",
        headers,
        body: JSON.stringify({ users }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error("Импорт не выполнен");
      setStatus(`Синхронизировано абонентов: ${data.imported}`);
    } catch (error) {
      setStatus(error instanceof Error ? error.message : "Ошибка импорта");
    } finally {
      setBusy(false);
    }
  }

  if (!company) {
    return <main className="partner-page">
      <section className="partner-card partner-login">
        <div className="partner-mark">T</div>
        <p className="eyebrow">TVОICE PARTNER</p>
        <h1>Портал компании</h1>
        <p className="muted">Управление корпоративным пространством, SIP-профилем и каталогом абонентов.</p>
        <label>Код компании<input value={code} onChange={(event) => setCode(event.target.value.toUpperCase())} placeholder="COMPANY01" /></label>
        <label>Ключ администратора<input type="password" value={key} onChange={(event) => setKey(event.target.value)} /></label>
        {status && <p className="form-error" role="status" aria-live="polite">{status}</p>}
        <button onClick={connect} disabled={busy || !code.trim() || !key.trim()}>{busy ? "Проверяем…" : "Войти"}</button>
      </section>
    </main>;
  }

  const invite = `tvoice://company?code=${encodeURIComponent(company.code)}`;
  return <main className="partner-page">
    <div className="partner-shell">
      <header className="partner-header">
        <div><p className="eyebrow">TVОICE PARTNER</p><h1>{company.name}</h1><p className="muted">Код компании: <strong>{company.code}</strong></p></div>
        <button className="partner-secondary" onClick={() => {
          setCompany(null);
          sessionStorage.removeItem("tvoice.partner.code");
          sessionStorage.removeItem("tvoice.partner.key");
        }}>Выйти</button>
      </header>
      <section className="partner-grid">
        <article className="partner-card">
          <h2>Подключение сотрудников</h2>
          <p className="muted">Передайте сотрудникам код или ссылку. После выбора компании им нужен только SIP-логин и пароль.</p>
          <div className="partner-code">{company.code}</div>
          <button onClick={() => navigator.clipboard.writeText(invite)}>Скопировать ссылку подключения</button>
        </article>
        <article className="partner-card">
          <h2>SIP-профиль</h2>
          <dl><dt>Сервер</dt><dd>{company.sip.host}</dd><dt>Порт</dt><dd>{company.sip.port}</dd><dt>Транспорт</dt><dd>{company.sip.transport.toUpperCase()}</dd></dl>
          <p className="muted">Пароли пользователей не хранятся в Tvoice: их проверяет сервер вашей компании.</p>
        </article>
        <article className="partner-card partner-directory">
          <h2>Каталог абонентов</h2>
          <p className="muted">Одна строка на сотрудника: <code>75566;Фарид Усманов</code>. Новый импорт заменяет активный каталог.</p>
          <textarea value={directory} onChange={(event) => setDirectory(event.target.value)} placeholder={"75566;Фарид Усманов\n78088;Мадина Саидова"} />
          {status && <p className={status.startsWith("Синхронизировано") ? "partner-success" : "form-error"} role="status" aria-live="polite">{status}</p>}
          <button onClick={importDirectory} disabled={busy || !directory.trim()}>{busy ? "Синхронизация…" : "Синхронизировать каталог"}</button>
        </article>
      </section>
    </div>
  </main>;
}
