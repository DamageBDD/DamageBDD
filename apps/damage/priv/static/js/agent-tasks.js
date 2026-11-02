// Shared task lifecycle presentation rules. The dashboard workspace owns rendering.
export const isTerminal = s => ['completed','failed','cancelled','cancelled_unreconciled','exhausted'].includes(s);
export const controlsFor = (s, task = {}) => {
  if (['budget_reserving','settling','receipting','reconciling'].includes(s)) return ['learning'];
  if (s === 'accounting_pending' || (s === 'interrupted' &&
      ['reservation_pending','settlement_pending','receipt_pending'].includes(task.budget?.status))) {
    return ['reconcile','learning'];
  }
  if (s === 'interrupted' && ['executing','verifying'].includes(task.interrupted_phase)) {
    return ['cancel','learning'];
  }
  if (isTerminal(s)) return ['learning'];
  if (s === 'awaiting_approval') return ['approve','reject','pause','cancel','learning'];
  if (s === 'paused') return ['resume','cancel','learning'];
  if (s === 'interrupted') return ['resume','cancel','learning'];
  return ['pause','cancel','learning'];
};
export function budgetLabel(task) {
  const b = task.budget;
  if (!b || b.mode === 'disabled') return 'Accounting disabled explicitly; no agent treasury claim.';
  return `${b.status}: ${b.spent_units} / ${b.max_cost_units} DAMAGE base units booked; ` +
    `${b.remaining_units} units remain under this task ceiling. AE transaction fees are separate.`;
}
