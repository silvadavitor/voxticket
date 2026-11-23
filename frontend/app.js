// Front estático: só conversa com a API (contracts/openapi.yaml). config.js vem do Terraform.

const CONFIG = Object.assign(
  { apiBase: "/api", grafanaUrl: "http://localhost:3000", rabbitUrl: "http://localhost:15672" },
  window.VOXTICKET_CONFIG || {},
);

// status da saga → rótulo, cor e passo atual da linha do tempo (0..4; 5 = tudo concluído)
const STATUS = {
  RECEIVED:         { label: "Recebido",               chip: "chip-run",  step: 1 },
  TRANSCRIBING:     { label: "Transcrevendo",          chip: "chip-run",  step: 2 },
  CATEGORIZING:     { label: "Categorizando",          chip: "chip-run",  step: 3 },
  TICKET_REQUESTED: { label: "Abrindo chamado",        chip: "chip-run",  step: 4 },
  TICKET_OPENED:    { label: "Chamado aberto",         chip: "chip-ok",   step: 5, final: true },
  REJECTED:         { label: "Recusado: sem crédito",  chip: "chip-bad",  step: 1, final: true, failed: true },
  FAILED:           { label: "Falhou: compensado",     chip: "chip-bad",  step: 2, final: true, failed: true },
  EXPIRED:          { label: "Expirou: compensado",    chip: "chip-warn", step: 2, final: true, failed: true },
};
const PRIORITY = { CRITICAL: "chip-bad", HIGH: "chip-warn", MEDIUM: "chip-run", LOW: "chip-wait" };

const $ = (sel) => document.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const fmtTime = (iso) => (iso ? new Date(iso).toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "medium" }) : "—");
const state = { audio: null, recorder: null, tab: "pedidos" };

// ---------------------------------------------------------------- API

async function api(path, options = {}) {
  const r = await fetch(`${CONFIG.apiBase}${path}`, { signal: AbortSignal.timeout(5000), ...options });
  if (!r.ok) throw new Error(`${r.status}`);
  return r.status === 204 ? null : r.json();
}

async function checkService(path, chipId, name) {
  const chip = $(chipId);
  try {
    const h = await api(path);
    const deps = [h.db === "down" && "banco fora", h.broker === "down" && "broker fora"].filter(Boolean);
    chip.textContent = deps.length ? `${name}: ${deps.join(", ")}` : `${name} online`;
    chip.className = `chip ${deps.length ? "chip-warn" : "chip-ok"}`;
    return true;
  } catch {
    chip.textContent = `${name} offline`;
    chip.className = "chip chip-bad";
    return false;
  }
}

async function checkTicketService() {
  const chip = $("#svc-ticket");
  try {
    await api("/tickets?limit=1");
    chip.textContent = "ticket-service online";
    chip.className = "chip chip-ok";
  } catch {
    chip.textContent = "ticket-service offline";
    chip.className = "chip chip-bad";
  }
}

async function checkQuotaService() {
  const chip = $("#svc-quota");
  try {
    await api("/tenants");
    chip.textContent = "quota-service online";
    chip.className = "chip chip-ok";
  } catch {
    chip.textContent = "quota-service offline";
    chip.className = "chip chip-bad";
  }
}

function checkAll() {
  checkService("/health", "#svc-request", "request-service");
  checkTicketService();
  checkQuotaService();
}

// ---------------------------------------------------------------- pedidos

// ---------------------------------------------------------------- tracing (o trace começa no navegador)
const traceIds = (() => { try { return JSON.parse(localStorage.getItem("voxticket.traces")) || {}; } catch { return {}; } })();
const hex = (bytes) => Array.from(crypto.getRandomValues(new Uint8Array(bytes)), (b) => b.toString(16).padStart(2, "0")).join("");
function newTraceparent() {
  const traceId = hex(16);
  return { traceId, header: `00-${traceId}-${hex(8)}-01` };
}
function rememberTrace(requestId, traceId) {
  traceIds[requestId] = traceId;
  try { localStorage.setItem("voxticket.traces", JSON.stringify(Object.fromEntries(Object.entries(traceIds).slice(-200)))); } catch { /* sem storage */ }
}

function traceUrl(id) {
  const traceId = traceIds[id];
  const query = traceId || `{span.messaging.message.conversation_id="${id}"}`;
  const pane = {
    a: {
      datasource: "tempo",
      queries: [{ refId: "A", datasource: { type: "tempo", uid: "tempo" }, queryType: "traceql", query }],
      range: { from: "now-6h", to: "now" },
    },
  };
  return `${CONFIG.grafanaUrl}/explore?schemaVersion=1&orgId=1&panes=${encodeURIComponent(JSON.stringify(pane))}`;
}

function renderRequest(req) {
  let el = document.getElementById(`r-${req.requestId}`);
  if (!el) {
    el = $("#tpl-request").content.firstElementChild.cloneNode(true);
    el.id = `r-${req.requestId}`;
    el.classList.add("new");
    el.querySelector(".rid").textContent = req.requestId;
    el.querySelector(".trace").href = traceUrl(req.requestId);
  }
  const info = STATUS[req.status] || { label: req.status, chip: "chip-wait", step: 0 };
  const chip = el.querySelector(".status");
  chip.textContent = info.label;
  chip.className = `status chip ${info.chip}`;

  el.querySelectorAll(".timeline li").forEach((li) => {
    const s = Number(li.dataset.step);
    li.className = "";
    if (info.failed) {
      if (s < info.step) li.classList.add("done");
      else if (s === info.step) li.classList.add("failed");
    } else if (s < info.step) li.classList.add("done");
    else if (s === info.step && !info.final) li.classList.add("active");
  });

  const d = [`<span>Cliente: <b>${esc(req.tenantId)}</b></span>`, `<span class="muted">${fmtTime(req.createdAt)}</span>`];
  if (req.category) d.push(`<span>Categoria: <b>${esc(req.category)}</b></span>`);
  if (req.priority) d.push(`<span>Prioridade: <b>${esc(req.priority)}</b></span>`);
  if (req.ticketId) d.push(`<span>Chamado: <b>${esc(req.ticketId)}</b></span>`);
  if (req.failureReason) d.push(`<span class="comp">${esc(req.failureReason)}</span>`);
  el.querySelector(".details").innerHTML = d.join("");
  return el;
}

async function refreshRequests() {
  const list = $("#list");
  try {
    const requests = await api("/audios?limit=30");
    const els = requests.map(renderRequest);
    list.replaceChildren(...els);
    els.forEach((el) => setTimeout(() => el.classList.remove("new"), 500));
    $("#requests-empty").hidden = requests.length > 0;
    $("#requests-empty").textContent = "Nenhum pedido ainda. Grave ou envie um áudio.";
  } catch {
    $("#requests-empty").hidden = list.children.length > 0;
    $("#requests-empty").textContent = "request-service fora do ar: suba os serviços (docker compose up -d --build).";
  }
}

// ---------------------------------------------------------------- chamados

async function refreshTickets() {
  const tenant = $("#tickets-tenant").value.trim();
  const qs = new URLSearchParams({ limit: "100", ...(tenant && { tenantId: tenant }) });
  try {
    const tickets = await api(`/tickets?${qs}`);
    $("#tickets-body").innerHTML = tickets.map((t) => `
      <tr>
        <td><b>${esc(t.ticketId)}</b></td>
        <td>${esc(t.tenantId)}</td>
        <td>${esc(t.category)}</td>
        <td>${t.priority ? `<span class="chip ${PRIORITY[t.priority] || "chip-wait"}">${esc(t.priority)}</span>` : "—"}</td>
        <td>${fmtTime(t.createdAt)}</td>
        <td><a href="${traceUrl(t.requestId)}" target="_blank" rel="noopener"><code>${esc(t.requestId).slice(0, 8)}…</code></a></td>
      </tr>`).join("");
    $("#tickets-table").hidden = tickets.length === 0;
    $("#tickets-empty").hidden = tickets.length > 0;
    $("#tickets-empty").textContent = "Nenhum chamado ainda.";
    $("#tickets-count").textContent = tickets.length ? tickets.length : "";
  } catch {
    $("#tickets-table").hidden = true;
    $("#tickets-empty").hidden = false;
    $("#tickets-empty").textContent = "ticket-service fora do ar: suba os serviços (docker compose up -d --build).";
  }
}

// ---------------------------------------------------------------- clientes

async function setTenantLimit(tenantId, quotaLimit) {
  const r = await fetch(`${CONFIG.apiBase}/tenants/${encodeURIComponent(tenantId)}`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ quotaLimit }),
  });
  if (r.status === 409) throw new Error("o limite não pode ficar abaixo dos créditos já usados");
  if (!r.ok) throw new Error(`a API respondeu ${r.status}`);
  return r.json();
}

async function refreshTenants() {
  try {
    const tenants = await api("/tenants");
    $("#tenants-list").innerHTML = tenants.map((t) => `<option value="${esc(t.tenantId)}">`).join("");
    if (state.tab !== "clientes") return;
    $("#tenants-body").innerHTML = tenants.map((t) => {
      const pct = t.quotaLimit ? Math.min(100, Math.round((t.used / t.quotaLimit) * 100)) : 100;
      return `
      <tr>
        <td><b>${esc(t.tenantId)}</b></td>
        <td>${t.quotaLimit}</td>
        <td>${t.used}</td>
        <td>${t.available ? t.available : '<span class="chip chip-bad">0</span>'}</td>
        <td><div class="bar ${t.available ? "" : "full"}"><span style="width:${pct}%"></span></div></td>
        <td><button class="link-btn small" type="button" data-edit="${esc(t.tenantId)}" data-limit="${t.quotaLimit}">editar</button></td>
      </tr>`;
    }).join("");
    $("#tenants-table").hidden = tenants.length === 0;
    $("#tenants-empty").hidden = tenants.length > 0;
    $("#tenants-empty").textContent = "Nenhum cliente cadastrado.";
  } catch {
    if (state.tab !== "clientes") return;
    $("#tenants-table").hidden = true;
    $("#tenants-empty").hidden = false;
    $("#tenants-empty").textContent = "quota-service fora do ar: suba os serviços (docker compose up -d --build).";
  }
}

async function saveTenant(e) {
  e.preventDefault();
  const id = $("#tenant-id").value.trim();
  const limit = Number($("#tenant-limit").value);
  try {
    const t = await setTenantLimit(id, limit);
    $("#tenant-msg").textContent = `${t.tenantId}: limite ${t.quotaLimit}, ${t.available} disponíveis`;
    refreshTenants();
  } catch (err) {
    $("#tenant-msg").textContent = `Erro: ${err.message}`;
  }
}

// ---------------------------------------------------------------- gravação e envio

function setAudio(blob, name) {
  state.audio = blob ? { blob, name } : null;
  $("#btn-send").disabled = !blob;
  $("#file-name").textContent = blob ? `${name} (${Math.max(1, Math.round(blob.size / 1024))} KB)` : "Escolher arquivo de áudio…";
}

async function toggleRecord() {
  const btn = $("#btn-record");
  if (state.recorder) { state.recorder.stop(); return; }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const chunks = [];
    const rec = new MediaRecorder(stream);
    const t0 = Date.now();
    const timer = setInterval(() => { $("#record-time").textContent = `${Math.round((Date.now() - t0) / 1000)} s`; }, 250);
    rec.ondataavailable = (e) => chunks.push(e.data);
    rec.onstop = () => {
      clearInterval(timer);
      stream.getTracks().forEach((t) => t.stop());
      state.recorder = null;
      btn.classList.remove("recording");
      btn.querySelector(".label").textContent = "Gravar áudio";
      setAudio(new Blob(chunks, { type: rec.mimeType || "audio/webm" }), "gravacao.webm");
    };
    rec.start();
    state.recorder = rec;
    btn.classList.add("recording");
    btn.querySelector(".label").textContent = "Parar";
  } catch {
    $("#send-msg").textContent = "Sem acesso ao microfone (o navegador só libera em localhost ou HTTPS). Use um arquivo.";
  }
}

async function postAudio(tenantId, blob, name) {
  const form = new FormData();
  form.append("tenantId", tenantId);
  form.append("file", blob, name);
  const trace = newTraceparent();
  const r = await fetch(`${CONFIG.apiBase}/audios`, { method: "POST", body: form, headers: { traceparent: trace.header } });
  if (r.status !== 202) throw new Error(`a API respondeu ${r.status}`);
  const body = await r.json();
  rememberTrace(body.requestId, trace.traceId);
  return body;
}

async function send() {
  const tenant = $("#tenant").value.trim() || "tenant-demo";
  const msg = $("#send-msg");
  $("#btn-send").disabled = true;
  msg.textContent = "Enviando…";
  try {
    const { requestId } = await postAudio(tenant, state.audio.blob, state.audio.name);
    msg.textContent = `202 Accepted · ${requestId}`;
    setAudio(null);
    refreshRequests();
  } catch (e) {
    msg.textContent = e.message.includes("Failed to fetch") || e.message.startsWith("5")
      ? "request-service fora do ar: suba os serviços (docker compose up -d --build)."
      : `Erro: ${e.message}`;
    $("#btn-send").disabled = false;
  }
}

// ---------------------------------------------------------------- corrida (F5)

async function race() {
  const n = Math.min(Math.max(Number($("#race-n").value) || 1, 1), 200);
  const quota = Math.min(Math.max(Number($("#race-quota").value) || 0, 0), 200);
  const tenant = `corrida-${new Date().toTimeString().slice(0, 8).replaceAll(":", "")}`;
  const ids = new Set();
  const c = { sent: 0, ok: 0, rejected: 0, pending: 0 };
  const show = () => {
    $("#race-sent").textContent = c.sent; $("#race-ok").textContent = c.ok;
    $("#race-rejected").textContent = c.rejected; $("#race-pending").textContent = c.pending;
  };
  $("#btn-race").disabled = true;
  show();
  try {
    await setTenantLimit(tenant, quota);
    $("#race-msg").textContent = `cliente ${tenant} criado com ${quota} créditos · disparando ${n} pedidos`;
  } catch (e) {
    $("#race-msg").textContent = `Erro ao criar o cliente: ${e.message}`;
    $("#btn-race").disabled = false;
    return;
  }
  const silence = new Blob([new Uint8Array(1024)], { type: "audio/ogg" });

  await Promise.all(Array.from({ length: n }, () =>
    postAudio(tenant, silence, "corrida.ogg").then(({ requestId }) => { ids.add(requestId); c.sent++; show(); }).catch(() => {})));

  const timer = setInterval(async () => {
    try {
      const all = await api(`/audios?tenantId=${encodeURIComponent(tenant)}&limit=200`);
      const mine = all.filter((r) => ids.has(r.requestId));
      c.ok = mine.filter((r) => r.status === "TICKET_OPENED").length;
      c.rejected = mine.filter((r) => STATUS[r.status]?.failed).length;
      c.pending = ids.size - c.ok - c.rejected;
      show();
      if (c.pending === 0) { clearInterval(timer); $("#btn-race").disabled = false; }
    } catch { /* API oscilando: tenta de novo */ }
  }, 1500);
}

// ---------------------------------------------------------------- abas e inicialização

const REFRESH = { pedidos: () => refreshRequests(), chamados: () => refreshTickets(), clientes: () => refreshTenants() };

function showTab(tab) {
  state.tab = tab;
  document.querySelectorAll(".tab").forEach((b) => {
    const on = b.dataset.tab === tab;
    b.classList.toggle("active", on);
    b.setAttribute("aria-selected", on);
  });
  $("#tab-pedidos").hidden = tab !== "pedidos";
  $("#tab-chamados").hidden = tab !== "chamados";
  $("#tab-clientes").hidden = tab !== "clientes";
  REFRESH[tab]();
}

$("#link-grafana").href = `${CONFIG.grafanaUrl}/d/voxticket-saga`;
$("#link-rabbit").href = CONFIG.rabbitUrl;
document.querySelectorAll(".tab").forEach((b) => b.addEventListener("click", () => showTab(b.dataset.tab)));
$("#btn-record").addEventListener("click", toggleRecord);
$("#file").addEventListener("change", (e) => { const f = e.target.files[0]; if (f) setAudio(f, f.name); });
$("#btn-send").addEventListener("click", send);
$("#btn-race").addEventListener("click", race);
$("#tickets-tenant").addEventListener("input", refreshTickets);
$("#tenant-form").addEventListener("submit", saveTenant);
$("#tenants-body").addEventListener("click", (e) => {
  const b = e.target.closest("[data-edit]");
  if (!b) return;
  $("#tenant-id").value = b.dataset.edit;
  $("#tenant-limit").value = b.dataset.limit;
  $("#tenant-limit").focus();
});

checkAll();
showTab("pedidos");
setInterval(checkAll, 5000);
setInterval(() => REFRESH[state.tab](), 2000);
refreshTickets(); // contador da aba
refreshTenants(); // sugestões de cliente no envio
setInterval(() => state.tab === "pedidos" && refreshTickets(), 5000);
