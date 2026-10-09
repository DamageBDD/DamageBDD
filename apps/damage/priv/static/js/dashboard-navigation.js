/* Primary dashboard navigation. Tabby is reserved for nested modal/report tabs.
 * No panel content is fetched, replaced or recreated when changing sections.
 */
const COLLAPSE_KEY = 'damage.dashboard.sidebar.collapsed.v1';
const DEFAULT_PANEL = 'execution-tab';
let singleton = null;

/** Decode only simple local panel identifiers; never interpolate a hash into CSS. */
export function panelIdFromHash(value) {
  if (typeof value !== 'string' || value.length > 160) return null;
  try {
    const id = decodeURIComponent(value.replace(/^#/, ''));
    return /^[a-z][a-z0-9-]*-tab$/.test(id) ? id : null;
  } catch { return null; }
}

export function initDashboardNavigation() {
  if (singleton) return singleton;
  if (typeof document === 'undefined') return null;
  const shell = document.querySelector('[data-dashboard-shell]');
  const sidebar = document.getElementById('dashboard-sidebar');
  const nav = document.getElementById('dashboard-navigation');
  const main = document.getElementById('dashboard-main');
  const toggle = document.getElementById('dashboard-nav-toggle');
  const closer = document.getElementById('dashboard-nav-close');
  const backdrop = document.getElementById('dashboard-nav-backdrop');
  if (!shell || !sidebar || !nav || !main || !toggle || !closer || !backdrop) return null;

  const links = [...nav.querySelectorAll('a[data-dashboard-panel]')];
  const panels = new Map();
  for (const link of links) {
    const id = panelIdFromHash(link.getAttribute('href'));
    const panel = id && document.getElementById(id);
    if (panel?.matches('[data-dashboard-view]') && link.dataset.dashboardPanel === id) {
      panels.set(id, {link, panel});
    }
  }
  if (!panels.has(DEFAULT_PANEL)) return null;
  const media = window.matchMedia('(max-width: 900px)');
  const skip = document.querySelector('.workspace-skip');
  let active = null, pending = null, drawerOpen = false, collapsed = false;
  let restoreFocus = null;
  try { collapsed = window.localStorage.getItem(COLLAPSE_KEY) === 'true'; } catch { /* Storage may be blocked. */ }

  // Hidden or server-omitted navigation must not be reachable via a URL or API.
  // These are UI constraints only; backend authorization remains authoritative.
  function available(id) {
    const entry = panels.get(id);
    if (!entry || entry.link.getAttribute('aria-disabled') === 'true') return false;
    for (let node = entry.link; node && node !== nav.parentElement; node = node.parentElement) {
      if (node.hidden) return false;
    }
    return true;
  }
  function visibleLinks() {
    return links.filter(link => available(link.dataset.dashboardPanel));
  }
  function isFocusable(element) {
    return !!element?.isConnected && !element.closest('[hidden], [inert]') && element.getClientRects().length > 0;
  }
  function focusMain() {
    const panel = panels.get(active)?.panel || main;
    panel.focus({preventScroll: true});
  }
  function syncLayout() {
    shell.classList.toggle('sidebar-collapsed', collapsed && !media.matches);
    shell.classList.toggle('sidebar-open', drawerOpen && media.matches);
    document.body.classList.toggle('dashboard-nav-open', drawerOpen && media.matches);
    sidebar.inert = media.matches && !drawerOpen;
    main.inert = media.matches && drawerOpen;
    if (skip) skip.inert = media.matches && drawerOpen;
    backdrop.hidden = !media.matches || !drawerOpen;
    const label = media.matches ? (drawerOpen ? 'Close navigation' : 'Open navigation') : (collapsed ? 'Expand navigation' : 'Collapse navigation');
    toggle.setAttribute('aria-expanded', String(media.matches ? drawerOpen : !collapsed));
    toggle.setAttribute('aria-label', label);
    toggle.title = label;
    if (media.matches && drawerOpen) {
      sidebar.setAttribute('role', 'dialog');
      sidebar.setAttribute('aria-modal', 'true');
      sidebar.removeAttribute('aria-hidden');
    } else {
      sidebar.removeAttribute('role');
      sidebar.removeAttribute('aria-modal');
      if (media.matches) sidebar.setAttribute('aria-hidden', 'true');
      else sidebar.removeAttribute('aria-hidden');
    }
    closer.hidden = !media.matches;
  }
  function closeDrawer({focus = true} = {}) {
    if (!drawerOpen) return;
    drawerOpen = false;
    syncLayout();
    if (focus) (isFocusable(restoreFocus) ? restoreFocus : toggle).focus({preventScroll: true});
    restoreFocus = null;
  }
  function openDrawer() {
    if (!media.matches || drawerOpen) return;
    restoreFocus = document.activeElement;
    drawerOpen = true;
    syncLayout();
    (panels.get(active)?.link || visibleLinks()[0] || closer).focus({preventScroll: true});
  }
  function setCollapsed(value) {
    collapsed = !!value;
    try { window.localStorage.setItem(COLLAPSE_KEY, String(collapsed)); } catch { /* Optional preference. */ }
    syncLayout();
    window.dispatchEvent(new Event('resize'));
  }
  function writeHash(id, method) {
    if (method === 'none' || window.location.hash === '#' + id) return;
    const url = new URL(window.location.href);
    url.hash = id;
    try { window.history[method === 'replace' ? 'replaceState' : 'pushState'](window.history.state, '', url); }
    catch { /* file:// previews and restricted embedding may disallow history. */ }
  }
  function navigate(id0, {history = 'push', focus = true} = {}) {
    const id = panelIdFromHash(id0);
    if (!id || !available(id)) return false;
    pending = null;
    const previous = active;
    active = id;
    for (const [key, {link, panel}] of panels) {
      const selected = key === id;
      panel.hidden = !selected;
      if (selected) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    }
    const {link, panel} = panels.get(id);
    document.getElementById('dashboard-section-title').textContent = link.dataset.navTitle;
    document.getElementById('dashboard-section-group').textContent = link.dataset.navGroup;
    document.getElementById('dashboard-section-description').textContent = link.dataset.navDescription;
    document.title = `${link.dataset.navTitle} · DamageBDD`;
    writeHash(id, history);
    closeDrawer({focus: false});
    if (focus) {
      if (previous !== id) window.scrollTo(0, 0);
      focusMain();
    }
    if (previous !== id) {
      document.dispatchEvent(new CustomEvent('damage:panelchange', {
        detail: {id, panel, link, previousId: previous, previousPanel: panels.get(previous)?.panel || null}
      }));
      window.dispatchEvent(new Event('resize'));
    }
    return true;
  }
  function fromLocation({focus = false} = {}) {
    const requested = panelIdFromHash(window.location.hash);
    const deferred = requested && panels.has(requested) && !available(requested) ? requested : null;
    navigate(available(requested) ? requested : DEFAULT_PANEL, {history: 'none', focus});
    // Billing permission resolves asynchronously. Do not reveal it while hidden.
    pending = deferred;
  }
  toggle.addEventListener('click', () => {
    if (media.matches) drawerOpen ? closeDrawer() : openDrawer();
    else setCollapsed(!collapsed);
  });
  closer.addEventListener('click', () => closeDrawer());
  backdrop.addEventListener('click', () => closeDrawer());
  sidebar.addEventListener('click', event => {
    const link = event.target.closest('a[data-dashboard-panel], a[data-dashboard-home]');
    if (link && !event.ctrlKey && !event.metaKey && !event.shiftKey && !event.altKey && event.button === 0) {
      event.preventDefault();
      navigate(link.hasAttribute('data-dashboard-home') ? DEFAULT_PANEL : link.dataset.dashboardPanel);
    }
  });
  // Capture runs before direct button handlers open wallet/install/auth modals.
  sidebar.addEventListener('click', event => {
    if (event.target.closest('[data-micromodal-trigger], #open-node-wallet-btn')) closeDrawer();
  }, {capture: true});
  nav.addEventListener('keydown', event => {
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
    if (!['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(event.key)) return;
    const current = event.target.closest('a[data-dashboard-panel]');
    const entries = visibleLinks(), index = entries.indexOf(current);
    if (index < 0 || !entries.length) return;
    event.preventDefault();
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? entries.length - 1 :
      (index + (event.key === 'ArrowUp' ? -1 : 1) + entries.length) % entries.length;
    entries[next].focus();
  });
  document.addEventListener('keydown', event => {
    if (!drawerOpen || !media.matches) return;
    if (event.key === 'Escape') {
      event.preventDefault(); closeDrawer(); return;
    }
    if (event.key !== 'Tab') return;
    const focusable = [...sidebar.querySelectorAll('a[href], button:not(:disabled), [tabindex="0"]')]
      .filter(isFocusable);
    const first = focusable[0], last = focusable.at(-1);
    if (!first) { event.preventDefault(); return; }
    if (event.shiftKey && (document.activeElement === first || !sidebar.contains(document.activeElement))) {
      event.preventDefault(); last.focus();
    } else if (!event.shiftKey && (document.activeElement === last || !sidebar.contains(document.activeElement))) {
      event.preventDefault(); first.focus();
    }
  });
  media.addEventListener('change', () => {
    const wasInSidebar = sidebar.contains(document.activeElement);
    const wasOpen = drawerOpen;
    drawerOpen = false;
    restoreFocus = null;
    syncLayout();
    if ((wasInSidebar && media.matches) || (wasOpen && !media.matches)) toggle.focus({preventScroll: true});
  });
  window.addEventListener('popstate', () => fromLocation({focus: true}));
  window.addEventListener('hashchange', () => {
    // Leave ordinary in-page anchors (step library, report lines) alone.
    if (panelIdFromHash(window.location.hash) || !window.location.hash) fromLocation({focus: true});
  });
  new MutationObserver(() => {
    if (active && !available(active)) {
      const focusedEntry = [...panels.values()].some(({panel, link}) =>
        panel.contains(document.activeElement) || link === document.activeElement);
      navigate(DEFAULT_PANEL, {history: 'replace', focus: focusedEntry});
    } else if (pending && available(pending) && panelIdFromHash(window.location.hash) === pending) {
      navigate(pending, {history: 'none', focus: false});
    }
  }).observe(nav, {subtree: true, attributes: true, attributeFilter: ['hidden', 'aria-disabled']});

  singleton = Object.freeze({navigate, closeDrawer, openDrawer, get activePanel() { return active; }});
  window.dashboardNavigation = singleton;
  shell.classList.add('navigation-ready');
  syncLayout();
  fromLocation();
  return singleton;
}

if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initDashboardNavigation, {once: true});
  else initDashboardNavigation();
}
