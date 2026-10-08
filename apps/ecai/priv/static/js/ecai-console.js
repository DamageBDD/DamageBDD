/* ECAI Control Plane. Uses only routes exported by the current ECAI Cowboy handlers. */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const routes = [
    // Parameters represent the actual path, query and JSON fields handled by the server.
    { group: "Authentication", method: "GET", path: "/ecai/auth/session", description: "Read-only account session check; no L402 invoice is generated." },
    { group: "Search & chat", method: "POST", path: "/ecai/search", description: "Free-text public search, with proof material.", body: { q: "elliptic curve", limit: 10 } },
    { group: "Search & chat", method: "GET", path: "/ecai/chat", description: "Local chat service health." },
    { group: "Search & chat", method: "POST", path: "/ecai/chat", description: "ECAI chat by session and user.", body: { session_id: "console", user_id: "console-user", message: "What is ECAI?" } },
    { group: "Search & chat", method: "POST", path: "/v1/chat/completions", description: "OpenAI-compatible chat adapter (non-streaming).", body: { model: "ecai", messages: [{ role: "user", content: "What is ECAI?" }] } },
    { group: "Knowledge & private", method: "POST", path: "/ecai/ekef", description: "Legacy on-chain knowledge minting; server-side signer required.", body: { subject: "ECAI", predicate: "indexes", object: "knowledge", context: "demo" }, confirm: "This may mint an NFT and incur on-chain costs. Continue?" },
    { group: "Knowledge & private", method: "POST", path: "/ecai/private/:corpus/index", description: "Index an owner-scoped private batch. No client-supplied identity or keys.", params: ["corpus"], body: { batch_id: "00000000000000000000000000000001", records: [{ title: "A private fact", text: "Example content" }] } },
    { group: "Knowledge & private", method: "POST", path: "/ecai/private/:corpus/search", description: "Private knowledge retrieval.", params: ["corpus"], body: { query: "example", limit: 8 } },
    { group: "Knowledge & private", method: "POST", path: "/ecai/private/:corpus/fetch", description: "Fetch private record by ID.", params: ["corpus"], body: { id: "record-id" } },
    { group: "Knowledge & private", method: "POST", path: "/ecai/private/:corpus/ask", description: "Answer from private sources via an operator-approved destination.", params: ["corpus"], body: { question: "What is known?", destination: "local" } },
    { group: "Index jobs", method: "GET", path: "/ecai/index-jobs/status", description: "Durable queue, capacity and worker counts." },
    { group: "Index jobs", method: "GET", path: "/ecai/index-jobs/presets", description: "Preconfigured Wikimedia source presets." },
    { group: "Index jobs", method: "GET", path: "/ecai/index-jobs", description: "List persisted indexing jobs.", query: { state: "", kind: "", limit: "50" } },
    { group: "Index jobs", method: "POST", path: "/ecai/index-jobs", description: "Enqueue validated ecai-index-job/v1 spec. Idempotency key required for safe retry.", body: { schema: "ecai-index-job/v1", kind: "wikimedia_visibility", source: {}, target: {}, options: {}, finalize: {} }, key: true },
    { group: "Index jobs", method: "POST", path: "/ecai/index-jobs/presets/:preset", description: "Queue curated preset; no overrides accepted.", params: ["preset"], body: {}, key: true },
    { group: "Index jobs", method: "GET", path: "/ecai/index-jobs/:id", description: "Inspect a persisted job.", params: ["id"] },
    { group: "Index jobs", method: "POST", path: "/ecai/index-jobs/:id/pause", description: "Pause eligible running job.", params: ["id"], body: {} },
    { group: "Index jobs", method: "POST", path: "/ecai/index-jobs/:id/resume", description: "Resume paused job.", params: ["id"], body: {} },
    { group: "Index jobs", method: "POST", path: "/ecai/index-jobs/:id/cancel", description: "Cancel eligible job.", params: ["id"], body: {}, confirm: "Cancel this index job?" },
    { group: "Index jobs", method: "POST", path: "/ecai/index-jobs/:id/retry", description: "Requeue a canceled job from its durable checkpoint, or retry a failed job within its retry allowance.", params: ["id"], body: {}, confirm: "Resume this job from its last durable checkpoint, if available?" },
    { group: "Index jobs", method: "GET", path: "/ecai/index-jobs/:id/artifact", description: "Retrieve completed artifact and NFT metadata.", params: ["id"] },
    { group: "Index jobs", method: "SSE", path: "/ecai/index-jobs/:id/events", description: "Authenticated Server-Sent Events stream. Expanding a job starts tracking automatically.", params: ["id"] },
    { group: "Wikimedia", method: "GET", path: "/ecai/wikimedia/sources", description: "Discover source catalog.", query: { project: "enwiki", pageview_project: "en.wikipedia", months: "" } },
    { group: "Wikimedia", method: "GET", path: "/ecai/wikimedia/plan", description: "Compute read-only ingestion plan.", query: { project: "enwiki", limit: "10000" } },
    { group: "Wikimedia", method: "GET", path: "/ecai/wikimedia/search", description: "Search Wikimedia index.", query: { q: "elliptic curve", limit: "25", language: "" } },
    { group: "Wikimedia", method: "GET", path: "/ecai/wikimedia/doctor", description: "Diagnostic checks for Wikimedia pipeline." },
    { group: "Marketplace", method: "GET", path: "/ecai/market/jobs", description: "List marketplace jobs.", query: { status: "any" } },
    { group: "Marketplace", method: "GET", path: "/ecai/market/jobs/:id", description: "Inspect marketplace job (numeric ID).", params: ["id"] },
    { group: "Marketplace", method: "POST", path: "/ecai/market/jobs/publish", description: "Publish marketplace chunk jobs.", body: { owner_ak: "ak_...", market_ct: "ct_...", paths: [], reward_damage: 1, ttl_blocks: 100 } },
    { group: "Marketplace", method: "POST", path: "/ecai/market/jobs/:id/claim", description: "Claim a job as a miner.", params: ["id"], body: { miner_ak: "ak_..." } },
    { group: "Marketplace", method: "POST", path: "/ecai/market/jobs/:id/submit", description: "Submit attestation and evidence.", params: ["id"], body: { miner_ak: "ak_...", attestation: "proof", evidence_ref: "" } },
    { group: "Marketplace", method: "POST", path: "/ecai/market/jobs/:id/pay", description: "Mark a job as paid locally; no on-chain transfer occurs.", params: ["id"], body: { admin_ak: "ak_..." }, confirm: "Mark this job paid in volatile local state? No on-chain transfer occurs." },
    { group: "Yelp operations", method: "GET", path: "/yelp/status", description: "Yelp dataset loader and index metrics." },
    { group: "Yelp operations", method: "GET", path: "/yelp/chunk_job", description: "Inspect async chunking job." },
    { group: "Yelp operations", method: "POST", path: "/yelp/chunk", description: "Start server-side Yelp chunking.", body: { in: "yelp_academic_dataset_business.json", out_dir: "chunks", chunk_size: 5000 }, confirm: "Start server-side chunking?" },
    { group: "Yelp operations", method: "POST", path: "/yelp/chunk_async", description: "Start asynchronous server-side chunking.", body: { in: "yelp_academic_dataset_business.json", out_dir: "chunks", chunk_size: 5000 }, confirm: "Start an asynchronous chunk job?" },
    { group: "Yelp operations", method: "POST", path: "/yelp/chunk_cancel", description: "Cancel the active chunking job.", body: {}, confirm: "Cancel the current chunking job?" },
    { group: "Yelp operations", method: "POST", path: "/yelp/assign", description: "Assign chunk shards to this node.", body: { cluster_id: 0, cluster_size: 4 }, confirm: "Assign Yelp shard ownership on this node?" },
    { group: "Yelp operations", method: "POST", path: "/yelp/ipfs", description: "Publish local chunks to IPFS.", body: {}, confirm: "Publish existing chunk data to IPFS?" },
    { group: "Yelp operations", method: "POST", path: "/yelp/headers", description: "Export on-chain term header commitments.", body: {}, confirm: "Export index term headers?" },
    { group: "Yelp operations", method: "POST", path: "/yelp/manifest", description: "Build combined on-chain manifest.", body: {}, confirm: "Build the publication manifest?" },
    { group: "Code administration", method: "GET", path: "/ecai/admin/code/status", description: "Admin-only learning, repair, health and review status." },
    { group: "Code administration", method: "GET", path: "/ecai/admin/code/repairs", description: "Recent persisted repair records (sanitized)." },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/learn", description: "Start or schedule a code learning cycle.", body: {}, confirm: "Request a code learning cycle?" },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/scan", description: "Scan for repair candidates.", body: {}, confirm: "Run the repair scanner?" },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/propose", description: "Propose a repair for a known scanner finding.", body: { application: "ecai", module: "ecai_patch_worker", fingerprint: "<finding fingerprint>" }, confirm: "Start a targeted repair proposal?" },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/integrate", description: "Run the isolated integration verifier.", body: {}, confirm: "Run integration verification?" },
    { group: "Code administration", method: "GET", path: "/ecai/admin/code/reviews", description: "List durable human-review queue." },
    { group: "Code administration", method: "GET", path: "/ecai/admin/code/reviews/:id", params: ["id"], description: "Inspect frozen patch and audit events." },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/reviews/:id/approve", params: ["id"], description: "Approve a pinned patch SHA.", body: { patch_sha256: "<review SHA-256>", note: "Code reviewed and verified" }, confirm: "Approve this pinned patch?" },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/reviews/:id/reject", params: ["id"], description: "Reject a pinned patch SHA.", body: { patch_sha256: "<review SHA-256>", note: "Request regeneration before merging" }, confirm: "Reject this pinned patch?" },
    { group: "Code administration", method: "POST", path: "/ecai/admin/code/reviews/:id/publish", params: ["id"], description: "Two-stage approval gate: publish verified commit to origin review branch (not main).", body: { patch_sha256: "<review SHA-256>", revision: 2, confirm: "push to origin" }, confirm: "Create a remote review branch in origin?" },
    { group: "Realtime", method: "WS", path: "/ecai/ws/", description: "WebSocket: ping and get_price. Connect from Operations to inspect events." }
  ];

  const privateExamples = {
    search: { query: "example", limit: 8 },
    fetch: { id: "record-id" },
    index: () => ({ batch_id: randomHex(16), records: [{ title: "A private fact", text: "Example content" }] }),
    ask: { question: "What is known about this topic?", destination: "local" }
  };
  const marketExamples = { claim: { miner_ak: "ak_..." }, submit: { miner_ak: "ak_...", attestation: "attestation", evidence_ref: "" }, pay: { admin_ak: "ak_..." } };
  const VIEW_NAMES = { overview: "Overview", search: "Knowledge search", chat: "Conversation", indexing: "Index jobs", wikimedia: "Wikimedia", knowledge: "Knowledge & privacy", marketplace: "Marketplace", operations: "Operations", code: "Code learning & repair", api: "API explorer" };
  const state = {
    authenticated: false, accessToken: null, email: "", view: "overview", jobs: [], presets: [], marketJobs: [],
    nodeAdmin: false, codeAdmin: false, codeFeatureConfigured: false, adminProbeSequence: 0, codeQueue: {}, codeRepairs: [], codeReviews: [], codeReview: null, codeReviewOpenId: "", codeReviewLoadSerial: 0, codeDiffFiles: [], codeDiffSelectedFile: "0",
    selectedIndexId: "", selectedIndexJob: null, jobEntries: new Map(), selectedMarketId: "", activeRoute: -1, lastApiResult: null,
    chatSession: randomHex(16), chatUser: `console-${randomHex(12)}`, chatBusy: false,
    streamSession: null, socket: null,
    wikiSelectedPresets: new Set(), wikiPresetKeys: new Map(), wikiQueueBusy: false, wikiLoadingPresets: false,
    wikiCatalog: null, wikiCatalogKey: "", wikiMonthsSelected: new Set(),
    wikiDiscoveryEpoch: 0, wikiPlan: null, wikiPlanEpoch: 0, wikiPlanBusy: false,
    services: { chat: "pending", queue: "pending", yelp: "pending" },
    queueFeatures: { canceledRetry: false }, poller: null, telemetryPoller: null, clockTicker: null, toastTimer: null
  };

  function randomHex(size) {
    const bytes = new Uint8Array(size);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  }
  function newKey(prefix = "ecai-console") {
    return `${prefix}-${typeof crypto.randomUUID === "function" ? crypto.randomUUID() : randomHex(16)}`;
  }
  function pretty(value) { return typeof value === "string" ? value : JSON.stringify(value, null, 2); }
  function formatNumber(value, digits = 0) {
    if (!Number.isFinite(value)) return "—";
    return Number(value).toLocaleString(undefined, { maximumFractionDigits: digits, minimumFractionDigits: digits > 0 ? digits : 0 });
  }
  function formatEta(ms) {
    if (!Number.isFinite(ms) || ms < 0) return "—";
    if (ms < 1000) return `${Math.round(ms)} ms`;
    const seconds = Math.round(ms / 1000);
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = seconds % 60;
    if (h) return `${h}h ${m}m`;
    if (m) return `${m}m ${s}s`;
    return `${s}s`;
  }
  function formatDuration(ms) {
    if (!Number.isFinite(ms) || ms < 0) return "—";
    const sec = Math.max(0, Math.floor(ms / 1000));
    const days = Math.floor(sec / 86400);
    const hours = Math.floor((sec % 86400) / 3600);
    const mins = Math.floor((sec % 3600) / 60);
    const seconds = sec % 60;
    if (days) return `${days}d ${hours}h ${mins}m`;
    if (hours) return `${hours}h ${mins}m ${seconds}s`;
    if (mins) return `${mins}m ${seconds}s`;
    return `${seconds}s`;
  }
  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes < 0) return "—";
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
  }
  function elapsedRuntime(job, key, receivedAt = 0) {
    const base = job?.runtime?.[key];
    if (!Number.isFinite(base)) return "—";
    const shouldTick = key === "wall_elapsed_ms" ? !terminalIndexState(job?.state) : isRunningLike(job?.state);
    const tick = shouldTick && Number.isFinite(receivedAt) && receivedAt > 0
      ? Math.max(0, performance.now() - receivedAt) : 0;
    return formatDuration(base + tick);
  }
  function etaLabel(job) {
    const status = job?.progress?.eta_status;
    if (progressEta(job) !== "—") return `~ ${progressEta(job)} (provisional)`;
    if (!isRunningLike(job?.state)) return "—";
    if (status === "stale") return "Waiting for progress";
    if (status === "warming_up") return "Measuring throughput…";
    return "Not enough progress yet";
  }
  function addRuntimeStat(host, label, value, clock = null) {
    const card = element("div", "job-runtime-stat");
    const title = element("span", "job-runtime-stat-title", label);
    const stat = element("strong", "job-runtime-stat-value", value);
    if (clock) stat.dataset.runtimeClock = clock;
    card.append(title, stat);
    host.append(card);
  }
  function formatWhen(value) {
    if (!Number.isFinite(value)) return "—";
    try { return new Date(value).toLocaleString(); }
    catch (_) { return String(value); }
  }
  function titleCase(value) {
    return String(value || "").replace(/[_-]+/g, " ").replace(/\b\w/g, (m) => m.toUpperCase());
  }
  function compactValue(value, limit = 72) {
    if (value === undefined || value === null || value === "") return "—";
    const text = typeof value === "string" ? value : Array.isArray(value) ? value.join(", ") : typeof value === "object" ? pretty(value) : String(value);
    return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
  }
  function isRunningLike(stateName) {
    return ["preparing", "running", "pause_requested", "cancel_requested", "finalizing"].includes(String(stateName || ""));
  }
  function terminalIndexState(name) {
    return ["paused", "canceled", "failed", "completed", "ready_to_mint", "minted"].includes(String(name || ""));
  }
  function progressKnown(progress) {
    return Number.isFinite(progress?.percent) ||
      (Number.isFinite(progress?.completed) && Number.isFinite(progress?.total) && progress.total > 0);
  }
  function progressText(progress) {
    return progressKnown(progress) ? `${progressPercent(progress).toFixed(1)}%` : "—";
  }
  function progressEta(job) {
    return isRunningLike(job?.state) && Number.isFinite(job?.progress?.eta_ms) && job.progress.eta_ms >= 0
      ? formatEta(job.progress.eta_ms) : "—";
  }
  function stageFor(stateName) {
    const state = String(stateName || "queued");
    if (["queued"].includes(state)) return 0;
    if (["preparing", "pause_requested", "cancel_requested", "paused"].includes(state)) return 1;
    if (["running"].includes(state)) return 2;
    return 3;
  }
  function jobTitle(job) {
    return job?.spec?.source?.project || job?.spec?.kind || "Index job";
  }
  function jobSubtitle(job) {
    return job?.spec?.source?.path || job?.spec?.source?.dump_file || job?.spec?.target?.snapshot_name || job?.id || "";
  }
  function checkpointEntries(job) {
    const checkpoint = job?.checkpoint;
    if (!checkpoint || typeof checkpoint !== "object") return [];
    const out = [];
    for (const [key, value] of Object.entries(checkpoint)) {
      if (value === undefined || value === null || value === "") continue;
      out.push([titleCase(key), compactValue(value)]);
      if (out.length >= 8) break;
    }
    return out;
  }
  function artifactEntries(job) {
    const artifact = job?.artifact;
    if (!artifact || typeof artifact !== "object") return [];
    const preferred = ["path", "snapshot_path", "manifest_path", "records", "ready_to_mint", "nft_id", "cid", "ipfs_cid"];
    const out = [];
    for (const key of preferred) {
      if (artifact[key] === undefined || artifact[key] === null || artifact[key] === "") continue;
      out.push([titleCase(key), compactValue(artifact[key])]);
    }
    if (!out.length) {
      for (const [key, value] of Object.entries(artifact)) {
        if (value === undefined || value === null || value === "") continue;
        out.push([titleCase(key), compactValue(value)]);
        if (out.length >= 6) break;
      }
    }
    return out.slice(0, 8);
  }
  function renderProgressTrack(pct, stateName, wide = false) {
    const bar = element("div", `progress-track${wide ? " progress-track-wide" : ""}${isRunningLike(stateName) ? " is-running" : ""}`);
    const fill = element("div", `progress-fill${isRunningLike(stateName) ? " is-animated" : ""}`);
    fill.style.width = `${Math.max(0, Math.min(100, pct || 0))}%`;
    bar.append(fill);
    return bar;
  }
  function renderJobPanel(job, host) {
    if (!host) return;
    host.replaceChildren();
    if (!job || typeof job !== "object") {
      host.className = "job-inspector empty";
      host.textContent = "Select a job to inspect its progress, throughput, checkpoints and resulting artifact.";
      return;
    }
    host.className = "job-inspector";
    const pct = progressPercent(job.progress);
    const phase = titleCase(job?.progress?.phase || job?.state || "queued");
    const hero = element("section", "job-hero");
    const heroTop = element("div", "job-hero-top");
    const copy = element("div", "job-hero-copy");
    copy.append(element("h3", "", jobTitle(job)), element("p", "", jobSubtitle(job) === job?.id ? String(job.id) : `${jobSubtitle(job)} · ${job.id || ""}`));
    heroTop.append(copy, element("span", `status-tag state-${job.state || ""}`, titleCase(job.state || "unknown")));
    hero.append(heroTop);
    const headline = element("div", "job-progress-headline");
    const left = element("div");
    left.append(element("div", "job-progress-value", progressText(job.progress)), element("div", "job-progress-caption", `${phase} · ${job?.progress?.completed ?? 0} of ${job?.progress?.total ?? "?"}`));
    const right = element("div", "job-progress-caption", `ETA ${etaLabel(job)}`);
    headline.append(left, right);
    hero.append(headline, renderProgressTrack(pct, job.state, true));
    const pills = element("div", "job-pill-row");
    const pillValues = [
      ["Queue position", job?.queue_position ?? "—"],
      ["Rate", Number.isFinite(job?.progress?.rate_per_second) ? `${formatNumber(job.progress.rate_per_second, 2)}/s` : "—"],
      ["Updated", formatWhen(job?.progress?.updated_at_ms || job?.updated_at_ms)],
      ["Owner", compactValue(job?.owner || job?.spec?.owner || "session")]
    ];
    pillValues.forEach(([k, v]) => pills.append(element("span", "job-pill", `${k}: ${v}`)));
    hero.append(pills);
    host.append(hero);

    const stats = element("div", "job-stats-grid");
    [
      ["Completed", formatNumber(job?.progress?.completed ?? 0)],
      ["Total", job?.progress?.total ?? "—"],
      ["Started", formatWhen(job?.started_at_ms || job?.created_at_ms)],
      ["Finished", formatWhen(job?.finished_at_ms)]
    ].forEach(([label, value]) => {
      const card = element("div", "job-stat-card");
      card.append(element("span", "job-stat-label", label), element("span", `job-stat-value${String(value).length > 18 ? " smallish" : ""}`, String(value)));
      stats.append(card);
    });
    host.append(stats);

    const runtime = job.runtime || {};
    const worker = isRunningLike(job?.state) ? (job.resources || {}) : {active: false};
    const telemetry = element("section", "job-runtime-panel");
    const heading = element("div", "job-runtime-heading");
    heading.append(element("h4", "", "Runtime & resource usage"),
      element("span", "job-runtime-note", "Active time excludes queueing, pauses and downtime"));
    telemetry.append(heading);
    const timing = element("div", "job-runtime-grid");
    addRuntimeStat(timing, "Time spent · wall", elapsedRuntime(job, "wall_elapsed_ms"), "wall_elapsed_ms");
    addRuntimeStat(timing, "Active processing", elapsedRuntime(job, "active_elapsed_ms"), "active_elapsed_ms");
    addRuntimeStat(timing, "Current attempt", elapsedRuntime(job, "attempt_elapsed_ms"), "attempt_elapsed_ms");
    addRuntimeStat(timing, "Since checkpoint", formatDuration(runtime.last_progress_age_ms));
    addRuntimeStat(timing, "ETA", etaLabel(job));
    telemetry.append(timing);
    const resources = element("div", "job-runtime-grid job-resource-grid");
    addRuntimeStat(resources, "Worker memory", worker.active ? formatBytes(worker.memory_bytes) : "—");
    addRuntimeStat(resources, "Scheduler work", worker.active && Number.isFinite(worker.reductions_per_second)
      ? `${formatNumber(worker.reductions_per_second, 0)} red/s` : "—");
    addRuntimeStat(resources, "Total reductions", worker.active ? formatNumber(worker.reductions_total) : "—");
    addRuntimeStat(resources, "Mailbox", worker.active ? formatNumber(worker.message_queue_len) : "—");
    addRuntimeStat(resources, "Heap", worker.active && Number.isFinite(worker.total_heap_words)
      ? `${formatNumber(worker.total_heap_words)} words` : "—");
    addRuntimeStat(resources, "Minor GCs", worker.active ? formatNumber(worker.minor_gcs) : "—");
    addRuntimeStat(resources, "Process state", worker.active ? titleCase(worker.status) : "—");
    telemetry.append(resources);
    telemetry.append(element("p", "job-runtime-note", worker.active
      ? "BEAM process-local counters · reductions/sec is a scheduler-work proxy, not CPU %."
      : "Worker stopped or not yet allocated; live process counters are unavailable."));
    host.append(telemetry);

    const stageLabels = [
      ["Queued", "Accepted and waiting for worker capacity."],
      ["Preparing", "Source planning and recovery checkpoint setup."],
      ["Running", "Actively retrieving and indexing records."],
      ["Finalized", "Artifact/result ready, or the job exited with a terminal state."]
    ];
    const stopped = ["failed", "canceled"].includes(job.state);
    if (stopped) stageLabels[3] = ["Stopped", "Job stopped before completing. Review its error or retry the job."];
    const currentStage = stageFor(job.state);
    const stages = element("div", "job-stage-list");
    stageLabels.forEach(([label, desc], idx) => {
      const cls = `job-stage-card${idx < currentStage ? " is-done" : ""}${idx === currentStage ? " is-active" : ""}`;
      const card = element("div", cls);
      const title = element("div", "job-stage-title");
      title.append(element("span", "", label), element("span", "job-stage-dot"));
      card.append(title, element("div", "job-stage-copy", idx === currentStage ? `${desc} Current state: ${titleCase(job.state || "unknown")}.` : desc));
      stages.append(card);
    });
    host.append(stages);

    const checkpointGrid = element("div", "job-checkpoint-grid");
    const checkpoint = element("section", "job-checkpoint-card");
    checkpoint.append(element("h4", "", "Checkpoint / latest cursor"));
    const cpList = element("div", "job-checkpoint-list");
    const cpEntries = checkpointEntries(job);
    if (!cpEntries.length) cpList.append(element("div", "muted small", "No checkpoint metadata has been published yet."));
    cpEntries.forEach(([k,v]) => { const row = element("div", "job-checkpoint-item"); row.append(element("span", "job-checkpoint-key", k), element("span", "job-checkpoint-value", v)); cpList.append(row); });
    checkpoint.append(cpList);
    checkpointGrid.append(checkpoint);
    const artifact = element("section", "job-checkpoint-card");
    artifact.append(element("h4", "", "Artifact / result cues"));
    const artList = element("div", "job-checkpoint-list");
    const artEntries = artifactEntries(job);
    if (!artEntries.length) artList.append(element("div", "muted small", "No artifact metadata is available yet for this job."));
    artEntries.forEach(([k,v]) => { const row = element("div", "job-checkpoint-item"); row.append(element("span", "job-checkpoint-key", k), element("span", "job-checkpoint-value", v)); artList.append(row); });
    artifact.append(artList);
    checkpointGrid.append(artifact);
    host.append(checkpointGrid);
  }
  function put(id, value) { const node = $(id); if (node) node.textContent = pretty(value); }
  function showError(error) {
    if (error?.status === 402) return "HTTP 402: access/payment challenge. Verify the DamageBDD session and the node's L402 policy; no payment was made.";
    if (error?.status === 403 && error?.body?.error === "bearer_required")
      return "An explicit DamageBDD bearer token is required for patch decisions. Sign in using the console before approving or publishing.";
    if (error?.body?.error !== undefined) return pretty(error.body.error);
    if (error?.body?.message !== undefined) return pretty(error.body.message);
    return error?.message || "Request failed";
  }
  function toast(message, bad = false) {
    const node = $("consoleToast");
    node.textContent = message;
    node.classList.toggle("error", bad);
    node.hidden = false;
    clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(() => { node.hidden = true; }, 4300);
  }
  function element(tag, className = "", value = null) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (value !== null) node.textContent = String(value);
    return node;
  }
  function safePath(value) {
    // Always stay on the same origin, including for server-provided links.
    const url = new URL(value, location.origin);
    if (url.origin !== location.origin || !value.startsWith("/")) throw new Error("Only local ECAI endpoints are permitted");
    return url.pathname + url.search;
  }
  function currentToken() {
    if (state.accessToken) return state.accessToken;
    try { return window.TokenManager?.getToken?.() || ""; } catch (_) { return ""; }
  }
  function headers(extra = {}) {
    const h = { Accept: "application/json", ...extra };
    const token = currentToken();
    if (token) h.Authorization = `Bearer ${token}`;
    return h;
  }
  async function request(path, options = {}) {
    const opts = { credentials: "include", method: options.method || "GET", signal: options.signal, headers: headers(options.headers) };
    if (Object.prototype.hasOwnProperty.call(options, "body")) {
      opts.headers["Content-Type"] = "application/json";
      opts.body = JSON.stringify(options.body);
    }
    const response = await fetch(safePath(path), opts);
    const raw = await response.text();
    let data;
    try { data = raw ? JSON.parse(raw) : {}; } catch (_) { data = { raw: raw.slice(0, 4000) }; }
    if (!response.ok) {
      const error = new Error(`HTTP ${response.status}`);
      error.status = response.status; error.body = data;
      if (response.status === 401 && !options.ignoreAuth) setAuthenticated(false);
      // 402 can mean an L402 challenge, not a stopped service. Never auto-pay.
      throw error;
    }
    return data;
  }
  function setAuthenticated(on, label = "") {
    const newlyAuthenticated = !!on && !state.authenticated;
    state.authenticated = !!on;
    if (on && label) state.email = label;
    $("loginBtn").hidden = !!on;
    $("logoutBtn").hidden = !on;
    put("authIdentity", on ? (state.email || "DamageBDD session") : "Guest access");
    if (!on) {
      state.adminProbeSequence++;
      state.nodeAdmin = false; state.codeAdmin = false; state.codeFeatureConfigured = false;
      clearCodeReviewFocus(); state.codeRepairs = []; state.codeReviews = [];
      state.codeQueue = {}; state.codeStatusLastPoll = 0;
      $("codeMetrics").replaceChildren(element("div", "empty-state", "Node administrator session required."));
      $("codeServiceCards").replaceChildren();
      put("codeStatusUpdated", "Sign in to view telemetry");
      put("codeLearningStatus", "No administrator status loaded.");
      put("codeRepairStatus", "No repair status loaded.");
      renderCodeRepairs(); renderCodeReviews();
      showCodeAdminNavigation();
      setCodeActionsEnabled(false);
      if (state.view === "code") navigate("overview");
      put("codeReviewDetail", "Select a validated repair from the review queue.");
      put("codeReviewDiff", "No patch selected.");
      codeReviewButtons();
      stopStream();
      state.jobs = []; state.presets = []; state.marketJobs = []; state.selectedIndexJob = null;
      state.wikiSelectedPresets.clear();
      state.wikiPresetKeys.clear();
      resetWikiCatalog();
      renderWikiProjects();
      state.selectedIndexId = ""; state.selectedMarketId = "";
      put("privateOutput", "Sign in to use private corpora.");
      put("marketDetail", "No job selected.");
      renderJobs(); renderPresets(); renderMarketJobs(); renderOverviewJobs();
    }
    // The read-only session probe supplies the node-admin role before the
    // privileged API probe. Never infer a role from login success alone.
    if (newlyAuthenticated) state.adminProbeSequence++;
  }
  function openLogin(message = "") {
    put("consoleLoginStatus", message);
    const dlg = $("consoleLoginDialog");
    if (!dlg.open) { if (dlg.showModal) dlg.showModal(); else dlg.setAttribute("open", ""); }
  }
  function closeLogin() {
    const dlg = $("consoleLoginDialog");
    if (dlg.open) { if (dlg.close) dlg.close(); else dlg.removeAttribute("open"); }
  }
  async function login(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const email = form.elements.email.value.trim();
    const password = form.elements.password.value;
    if (!email || !password) return;
    $("consoleLoginSubmit").disabled = true;
    put("consoleLoginStatus", "Signing in…");
    try {
      const response = await fetch("/accounts/auth/", {
        method: "POST", credentials: "include", headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ username: email, password })
      });
      let data = {};
      try { data = await response.json(); } catch (_) { /* server may return HTML */ }
      if (response.status === 404) throw new Error("DamageBDD login route is missing on this ECAI listener. Deploy the auth route fix and reload the router.");
      if (!response.ok || !data.access_token) throw new Error(data.message || data.error || `Authentication failed (HTTP ${response.status})`);
      state.accessToken = data.access_token;
      state.email = data.email || email;
      try {
        window.TokenManager?.on_custodial_login?.(data.address, state.email, data.access_token);
        window.TokenManager?.activate?.("custodial");
      } catch (_) { /* explicit bearer token still works in this tab */ }
      form.elements.password.value = "";
      setAuthenticated(true, state.email);
      closeLogin();
      toast("Signed in to DamageBDD");
      await refreshOverview();
      if (state.view !== "overview") await refreshView();
    } catch (error) { put("consoleLoginStatus", showError(error)); }
    finally { $("consoleLoginSubmit").disabled = false; }
  }
  async function logout() {
    try { await request("/accounts/logout", { method: "POST", body: {} }); } catch (_) { /* clear local state regardless */ }
    try { window.TokenManager?.logout?.(window.TokenManager?.getMode?.()); } catch (_) { /* optional */ }
    state.accessToken = null; state.email = "";
    setAuthenticated(false);
    toast("Signed out of the console");
  }
  async function probeAuth() {
    try {
      // The index-jobs endpoint invokes the L402 authorization flow on guests.
      // Probe the account session first; only authenticated clients query jobs.
      const session = await request("/ecai/auth/session", { ignoreAuth: true });
      if (!session.authenticated) {
        state.services.queue = "auth";
        if (state.authenticated) { state.accessToken = null; setAuthenticated(false); }
        return false;
      }
      if (!state.authenticated) setAuthenticated(true, state.email || session.public_key || "DamageBDD session");
      // A persisted DamageBDD session may be recovered after deep-linking to
      // #code. Close the redundant login dialog and load the admin workspace.
      closeLogin();
      applyCodeSession(session);
      await probeCodeAccess();
      if (state.view === "code") await refreshCode();
      const result = await request("/ecai/index-jobs/status", { ignoreAuth: true });
      state.services.queue = "online";
      updateQueueMetrics(result.status || {});
      return true;
    } catch (error) {
      state.services.queue = error.status === 402 ? "payment" : error.status === 401 ? "auth" : "unavailable";
      if (error.status === 401) setAuthenticated(false);
      return false;
    }
  }
  function navigate(view) {
    if (!Object.prototype.hasOwnProperty.call(VIEW_NAMES, view)) view = "overview";
    const previous = state.view;
    state.view = view;
    for (const panel of document.querySelectorAll("[data-panel]")) {
      const active = panel.dataset.panel === view;
      panel.hidden = !active;
      panel.classList.toggle("is-visible", active);
    }
    for (const link of document.querySelectorAll("[data-view]")) {
      const active = link.dataset.view === view;
      link.classList.toggle("is-active", active);
      if (active) link.setAttribute("aria-current", "page"); else link.removeAttribute("aria-current");
    }
    put("viewBreadcrumb", VIEW_NAMES[view]);
    if (location.hash !== `#${view}`) history.replaceState(null, "", `#${view}`);
    closeNav();
    if (previous === "indexing" && view !== "indexing") stopStream();
    if (view !== "overview") refreshView().catch((error) => toast(showError(error), true));
  }
  function closeNav() { $("consoleSidebar").classList.remove("is-open"); $("mobileScrim").hidden = true; }
  function updateQueueMetrics(data) {
    state.queueFeatures.canceledRetry = data.canceled_checkpoint_retry === true;
    for (const entry of state.jobEntries.values()) if (entry.item.open) renderJobActions(entry);
    const running = data.running_jobs ?? data.running;
    const queued = data.queued_jobs ?? data.queued;
    put("metricRunning", running ?? "—"); put("queueRunning", running ?? "—");
    put("metricQueued", queued ?? "—"); put("queueQueued", queued ?? "—");
    put("queueWorkers", data.max_concurrency ?? data.active_workers ?? data.workers ?? "—");
  }
  function statusText(service) { return service === "online" ? "Available" : service === "auth" ? "Sign in required" : service === "payment" ? "Access/L402 challenge (402)" : service === "unavailable" ? "Unavailable" : "Not checked"; }
  function renderServices() {
    const container = $("overviewServices"); container.replaceChildren();
    for (const [name, key] of [["Local conversation", "chat"], ["Durable indexing", "queue"], ["Yelp index", "yelp"]]) {
      const row = element("div", "service-row");
      const dot = element("span", `service-dot ${state.services[key] === "online" ? "is-good" : "is-bad"}`);
      row.append(dot, element("span", "service-name", name), element("span", "service-state", statusText(state.services[key])));
      container.append(row);
    }
    const online = state.services.chat === "online";
    put("metricChat", online ? "Online" : statusText(state.services.chat));
    put("topbarRuntime", online ? "Chat endpoint responding" : "Some services may be unavailable");
    $("sidebarStatusDot").classList.toggle("online", online);
    put("sidebarNodeState", online ? "ECAI responding" : "Check node services");
  }
  async function refreshOverview() {
    const check = await Promise.allSettled([
      request("/ecai/chat", { ignoreAuth: true }),
      request("/yelp/status", { ignoreAuth: true }),
      probeAuth()
    ]);
    state.services.chat = check[0].status === "fulfilled" && check[0].value?.status === "ok" ? "online" : "unavailable";
    if (check[1].status === "fulfilled") {
      state.services.yelp = "online";
      const docs = check[1].value?.index_size?.docs;
      put("metricDocs", typeof docs === "number" ? docs.toLocaleString() : "—");
    } else state.services.yelp = "unavailable";
    if (check[2].status === "fulfilled" && check[2].value) {
      await refreshJobs().catch(() => {});
    }
    renderServices();
    renderOverviewJobs();
  }
  function renderOverviewJobs() {
    const parent = $("overviewJobs"); parent.replaceChildren();
    if (!state.authenticated) { parent.append(element("div", "empty-state", "Sign in to see current queue activity.")); return; }
    if (!state.jobs.length) { parent.append(element("div", "empty-state", "No recent jobs on this node.")); return; }
    for (const job of state.jobs.slice(0, 4)) {
      const row = element("div", "overview-job");
      const copy = element("div", "overview-job-copy");
      const title = element("strong", "", jobTitle(job));
      copy.append(title, element("small", "", job.id || ""));
      const side = element("div", "overview-job-copy");
      const pct = progressPercent(job.progress);
      side.append(element("div", "small muted", `${titleCase(job?.progress?.phase || job.state || "unknown")} · ${pct.toFixed(1)}%`), renderProgressTrack(pct, job.state, false));
      const badge = element("span", `status-tag state-${job.state || ""}`, job.state || "unknown");
      row.append(element("div", "overview-job-icon", "▦"), copy, side, badge);
      parent.append(row);
    }
  }

  function expectSuccess(data) {
    if (data?.ok === false || data?.status === "error") {
      const error = new Error(pretty(data?.error || data?.message || "Operation failed"));
      error.body = data;
      throw error;
    }
    return data;
  }
  async function task(fn, outputId = null) {
    try { return await fn(); }
    catch (error) {
      const message = showError(error);
      if (outputId) put(outputId, `Error: ${message}`);
      toast(message, true);
      return undefined;
    }
  }
  async function search(event) {
    event.preventDefault();
    const q = $("searchQuery").value.trim();
    const limit = Math.min(100, Math.max(1, Number($("searchLimit").value) || 10));
    if (!q) return;
    put("searchStatus", "Searching the index…");
    const results = $("searchResults"); results.replaceChildren();
    await task(async () => {
      const data = expectSuccess(await request("/ecai/search", { method: "POST", body: { q, limit }, ignoreAuth: true }));
      const items = Array.isArray(data.results) ? data.results : [];
      if (!items.length) results.append(element("div", "empty-state", "No matching records. Try a broader term."));
      for (const result of items) {
        const card = element("article", "result-card");
        const title = result?.preview || result?.record?.name || result?.record?.title || result?.doc_id || "Knowledge record";
        card.append(element("strong", "", title));
        const context = result?.record?.description || result?.record?.text || result?.record?.category;
        if (context) card.append(element("p", "", String(context).slice(0, 450)));
        const meta = element("div", "result-meta");
        if (result?.doc_id) meta.append(element("span", "", `ID: ${result.doc_id}`));
        if (Number.isFinite(result?.score)) meta.append(element("span", "", `Score: ${result.score.toFixed(3)}`));
        if (result?.record?.city) meta.append(element("span", "", result.record.city));
        card.append(meta); results.append(card);
      }
      put("searchStatus", `${items.length} result${items.length === 1 ? "" : "s"} returned`);
      put("searchProofs", data.proofs ?? "No proof material returned by this endpoint.");
    }, "searchStatus");
  }
  function resetChat() {
    state.chatSession = randomHex(16);
    state.chatUser = `console-${randomHex(12)}`;
    $("chatMessages").replaceChildren();
    const welcome = element("div", "chat-welcome");
    welcome.append(element("div", "welcome-icon", "e·"), element("h2", "", "A new conversation"), element("p", "", "Ask a question about your indexed knowledge."));
    $("chatMessages").append(welcome);
    put("chatSessionLabel", `Session ${state.chatSession.slice(0, 12)}`);
    put("chatStatus", "Ready");
  }
  function addChatMessage(content, role) {
    const area = $("chatMessages");
    area.querySelector(".chat-welcome")?.remove();
    area.append(element("div", `chat-bubble ${role === "user" ? "from-user" : "from-agent"}`, content));
    area.scrollTop = area.scrollHeight;
  }
  async function sendChat(event) {
    event.preventDefault();
    if (state.chatBusy) return;
    const message = $("chatPrompt").value.trim();
    if (!message) return;
    $("chatPrompt").value = "";
    addChatMessage(message, "user");
    state.chatBusy = true; $("chatSend").disabled = true;
    put("chatStatus", "Retrieving a reply…");
    try {
      const response = expectSuccess(await request("/ecai/chat", { method: "POST", body: {
        session_id: state.chatSession, user_id: state.chatUser, message
      }, ignoreAuth: true }));
      addChatMessage(response.reply ?? "Empty response", "agent");
      put("chatStatus", "Reply received");
    } catch (error) { addChatMessage(`Unable to obtain a reply: ${showError(error)}`, "agent"); put("chatStatus", "Request failed"); }
    finally { state.chatBusy = false; $("chatSend").disabled = false; $("chatPrompt").focus(); }
  }

  function indexActions(job) {
    const status = job.state;
    if (["running", "preparing"].includes(status)) return ["pause", "cancel"];
    if (status === "paused") return ["resume", "cancel"];
    if (["queued", "pause_requested"].includes(status)) return ["cancel"];
    if (["failed", "canceled"].includes(status)) return ["retry"];
    return [];
  }
  function progressPercent(progress = {}) {
    if (Number.isFinite(progress.percent)) return Math.max(0, Math.min(100, progress.percent));
    if (Number.isFinite(progress.completed) && Number.isFinite(progress.total) && progress.total > 0)
      return Math.max(0, Math.min(100, 100 * progress.completed / progress.total));
    return 0;
  }
  async function refreshJobs() {
    if (!state.authenticated) return;
    const query = new URLSearchParams({ limit: "50" });
    if (state.view === "indexing" && $("indexState").value) query.set("state", $("indexState").value);
    const data = expectSuccess(await request(`/ecai/index-jobs?${query}`));
    state.jobs = Array.isArray(data.jobs) ? data.jobs : [];
    renderJobs();
    renderOverviewJobs();
  }
  function mergeIndexRecord(existing, incoming) {
    if (!existing) return incoming;
    const oldSeq = Number(existing.event_seq) || 0;
    const newSeq = Number(incoming.event_seq) || 0;
    // A list poll may arrive after a newer SSE checkpoint. Never regress progress.
    const primary = oldSeq > newSeq ? existing : incoming;
    const secondary = oldSeq > newSeq ? incoming : existing;
    return {
      ...secondary, ...primary,
      progress: { ...(secondary.progress || {}), ...(primary.progress || {}) },
      resources: primary.resources ?? secondary.resources,
      runtime: primary.runtime ?? secondary.runtime
    };
  }
  function createJobEntry(job) {
    const id = String(job.id);
    const item = element("details", "index-job-item");
    item.dataset.jobId = id;
    const summary = element("summary", "index-job-summary");
    const expanded = element("div", "index-job-expanded");
    const toolbar = element("div", "index-job-toolbar");
    const tracking = element("span", "index-job-tracking", "Open to track live events");
    tracking.setAttribute("role", "status");
    const controls = element("div", "index-job-controls");
    const refresh = element("button", "button button-outline button-sm", "Refresh details");
    refresh.type = "button";
    const artifact = element("button", "button button-outline button-sm", "Artifact");
    artifact.type = "button";
    const actions = element("div", "table-actions index-job-actions");
    controls.append(refresh, artifact, actions);
    toolbar.append(tracking, controls);
    const layout = element("div", "index-job-layout");
    const inspector = element("div", "job-inspector");
    const feed = element("section", "index-job-feed");
    feed.append(element("h3", "", "Live activity"));
    const hint = element("p", "context-hint", "This authenticated stream replays recent durable events and then follows new checkpoints.");
    const log = element("pre", "code-display index-job-event-log", "Waiting for events…");
    log.setAttribute("aria-label", `Progress events for ${id}`);
    feed.append(hint, log);
    layout.append(inspector, feed);
    const raw = element("details", "nested-expandable index-job-raw");
    const rawSummary = element("summary", "", "Raw job JSON");
    const rawPre = element("pre", "code-display", "No detail loaded.");
    raw.append(rawSummary, rawPre);
    expanded.append(toolbar, layout, raw);
    item.append(summary, expanded);
    const entry = { id, job, item, summary, tracking, actions, inspector, log, rawPre, artifact,
      runtimeAtPerformance: performance.now(), runtimeSample: job.runtime?.sampled_at_ms,
      events: [], lastSeq: null, historyComplete: false, streamBlocked: false };
    item.addEventListener("toggle", () => onJobToggle(entry));
    refresh.addEventListener("click", () => task(() => loadIndexJobDetail(entry)));
    artifact.addEventListener("click", () => task(() => loadArtifact(entry.id)));
    return entry;
  }
  function renderJobSummary(entry) {
    const {job, summary} = entry;
    const pct = progressPercent(job.progress);
    const identity = element("span", "index-job-identity");
    identity.append(element("strong", "index-job-name", jobTitle(job)), element("span", "index-job-id mono", entry.id));
    const source = job.spec?.kind;
    if (source) identity.append(element("span", "index-job-source", titleCase(source)));
    const stateBadge = element("span", `status-tag state-${job.state || ""}`, titleCase(job.state || "unknown"));
    const meter = element("span", "index-job-meter");
    const metrics = element("span", "index-job-meter-label");
    metrics.append(element("strong", "", progressText(job.progress)), element("small", "", `${job.progress?.completed ?? "—"} / ${job.progress?.total ?? "—"}`));
    meter.append(metrics, renderProgressTrack(pct, job.state, true));
    const trailing = element("span", "index-job-trailing");
    if (Number.isFinite(job.runtime?.active_elapsed_ms))
      trailing.append(element("small", "index-job-time-spent", `Active ${formatDuration(job.runtime.active_elapsed_ms)}`));
    if (progressEta(job) !== "—") trailing.append(element("small", "", `ETA ~${progressEta(job)}`));
    const chevron = element("span", "index-job-chevron", "⌄");
    chevron.setAttribute("aria-hidden", "true");
    trailing.append(chevron);
    summary.replaceChildren(identity, stateBadge, meter, trailing);
    summary.setAttribute("aria-label", `${jobTitle(job)} ${entry.id}, ${job.state || "unknown"}, ${progressText(job.progress)}. Expand for live progress.`);
  }
  function renderJobActions(entry) {
    const wrap = entry.actions;
    wrap.replaceChildren();
    for (const action of indexActions(entry.job)) {
      const checkpoint = entry.job?.checkpoint;
      const saved = checkpoint && typeof checkpoint === "object" && Object.keys(checkpoint).length > 0;
      const label = action === "retry"
        ? (saved ? "Resume from checkpoint" : "Restart job")
        : titleCase(action);
      const b = element("button", "", label);
      b.type = "button";
      b.disabled = !!entry.controlBusy;
      if (action === "retry" && entry.job?.state === "canceled" && !state.queueFeatures.canceledRetry) {
        b.disabled = true;
        b.title = "The running ECAI backend does not advertise canceled-job retry support. Deploy and restart the checkpoint-retry job service.";
      }
      if (action === "retry" && entry.job?.state === "failed" &&
          Number.isFinite(entry.job?.attempt) && Number.isFinite(entry.job?.max_retries) &&
          entry.job.attempt > entry.job.max_retries) {
        b.disabled = true;
        b.title = "Retry allowance exhausted. Create a new job with an adjusted policy if appropriate.";
      }
      b.addEventListener("click", () => task(() => controlIndexJob(entry.id, action)));
      wrap.append(b);
    }
  }
  function renderJobDetails(entry) {
    renderJobPanel(entry.job, entry.inspector);
    entry.rawPre.textContent = pretty(entry.job);
    renderJobActions(entry);
    entry.artifact.disabled = !entry.job.artifact && !["completed", "ready_to_mint", "minted"].includes(entry.job.state);
  }
  function renderJobs() {
    const parent = $("indexJobList");
    if (!state.authenticated || !state.jobs.length) {
      stopStream();
      state.selectedIndexId = "";
      state.selectedIndexJob = null;
      state.jobEntries.clear();
      parent.replaceChildren(element("div", "empty-state", state.authenticated ? "No jobs match this filter." : "Sign in to inspect jobs."));
      return;
    }
    const previous = state.jobEntries;
    const next = new Map();
    for (const job of state.jobs) {
      if (!job || !job.id) continue;
      const id = String(job.id);
      if (next.has(id)) continue;
      const entry = previous.get(id) || createJobEntry(job);
      entry.job = mergeIndexRecord(entry.job, job);
      if (job.runtime?.sampled_at_ms && job.runtime.sampled_at_ms !== entry.runtimeSample) {
        entry.runtimeAtPerformance = performance.now();
        entry.runtimeSample = job.runtime.sampled_at_ms;
      }
      renderJobSummary(entry);
      if (entry.item.open) renderJobDetails(entry);
      next.set(id, entry);
    }
    if (state.selectedIndexId && !next.has(state.selectedIndexId)) {
      stopStream();
      state.selectedIndexId = "";
      state.selectedIndexJob = null;
    }
    state.jobEntries = next;
    const entries = [...next.values()];
    entries.forEach((entry, pos) => {
      if (parent.children[pos] !== entry.item)
        parent.insertBefore(entry.item, parent.children[pos] || null);
    });
    while (parent.children.length > entries.length) parent.lastElementChild.remove();
    const active = next.get(state.selectedIndexId);
    if (active?.item.open) {
      state.selectedIndexJob = active.job;
      if (state.view === "indexing" && !document.hidden && !state.streamSession && !active.historyComplete && !active.streamBlocked)
        startJobStream(active);
    }
  }
  function tickJobClocks() {
    if (state.view !== "indexing" || document.hidden) return;
    const entry = state.jobEntries.get(state.selectedIndexId);
    if (!entry?.item.open) return;
    for (const clock of entry.inspector.querySelectorAll("[data-runtime-clock]")) {
      clock.textContent = elapsedRuntime(entry.job, clock.dataset.runtimeClock, entry.runtimeAtPerformance);
    }
  }
  async function pollJobTelemetry() {
    if (!state.authenticated || document.hidden || state.view !== "indexing") return;
    const entry = state.jobEntries.get(state.selectedIndexId);
    if (!entry?.item.open || !isRunningLike(entry.job?.state) || entry.telemetryBusy) return;
    entry.telemetryBusy = true;
    try { await loadIndexJobDetail(entry); }
    finally { entry.telemetryBusy = false; }
  }
  function jobIsOpen(entry) {
    return state.authenticated && state.view === "indexing" && !document.hidden &&
      state.jobEntries.get(entry.id) === entry && entry.item.open && state.selectedIndexId === entry.id;
  }
  function onJobToggle(entry) {
    if (!entry.item.open) {
      if (state.selectedIndexId === entry.id) {
        stopStream();
        state.selectedIndexId = "";
        state.selectedIndexJob = null;
        entry.tracking.textContent = "Tracking stopped · collapsed";
      }
      return;
    }
    if (state.selectedIndexId === entry.id) return;
    // Native details accordion: one detailed stream at a time.
    for (const other of state.jobEntries.values()) if (other !== entry && other.item.open) other.item.open = false;
    stopStream();
    state.selectedIndexId = entry.id;
    state.selectedIndexJob = entry.job;
    renderJobDetails(entry);
    entry.tracking.textContent = "Loading detail and live progress…";
    void task(() => loadIndexJobDetail(entry));
    startJobStream(entry);
  }
  async function loadIndexJobDetail(entry) {
    const result = expectSuccess(await request(`/ecai/index-jobs/${encodeURIComponent(entry.id)}`));
    if (!jobIsOpen(entry)) return;
    if (!result.job || typeof result.job !== "object") throw new Error("Job detail was not returned");
    entry.job = mergeIndexRecord(entry.job, result.job);
    entry.runtimeAtPerformance = performance.now();
    entry.runtimeSample = entry.job.runtime?.sampled_at_ms;
    state.selectedIndexJob = entry.job;
    renderJobSummary(entry);
    renderJobDetails(entry);
  }
  async function selectIndexJob(id) {
    const jobId = String(id);
    let entry = state.jobEntries.get(jobId);
    if (!entry) {
      const response = expectSuccess(await request(`/ecai/index-jobs/${encodeURIComponent(jobId)}`));
      if (!response.job) throw new Error("Job detail was not returned");
      state.jobs = [response.job, ...state.jobs.filter((job) => String(job.id) !== jobId)];
      renderJobs();
      entry = state.jobEntries.get(jobId);
    }
    if (!entry) throw new Error("Unable to display this job");
    entry.item.open = true;
    onJobToggle(entry);
    entry.item.scrollIntoView({ block: "nearest", behavior: "instant" });
  }
  async function controlIndexJob(id, action) {
    const entry = state.jobEntries.get(String(id));
    if (entry?.controlBusy) return;
    if (action === "cancel" && !confirm(`Cancel index job ${id}?`)) return;
    if (action === "retry") {
      const checkpoint = entry?.job?.checkpoint;
      const hasCheckpoint = checkpoint && typeof checkpoint === "object" && Object.keys(checkpoint).length > 0;
      const question = hasCheckpoint
        ? `Resume job ${id} from its last durable checkpoint? The current work unit may be repeated.`
        : `Restart job ${id}? No durable checkpoint is available, so processing may begin at the start.`;
      if (!confirm(question)) return;
    }
    if (entry) { entry.controlBusy = true; renderJobActions(entry); }
    try {
      const response = expectSuccess(await request(`/ecai/index-jobs/${encodeURIComponent(String(id))}/${action}`, { method: "POST", body: {} }));
      if (entry && response.job) {
        if ((action === "retry" || action === "resume") && entry.item.open) stopStream();
        entry.job = mergeIndexRecord(entry.job, response.job);
        if (action === "retry" || action === "resume") {
          entry.historyComplete = false;
          entry.streamBlocked = false;
          // Start from the transition just accepted; do not replay an earlier
          // canceled event as if it belongs to this worker attempt.
          entry.lastSeq = Math.max(0, (Number(response.job.event_seq) || 1) - 1);
          entry.events.push(`Operator ${action} accepted · waiting for a worker`);
          entry.log.textContent = entry.events.slice(-80).join("\n");
        }
        renderJobSummary(entry);
        if (entry.item.open) renderJobDetails(entry);
      }
      const hasSavedCheckpoint = entry?.job?.checkpoint && typeof entry.job.checkpoint === "object" &&
        Object.keys(entry.job.checkpoint).length > 0;
      toast(action === "retry"
        ? (hasSavedCheckpoint ? "Job requeued from its durable checkpoint" : "Job requeued to start again")
        : `Job ${action} accepted`);
      await refreshJobs();
      if (entry?.item.open) await loadIndexJobDetail(entry);
      if (entry?.item.open && !state.streamSession && !entry.streamBlocked && !entry.historyComplete) startJobStream(entry);
    } catch (error) {
      // A competing operator may have changed the state since this card was
      // rendered. Refresh it instead of displaying stale Retry controls.
      if (error.status === 409 || error.status === 429) await refreshJobs().catch(() => {});
      if (action === "retry" && error.status === 409 &&
          Array.isArray(error.body?.error) && error.body.error[0] === "invalid_state" &&
          error.body.error[1] === "canceled") {
        throw new Error("The server is still using the old canceled-job retry policy. Verify the loaded ecai_index_jobs_srv BEAM and restart the ECAI job supervisor after deploying the backend patch.");
      }
      throw error;
    } finally {
      if (entry) { entry.controlBusy = false; renderJobActions(entry); }
    }
  }
  function renderPresets() {
    const container = $("indexPresets"); container.replaceChildren();
    if (!state.authenticated || !state.presets.length) {
      container.append(element("div", "empty-state", state.authenticated ? "No presets configured on this node." : "Sign in to load curated sources."));
      return;
    }
    for (const preset of state.presets) {
      const card = element("article", "preset-card");
      card.append(element("h3", "", preset.label || preset.id || "Wikimedia"));
      card.append(element("p", "", preset.description || "Wikimedia visibility corpus"));
      card.append(element("small", "", preset.project || preset.id || ""));
      const btn = element("button", "button button-primary button-sm", "Queue preset ↗");
      btn.type = "button";
      btn.addEventListener("click", () => task(async () => {
        btn.disabled = true;
        try { await queuePreset(preset); } finally { btn.disabled = false; }
      }));
      card.append(btn); container.append(card);
    }
  }
  function presetStorageKey(preset) { return `ecai.console.preset.${preset}`; }
  async function queuePreset(preset) {
    if (!state.authenticated) { openLogin("Sign in to queue an index."); return; }
    const keyName = presetStorageKey(preset.id);
    let key;
    try { key = sessionStorage.getItem(keyName); } catch (_) { /* restrictive browser */ }
    if (!key) { key = newKey("ecai-preset"); try { sessionStorage.setItem(keyName, key); } catch (_) {} }
    const response = expectSuccess(await request(`/ecai/index-jobs/presets/${encodeURIComponent(preset.id)}`, {
      method: "POST", body: {}, headers: { "Idempotency-Key": key }
    }));
    try { sessionStorage.removeItem(keyName); } catch (_) {}
    toast(`${preset.label || preset.id} queued`);
    await refreshIndexing();
    if (response.job?.id) await selectIndexJob(response.job.id);
  }
  async function refreshIndexing() {
    if (!state.authenticated) return;
    const results = await Promise.allSettled([
      request("/ecai/index-jobs/status"), request("/ecai/index-jobs/presets"), refreshJobs()
    ]);
    if (results[0].status === "fulfilled") updateQueueMetrics(results[0].value.status || {});
    if (results[1].status === "fulfilled") {
      state.presets = Array.isArray(results[1].value.presets) ? results[1].value.presets : [];
      renderPresets();
    }
    if (results.every((r) => r.status === "rejected")) throw results[0].reason;
  }
  async function customJob(event) {
    event.preventDefault();
    if (!state.authenticated) { openLogin(); return; }
    await task(async () => {
      const spec = JSON.parse($("indexCustomSpec").value);
      if (!spec || typeof spec !== "object" || Array.isArray(spec)) throw new Error("A JSON object is required");
      const key = $("indexIdempotency").value.trim();
      if (!key) throw new Error("Generate an idempotency key first");
      const result = expectSuccess(await request("/ecai/index-jobs", { method: "POST", body: spec, headers: { "Idempotency-Key": key } }));
      toast("Index job queued");
      $("indexIdempotency").value = newKey("ecai-job");
      await refreshIndexing();
      if (result.job?.id) await selectIndexJob(result.job.id);
    });
  }
  async function loadArtifact(id) {
    const entry = state.jobEntries.get(String(id));
    if (!entry || !jobIsOpen(entry)) return;
    const result = expectSuccess(await request(`/ecai/index-jobs/${encodeURIComponent(entry.id)}/artifact`));
    if (!jobIsOpen(entry)) return;
    entry.job = { ...entry.job, artifact: result.artifact || entry.job.artifact, nft_metadata: result.nft_metadata };
    renderJobDetails(entry);
    toast("Artifact metadata loaded");
  }
  function stopStream() {
    const session = state.streamSession;
    state.streamSession = null;
    if (!session) return;
    if (session.retryTimer) clearTimeout(session.retryTimer);
    session.controller?.abort();
    const entry = state.jobEntries.get(session.jobId);
    if (entry?.item.open && !entry.historyComplete) entry.tracking.textContent = "Tracking paused";
  }
  function appendJobEvent(entry, event) {
    const phase = event.data?.progress?.phase || event.state || event.type || "event";
    const p = event.data?.progress;
    const n = p && Number.isFinite(p.completed) ? ` · ${formatNumber(p.completed)}${Number.isFinite(p.total) ? `/${formatNumber(p.total)}` : ""}` : "";
    const stamp = Number.isFinite(event.at_ms) ? new Date(event.at_ms).toLocaleTimeString() : "";
    const line = `${stamp}  #${event.seq || "?"}  ${titleCase(phase)}${n}`;
    entry.events.push(line);
    if (entry.events.length > 80) entry.events.splice(0, entry.events.length - 80);
    entry.log.textContent = entry.events.join("\n");
    entry.log.scrollTop = entry.log.scrollHeight;
  }
  function handleEventBlock(block, entry, session) {
    let eventName = "message";
    let eventId = "";
    const payload = [];
    for (const line of block.split("\n")) {
      if (!line || line.startsWith(":")) continue;
      const idx = line.indexOf(":");
      const field = idx < 0 ? line : line.slice(0, idx);
      const value = idx < 0 ? "" : line.slice(idx + 1).replace(/^ /, "");
      if (field === "id") eventId = value;
      if (field === "event") eventName = value;
      if (field === "data") payload.push(value);
    }
    if (!payload.length || !jobIsOpen(entry) || state.streamSession !== session) return;
    let event;
    try { event = JSON.parse(payload.join("\n")); } catch (_) { return; }
    if (String(event.job_id || "") !== entry.id) return;
    const seq = Number(event.seq ?? eventId);
    if (!Number.isSafeInteger(seq) || seq < 0 || (entry.lastSeq !== null && seq <= entry.lastSeq)) return;
    entry.lastSeq = seq;
    session.retries = 0; // A real event marks the transport healthy.
    const data = event.data && typeof event.data === "object" ? event.data : {};
    // Replayed history is for the timeline; the fetched snapshot may be newer.
    // Do not rewind a completed/updated job while replaying older checkpoints.
    if (seq >= (Number(entry.job.event_seq) || 0)) {
      const updated = { ...entry.job, event_seq: seq };
      if (event.state) updated.state = event.state;
      if (data.state) updated.state = data.state;
      if (data.progress && typeof data.progress === "object") updated.progress = { ...(updated.progress || {}), ...data.progress };
      if (data.checkpoint && typeof data.checkpoint === "object") updated.checkpoint = data.checkpoint;
      if (data.artifact && typeof data.artifact === "object") updated.artifact = data.artifact;
      if (data.result && typeof data.result === "object") updated.result = data.result;
      entry.job = updated;
      state.selectedIndexJob = updated;
      renderJobSummary(entry);
      renderJobDetails(entry);
      if (terminalIndexState(updated.state)) {
        session.terminal = true;
        entry.historyComplete = true;
        void task(refreshJobs);
      }
    }
    appendJobEvent(entry, { ...event, type: eventName });
  }
  function startJobStream(entry) {
    if (!jobIsOpen(entry) || entry.streamBlocked || entry.historyComplete) return;
    if (state.streamSession?.jobId === entry.id) return;
    stopStream();
    if (entry.lastSeq === null) {
      // Replay only the last few durable checkpoints, then continue in real time.
      entry.lastSeq = Math.max(0, (Number(entry.job.event_seq) || 0) - 16);
    }
    const session = { jobId: entry.id, controller: null, retryTimer: null, retries: 0, terminal: false };
    state.streamSession = session;
    void consumeJobStream(entry, session);
  }
  async function consumeJobStream(entry, session) {
    if (!jobIsOpen(entry) || state.streamSession !== session) return;
    session.controller = new AbortController();
    const controller = session.controller;
    let retryable = true;
    try {
      entry.tracking.textContent = session.retries ? "Reconnecting to live events…" : "Connecting to live events…";
      const url = `/ecai/index-jobs/${encodeURIComponent(entry.id)}/events?after_seq=${entry.lastSeq || 0}`;
      const response = await fetch(safePath(url), {
        method: "GET", credentials: "include", headers: headers({ Accept: "text/event-stream" }), signal: controller.signal
      });
      if (!response.ok) {
        retryable = ![401, 402, 403, 404].includes(response.status);
        const error = new Error(`Event stream HTTP ${response.status}`);
        error.status = response.status;
        throw error;
      }
      if (!response.body) throw new Error("Event stream body unavailable");
      entry.tracking.textContent = "● Live · durable checkpoints";
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      while (jobIsOpen(entry) && state.streamSession === session) {
        const { value, done } = await reader.read();
        buffer += decoder.decode(value || new Uint8Array(), { stream: !done }).replace(/\r\n/g, "\n");
        let marker;
        while ((marker = buffer.indexOf("\n\n")) >= 0) {
          handleEventBlock(buffer.slice(0, marker), entry, session);
          buffer = buffer.slice(marker + 2);
        }
        if (done) { if (buffer.trim()) handleEventBlock(buffer, entry, session); break; }
        if (buffer.length > 1048576) throw new Error("Oversized SSE event rejected");
      }
    } catch (error) {
      if (error.name === "AbortError" || !jobIsOpen(entry) || state.streamSession !== session) return;
      if (!retryable) {
        entry.streamBlocked = true;
        entry.tracking.textContent = `Live events unavailable: ${showError(error)}`;
      } else {
        entry.tracking.textContent = `Live feed interrupted: ${showError(error)}`;
      }
    } finally {
      if (state.streamSession !== session || !jobIsOpen(entry)) return;
      if (session.terminal || terminalIndexState(entry.job.state)) {
        entry.historyComplete = true;
        entry.tracking.textContent = "● History complete · job not running";
        state.streamSession = null;
      } else if (entry.streamBlocked) {
        state.streamSession = null;
      } else {
        const delay = Math.min(30000, 1500 * 2 ** Math.min(session.retries++, 4));
        entry.tracking.textContent = `Connection ended · reconnecting in ${Math.ceil(delay / 1000)}s`;
        session.retryTimer = setTimeout(() => { session.retryTimer = null; void consumeJobStream(entry, session); }, delay);
      }
    }
  }
  function queryString(params) {
    const q = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) if (value !== "" && value !== undefined && value !== null) q.set(key, String(value));
    return q.toString() ? `?${q.toString()}` : "";
  }
  async function wikiRequest(action, options, target) {
    await task(async () => {
      put(target, "Loading…");
      const data = expectSuccess(await request(`/ecai/wikimedia/${action}${queryString(options)}`));
      put(target, data);
    }, target);
  }
  // Wikimedia picker: two independent paths. Curated presets are always
  // submitted by ID; custom jobs are validated and constructed by the server.
  function wikiPresetProject(preset) { return String(preset?.project || preset?.id || ""); }
  function inferredPageviewProject(project) {
    return /^[a-z0-9_-]+wiki$/.test(project)
      ? `${project.slice(0, -4)}.wikipedia` : "";
  }
  function wikiPresetActive(project) {
    return state.jobs.some((job) => job?.spec?.source?.project === project &&
      ["queued", "preparing", "running", "finalizing", "pause_requested", "paused"].includes(job.state));
  }
  function renderWikiProjects() {
    const host = $("wikiPresetChoices");
    host.replaceChildren();
    if (!state.authenticated) {
      host.append(element("div", "empty-state", "Sign in with your DamageBDD account to pick indexing projects."));
    } else if (!state.presets.length) {
      host.append(element("div", "empty-state", "No server-defined Wikimedia presets are available."));
    } else {
      const filter = $("wikiPresetSearch").value.trim().toLowerCase();
      const matching = state.presets.filter((preset) =>
        `${preset.label || ""} ${preset.description || ""} ${preset.id || ""} ${wikiPresetProject(preset)}`.toLowerCase().includes(filter));
      if (!matching.length) host.append(element("div", "empty-state", "No projects match that search."));
      for (const preset of matching) {
        const id = String(preset.id || "");
        if (!id) continue;
        const checked = state.wikiSelectedPresets.has(id);
        const card = element("label", `wiki-project-card${checked ? " is-selected" : ""}`);
        const head = element("span", "wiki-project-card-head");
        const checkbox = element("input");
        checkbox.type = "checkbox";
        checkbox.checked = checked;
        checkbox.disabled = state.wikiQueueBusy;
        checkbox.setAttribute("aria-label", `Select ${preset.label || id}`);
        checkbox.addEventListener("change", () => {
          if (checkbox.checked) state.wikiSelectedPresets.add(id);
          else state.wikiSelectedPresets.delete(id);
          card.classList.toggle("is-selected", checkbox.checked);
          const count = state.wikiSelectedPresets.size;
          put("wikiSelectedCount", `${count} selected`);
          $("wikiQueueSelected").disabled = !state.authenticated || state.wikiQueueBusy || count === 0;
          $("wikiClearSelected").disabled = state.wikiQueueBusy || count === 0;
        });
        const copy = element("span", "wiki-project-card-copy");
        copy.append(element("strong", "", preset.label || id), element("small", "", `${wikiPresetProject(preset)} · server preset`));
        head.append(checkbox, copy);
        card.append(head, element("span", "wiki-project-description", preset.description || "Index this Wikimedia corpus."));
        if (wikiPresetActive(wikiPresetProject(preset))) {
          card.append(element("span", "wiki-project-active", "A job for this project is already active"));
        }
        host.append(card);
      }
    }
    const count = state.wikiSelectedPresets.size;
    put("wikiSelectedCount", `${count} selected`);
    $("wikiQueueSelected").disabled = !state.authenticated || state.wikiQueueBusy || count === 0;
    $("wikiSelectAll").disabled = state.wikiQueueBusy || !state.authenticated || !state.presets.length;
    $("wikiClearSelected").disabled = state.wikiQueueBusy || count === 0;
  }
  function populateWikiProjects() {
    const control = $("wikiProject");
    const previous = control.value;
    const projects = [...new Set(state.presets.map(wikiPresetProject).filter((p) => /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(p) && !p.includes("..")))];
    if (!projects.length) projects.push("enwiki");
    control.replaceChildren();
    for (const project of projects) {
      const preset = state.presets.find((item) => wikiPresetProject(item) === project);
      const option = element("option", "", `${preset?.label || project} · ${project}`);
      option.value = project;
      control.append(option);
    }
    control.value = projects.includes(previous) ? previous : projects[0];
    if (control.value !== previous) {
      $("wikiPageviewProject").value = inferredPageviewProject(control.value);
      resetWikiCatalog();
    }
  }
  async function refreshWikiProjects(force = false) {
    if (!state.authenticated) {
      renderWikiProjects();
      put("wikiPickerStatus", "Sign in to add indexing jobs.");
      return;
    }
    if (state.wikiLoadingPresets) return;
    if (!force && state.presets.length) {
      populateWikiProjects();
      renderWikiProjects();
      return;
    }
    state.wikiLoadingPresets = true;
    put("wikiPickerStatus", "Loading node-configured indexing projects…");
    try {
      const data = expectSuccess(await request("/ecai/index-jobs/presets"));
      if (!state.authenticated) return;
      state.presets = Array.isArray(data.presets) ? data.presets : [];
      const validIds = new Set(state.presets.map((preset) => String(preset.id)));
      for (const id of state.wikiSelectedPresets) if (!validIds.has(id)) state.wikiSelectedPresets.delete(id);
      populateWikiProjects();
      renderWikiProjects();
      renderPresets();
      put("wikiPickerStatus", `${state.presets.length} projects ready. Choose one or more to enqueue.`);
    } catch (error) {
      put("wikiPickerStatus", `Unable to load projects: ${showError(error)}`);
      throw error;
    } finally { state.wikiLoadingPresets = false; }
  }
  function wikiQueueResult(id, success, message, jobId = "") {
    const host = $("wikiEnqueueResults");
    const row = element("div", `wiki-queue-result${success ? " is-success" : " is-error"}`);
    row.append(element("span", "", `${success ? "✓" : "!"} ${id}: ${message}`));
    if (jobId) {
      const btn = element("button", "text-button", "View job ↗");
      btn.type = "button";
      btn.addEventListener("click", () => task(async () => {
        navigate("indexing");
        await refreshIndexing();
        await selectIndexJob(jobId);
      }));
      row.append(btn);
    }
    host.prepend(row);
  }
  async function queueSelectedWikiPresets() {
    if (!state.authenticated) { openLogin("Sign in to queue Wikimedia datasets."); return; }
    if (state.wikiQueueBusy) return;
    const selections = state.presets.filter((preset) => state.wikiSelectedPresets.has(String(preset.id)));
    if (!selections.length) return;
    const running = selections.filter((preset) => wikiPresetActive(wikiPresetProject(preset))).length;
    const warning = running ? `\n${running} project(s) already have active work. This may compete for the same output index.` : "";
    if (!confirm(`Add ${selections.length} Wikimedia indexing job(s) to this node's durable queue?${warning}`)) return;
    state.wikiQueueBusy = true;
    renderWikiProjects();
    $("wikiEnqueueResults").replaceChildren();
    let successes = 0;
    try {
      for (const preset of selections) {
        const keyName = presetStorageKey(preset.id);
        let key = state.wikiPresetKeys.get(String(preset.id));
        if (!key) {
          try { key = sessionStorage.getItem(keyName); } catch (_) { /* storage may be blocked */ }
        }
        if (!key) key = newKey("ecai-wiki-preset");
        state.wikiPresetKeys.set(String(preset.id), key);
        try { sessionStorage.setItem(keyName, key); } catch (_) { /* no storage */ }
        put("wikiPickerStatus", `Queueing ${preset.label || preset.id} (${successes + 1}/${selections.length})…`);
        try {
          const response = expectSuccess(await request(`/ecai/index-jobs/presets/${encodeURIComponent(preset.id)}`, {
            method: "POST", body: {}, headers: { "Idempotency-Key": key }
          }));
          successes++;
          state.wikiSelectedPresets.delete(String(preset.id));
          state.wikiPresetKeys.delete(String(preset.id));
          try { sessionStorage.removeItem(keyName); } catch (_) { /* no storage */ }
          wikiQueueResult(preset.label || preset.id, true, "Queued", response.job?.id);
        } catch (error) {
          // Keep the same idempotency key and the selection for a safe retry.
          wikiQueueResult(preset.label || preset.id, false, showError(error));
        }
      }
    } finally {
      state.wikiQueueBusy = false;
      put("wikiPickerStatus", `${successes}/${selections.length} jobs accepted. Failed selections can be retried safely.`);
      await refreshJobs().catch(() => {});
      renderWikiProjects();
    }
  }
  function resetWikiCatalog() {
    state.wikiDiscoveryEpoch++;
    state.wikiCatalog = null;
    state.wikiCatalogKey = "";
    state.wikiMonthsSelected.clear();
    $("wikiRelease").replaceChildren();
    const placeholder = element("option", "", "Discover releases first");
    placeholder.value = "";
    $("wikiRelease").append(placeholder);
    $("wikiRelease").disabled = true;
    $("wikiRecentSix").disabled = true;
    $("wikiRecentAll").disabled = true;
    $("wikiMonthChoices").replaceChildren(element("div", "empty-state", "Discover sources to pick months."));
    put("wikiMonthCount", "0 selected");
    $("wikiMonths").value = "";
    invalidateWikiPlan("Discover sources for this project before previewing.");
  }
  function wikiCatalogIdentity() {
    return `${$("wikiProject").value.trim()}|${$("wikiPageviewProject").value.trim()}`;
  }
  function wikiInput() {
    const project = $("wikiProject").value.trim();
    const pageview_project = $("wikiPageviewProject").value.trim();
    const content_release = $("wikiRelease").value.trim();
    const pageview_months = [...state.wikiMonthsSelected].sort();
    const limit = Number($("wikiPlanLimit").value);
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(project)) throw new Error("Choose a valid Wikimedia project.");
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(pageview_project)) throw new Error("Invalid pageview project identifier.");
    if (!/^\d{8}$/.test(content_release) || !state.wikiCatalog?.available_cirrus_releases?.includes(content_release))
      throw new Error("Discover sources and choose a listed Cirrus release.");
    if (!pageview_months.length || pageview_months.length > 64) throw new Error("Choose between 1 and 64 pageview months.");
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 10000000) throw new Error("Record limit must be between 1 and 10,000,000.");
    if (state.wikiCatalogKey !== wikiCatalogIdentity()) throw new Error("Project settings changed. Rediscover sources first.");
    return { project, pageview_project, content_release, pageview_months, limit,
      minimum_active_months: Math.min(6, pageview_months.length) };
  }
  function wikiInputIdentity() {
    try { return JSON.stringify(wikiInput()); } catch (_) { return ""; }
  }
  function invalidateWikiPlan(message = "Selection changed. Preview a new plan before queueing.") {
    state.wikiPlanEpoch++;
    state.wikiPlan = null;
    $("wikiQueuePlanBtn").disabled = true;
    $("wikiPlanBtn").disabled = !state.wikiCatalog || !state.authenticated || state.wikiPlanBusy;
    put("wikiPlanStatus", message);
    renderWikiPlanSummary();
  }
  function renderWikiMonths() {
    const host = $("wikiMonthChoices");
    host.replaceChildren();
    const months = state.wikiCatalog?.requested_pageview_months || [];
    for (const month of months) {
      const active = state.wikiMonthsSelected.has(month);
      const item = element("label", `wiki-month-choice${active ? " is-selected" : ""}`);
      const input = element("input");
      input.type = "checkbox";
      input.checked = active;
      input.value = month;
      input.addEventListener("change", () => {
        if (input.checked) state.wikiMonthsSelected.add(month);
        else state.wikiMonthsSelected.delete(month);
        item.classList.toggle("is-selected", input.checked);
        $("wikiMonths").value = [...state.wikiMonthsSelected].sort().join(",");
        put("wikiMonthCount", `${state.wikiMonthsSelected.size} selected`);
        invalidateWikiPlan();
      });
      item.append(input, element("span", "", month));
      host.append(item);
    }
    $("wikiMonths").value = [...state.wikiMonthsSelected].sort().join(",");
    put("wikiMonthCount", `${state.wikiMonthsSelected.size} selected`);
  }
  function pickWikiMonths(count) {
    if (!state.wikiCatalog) return;
    const months = state.wikiCatalog.requested_pageview_months || [];
    state.wikiMonthsSelected = new Set(count === "all" ? months : months.slice(-count));
    renderWikiMonths();
    invalidateWikiPlan();
  }
  async function discoverWikiSources() {
    if (state.wikiQueueBusy) return;
    const project = $("wikiProject").value.trim();
    const pageview_project = $("wikiPageviewProject").value.trim();
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(project) || !/^[A-Za-z0-9._-]{1,128}$/.test(pageview_project)) {
      put("wikiPlanStatus", "Project and pageview project must be valid tokens.");
      return;
    }
    resetWikiCatalog();
    const epoch = state.wikiDiscoveryEpoch;
    $("wikiSourcesBtn").disabled = true;
    put("wikiPlanStatus", "Discovering published releases on Wikimedia…");
    try {
      const response = expectSuccess(await request(`/ecai/wikimedia/sources${queryString({ project, pageview_project })}`));
      if (epoch !== state.wikiDiscoveryEpoch || wikiCatalogIdentity() !== `${project}|${pageview_project}`) return;
      const catalog = response.sources;
      if (!catalog || catalog.project !== project || catalog.pageview_project !== pageview_project) throw new Error("Catalog does not match the selected project.");
      const releases = (Array.isArray(catalog.available_cirrus_releases) ? catalog.available_cirrus_releases : [])
        .filter((value) => typeof value === "string" && /^\d{8}$/.test(value));
      const months = [...new Set((Array.isArray(catalog.requested_pageview_months) ? catalog.requested_pageview_months : [])
        .filter((value) => typeof value === "string" && /^\d{4}-(0[1-9]|1[0-2])$/.test(value)))].sort().slice(-64);
      if (!releases.length || !months.length) throw new Error("No releases or month suggestions were returned for this project.");
      catalog.available_cirrus_releases = releases;
      catalog.requested_pageview_months = months;
      state.wikiCatalog = catalog;
      state.wikiCatalogKey = wikiCatalogIdentity();
      const control = $("wikiRelease");
      control.replaceChildren();
      for (const release of releases) {
        const option = element("option", "", `${release.slice(0,4)}-${release.slice(4,6)}-${release.slice(6,8)}${release === releases[0] ? " · newest listed" : ""}`);
        option.value = release;
        control.append(option);
      }
      control.disabled = false;
      $("wikiRecentSix").disabled = false;
      $("wikiRecentAll").disabled = false;
      state.wikiMonthsSelected = new Set(months.slice(-6));
      renderWikiMonths();
      put("wikiSourcesOutput", catalog);
      put("wikiPlanStatus", `${releases.length} releases found. Select months, then preview to validate the sources.`);
      $("wikiPlanBtn").disabled = !state.authenticated;
      renderWikiPlanSummary();
    } catch (error) {
      if (epoch === state.wikiDiscoveryEpoch) {
        put("wikiSourcesOutput", `Discovery failed: ${showError(error)}`);
        put("wikiPlanStatus", `Source discovery failed: ${showError(error)}`);
      }
    } finally { $("wikiSourcesBtn").disabled = false; }
  }
  function renderWikiPlanSummary() {
    const host = $("wikiPlanSummary");
    host.replaceChildren();
    let input;
    try { input = wikiInput(); } catch (_) {
      host.append(element("div", "empty-state", "Discover a release and select at least one month to build a valid job."));
      return;
    }
    const summary = [
      ["Project", input.project], ["Cirrus release", input.content_release],
      ["Pageview months", `${input.pageview_months.length} · ${input.pageview_months[0]} → ${input.pageview_months.at(-1)}`],
      ["Max records", formatNumber(input.limit)]
    ];
    if (state.wikiPlan?.inputKey === JSON.stringify(input)) {
      const catalog = state.wikiPlan.summary;
      summary.push(["Content shards", catalog?.content_shards ?? "—"], ["Pageview files", catalog?.pageview_files ?? "—"]);
    }
    for (const [key,value] of summary) {
      const line = element("div", "wiki-plan-summary-line");
      line.append(element("span", "", key), element("strong", "", String(value)));
      host.append(line);
    }
    if (!state.wikiPlan) host.append(element("div", "wiki-plan-warning", "Preview is required before queueing. Files and final job specification are verified by the server."));
    else host.append(element("div", "wiki-plan-approved",
      state.wikiPlan.queued ? "✓ Job queued successfully" : "✓ Validated plan ready to queue"));
    if (state.wikiPlan?.spec?.finalize?.publish_ipfs === true) {
      host.append(element("div", "wiki-plan-warning", "This job is configured to publish its resulting artifact to IPFS."));
    }
  }
  async function previewWikiPlan() {
    if (state.wikiPlanBusy) return;
    let input;
    try { input = wikiInput(); } catch (error) { put("wikiPlanStatus", error.message); return; }
    if (!state.authenticated) { openLogin("Sign in to queue a custom Wikimedia job."); return; }
    invalidateWikiPlan("Resolving source files and validating a job plan…");
    const epoch = state.wikiPlanEpoch;
    state.wikiPlanBusy = true;
    $("wikiPlanBtn").disabled = true;
    try {
      const params = { project: input.project, pageview_project: input.pageview_project,
        content_release: input.content_release, months: input.pageview_months.join(","),
        limit: input.limit, minimum_active_months: input.minimum_active_months };
      const response = expectSuccess(await request(`/ecai/wikimedia/plan${queryString(params)}`));
      if (epoch !== state.wikiPlanEpoch || wikiInputIdentity() !== JSON.stringify(input)) return;
      const plan = response.plan;
      const spec = plan?.spec;
      if (spec?.schema !== "ecai-index-job/v1" || spec?.kind !== "wikimedia_visibility" ||
          spec.source?.project !== input.project || spec.source?.pageview_project !== input.pageview_project ||
          spec.source?.content_release !== input.content_release ||
          JSON.stringify(spec.source?.pageview_months) !== JSON.stringify(input.pageview_months) ||
          spec.options?.limit !== input.limit || plan.catalog?.cirrus_release !== input.content_release)
        throw new Error("The node returned a plan that does not match the chosen source settings.");
      state.wikiPlan = { inputKey: JSON.stringify(input), spec, summary: plan.catalog, key: newKey("ecai-wiki-plan"), queued: false };
      put("wikiPlanOutput", plan);
      put("wikiPlanStatus", "The server validated the selected release, month files and job specification.");
      $("wikiQueuePlanBtn").disabled = false;
      renderWikiPlanSummary();
    } catch (error) {
      if (epoch === state.wikiPlanEpoch) {
        put("wikiPlanOutput", `Plan failed: ${showError(error)}`);
        put("wikiPlanStatus", `Preview failed: ${showError(error)}`);
      }
    } finally {
      state.wikiPlanBusy = false;
      $("wikiPlanBtn").disabled = !state.wikiCatalog || !state.authenticated;
    }
  }
  async function queueWikiPlan() {
    const plan = state.wikiPlan;
    if (!plan || plan.queued || plan.inputKey !== wikiInputIdentity() || state.wikiQueueBusy) return;
    if (!state.authenticated) { openLogin("Sign in to queue this job."); return; }
    const project = plan.spec.source.project;
    const running = wikiPresetActive(project);
    if (!confirm(`Queue the validated ${project} job (${plan.spec.options.limit.toLocaleString()} records)?${running ? "\nA job for this project is already active and may use the same output index." : ""}`)) return;
    state.wikiQueueBusy = true;
    $("wikiQueuePlanBtn").disabled = true;
    put("wikiPlanStatus", "Submitting the validated plan to the durable queue…");
    try {
      const response = expectSuccess(await request("/ecai/index-jobs", {
        method: "POST", body: plan.spec, headers: { "Idempotency-Key": plan.key }
      }));
      plan.queued = true;
      renderWikiPlanSummary();
      put("wikiPlanStatus", `Queued ${project}: ${response.job?.id || "accepted"}. Change a selection and preview again for a new job.`);
      wikiQueueResult(project, true, "Validated plan queued", response.job?.id);
      toast("Wikimedia job accepted by the durable queue");
      await refreshJobs().catch(() => {});
    } catch (error) {
      $("wikiQueuePlanBtn").disabled = false;
      put("wikiPlanStatus", `Queue request failed: ${showError(error)}. Retry retains the same idempotency key.`);
    } finally { state.wikiQueueBusy = false; }
  }

  function refreshWikimedia() { return wikiRequest("doctor", {}, "wikiDoctorOutput"); }
  async function submitEkef(event) {
    event.preventDefault();
    if (!state.authenticated) { openLogin("Sign in before minting knowledge."); return; }
    if (!confirm("Minting knowledge may submit a blockchain transaction and incur fees. Continue?")) return;
    await task(async () => {
      const form = event.currentTarget;
      const payload = Object.fromEntries(new FormData(form).entries());
      const result = expectSuccess(await request("/ecai/ekef", { method: "POST", body: payload }));
      put("ekefOutput", result);
      toast("Knowledge mint operation returned successfully");
    }, "ekefOutput");
  }
  function fillPrivateExample() {
    const action = $("privateAction").value;
    const template = privateExamples[action];
    $("privatePayload").value = JSON.stringify(typeof template === "function" ? template() : template, null, 2);
  }
  async function submitPrivate(event) {
    event.preventDefault();
    if (!state.authenticated) { openLogin("Sign in to access a private corpus."); return; }
    const corpus = $("privateCorpus").value.trim();
    if (!/^[A-Za-z0-9_-]{1,80}$/.test(corpus)) { toast("Invalid corpus identifier", true); return; }
    await task(async () => {
      const action = $("privateAction").value;
      const payload = JSON.parse($("privatePayload").value);
      if (!payload || typeof payload !== "object" || Array.isArray(payload)) throw new Error("Private request must be a JSON object");
      // API explicitly rejects client-supplied owner, provider and key material.
      if (["owner", "principal", "key", "private_key", "provider", "path"].some((key) => Object.hasOwn(payload, key))) throw new Error("Remove identity, key and provider fields; the server supplies these");
      const response = expectSuccess(await request(`/ecai/private/${encodeURIComponent(corpus)}/${action}`, { method: "POST", body: payload }));
      put("privateOutput", response);
      toast("Private operation succeeded");
    }, "privateOutput");
  }

  async function refreshMarket() {
    if (!state.authenticated) return;
    const filter = $("marketStatus").value;
    const data = expectSuccess(await request(`/ecai/market/jobs${queryString({ status: filter })}`));
    state.marketJobs = Array.isArray(data.jobs) ? data.jobs : [];
    renderMarketJobs();
  }
  function renderMarketJobs() {
    const body = $("marketRows"); body.replaceChildren();
    if (!state.authenticated || !state.marketJobs.length) {
      const row = element("tr");
      const cell = element("td", "empty-cell", state.authenticated ? "No jobs match the selected status." : "Sign in to list marketplace jobs.");
      cell.colSpan = 5; row.append(cell); body.append(row); return;
    }
    for (const job of state.marketJobs) {
      const row = element("tr");
      const id = element("td");
      const b = element("button", "table-link", job.id ?? "—");
      b.addEventListener("click", () => task(() => selectMarketJob(job.id), "marketDetail"));
      id.append(b);
      row.append(id);
      const status = element("td"); status.append(element("span", `status-tag state-${job.status || job.state || ""}`, job.status || job.state || "unknown"));
      row.append(status, element("td", "mono small", job.owner_ak || job.owner || "—"), element("td", "", job.reward_damage ?? job.reward ?? "—"));
      const more = element("td");
      const detail = element("button", "text-button", "Inspect →");
      detail.addEventListener("click", () => task(() => selectMarketJob(job.id), "marketDetail"));
      more.append(detail); row.append(more); body.append(row);
    }
  }
  async function selectMarketJob(id) {
    if (!/^[0-9]+$/.test(String(id))) throw new Error("Marketplace IDs must be integers");
    const result = expectSuccess(await request(`/ecai/market/jobs/${encodeURIComponent(String(id))}`));
    state.selectedMarketId = String(id);
    put("marketSelection", `Job #${id}`);
    put("marketDetail", result.job);
    $("marketActionSubmit").disabled = false;
  }
  function updateMarketActionExample() { $("marketActionBody").value = JSON.stringify(marketExamples[$("marketAction").value], null, 2); }
  async function publishMarket(event) {
    event.preventDefault();
    if (!state.authenticated) { openLogin(); return; }
    await task(async () => {
      const form = event.currentTarget;
      const body = {
        owner_ak: form.elements.owner_ak.value.trim(), market_ct: form.elements.market_ct.value.trim(),
        paths: form.elements.paths.value.split("\n").map((x) => x.trim()).filter(Boolean),
        reward_damage: Number(form.elements.reward_damage.value), ttl_blocks: Number(form.elements.ttl_blocks.value)
      };
      if (!Number.isSafeInteger(body.reward_damage) || body.reward_damage <= 0 || !Number.isSafeInteger(body.ttl_blocks) || body.ttl_blocks <= 0)
        throw new Error("Reward and TTL must be positive integers");
      if (!confirm("Publish these chunk jobs to the configured marketplace?")) return;
      const data = expectSuccess(await request("/ecai/market/jobs/publish", { method: "POST", body }));
      toast(`${data.job_ids?.length ?? 0} marketplace job(s) published`);
      put("marketDetail", data);
      await refreshMarket();
    }, "marketDetail");
  }
  async function actionMarket(event) {
    event.preventDefault();
    if (!state.authenticated) { openLogin(); return; }
    if (!state.selectedMarketId) { toast("Select a marketplace job first", true); return; }
    await task(async () => {
      const action = $("marketAction").value;
      const body = JSON.parse($("marketActionBody").value);
      if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("A JSON object is required");
      if (action === "pay" && !confirm("This only marks the job paid in volatile local state; no on-chain payment occurs. Continue?")) return;
      const result = expectSuccess(await request(`/ecai/market/jobs/${encodeURIComponent(state.selectedMarketId)}/${action}`, { method: "POST", body }));
      put("marketDetail", result);
      toast(`Marketplace ${action} accepted`);
      await refreshMarket();
    }, "marketDetail");
  }
  async function yelpGet(path, target) {
    await task(async () => put(target, expectSuccess(await request(path, { ignoreAuth: true }))), target);
  }
  async function yelpPost(path, body, label) {
    if (!state.authenticated) { openLogin("Sign in before running operational actions."); return; }
    if (!confirm(label)) return;
    await task(async () => {
      const data = expectSuccess(await request(path, { method: "POST", body }));
      put("yelpActionOutput", data);
      toast("Yelp operation returned successfully");
      await yelpGet("/yelp/status", "yelpStatusOutput");
    }, "yelpActionOutput");
  }
  function socketLine(value) {
    const pre = $("wsOutput");
    pre.textContent = `${pre.textContent.slice(-18000)}\n${value}`.trim();
    pre.scrollTop = pre.scrollHeight;
  }
  function wsConnected(on) {
    $("wsConnect").disabled = on; $("wsPing").disabled = !on;
    $("wsPrice").disabled = !on; $("wsDisconnect").disabled = !on;
  }
  function connectSocket() {
    if (state.socket && state.socket.readyState <= WebSocket.OPEN) return;
    const scheme = location.protocol === "https:" ? "wss:" : "ws:";
    const socket = new WebSocket(`${scheme}//${location.host}/ecai/ws/`);
    state.socket = socket;
    socketLine("Connecting to /ecai/ws/ …");
    socket.onopen = () => { if (state.socket === socket) { wsConnected(true); socketLine("Connected"); } };
    socket.onmessage = (event) => { if (state.socket === socket) socketLine(String(event.data).slice(0, 10000)); };
    socket.onerror = () => { if (state.socket === socket) socketLine("Socket error"); };
    socket.onclose = () => { if (state.socket === socket) { state.socket = null; wsConnected(false); socketLine("Disconnected"); } };
  }
  function sendSocket(action) { if (state.socket?.readyState === WebSocket.OPEN) state.socket.send(JSON.stringify({ action })); }
  function disconnectSocket() { state.socket?.close(); state.socket = null; wsConnected(false); }

  function renderRoutes() {
    const filter = $("apiFilter").value.trim().toLowerCase();
    const list = $("apiRoutes"); list.replaceChildren();
    let lastGroup = ""; let shown = 0;
    routes.forEach((route, index) => {
      if (filter && !`${route.group} ${route.method} ${route.path} ${route.description}`.toLowerCase().includes(filter)) return;
      if (route.group !== lastGroup) {
        list.append(element("div", "api-route-group", route.group));
        lastGroup = route.group;
      }
      const button = element("button", `api-route${state.activeRoute === index ? " is-selected" : ""}`);
      button.type = "button";
      button.append(element("span", `http-method ${route.method.toLowerCase()}`, route.method), element("span", "api-route-path", route.path));
      button.addEventListener("click", () => selectRoute(index));
      list.append(button); shown++;
    });
    if (!shown) list.append(element("div", "empty-state", "No endpoints match your filter."));
  }
  function addParam(parent, key, description, initial) {
    const label = element("label");
    label.append(document.createTextNode(description));
    const input = element("input");
    input.required = true; input.dataset.param = key; input.value = initial || "";
    input.autocomplete = "off";
    label.append(input); parent.append(label);
  }
  function selectRoute(index) {
    if (!routes[index]) return;
    state.activeRoute = index;
    const route = routes[index];
    put("apiRequestTitle", route.path);
    put("apiRequestDescription", route.description);
    put("apiMethodTag", route.method);
    put("apiResponse", "No request sent.");
    put("apiResponseMeta", "Ready to send.");
    $("apiCopyResponse").disabled = true;
    $("apiRequestSubmit").disabled = false;
    $("apiRequestSubmit").textContent = route.method === "SSE" ? "Track job events ↗" : route.method === "WS" ? "Open socket ↗" : "Send request ↗";
    const pathWrapper = $("apiPathParams"); pathWrapper.replaceChildren();
    for (const key of route.params || []) {
      addParam(pathWrapper, key, `Path · ${key}`, key === "id" ? (route.group === "Marketplace" ? state.selectedMarketId : state.selectedIndexId) : "");
    }
    const queryWrapper = $("apiQueryParams"); queryWrapper.replaceChildren();
    for (const [key, value] of Object.entries(route.query || {})) {
      const label = element("label"); label.append(document.createTextNode(`Query · ${key}`));
      const input = element("input"); input.dataset.query = key; input.value = value; input.placeholder = `Optional ${key}`;
      label.append(input); queryWrapper.append(label);
    }
    const bodyWrapper = $("apiRequestBodyWrapper");
    bodyWrapper.hidden = route.method !== "POST";
    $("apiRequestBody").value = route.method === "POST" ? JSON.stringify(route.body ?? {}, null, 2) : "";
    if (route.key) {
      addParam(pathWrapper, "idempotency-key", "Header · Idempotency-Key", newKey("ecai-request"));
    }
    renderRoutes();
  }
  async function apiExplorerRequest(event) {
    event.preventDefault();
    const route = routes[state.activeRoute];
    if (!route) return;
    await task(async () => {
      let path = route.path;
      for (const input of $("apiPathParams").querySelectorAll("[data-param]")) {
        if (input.dataset.param === "idempotency-key") continue;
        if (!input.value.trim()) throw new Error(`Missing path parameter: ${input.dataset.param}`);
        path = path.replace(`:${input.dataset.param}`, encodeURIComponent(input.value.trim()));
      }
      if (route.method === "WS") { navigate("operations"); connectSocket(); return; }
      if (route.method === "SSE") {
        const id = $("apiPathParams").querySelector("[data-param='id']")?.value.trim();
        navigate("indexing"); await selectIndexJob(id); return;
      }
      const query = {};
      for (const input of $("apiQueryParams").querySelectorAll("[data-query]")) query[input.dataset.query] = input.value.trim();
      path += queryString(query);
      const options = { method: route.method };
      if (route.method === "POST") {
        options.body = JSON.parse($("apiRequestBody").value);
        if (!options.body || typeof options.body !== "object" || Array.isArray(options.body)) throw new Error("JSON request body must be an object");
        if (route.key) {
          const key = $("apiPathParams").querySelector("[data-param='idempotency-key']")?.value.trim();
          if (!key) throw new Error("Idempotency key is required");
          options.headers = { "Idempotency-Key": key };
        }
        if (!state.authenticated && !["/ecai/search", "/ecai/chat", "/ecai/auth/session"].includes(route.path)) { openLogin("Sign in to perform this action."); return; }
      }
      if (route.confirm && !confirm(route.confirm)) return;
      const start = performance.now();
      $("apiRequestSubmit").disabled = true;
      put("apiResponseMeta", "Sending request…");
      try {
        const result = expectSuccess(await request(path, options));
        state.lastApiResult = result;
        put("apiResponse", result);
        put("apiResponseMeta", `${route.method} ${path} · ${(performance.now() - start).toFixed(0)} ms · OK`);
        $("apiCopyResponse").disabled = false;
        if (route.key) $("apiPathParams").querySelector("[data-param='idempotency-key']").value = newKey("ecai-request");
      } finally { $("apiRequestSubmit").disabled = false; }
    }, "apiResponse");
  }
  function copyResponse() {
    if (state.lastApiResult === null) return;
    if (!navigator.clipboard?.writeText) { toast("Clipboard is not available in this browser", true); return; }
    navigator.clipboard.writeText(pretty(state.lastApiResult)).then(() => toast("Response copied"), () => toast("Unable to copy response", true));
  }
  // Server-derived session claims control *navigation only*. Privileged
  // requests remain checked independently by DamageBDD and ECAI on the server.
  function showCodeAdminNavigation() {
    $("codeAdminNav").hidden = !(state.authenticated && (state.nodeAdmin || state.codeAdmin));
  }
  function setCodeActionsEnabled(allowed) {
    for (const id of ["codeLearn", "codeScan", "codeIntegrate", "codeProposeSubmit"]) {
      $(id).disabled = !allowed;
    }
    codeReviewButtons();
  }
  function applyCodeSession(session) {
    state.nodeAdmin = session?.node_admin === true;
    state.codeFeatureConfigured = session?.code_admin_enabled === true;
    // A session capability hint cannot replace a successful privileged API
    // response. Probe the actual role gate before enabling mutation controls.
    state.codeAdmin = false;
    showCodeAdminNavigation();
    setCodeActionsEnabled(false);
    if (state.nodeAdmin && !state.codeFeatureConfigured) {
      put("codeAdminNotice", "DamageBDD node-admin identity confirmed. ECAI code administration is disabled; configure ecai.code_admin_enabled=true and restart the node.");
    }
  }
  function codeAdminDiagnostics(error) {
    if (error?.status === 404) return "Admin routes are not registered (HTTP 404). Set ecai.code_admin_enabled=true and restart ECAI to register the router and review queue worker.";
    if (error?.status === 402) return "The admin API returned an L402 access challenge. Check DamageBDD authentication and policy; no payment was attempted.";
    if (error?.status === 403) {
      const reason = error?.body?.error;
      if (reason === "admin_console_disabled") return "Code administration is disabled by configuration. Enable ecai.code_admin_enabled=true and restart ECAI.";
      if (reason === "admin_role_required") return "Access denied: the authenticated account must be in damage.node_admins (and in ecai.code_admin_accounts if that scope is nonempty).";
      return "Admin request forbidden (HTTP 403). Confirm the bearer session and node-admin configuration.";
    }
    if (error?.status === 401) return "Session expired. Sign in with your DamageBDD node-admin account again.";
    if (error?.status === 503) return "The ECAI admin service is unavailable (HTTP 503). Check the code security supervisor and review queue worker.";
    return `Unable to contact the code administration service: ${showError(error)}`;
  }
  // Privileged code administration. The server enforces the role, not this menu.
  async function probeCodeAccess() {
    if (!state.authenticated) return;
    const seq = state.adminProbeSequence;
    try {
      const info = expectSuccess(await request("/ecai/admin/code/status", { ignoreAuth: true }));
      if (!state.authenticated || seq !== state.adminProbeSequence) return;
      state.codeAdmin = true;
      state.codeQueue = info.status?.reviews || {};
      showCodeAdminNavigation();
      setCodeActionsEnabled(true);
      put("codeAdminNotice", "Node administrator access confirmed by the server.");
    } catch (error) {
      if (!state.authenticated || seq !== state.adminProbeSequence) return;
      state.codeAdmin = false;
      showCodeAdminNavigation();
      setCodeActionsEnabled(false);
      if (state.nodeAdmin) put("codeAdminNotice", codeAdminDiagnostics(error));
    }
  }
  // The repair endpoint deliberately omits source/diff contents; associate an
  // imported review only when the fingerprint, patch hash AND base commit agree.
  function reviewForRepair(repair) {
    if (!repair?.fingerprint || !repair?.patch_sha256 || !repair?.base_commit) return null;
    return state.codeReviews.find((review) => review.fingerprint === repair.fingerprint &&
      review.patch_sha256 === repair.patch_sha256 && review.base_commit === repair.base_commit) || null;
  }
  function reviewIsValidated(review) { return String(review?.verification?.status || "").toLowerCase() === "validated"; }
  function filterMatches(text, term) { return !term || String(text || "").toLowerCase().includes(term); }
  function renderCodeRepairs() {
    const list = $("codeRepairRows"); list.replaceChildren();
    const term = $("codeRepairSearch").value.trim().toLowerCase();
    const validation = $("codeRepairValidation").value;
    const app = $("codeRepairApp").value;
    const reviewedOnly = $("codeRepairWithDiff").checked;
    const repairs = state.codeRepairs.filter((repair) => {
      const status = String(repair.status || "").toLowerCase();
      const matchValidation = !validation || (validation === "validated" && status === "validated") ||
        (validation === "failed" && ["failed", "error", "rejected", "blocked"].includes(status)) ||
        (validation === "other" && !["validated", "failed", "error", "rejected", "blocked"].includes(status));
      return matchValidation && (!app || repair.application === app) &&
        (!reviewedOnly || Boolean(reviewForRepair(repair))) &&
        filterMatches([repair.application, repair.module, repair.fingerprint, repair.summary,
          repair.security_property, repair.patch_sha256, repair.failure_class, repair.stage].join(" "), term);
    });
    put("codeRepairVisibleCount", `${repairs.length} of ${state.codeRepairs.length} repair attempts shown${validation === "validated" ? " · verifier-validated" : ""}`);
    if (!repairs.length) {
      list.append(element("div", "empty-state", state.codeRepairs.length ? "No repairs match these filters." : "No repair attempts recorded."));
      return;
    }
    for (const repair of repairs.slice(0, 200)) {
      const row = element("article", "code-repair-row");
      const details = element("div", "code-repair-row-main");
      details.append(element("strong", "", `${repair.application || "?"} / ${repair.module || "?"}`));
      if (repair.summary) details.append(element("div", "small muted code-row-summary", repair.summary));
      details.append(element("div", "small muted mono code-row-hash", `${String(repair.fingerprint || "—").slice(0, 22)}…`));
      const badge = element("span", `status-tag state-${repair.status || "pending"}`, repair.status || "unknown");
      const updated = element("span", "small muted", repair.updated_at || repair.created_at || "—");
      const action = element("div", "code-repair-row-actions");
      const matching = reviewForRepair(repair);
      if (matching) {
        const view = element("button", "button button-outline button-sm", "View diff ↗");
        view.type = "button";
        view.addEventListener("click", () => openCodeReviewFromRepair(matching.id));
        action.append(view);
      } else {
        action.append(element("span", "small muted", repair.status === "validated" ? "Diff not in current review list" : "Not reviewable"));
      }
      row.append(details, badge, updated, action);
      list.append(row);
    }
  }
  function filteredCodeReviews() {
    const term = $("codeReviewSearch").value.trim().toLowerCase();
    const status = $("codeReviewStatus").value;
    const app = $("codeReviewApp").value;
    const verification = $("codeReviewValidation").value;
    return state.codeReviews.filter((review) =>
      (!status || review.status === status) && (!app || review.application === app) &&
      (!verification || (verification === "validated" ? reviewIsValidated(review) : !reviewIsValidated(review))) &&
      filterMatches([review.id, review.application, review.module, review.summary, review.security_property,
        review.fingerprint, review.patch_sha256, review.base_commit, review.source_path].join(" "), term));
  }
  function parkCodeWorkspace() {
    const workspace = $("codeReviewWorkspace");
    $("codeReviewWorkspaceParking").append(workspace);
    workspace.hidden = true;
  }
  function clearCodeReviewFocus() {
    state.codeReviewOpenId = "";
    state.codeReviewLoadSerial++;
    state.codeReview = null;
    $("codePublishPhrase").value = "";
    parkCodeWorkspace();
    codeReviewButtons();
  }
  function renderCodeReviews() {
    const host = $("codeReviewRows");
    // The single live review form must survive list refreshes without cloning.
    parkCodeWorkspace();
    host.replaceChildren();
    const reviews = filteredCodeReviews();
    put("codeReviewVisibleCount", `${reviews.length} of ${state.codeReviews.length} patches shown · diff loaded on expansion`);
    if (!reviews.length) {
      host.append(element("div", "empty-state", state.codeReviews.length ? "No patches match these filters." : "No verifier-validated patches have entered the review queue."));
      clearCodeReviewFocus();
      return;
    }
    const openId = state.codeReviewOpenId;
    let openCard = null;
    for (const review of reviews) {
      const id = String(review.id || "");
      const card = element("details", "code-review-card");
      card.dataset.reviewId = id;
      const summary = element("summary", "code-review-summary");
      const title = element("div", "code-review-title");
      title.append(element("strong", "", `${review.application || "?"} / ${review.module || "?"}`));
      title.append(element("span", "small mono muted code-row-hash", id.slice(0, 16) + "…"));
      if (review.summary) title.append(element("p", "code-row-summary", review.summary));
      const status = element("span", `status-tag state-${review.status || "pending"}`, review.status || "unknown");
      const validation = element("span", `code-validation-label${reviewIsValidated(review) ? " verified" : ""}`,
        reviewIsValidated(review) ? "✓ Verified" : "Verification: " + (review.verification?.status || "unknown"));
      const approvals = element("span", "small muted code-review-approval-count", `${review.approvals?.length || 0} / ${state.codeQueue.required_approvals || 1} approvals`);
      const when = element("span", "small muted code-review-time", review.created_at || "—");
      const chevron = element("span", "code-review-chevron"); chevron.setAttribute("aria-hidden", "true"); chevron.textContent = "⌄";
      summary.append(title, status, validation, approvals, when, chevron);
      const content = element("div", "code-review-content");
      const hint = element("p", "context-hint", `Pinned patch · ${String(review.patch_sha256 || "").slice(0, 20)}… · base ${String(review.base_commit || "").slice(0, 12)}…`);
      content.append(hint);
      card.append(summary, content);
      card.addEventListener("toggle", () => {
        if (card.open) void openCodeReviewCard(card, review);
        else if (state.codeReviewOpenId === id) clearCodeReviewFocus();
      });
      host.append(card);
      if (id === openId) openCard = card;
    }
    if (openId && openCard) openCard.open = true;
    else if (openId) clearCodeReviewFocus();
  }
  async function openCodeReviewCard(card, summary) {
    if (!card.open) return;
    const id = String(summary.id);
    // Only one patch can be under review at once.
    state.codeReviewOpenId = id;
    for (const other of $("codeReviewRows").querySelectorAll("details.code-review-card[open]")) {
      if (other !== card) other.open = false;
    }
    const workspace = $("codeReviewWorkspace");
    card.querySelector(".code-review-content").append(workspace);
    workspace.hidden = false;
    if (state.codeReview?.id === id && state.codeReview.revision === summary.revision && state.codeReview.patch) {
      codeReviewButtons();
      return;
    }
    state.codeReview = null;
    $("codePublishPhrase").value = "";
    put("codeReviewDetail", "Loading immutable verification record…");
    put("codeReviewDiff", "Loading diff…");
    put("codeActionStatus", `Loading patch ${id.slice(0, 16)}…`);
    codeReviewButtons();
    await task(() => selectCodeReview(id), "codeActionStatus");
  }
  function openCodeReviewFromRepair(id) {
    if (!state.codeReviews.some((review) => review.id === id)) { toast("Matching reviewed patch is no longer in the current queue", true); return; }
    if (state.codeReviewOpenId && state.codeReviewOpenId !== id) clearCodeReviewFocus();
    $("codeReviewSearch").value = "";
    $("codeReviewStatus").value = "";
    $("codeReviewApp").value = "";
    $("codeReviewValidation").value = "";
    renderCodeReviews();
    const card = Array.from($("codeReviewRows").querySelectorAll("details.code-review-card"))
      .find((entry) => entry.dataset.reviewId === id);
    if (card) {
      card.open = true;
      card.querySelector("summary")?.focus({ preventScroll: true });
      card.scrollIntoView({ behavior: "smooth", block: "start" });
    }
  }
  function splitCodePatch(patch) {
    const chunks = [];
    const lines = String(patch || "").split("\n");
    let current = null;
    for (const line of lines) {
      if (line.startsWith("diff --git ")) {
        if (current) chunks.push(current);
        const found = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
        current = { path: found ? found[2] : `Patch file ${chunks.length + 1}`, lines: [] };
      }
      if (!current) current = { path: "Patch", lines: [] };
      current.lines.push(line);
    }
    if (current) chunks.push(current);
    return chunks;
  }
  function diffChanges(files) {
    let adds = 0, removes = 0;
    for (const file of files) for (const line of file.lines) {
      if (line.startsWith("+") && !line.startsWith("+++")) adds++;
      else if (line.startsWith("-") && !line.startsWith("---")) removes++;
    }
    return { adds, removes };
  }
  function renderCodeDiff() {
    const list = $("codeDiffFileList"); list.replaceChildren();
    const host = $("codeReviewDiff"); host.replaceChildren();
    const files = state.codeDiffFiles;
    if (!files.length) { host.textContent = "No patch content available."; return; }
    const overall = diffChanges(files);
    put("codeDiffSummary", `${files.length} changed file${files.length === 1 ? "" : "s"} · +${overall.adds} / −${overall.removes} lines`);
    const activeIndex = state.codeDiffSelectedFile;
    for (const [value, label] of [["all", "All changes"], ...files.map((f, i) => [String(i), f.path])]) {
      const btn = element("button", `code-file-button${activeIndex === value ? " is-active" : ""}`, label);
      btn.type = "button"; btn.setAttribute("aria-pressed", String(activeIndex === value));
      btn.addEventListener("click", () => { state.codeDiffSelectedFile = value; renderCodeDiff(); });
      list.append(btn);
    }
    const selected = activeIndex === "all" ? files : [files[Number(activeIndex)] || files[0]];
    let rendered = 0; const MAX_LINES = 4500;
    for (const file of selected) {
      const heading = element("div", "code-diff-file-heading", file.path);
      host.append(heading);
      for (const line of file.lines) {
        if (rendered++ >= MAX_LINES) break;
        let cls = "code-diff-line";
        if (line.startsWith("@@")) cls += " is-hunk";
        else if (line.startsWith("+") && !line.startsWith("+++")) cls += " is-addition";
        else if (line.startsWith("-") && !line.startsWith("---")) cls += " is-removal";
        else if (/^(diff --git|index |--- |\+\+\+ |new file|deleted file|rename |similarity )/.test(line)) cls += " is-meta";
        host.append(element("div", cls, line || " "));
      }
      if (rendered >= MAX_LINES) break;
    }
    if (rendered >= MAX_LINES) host.append(element("p", "context-hint", "Display limited to 4,500 lines; Copy full diff preserves every line."));
  }
  function renderCodeVerification(review) {
    const host = $("codeReviewVerification"); host.replaceChildren();
    const verification = review.verification || {};
    const top = element("div", "code-verification-hero");
    top.append(element("span", `code-validation-label${reviewIsValidated(review) ? " verified" : ""}`, reviewIsValidated(review) ? "✓ Verifier validated" : `Verifier: ${verification.status || "unknown"}`));
    top.append(element("span", "small muted", `${review.approvals?.length || 0} of ${state.codeQueue.required_approvals || 1} approvals`));
    host.append(top);
    const facts = element("div", "code-verification-facts");
    for (const [label, value] of [["Patch SHA-256", review.patch_sha256], ["Base commit", review.base_commit],
      ["Finding fingerprint", review.fingerprint], ["Security property", review.security_property || "—"]]) {
      const item = element("div", "code-verification-fact");
      item.append(element("span", "", label), element("strong", "", value || "—"));
      facts.append(item);
    }
    host.append(facts);
    const steps = Array.isArray(verification.steps) ? verification.steps : [];
    if (steps.length) {
      const stepList = element("div", "code-verification-steps");
      for (const step of steps) {
        const value = step.ok === true ? "Passed" : step.ok === false ? "Failed" : "Recorded";
        const cell = element("span", `code-verification-step${step.ok === true ? " passed" : ""}`,
          `${step.step || "Verifier step"}: ${value}`);
        stepList.append(cell);
      }
      host.append(stepList);
    }
  }
  function codeObject(value) {
    return value && typeof value === "object" && !Array.isArray(value) ? value : {};
  }
  function codeCount(value, fallback = null) {
    return typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fallback;
  }
  function codeValue(value, fallback = "—") {
    if (value === undefined || value === null || value === "undefined" || value === "") return fallback;
    if (typeof value === "object") return pretty(value).slice(0, 180);
    return String(value);
  }
  function codeTime(value) {
    const n = typeof value === "number" ? value : Date.parse(String(value || ""));
    return Number.isFinite(n) ? formatWhen(n) : "—";
  }
  function codeProgress(value) {
    if (!Number.isFinite(value)) return null;
    return Math.max(0, Math.min(100, value));
  }
  function codeMetric(label, value, caption, mood = "") {
    const card = element("div", `code-metric${mood ? ` has-${mood}` : ""}`);
    card.append(element("span", "code-metric-label", label), element("strong", "code-metric-value", value), element("div", "code-metric-caption", caption));
    return card;
  }
  function codeService(title, status, tone, description, facts, progress = null) {
    const card = element("section", "code-service");
    const head = element("div", "code-service-head");
    head.append(element("h4", "", title), element("span", `code-service-state ${tone}`, status));
    card.append(head, element("p", "code-service-description", description));
    if (Number.isFinite(progress)) {
      const meter = element("div", "code-mini-progress");
      meter.setAttribute("role", "progressbar");
      meter.setAttribute("aria-label", `${title} completion`);
      meter.setAttribute("aria-valuemin", "0");
      meter.setAttribute("aria-valuemax", "100");
      meter.setAttribute("aria-valuenow", String(Math.round(progress)));
      const fill = element("span");
      fill.style.width = `${progress}%`;
      meter.append(fill); card.append(meter);
    }
    const group = element("div", "code-service-facts");
    for (const [key, value] of facts) {
      const row = element("div", "code-service-fact");
      row.append(element("span", "", key), element("strong", "", codeValue(value)));
      group.append(row);
    }
    card.append(group);
    return card;
  }
  function renderCodeOperations(learningInput, queueInput) {
    const learning = codeObject(learningInput);
    const learner = codeObject(learning.learner);
    const patchManager = codeObject(learning.patch_manager);
    const integration = codeObject(learning.integration);
    const health = codeObject(learning.health_monitor);
    const queue = codeObject(queueInput);
    const counts = codeObject(queue.counts);
    const integrationCounts = codeObject(integration.job_counts);
    const complete = codeCount(learner.completed);
    const total = codeCount(learner.total);
    const pct = codeProgress(codeCount(learner.progress_percent));
    const active = codeCount(patchManager.active);
    const pending = codeCount(patchManager.pending);
    const reviewsPending = codeCount(counts.pending, 0);
    const reviewsApproved = codeCount(counts.approved, 0);
    const reviewsPublished = codeCount(counts.published, 0);
    const broken = codeCount(integrationCounts.broken);
    const metrics = $("codeMetrics"); metrics.replaceChildren();
    [
      ["Learning cycle", total !== null && complete !== null ? `${formatNumber(complete)} / ${formatNumber(total)}` : "—", `${codeValue(learner.phase, "Unknown phase")} · cycle ${codeValue(learner.cycle)}`],
      ["Active repair workers", active === null ? "—" : formatNumber(active), `Concurrency ${codeValue(patchManager.max_concurrent)}`],
      ["Repair backlog", pending === null ? "—" : formatNumber(pending), `${codeValue(patchManager.queued_live, "0")} queued · ${codeValue(patchManager.retry_wait, "0")} retry wait`, pending > 0 ? "attention" : ""],
      ["Awaiting review", formatNumber(reviewsPending), `Verifier-validated patches pending approval`, reviewsPending > 0 ? "attention" : ""],
      ["Approved patches", formatNumber(reviewsApproved), `Awaiting independent publication`],
      ["Published reviews", formatNumber(reviewsPublished), `Review branches published to origin`, reviewsPublished > 0 ? "success" : ""]
    ].forEach(([label, val, caption, tone]) => metrics.append(codeMetric(label, val, caption, tone)));
    const services = $("codeServiceCards"); services.replaceChildren();
    const learnerUnavailable = !Object.keys(learner).length;
    const learnerPhase = codeValue(learner.phase, "Unavailable");
    const managerError = codeValue(patchManager.last_error, "");
    const managerUnavailable = !Object.keys(patchManager).length;
    const learnerError = codeValue(learner.last_error, "");
    const integrationError = codeValue(integration.last_error, "");
    services.append(codeService("Code learner", learnerUnavailable ? "Unavailable" : titleCase(learnerPhase),
      learnerUnavailable || learnerError ? "warn" : "ok",
      learnerUnavailable ? "The learning worker did not return usable status." : "Current cycle and durable learning progress.",
      [["Completed", complete !== null ? formatNumber(complete) : "—"],
       ["In flight", codeValue(learner.inflight_count)],
       ["Queued", codeValue(learner.queued)],
       ["Last cycle completed", codeTime(learner.last_completed_at)],
       ...(learnerError ? [["Last error", learnerError]] : [])], pct));
    services.append(codeService("Repair manager", managerUnavailable ? "Unavailable" : managerError ? "Attention" : active > 0 ? "Working" : "Standing by",
      managerUnavailable || managerError ? "warn" : "ok",
      managerUnavailable ? "Repair manager status is unavailable." : "Current worker usage and persisted repair backlog (not cumulative totals).",
      [["Active", codeValue(active)],
       ["Queued / retry wait", `${codeValue(patchManager.queued_live, "0")} / ${codeValue(patchManager.retry_wait, "0")}`],
       ["Stale running", codeValue(patchManager.stale_running)],
       ["Last scan", codeTime(patchManager.last_run_at)],
       ...(managerError ? [["Last error", managerError]] : [])]));
    services.append(codeService("Integration & review", broken > 0 ? "Needs attention" : "Tracked", broken > 0 || integrationError ? "warn" : "ok",
      "Verifier integration outcomes and immutable review-queue publication state.",
      [["Clean / broken", `${codeValue(integrationCounts.clean, "0")} / ${codeValue(broken, "0")}`],
       ["Review approvals required", codeValue(queue.required_approvals)],
       ["Publishing", queue.publishing && queue.publishing !== "null" ? "In progress" : "Idle"],
       ["Origin push", queue.publish_enabled ? "Enabled" : "Disabled"],
       ...(integrationError ? [["Last error", integrationError]] : [])]));
    put("codeStatusUpdated", `Telemetry checked ${new Date().toLocaleTimeString()}`);
  }
  const CODE_PUBLISH_BLOCKERS = {
    push_disabled: "Publishing is disabled in ECAI configuration (code_review_push_enabled).",
    review_not_approved: "The review is not yet approved for publication.",
    already_published: "This immutable review has already been published; open the existing origin review branch.",
    review_rejected: "This review was rejected and cannot be published.",
    approvals_missing: "Additional independent review approval is required.",
    publisher_is_reviewer: "This account approved the patch. Sign in as a different authorized node admin to publish it.",
    invalid_publisher_identity: "The authenticated publisher identity is invalid.",
    repair_superseded: "The underlying validated repair has changed; generate and approve a new pinned review.",
    repair_not_available: "The associated durable repair record is missing.",
    publication_in_progress: "Another Git publication is currently running.",
    stale_review_revision: "The review changed since it was loaded. Reload and inspect the latest revision.",
    patch_hash_mismatch: "The submitted patch SHA no longer matches the immutable review.",
    stale_base_commit: "The repository HEAD differs from the approved base commit. Rebase and re-verify the patch.",
    origin_remote_unavailable: "The origin push remote is not configured or accessible.",
    reconcile_required: "The previous push outcome is uncertain; an administrator must reconcile the remote branch first."
  };
  function renderCodePublishGate(review, hasBearer) {
    const box = $("codePublishGate"); box.replaceChildren();
    box.className = "code-publish-gate";
    if (!review) { box.textContent = "Open a reviewed patch to inspect publication eligibility."; return false; }
    const gate = codeObject(review.publication_gate);
    const reasons = Array.isArray(gate.blockers) ? [...gate.blockers] : ["server_gate_unavailable"];
    if (!hasBearer) reasons.unshift("bearer_required");
    if (state.codeQueue.publishing && state.codeQueue.publishing !== "null" && state.codeQueue.publishing !== review.id) reasons.push("publication_in_progress");
    const allowed = gate.eligible === true && reasons.length === 0 && state.codeAdmin;
    box.classList.add(allowed ? "is-ready" : "is-blocked");
    box.append(element("strong", "code-publish-gate-title", allowed ? "Eligible for independent publication" : "Publication currently blocked"));
    if (allowed) {
      box.append(element("p", "", "Review and account permissions satisfy the server gate. Remote branch, Git HEAD, and fresh verification are checked again at publish time."));
    } else {
      const ul = element("ul");
      for (const reason of [...new Set(reasons)]) {
        const text = reason === "bearer_required" ? "A DamageBDD bearer-token sign-in is required for publication." :
          reason === "server_gate_unavailable" ? "This ECAI backend does not expose publisher eligibility. Deploy the gate-diagnostics update and restart ECAI." :
          CODE_PUBLISH_BLOCKERS[reason] || `Publication check failed: ${titleCase(reason)}`;
        ul.append(element("li", "", text));
      }
      box.append(ul);
    }
    if (review.status === "publish_failed" && review.last_error && review.last_error !== "undefined") {
      box.append(element("p", "", `Previous publication failure: ${codeValue(review.last_error).slice(0, 350)}`));
    }
    return allowed;
  }
  function codeReviewButtons() {
    const review = state.codeReview;
    const valid = Boolean(state.codeAdmin && review && state.codeReviewOpenId === review.id);
    const token = currentToken();
    const bearer = typeof token === "string" && token.trim().length > 0;
    const status = review?.status;
    $("codeApprove").disabled = !valid || !bearer || status !== "pending";
    $("codeReject").disabled = !valid || !bearer || !["pending", "approved", "publish_failed"].includes(status);
    const publishEligible = renderCodePublishGate(valid ? review : null, bearer);
    $("codePublish").disabled = !valid || !publishEligible ||
      !["approved", "publish_failed"].includes(status) || $("codePublishPhrase").value.trim() !== "push to origin";
    $("codeReloadReview").disabled = !valid;
    $("codeCopyDiff").disabled = !valid || !review.patch;
    $("codeBearerNotice").hidden = !valid || bearer;
  }
  async function selectCodeReview(id) {
    const seq = ++state.codeReviewLoadSerial;
    const result = expectSuccess(await request(`/ecai/admin/code/reviews/${encodeURIComponent(id)}`));
    const review = result.review;
    if (!review || review.id !== id) throw new Error("Review identity mismatch");
    // Responses may arrive after a different patch was opened or this card closed.
    if (seq !== state.codeReviewLoadSerial || state.codeReviewOpenId !== id) return;
    const previous = state.codeReview;
    state.codeReview = review;
    const { patch, events, ...safeDetails } = review;
    put("codeReviewDetail", safeDetails);
    state.codeDiffFiles = splitCodePatch(patch);
    if (previous?.id !== id) state.codeDiffSelectedFile = "0";
    renderCodeDiff();
    renderCodeVerification(review);
    put("codeReviewAudit", Array.isArray(events) ? events : []);
    if (previous?.id !== id) { $("codePublishPhrase").value = ""; $("codeReviewNote").value = ""; }
    put("codeActionStatus", `Reviewed diff ${id.slice(0, 16)} · ${review.status}. Check SHA-256, base commit and verifier evidence before approving.`);
    codeReviewButtons();
  }
  async function refreshCode() {
    if (!state.authenticated) { openLogin("Sign in with a node administrator account."); return; }
    try {
      const status = expectSuccess(await request("/ecai/admin/code/status"));
      state.codeAdmin = true;
      showCodeAdminNavigation();
      setCodeActionsEnabled(true);
      state.codeQueue = status.status?.reviews || {};
      const learning = status.status?.learning || {};
      put("codeLearningStatus", { learner: learning.learner, store: learning.store,
        health_monitor: learning.health_monitor, log_learning: learning.log_learning });
      put("codeRepairStatus", { patch_manager: learning.patch_manager, integration: learning.integration,
        review_queue: state.codeQueue });
      renderCodeOperations(learning, state.codeQueue);
      state.codeStatusLastPoll = Date.now();
      const [repairs, reviews] = await Promise.all([
        request("/ecai/admin/code/repairs"), request("/ecai/admin/code/reviews")
      ]);
      state.codeRepairs = Array.isArray(repairs.repairs) ? repairs.repairs : [];
      state.codeReviews = Array.isArray(reviews.reviews) ? reviews.reviews : [];
      state.codeQueue = reviews.queue || state.codeQueue;
      renderCodeOperations(learning, state.codeQueue);
      put("codeRepairCount", `${repairs.total ?? state.codeRepairs.length} repair records (showing latest ${state.codeRepairs.length})`);
      put("codeReviewCounts", Object.entries(state.codeQueue.counts || {}).map(([k,v]) => `${k}: ${v}`).join(" · ") || "Queue empty");
      put("codeAdminNotice", `Admin access granted · ${state.codeQueue.required_approvals || 1} approval(s) required · publishing ${state.codeQueue.publish_enabled ? "configured" : "disabled"}`);
      renderCodeRepairs(); renderCodeReviews();
      codeReviewButtons();
    } catch (error) {
      state.codeAdmin = false;
      clearCodeReviewFocus();
      state.codeRepairs = []; state.codeReviews = [];
      showCodeAdminNavigation();
      setCodeActionsEnabled(false);
      renderCodeRepairs(); renderCodeReviews();
      put("codeAdminNotice", codeAdminDiagnostics(error));
      put("codeRepairStatus", `Admin API unavailable: ${showError(error)}`);
      $("codeMetrics").replaceChildren(element("div", "empty-state", codeAdminDiagnostics(error)));
      $("codeServiceCards").replaceChildren();
      put("codeStatusUpdated", "Telemetry unavailable");
    }
  }
  async function refreshCodeStatusOnly() {
    if (!state.codeAdmin || document.hidden || state.view !== "code") return;
    const status = expectSuccess(await request("/ecai/admin/code/status"));
    const learning = status.status?.learning || {};
    state.codeQueue = status.status?.reviews || state.codeQueue;
    put("codeLearningStatus", { learner: learning.learner, store: learning.store,
      health_monitor: learning.health_monitor, log_learning: learning.log_learning });
    put("codeRepairStatus", { patch_manager: learning.patch_manager, integration: learning.integration,
      review_queue: state.codeQueue });
    renderCodeOperations(learning, state.codeQueue);
    state.codeStatusLastPoll = Date.now();
    codeReviewButtons();
  }
  async function codeWorkerAction(action, label) {
    if (!state.codeAdmin) { put("codeActionStatus", "Code admin operations are not enabled for this session."); return; }
    if (!confirm(`${label}? This operation is executed by the ECAI node.`)) return;
    await task(async () => {
      const result = expectSuccess(await request(`/ecai/admin/code/${action}`, { method: "POST", body: {} }));
      toast(result.message || `Requested ${action}`);
      await refreshCode();
    }, "codeActionStatus");
  }
  async function codePropose(event) {
    event.preventDefault();
    if (!state.codeAdmin) { put("codeActionStatus", "Code admin operations are not enabled for this session."); return; }
    const application = $("codeProposeApp").value;
    const module = $("codeProposeModule").value.trim();
    const fingerprint = $("codeProposeFingerprint").value.trim();
    if (!module || !fingerprint) return;
    if (!confirm(`Propose a repair for ${application}:${module} and finding ${fingerprint.slice(0, 20)}…?`)) return;
    await task(async () => {
      const result = expectSuccess(await request("/ecai/admin/code/propose", { method: "POST",
        body: { application, module, fingerprint } }));
      toast(result.message || "Repair proposal worker accepted");
      await refreshCode();
    }, "codeActionStatus");
  }
  async function codeReviewDecision(action) {
    const review = state.codeReview;
    if (!review) return;
    const note = $("codeReviewNote").value.trim();
    if (note.length < 8 || note.length > 2048) { put("codeActionStatus", "Supply review findings of at least 8 characters."); return; }
    if (!confirm(`${action === "approve" ? "Approve" : "Reject"} the SHA-256 pinned patch ${review.patch_sha256.slice(0, 16)}…?`)) return;
    await task(async () => {
      expectSuccess(await request(`/ecai/admin/code/reviews/${encodeURIComponent(review.id)}/${action}`, {
        method: "POST", body: { patch_sha256: review.patch_sha256, note }
      }));
      $("codeReviewNote").value = "";
      toast(`Patch ${action === "approve" ? "review recorded" : "rejected"}`);
      await refreshCode();
      if (state.codeReviewOpenId === review.id) await selectCodeReview(review.id);
    }, "codeActionStatus");
  }
  async function codePublish() {
    const review = state.codeReview;
    if (!review || $("codePublishPhrase").value.trim() !== "push to origin") return;
    if (!renderCodePublishGate(review, !!currentToken())) return;
    if (!confirm(`Publish reviewed patch ${review.patch_sha256.slice(0, 16)}… to origin/ecai/reviews/${review.id}? This creates a remote Git branch, not a merge to main.`)) return;
    await task(async () => {
      try {
        expectSuccess(await request(`/ecai/admin/code/reviews/${encodeURIComponent(review.id)}/publish`, {
          method: "POST", body: { patch_sha256: review.patch_sha256, revision: review.revision, confirm: "push to origin" }
        }));
      } catch (error) {
        if (error.status === 409) {
          await selectCodeReview(review.id);
          const reason = error.body?.error;
          throw new Error(CODE_PUBLISH_BLOCKERS[reason] || `Publication rejected: ${codeValue(reason, "review state changed")}. Reload the review and check the publish gate.`);
        }
        throw error;
      }
      toast("Publication queued; re-verification and push are running.");
      await refreshCode();
      if (state.codeReviewOpenId === review.id) await selectCodeReview(review.id);
    }, "codeActionStatus");
  }
  function copyCodeDiff() {
    if (!state.codeReview?.patch) return;
    if (!navigator.clipboard?.writeText) { toast("Clipboard is unavailable", true); return; }
    navigator.clipboard.writeText(state.codeReview.patch).then(() => toast("Diff copied"), () => toast("Unable to copy diff", true));
  }

  async function refreshView() {
    switch (state.view) {
      case "overview": await refreshOverview(); break;
      case "indexing": await refreshIndexing(); break;
      case "wikimedia": await refreshWikiProjects(); break;
      case "code": await refreshCode(); break;
      case "marketplace": await refreshMarket(); break;
      case "operations": await yelpGet("/yelp/status", "yelpStatusOutput"); break;
      case "api": renderRoutes(); break;
      default: break; // Search and private operations only execute on user request.
    }
  }
  function bindEvents() {
    $("consoleNav").addEventListener("click", (event) => {
      const link = event.target.closest("[data-view]"); if (link) navigate(link.dataset.view);
    });
    for (const button of document.querySelectorAll("[data-go]")) button.addEventListener("click", () => navigate(button.dataset.go));
    $("openNav").addEventListener("click", () => { $("consoleSidebar").classList.add("is-open"); $("mobileScrim").hidden = false; });
    $("closeNav").addEventListener("click", closeNav);
    $("mobileScrim").addEventListener("click", closeNav);
    $("refreshView").addEventListener("click", () => task(refreshView));
    $("refreshHealth").addEventListener("click", () => task(refreshOverview));
    $("loginBtn").addEventListener("click", () => openLogin());
    $("logoutBtn").addEventListener("click", () => task(logout));
    $("consoleLoginForm").addEventListener("submit", login);
    $("consoleLoginClose").addEventListener("click", closeLogin);
    $("consoleLoginDialog").addEventListener("click", (event) => { if (event.target === $("consoleLoginDialog")) closeLogin(); });
    $("searchForm").addEventListener("submit", search);
    $("chatForm").addEventListener("submit", sendChat);
    $("chatPrompt").addEventListener("keydown", (event) => {
      if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); $("chatForm").requestSubmit(); }
    });
    $("newChatBtn").addEventListener("click", resetChat);
    $("refreshJobs").addEventListener("click", () => task(refreshIndexing));
    $("indexState").addEventListener("change", () => task(refreshJobs));
    $("reloadPresets").addEventListener("click", () => task(refreshIndexing));
    $("customJobForm").addEventListener("submit", customJob);
    $("newIdempotency").addEventListener("click", () => { $("indexIdempotency").value = newKey("ecai-job"); });
    $("wikiReloadProjects").addEventListener("click", () => task(() => refreshWikiProjects(true)));
    $("wikiPresetSearch").addEventListener("input", renderWikiProjects);
    $("wikiSelectAll").addEventListener("click", () => {
      const filter = $("wikiPresetSearch").value.trim().toLowerCase();
      for (const preset of state.presets) {
        if (`${preset.label || ""} ${preset.description || ""} ${preset.id || ""} ${wikiPresetProject(preset)}`.toLowerCase().includes(filter))
          state.wikiSelectedPresets.add(String(preset.id));
      }
      renderWikiProjects();
    });
    $("wikiClearSelected").addEventListener("click", () => { state.wikiSelectedPresets.clear(); renderWikiProjects(); });
    $("wikiQueueSelected").addEventListener("click", () => task(queueSelectedWikiPresets));
    $("wikiProject").addEventListener("change", () => {
      $("wikiPageviewProject").value = inferredPageviewProject($("wikiProject").value);
      resetWikiCatalog();
    });
    $("wikiPageviewProject").addEventListener("input", resetWikiCatalog);
    $("wikiSourcesBtn").addEventListener("click", () => task(discoverWikiSources));
    $("wikiRelease").addEventListener("change", () => invalidateWikiPlan());
    $("wikiRecentSix").addEventListener("click", () => pickWikiMonths(6));
    $("wikiRecentAll").addEventListener("click", () => pickWikiMonths("all"));
    $("wikiPlanLimit").addEventListener("input", () => invalidateWikiPlan());
    $("wikiPlanBtn").addEventListener("click", () => task(previewWikiPlan));
    $("wikiQueuePlanBtn").addEventListener("click", () => task(queueWikiPlan));
    $("wikiDoctorBtn").addEventListener("click", () => refreshWikimedia());
    $("wikiSearchForm").addEventListener("submit", (event) => {
      event.preventDefault();
      return wikiRequest("search", { q: $("wikiSearchQuery").value.trim(), limit: $("wikiSearchLimit").value.trim() }, "wikiSearchOutput");
    });
    $("ekefForm").addEventListener("submit", submitEkef);
    $("privateForm").addEventListener("submit", submitPrivate);
    $("privateAction").addEventListener("change", fillPrivateExample);
    $("privateExample").addEventListener("click", fillPrivateExample);
    $("codeRefresh").addEventListener("click", () => task(refreshCode, "codeActionStatus"));
    $("codeLearn").addEventListener("click", () => codeWorkerAction("learn", "Start a code learning cycle"));
    $("codeScan").addEventListener("click", () => codeWorkerAction("scan", "Scan for repair proposals"));
    $("codeIntegrate").addEventListener("click", () => codeWorkerAction("integrate", "Verify integration patchset"));
    $("codeProposeForm").addEventListener("submit", codePropose);
    for (const id of ["codeRepairSearch", "codeRepairValidation", "codeRepairApp", "codeRepairWithDiff"]) {
      $(id).addEventListener(id === "codeRepairSearch" ? "input" : "change", renderCodeRepairs);
    }
    for (const id of ["codeReviewSearch", "codeReviewStatus", "codeReviewApp", "codeReviewValidation"]) {
      $(id).addEventListener(id === "codeReviewSearch" ? "input" : "change", renderCodeReviews);
    }
    $("codeClearReviewFilters").addEventListener("click", () => {
      for (const id of ["codeReviewSearch", "codeReviewStatus", "codeReviewApp", "codeReviewValidation"]) $(id).value = "";
      renderCodeReviews();
    });
    $("codeBearerLogin").addEventListener("click", () => openLogin("Sign in to obtain a bearer token for node-admin review actions."));
    $("codeApprove").addEventListener("click", () => codeReviewDecision("approve"));
    $("codeReject").addEventListener("click", () => codeReviewDecision("reject"));
    $("codePublish").addEventListener("click", codePublish);
    $("codeReloadReview").addEventListener("click", () => { if (state.codeReview?.id) task(() => selectCodeReview(state.codeReview.id), "codeActionStatus"); });
    $("codeCopyDiff").addEventListener("click", copyCodeDiff);
    $("codePublishPhrase").addEventListener("input", codeReviewButtons);
    $("marketRefresh").addEventListener("click", () => task(refreshMarket));
    $("marketStatus").addEventListener("change", () => task(refreshMarket));
    $("marketAction").addEventListener("change", updateMarketActionExample);
    $("publishForm").addEventListener("submit", publishMarket);
    $("marketActionForm").addEventListener("submit", actionMarket);
    $("yelpStatusBtn").addEventListener("click", () => yelpGet("/yelp/status", "yelpStatusOutput"));
    $("yelpJobBtn").addEventListener("click", () => yelpGet("/yelp/chunk_job", "yelpJobOutput"));
    $("yelpCancelBtn").addEventListener("click", () => yelpPost("/yelp/chunk_cancel", {}, "Cancel the active Yelp chunk job?"));
    $("yelpChunkForm").addEventListener("submit", (event) => {
      event.preventDefault(); const f = event.currentTarget.elements;
      return yelpPost("/yelp/chunk_async", { in: f.namedItem("in").value.trim(), out_dir: f.namedItem("out_dir").value.trim(), chunk_size: Number(f.namedItem("chunk_size").value) }, "Start a server-side Yelp chunk job?");
    });
    $("yelpAssignForm").addEventListener("submit", (event) => {
      event.preventDefault(); const f = event.currentTarget.elements;
      return yelpPost("/yelp/assign", { cluster_id: Number(f.namedItem("cluster_id").value), cluster_size: Number(f.namedItem("cluster_size").value) }, "Assign Yelp shards to this node?");
    });
    $("yelpPinBtn").addEventListener("click", () => yelpPost("/yelp/ipfs", {}, "Publish Yelp chunks to IPFS?"));
    $("yelpHeadersBtn").addEventListener("click", () => yelpPost("/yelp/headers", {}, "Export on-chain term headers?"));
    $("yelpManifestBtn").addEventListener("click", () => yelpPost("/yelp/manifest", {}, "Build a publication manifest?"));
    $("wsConnect").addEventListener("click", connectSocket);
    $("wsPing").addEventListener("click", () => sendSocket("ping"));
    $("wsPrice").addEventListener("click", () => sendSocket("get_price"));
    $("wsDisconnect").addEventListener("click", disconnectSocket);
    $("apiFilter").addEventListener("input", renderRoutes);
    $("apiRequestForm").addEventListener("submit", apiExplorerRequest);
    $("apiCopyResponse").addEventListener("click", copyResponse);
    window.addEventListener("hashchange", () => navigate(location.hash.slice(1)));
    window.addEventListener("beforeunload", () => {
      stopStream(); disconnectSocket(); clearInterval(state.poller);
      clearInterval(state.telemetryPoller); clearInterval(state.clockTicker);
    });
    document.addEventListener("visibilitychange", () => {
      if (document.hidden) { stopStream(); return; }
      if (state.authenticated && ["overview", "indexing", "code"].includes(state.view)) task(refreshView);
    });
  }
  function init() {
    if (!$("ecaiConsole")) return;
    bindEvents(); resetChat(); fillPrivateExample(); updateMarketActionExample();
    $("indexIdempotency").value = newKey("ecai-job");
    setAuthenticated(false);
    navigate(location.hash.slice(1) || "overview");
    renderRoutes();
    refreshOverview().catch(() => { renderServices(); });
    state.clockTicker = setInterval(tickJobClocks, 1000);
    state.telemetryPoller = setInterval(() => void task(pollJobTelemetry), 7000);
    state.poller = setInterval(() => {
      if (document.hidden || !state.authenticated) return;
      if (state.view === "code") {
        if (state.codeReview?.status === "publishing") task(refreshCode);
        else if (!state.codeStatusLastPoll || Date.now() - state.codeStatusLastPoll >= 24000) task(refreshCodeStatusOnly);
        return;
      }
      if (!["overview", "indexing"].includes(state.view)) return;
      task(async () => {
        const result = await request("/ecai/index-jobs/status");
        updateQueueMetrics(result.status || {});
        await refreshJobs();
      });
    }, 12000);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init, { once: true });
  else init();
})();
