// VoxTicket: página estática que conversa só com a API do request-service.
// Configuração em config.js (gerado pelo Terraform no deploy). Sem API no ar, entra em MODO DEMO
// e simula a saga localmente, seguindo o mesmo contrato.

const CONFIG = Object.assign(
  { apiBase: "/api", grafanaUrl: "http://localhost:3000", rabbitUrl: "http://localhost:15672" },
  window.VOXTICKET_CONFIG || {},
);

const STATUS = {
  RECEIVED:         { label: "Recebido",           chip: "chip-run",  step: 1 },
  TRANSCRIBING:     { label: "Transcrevendo",      chip: "chip-run",  step: 2 },
  CATEGORIZING:     { label: "Categorizando",      chip: "chip-run",  step: 3 },
  TICKET_REQUESTED: { label: "Abrindo chamado",    chip: "chip-run",  step: 4 },
  TICKET_OPENED:    { label: "Chamado aberto",     chip: "chip-ok",   step: 5, final: true },
  REJECTED:         { label: "Recusado: sem crédito", chip: "chip-bad", step: 1, final: true, failed: true },
  FAILED:           { label: "Falhou: compensado", chip: "chip-bad",  final: true, failed: true },
  EXPIRED:          { label: "Expirou: compensado", chip: "chip-warn", final: true, failed: true },
};

const $ = (sel) => document.querySelector(sel);
const state = { demo: false, requests: load(), audio: null, recorder: null };

// ---------------------------------------------------------------- API (ou simulação)

async function checkApi() {
  const chip = $("#api-status");
  try {
    const r = await fetch(`${CONFIG.apiBase}/health`, { signal: AbortSignal.timeout(2500) });
    if (!r.ok) throw new Error(r.status);
    state.demo = false;
    chip.textContent = "API online";
    chip.className = "chip chip-ok";
  } catch {
    state.demo = true;
    chip.textContent = "MODO DEMO (API offline: saga simulada)";
    chip.className = "chip chip-warn";
  }
}

async function postAudio(tenantId, blob, name) {
  if (state.demo) return demo.post(tenantId);
  const form = new FormData();
  form.append("tenantId", tenantId);
  form.append("file", blob, name);
  const r = await fetch(`${CONFIG.apiBase}/audios`, { method: "POST", body: form });
  if (r.status !== 202) throw new Error(`API respondeu ${r.status}`);
  return r.json(); // { requestId, statusUrl }
}

async function getStatus(id) {
  if (state.demo) return demo.get(id);
  const r = await fetch(`${CONFIG.apiBase}/audios/${id}`);
  if (!r.ok) throw new Error(`API respondeu ${r.status}`);
  return r.json(); // { status, category, priority, ticketId, failureReason, failedAtStep? }
}

// ---------------------------------------------------------------- modo demo
// Reproduz a saga e a regra do recurso escasso (cota por cliente) só no navegador.

const demo = {
  store: new Map(),
  quota: new Map(), // tenant → créditos usados
  limit(tenant) { return tenant === "tenant-f5" ? 10 : 1000; },
  post(tenant) {
    const id = crypto.randomUUID();
    const used = this.quota.get(tenant) || 0;
    const req = { status: "RECEIVED", tenant, t0: Date.now() };
    if (used >= this.limit(tenant)) {
      req.plan = [["REJECTED", 600]];
      req.failureReason = "Cliente sem créditos de transcrição";
    } else {
      this.quota.set(tenant, used + 1);
      const fail = Math.random() < 0.15;
      req.plan = fail
        ? [["TRANSCRIBING", 700], ["FAILED", 3500]]
        : [["TRANSCRIBING", 700], ["CATEGORIZING", 2800], ["TICKET_REQUESTED", 3800], ["TICKET_OPENED", 4800]];
      if (fail) {
        req.failureReason = "Transcrição falhou 3x: crédito devolvido, áudio movido para failed/";
        req.failedAtStep = 3;
        req.onFail = () => this.quota.set(tenant, (this.quota.get(tenant) || 1) - 1);
      }
    }
    this.store.set(id, req);
    return Promise.resolve({ requestId: id, statusUrl: `/audios/${id}` });
  },
  get(id) {
    const req = this.store.get(id);
    if (!req) return Promise.resolve({ status: "FAILED", failureReason: "desconhecido" });
    const elapsed = Date.now() - req.t0;
    for (const [status, at] of req.plan) {
      if (elapsed >= at && req.status !== status) {
        req.status = status;
        if (status === "FAILED" && req.onFail) req.onFail();
      }
    }
    const out = { status: req.status };
    if (STATUS[req.status].step >= 4 || req.status === "TICKET_OPENED") {
      out.category = "TECNICO"; out.priority = "HIGH";
    }
    if (req.status === "TICKET_OPENED") out.ticketId = `TCK-${id.slice(0, 6).toUpperCase()}`;
    if (STATUS[req.status].failed) { out.failureReason = req.failureReason; out.failedAtStep = req.failedAtStep; }
    return Promise.resolve(out);
  },
};

// ---------------------------------------------------------------- lista de pedidos

function load() {
  try { return JSON.parse(localStorage.getItem("voxticket.requests")) || []; } catch { return []; }
}
function save() {
  try { localStorage.setItem("voxticket.requests", JSON.stringify(state.requests.slice(0, 30))); } catch { /* sem storage */ }
}

function traceUrl(id) {
  const pane = {
    a: {
      datasource: "tempo",
      queries: [{ refId: "A", datasource: { type: "tempo", uid: "tempo" }, queryType: "traceql",
                  query: `{span.messaging.message.conversation_id="${id}"}` }],
      range: { from: "now-1h", to: "now" },
    },
  };
  return `${CONFIG.grafanaUrl}/explore?schemaVersion=1&orgId=1&panes=${encodeURIComponent(JSON.stringify(pane))}`;
}

function render(req) {
  let el = document.getElementById(`r-${req.id}`);
  if (!el) {
    el = $("#tpl-request").content.firstElementChild.cloneNode(true);
    el.id = `r-${req.id}`;
    el.classList.add("new");
    el.querySelector(".rid").textContent = req.id;
    el.querySelector(".trace").href = traceUrl(req.id);
    $("#list").prepend(el);
  }
  const info = STATUS[req.status] || { label: req.status, chip: "chip-wait", step: 0 };
  const chip = el.querySelector(".status");
  chip.textContent = info.label;
  chip.className = `status chip ${info.chip}`;

  // linha do tempo: passos concluídos, o atual e onde falhou
  const failedStep = info.failed ? (req.failedAtStep ?? info.step ?? 1) : null;
  el.querySelectorAll(".timeline li").forEach((li) => {
    const s = Number(li.dataset.step);
    li.className = "";
    if (failedStep !== null) {
      if (s < failedStep) li.classList.add("done");
      else if (s === failedStep) li.classList.add("failed");
    } else if (s < info.step) li.classList.add("done");
    else if (s === info.step && !info.final) li.classList.add("active");
  });

  const d = [];
  d.push(`<span>Cliente: <b>${esc(req.tenant)}</b></span>`);
  if (req.category) d.push(`<span>Categoria: <b>${esc(req.category)}</b></span>`);
  if (req.priority) d.push(`<span>Prioridade: <b>${esc(req.priority)}</b></span>`);
  if (req.ticketId) d.push(`<span>Chamado: <b>${esc(req.ticketId)}</b></span>`);
  if (req.failureReason) d.push(`<span class="comp">${esc(req.failureReason)}</span>`);
  el.querySelector(".details").innerHTML = d.join("");
  $("#empty").hidden = state.requests.length > 0;
}

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

async function track(req, onFinal) {
  for (;;) {
    try {
      Object.assign(req, await getStatus(req.id));
      render(req);
      save();
      if (STATUS[req.status]?.final) { onFinal?.(req); return; }
    } catch { /* API oscilando: tenta de novo */ }
    await new Promise((r) => setTimeout(r, 1000));
  }
}

// ---------------------------------------------------------------- gravação e envio

function setAudio(blob, name) {
  state.audio = blob ? { blob, name } : null;
  $("#btn-send").disabled = !blob;
  $("#file-name").textContent = blob ? `${name} (${Math.round(blob.size / 1024)} KB)` : "Escolher arquivo de áudio…";
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
    $("#send-msg").textContent = "Sem acesso ao microfone. Use um arquivo.";
  }
}

async function send() {
  const tenant = $("#tenant").value.trim() || "tenant-demo";
  const msg = $("#send-msg");
  $("#btn-send").disabled = true;
  msg.textContent = "Enviando…";
  try {
    const { requestId } = await postAudio(tenant, state.audio.blob, state.audio.name);
    msg.textContent = `202 Accepted: ${requestId}`;
    const req = { id: requestId, tenant, status: "RECEIVED" };
    state.requests.unshift(req);
    render(req);
    setAudio(null);
    track(req);
  } catch (e) {
    msg.textContent = `Erro: ${e.message}`;
    $("#btn-send").disabled = false;
  }
}

// ---------------------------------------------------------------- corrida (F5)

async function race() {
  const n = Math.min(Math.max(Number($("#race-n").value) || 1, 1), 200);
  const tenant = $("#race-tenant").value.trim() || "tenant-f5";
  const c = { sent: 0, ok: 0, rejected: 0, pending: 0 };
  const show = () => {
    $("#race-sent").textContent = c.sent; $("#race-ok").textContent = c.ok;
    $("#race-rejected").textContent = c.rejected; $("#race-pending").textContent = c.pending;
  };
  $("#btn-race").disabled = true;
  show();
  const silence = new Blob([new Uint8Array(1024)], { type: "audio/ogg" });

  await Promise.all(Array.from({ length: n }, async () => {
    try {
      const { requestId } = await postAudio(tenant, silence, "corrida.ogg");
      c.sent++; c.pending++; show();
      const req = { id: requestId, tenant, status: "RECEIVED" };
      track(req, (final) => {
        c.pending--;
        if (final.status === "TICKET_OPENED") c.ok++;
        else c.rejected++;
        show();
      });
    } catch { /* não aceito */ }
  }));
  $("#btn-race").disabled = false;
}

// ---------------------------------------------------------------- inicialização

$("#link-grafana").href = `${CONFIG.grafanaUrl}/d/voxticket-saga`;
$("#link-rabbit").href = CONFIG.rabbitUrl;
$("#btn-record").addEventListener("click", toggleRecord);
$("#file").addEventListener("change", (e) => { const f = e.target.files[0]; if (f) setAudio(f, f.name); });
$("#btn-send").addEventListener("click", send);
$("#btn-race").addEventListener("click", race);
$("#btn-clear").addEventListener("click", () => { state.requests = []; save(); $("#list").innerHTML = ""; $("#empty").hidden = false; });

checkApi().then(() => {
  state.requests.forEach((r) => { render(r); if (!STATUS[r.status]?.final) track(r); });
  $("#empty").hidden = state.requests.length > 0;
});
setInterval(checkApi, 10000);
