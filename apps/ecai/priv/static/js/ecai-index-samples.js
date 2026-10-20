/* Explicit public test data, sent through the existing inspect + queue flow.
 * Loading a sample never queues work, mints an NFT or makes a payment. */
export function initIndexSamples({ request, showError, managedSession, authEpoch, goSearch, selectWikiSmoke }) {
  const $ = (id) => document.getElementById(id);
  let generation = 0, controller = null;
  function report(id, message, error = false) {
    const node = $(id); if (!node) return;
    node.textContent = message; node.classList.toggle("is-error", error);
  }
  async function loadSample() {
    if (!managedSession()) { report("indexSampleStatus", "Sign in with a managed account to load a test source.", true); return; }
    const fileInput = $("quickIndexFile"), sourceTab = document.querySelector('[data-quick-index-source="file"]');
    if (!fileInput || !sourceTab || fileInput.disabled || sourceTab.disabled) { report("indexSampleStatus", "Wait for the current Quick Index operation to finish."); return; }
    const epoch = authEpoch(), seq = ++generation;
    controller?.abort(); const pending = new AbortController(); controller = pending;
    $("indexSampleLoad").disabled = true;
    report("indexSampleStatus", "Loading the bundled 3-record sample…");
    const timer = setTimeout(() => pending.abort(), 15000);
    try {
      const response = await fetch("/static/samples/knowledge-smoke.jsonl", { credentials: "same-origin", mode: "same-origin", redirect: "error", cache: "no-store", signal: pending.signal });
      if (!response.ok) throw new Error(`Sample file HTTP ${response.status}. Apply the static sample file with this patch.`);
      const bytes = await response.arrayBuffer();
      if (bytes.byteLength > 65536) throw new Error("Bundled sample exceeds the 64 KiB safety limit.");
      if (pending.signal.aborted || epoch !== authEpoch() || seq !== generation || !managedSession()) return;
      if (fileInput.disabled || sourceTab?.disabled) throw new Error("Quick Index is busy. Load the sample again when it finishes.");
      if (typeof DataTransfer !== "function") throw new Error("Download the JSONL sample and choose it with the File control in this browser.");
      const transfer = new DataTransfer();
      transfer.items.add(new File([bytes], "knowledge-smoke.jsonl", { type: "application/x-ndjson" }));
      sourceTab.click();
      fileInput.files = transfer.files;
      fileInput.dispatchEvent(new Event("change", { bubbles: true }));
      report("indexSampleStatus", "Sample loaded. Review Detect structure below, then choose Index detected source. Nothing has been queued yet.");
      $("quickIndexCard")?.scrollIntoView({ block: "nearest" });
    } catch (error) {
      if (seq !== generation || epoch !== authEpoch()) return;
      report("indexSampleStatus", error.name === "AbortError" ? "Sample request timed out. Download the sample or retry." : error.message, true);
    } finally {
      clearTimeout(timer);
      if (seq === generation) { controller = null; $("indexSampleLoad").disabled = !managedSession(); }
    }
  }
  $("indexSampleLoad")?.addEventListener("click", () => void loadSample());
  document.querySelectorAll("[data-sample-query]").forEach((button) => button.addEventListener("click", () => goSearch(button.dataset.sampleQuery)));
  $("wikiSampleCheck")?.addEventListener("click", async () => {
    const button = $("wikiSampleCheck"), epoch = authEpoch(); button.disabled = true;
    report("wikiSampleStatus", "Checking bundled Wikimedia files and fixture service…");
    try {
      const data = await request("/ecai/wikimedia/sample");
      if (epoch !== authEpoch()) return;
      if (data?.ok === false || data?.status === "error") throw new Error(JSON.stringify(data.error || data.message));
      const fixture = data.sample || data.fixture || data;
      if (fixture.ready === false) throw new Error("The fixture service reports that it is not ready.");
      report("wikiSampleStatus", "Sample service responded. Select only the smoke preset, add it to the queue, then follow its download, selection and indexing stages.");
    } catch (error) {
      if (epoch === authEpoch()) report("wikiSampleStatus", `Sample unavailable: ${showError(error)}. Restart ECAI after applying the fixture-startup fix; also check that priv/wikimedia-fixtures is packaged.`, true);
    } finally { button.disabled = !managedSession(); }
  });
  $("wikiSampleSelect")?.addEventListener("click", async () => {
    const button = $("wikiSampleSelect"), epoch = authEpoch(); button.disabled = true;
    try {
      if (await selectWikiSmoke() && epoch === authEpoch()) report("wikiSampleStatus", "Smoke preset selected. Add selected to index queue starts the real pipeline after confirmation.");
    } catch (error) {
      if (epoch === authEpoch()) report("wikiSampleStatus", showError(error), true);
    } finally { button.disabled = !managedSession(); }
  });
  document.addEventListener("ecai:quick-index-queued", () => {
    report("indexSampleStatus", "A Quick Index job was queued. Follow Execution history below; when complete, search for orbital orchard and retrieve its source.");
  });
  document.addEventListener("ecai:identity-changed", () => {
    generation++; controller?.abort(); controller = null;
    // The console emits identity-changed before assigning the new session mode.
    // Cancel synchronously, then read the settled capabilities in a microtask.
    const epoch = authEpoch();
    queueMicrotask(() => {
      if (epoch !== authEpoch()) return;
      for (const id of ["indexSampleLoad", "wikiSampleCheck", "wikiSampleSelect"])
        if ($(id)) $(id).disabled = !managedSession();
    });
    report("indexSampleStatus", "Load the sample to inspect it before indexing. Managed sign-in is required.");
    report("wikiSampleStatus", "Use the smoke preset to test the pipeline before starting a large download.");
  });
}
