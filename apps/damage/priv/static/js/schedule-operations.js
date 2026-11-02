// GET-only observation. A timeout must never cause a second funding request.
export async function awaitScheduleOperation(initial, readOperation, options = {}) {
  const sleep = options.sleep || (ms => new Promise(resolve => setTimeout(resolve, ms)));
  const now = options.now || Date.now;
  const deadline = now() + (options.timeoutMs ?? 600000);
  const maxReads = options.maxReads ?? 360;
  let result = initial, reads = 0;
  const visited = new Set();
  while (result?.operation_id) {
    const id = result.operation_id;
    options.onProgress?.(result);
    if (result.status === "complete") {
      if (!result.result || typeof result.result !== "object") {
        throw new Error(`Operation ${id} has no completion result. Check Pending operations.`);
      }
      return result.result;
    }
    if (result.status === "failed" || result.status === "reconciliation_required") {
      const uncertain = result.status === "reconciliation_required";
      throw new Error(`${uncertain ? "Confirmation is unresolved" : "Schedule operation failed"} at ${result.stage || "unknown"} (${result.error || "unknown error"}). Operation: ${id}.${result.tx_hash ? ` Transaction: ${result.tx_hash}.` : ""}${uncertain ? " Do not fund again; reconcile the existing transaction." : ""}`);
    }
    if (now() >= deadline || reads >= maxReads || options.keepWaiting?.() === false) {
      return {status: "operation_pending", operation_id: id};
    }
    let nextId = id;
    if (result.status === "superseded") {
      nextId = result.superseded_by;
      if (!nextId || visited.has(nextId) || nextId === id) throw new Error("Invalid schedule operation chain.");
      visited.add(id);
    } else if (result.status === "running") {
      await sleep(options.intervalMs ?? 2000);
    } else {
      throw new Error(`Unrecognized schedule operation status: ${result.status}. Check Pending operations.`);
    }
    try {
      result = await readOperation(nextId);
      reads += 1;
    } catch {
      return {status: "operation_pending", operation_id: nextId};
    }
    if (!result || result.operation_id !== nextId) {
      throw new Error("Invalid schedule operation response. Check Pending operations.");
    }
  }
  return result;
}

export function isPendingOperation(value) {
  return value?.status === "operation_pending";
}
