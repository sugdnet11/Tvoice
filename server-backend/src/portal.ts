const sharedStyles = `
  :root { color-scheme: light; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #10264a; background: #f3f7fd; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; background: radial-gradient(circle at top left, #e4f1ff 0, transparent 40%), #f3f7fd; }
  main { width: min(1080px, calc(100% - 32px)); margin: 0 auto; padding: 48px 0; }
  .card { background: rgba(255,255,255,.94); border: 1px solid #d8e3f1; border-radius: 24px; padding: 28px; box-shadow: 0 18px 50px rgba(22,67,120,.10); }
  .login { width: min(480px, 100%); margin: 8vh auto 0; }
  .mark { display: grid; place-items: center; width: 58px; height: 58px; border-radius: 18px; color: white; font-size: 28px; font-weight: 800; background: linear-gradient(145deg,#0b42ca,#1599ff); }
  .eyebrow { margin: 20px 0 4px; color: #087bee; font-size: 12px; font-weight: 800; letter-spacing: .16em; }
  h1 { margin: 0 0 10px; font-size: clamp(30px,5vw,48px); letter-spacing: -.04em; }
  h2 { margin: 0 0 10px; font-size: 22px; }
  p { line-height: 1.65; }
  .muted { color: #667892; }
  label { display: grid; gap: 8px; margin: 18px 0; font-weight: 700; }
  input, textarea { width: 100%; border: 1px solid #ccd9e9; border-radius: 14px; padding: 13px 15px; color: #10264a; background: white; font: inherit; outline: none; }
  input:focus, textarea:focus { border-color: #1184f4; box-shadow: 0 0 0 4px rgba(17,132,244,.12); }
  textarea { min-height: 220px; resize: vertical; }
  button, .button { display: inline-flex; justify-content: center; align-items: center; border: 0; border-radius: 14px; padding: 13px 18px; color: white; background: #087bee; font: inherit; font-weight: 800; cursor: pointer; text-decoration: none; }
  button:disabled { opacity: .55; cursor: wait; }
  .secondary { color: #10264a; background: #edf3fb; }
  .header { display: flex; justify-content: space-between; align-items: center; gap: 16px; margin-bottom: 24px; }
  .grid { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 20px; }
  .wide { grid-column: 1 / -1; }
  .code { margin: 18px 0; padding: 18px; border-radius: 14px; background: #edf6ff; color: #075eb3; font: 800 24px ui-monospace, monospace; letter-spacing: .08em; }
  dl { display: grid; grid-template-columns: 120px 1fr; gap: 12px; }
  dt { color: #71819a; } dd { margin: 0; font-weight: 700; }
  .status { min-height: 24px; color: #08704e; font-weight: 700; }
  .error { color: #c43030; }
  .legal { max-width: 820px; }
  .legal h2 { margin-top: 28px; }
  .legal a { color: #087bee; }
  @media (max-width: 720px) { main { padding: 24px 0; } .grid { grid-template-columns: 1fr; } .header { align-items: flex-start; } .card { padding: 22px; border-radius: 20px; } }
`;

export function partnerPortalHtml(): string {
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Tvoice Partner</title><style>${sharedStyles}</style></head><body>
  <main><section id="login" class="card login"><div class="mark">T</div><p class="eyebrow">TVOICE PARTNER</p><h1>Портал компании</h1><p class="muted">Управление корпоративным пространством, SIP-профилем и каталогом абонентов.</p>
  <label>Код компании<input id="code" autocomplete="username" placeholder="TOJIKTELECOM"></label><label>Ключ администратора<input id="key" type="password" autocomplete="current-password"></label><p id="loginStatus" class="status" role="status" aria-live="polite"></p><button id="connect">Войти</button></section>
  <section id="dashboard" hidden><header class="header"><div><p class="eyebrow">TVOICE PARTNER</p><h1 id="companyName"></h1><p class="muted">Код компании: <strong id="companyCode"></strong></p></div><button id="logout" class="secondary">Выйти</button></header><div class="grid">
  <article class="card"><h2>Подключение сотрудников</h2><p class="muted">Передайте сотрудникам код или ссылку. После выбора компании им нужен только SIP-логин и пароль.</p><div id="inviteCode" class="code"></div><button id="copy">Скопировать ссылку</button></article>
  <article class="card"><h2>SIP-профиль</h2><dl><dt>Сервер</dt><dd id="sipHost"></dd><dt>Порт</dt><dd id="sipPort"></dd><dt>Транспорт</dt><dd id="sipTransport"></dd></dl><p class="muted">SIP-пароли не сохраняются в Tvoice.</p></article>
  <article class="card wide"><h2>Каталог абонентов</h2><p class="muted">Одна строка на сотрудника: <code>75566;Фарид Усманов</code>. Новый импорт заменяет активный каталог.</p><textarea id="directory" placeholder="75566;Фарид Усманов&#10;78088;Мадина Саидова"></textarea><p id="directoryStatus" class="status" role="status" aria-live="polite"></p><button id="sync">Синхронизировать каталог</button></article>
  </div></section></main><script>
  const byId=(id)=>document.getElementById(id); let company=null;
  const credentials=()=>({'content-type':'application/json','x-tenant-code':byId('code').value.trim().toUpperCase(),'x-tenant-key':byId('key').value.trim()});
  byId('code').value=sessionStorage.getItem('tvoice.partner.code')||'TOJIKTELECOM'; byId('key').value=sessionStorage.getItem('tvoice.partner.key')||'';
  byId('connect').onclick=async()=>{ const button=byId('connect'); button.disabled=true; byId('loginStatus').textContent=''; try { const response=await fetch('/v1/partner/tenant',{headers:credentials()}); const data=await response.json(); if(!response.ok) throw new Error('Неверный код компании или ключ'); company=data.company; sessionStorage.setItem('tvoice.partner.code',company.code); sessionStorage.setItem('tvoice.partner.key',byId('key').value.trim()); byId('companyName').textContent=company.name; byId('companyCode').textContent=company.code; byId('inviteCode').textContent=company.code; byId('sipHost').textContent=company.sip.host; byId('sipPort').textContent=String(company.sip.port); byId('sipTransport').textContent=company.sip.transport.toUpperCase(); byId('login').hidden=true; byId('dashboard').hidden=false; } catch(error) { byId('loginStatus').textContent=error.message||'Ошибка подключения'; byId('loginStatus').classList.add('error'); } finally { button.disabled=false; } };
  byId('logout').onclick=()=>{ sessionStorage.removeItem('tvoice.partner.code'); sessionStorage.removeItem('tvoice.partner.key'); company=null; byId('key').value=''; byId('dashboard').hidden=true; byId('login').hidden=false; };
  byId('copy').onclick=async()=>{ if(!company)return; await navigator.clipboard.writeText('tvoice://company?code='+encodeURIComponent(company.code)); byId('copy').textContent='Ссылка скопирована'; };
  byId('sync').onclick=async()=>{ const status=byId('directoryStatus'); status.classList.remove('error'); const users=byId('directory').value.split(/\\r?\\n/).map(line=>line.trim()).filter(Boolean).map(line=>{const parts=line.split(/[;,\\t]/); return {sipNumber:(parts.shift()||'').trim(),displayName:parts.join(' ').trim(),isActive:true};}); if(!users.length||users.some(user=>!user.sipNumber||!user.displayName)){status.textContent='Формат строки: SIP-номер;Имя сотрудника';status.classList.add('error');return;} const button=byId('sync'); button.disabled=true; try { const response=await fetch('/v1/partner/directory',{method:'PUT',headers:credentials(),body:JSON.stringify({users})}); const data=await response.json(); if(!response.ok)throw new Error('Импорт не выполнен'); status.textContent='Синхронизировано абонентов: '+data.imported; } catch(error){status.textContent=error.message||'Ошибка импорта';status.classList.add('error');} finally{button.disabled=false;} };
  </script></body></html>`;
}

export function privacyHtml(): string {
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Политика конфиденциальности Tvoice</title><style>${sharedStyles}</style></head><body><main class="legal"><article class="card"><div class="mark">T</div><p class="eyebrow">TVOICE</p><h1>Политика конфиденциальности</h1><p class="muted">Дата обновления: 19 октября 2026 года</p>
  <h2>Какие данные обрабатываются</h2><p>Tvoice обрабатывает код компании, SIP-номер, отображаемое имя, сообщения, сведения о доставке сообщений, историю и технические данные звонков. Камера и микрофон используются только для функций связи после разрешения пользователя.</p>
  <h2>Авторизация</h2><p>SIP-пароль передаётся по защищённому HTTPS-соединению для проверки учётной записи и не записывается в базу данных Tvoice. Для работы SIP-связи приложение также устанавливает отдельное соединение с SIP-сервером выбранной компании.</p>
  <h2>Цели обработки</h2><p>Данные используются для авторизации, доставки сообщений, аудио- и видеосвязи, конференций, поддержки и защиты сервиса. Tvoice не продаёт персональные данные и не использует их для рекламного профилирования.</p>
  <h2>Хранение и защита</h2><p>Данные хранятся только в объёме, необходимом для работы сервиса и выполнения законных обязательств. Применяются разграничение доступа по компаниям, шифрование транспорта и ограниченные служебные ключи.</p>
  <h2>Удаление данных</h2><p>Учётные записи создаются оператором связи или вашей компанией, а не внутри приложения. Для удаления данных Tvoice используйте <a href="/data-deletion">страницу запроса на удаление</a>.</p>
  <h2>Контакты</h2><p>Оператор основной инфраструктуры — Tojiktelecom. Обратиться в поддержку можно через <a href="https://chat.tojiktelecom.tj/" rel="noreferrer">официального онлайн-консультанта</a>.</p></article></main></body></html>`;
}

export function dataDeletionHtml(): string {
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Удаление данных Tvoice</title><style>${sharedStyles}</style></head><body><main class="legal"><article class="card"><div class="mark">T</div><p class="eyebrow">TVOICE</p><h1>Удаление данных</h1><p>Tvoice не создаёт SIP-учётные записи внутри приложения. Их предоставляет Tojiktelecom или ваша организация.</p><h2>Как отправить запрос</h2><p>Откройте официальный онлайн-чат, укажите код компании, SIP-номер и попросите удалить данные Tvoice. Не отправляйте пароль.</p><p><a class="button" href="https://chat.tojiktelecom.tj/" rel="noreferrer">Открыть поддержку</a></p><h2>Что будет удалено</h2><p>После проверки владельца номера удаляются данные профиля, сообщения и связанные пользовательские данные Tvoice, кроме информации, которую необходимо сохранить по требованиям закона, безопасности или предотвращения злоупотреблений.</p><p><a href="/privacy">Политика конфиденциальности</a></p></article></main></body></html>`;
}
