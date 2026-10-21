/* Sidebar organization and settings launchers; existing handlers own all writes. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let hooks = null;
  let initialized = false;
  const mobile = () => matchMedia('(max-width: 800px)').matches;
  const current = () => hooks?.session?.() || {authenticated: false};
  const text = (id, value) => { const node = $(id); if (node) node.textContent = value; };
  const visible = (id, value) => { const node = $(id); if (node) node.hidden = !value; };

  function refresh() {
    if (!initialized) return;
    const s = current();
    const managed = s.authenticated && s.mode === 'custodial';
    const wallet = s.authenticated && s.mode === 'wallet';
    const admin = managed && s.nodeAdmin === true;
    const code = managed && (s.nodeAdmin === true || s.codeAdmin === true);
    text('accountSettingsIdentity', s.authenticated ? (s.identity || 'Signed-in account') : 'Guest access');
    text('accountSettingsMode', managed ? 'Managed account' : wallet ? 'Wallet session' : 'Not signed in');
    text('accountSettingsAddress', s.authenticated ? (s.address || 'Not available') : 'Sign in to view your account');
    text('accountSettingsNotice', managed
      ? 'Manage this session and your account-scoped settings. The node holds the signing key for supported managed-account operations.'
      : wallet ? 'Wallet sign-in proves identity. It does not authorize managed-only indexing, cloud reservations or node administration.'
      : 'Browse first. Sign in or create an account when you are ready to save work and configure account services.');
    for (const id of ['accountSettingsLogin', 'accountSettingsCreate', 'accountSettingsWallet']) visible(id, !s.authenticated);
    for (const id of ['accountSettingsSwitch', 'accountSettingsLogout']) visible(id, s.authenticated);
    for (const button of document.querySelectorAll('[data-settings-managed]')) button.disabled = !managed;
    text('accountSettingsAccess', managed
      ? 'These preferences apply to your account, not the whole node.'
      : 'The settings below require a managed email session. Use Sign in to access them.');
    visible('accountSettingsManagedLogin', wallet);
    text('nodeSettingsAccess', code
      ? 'Administrator navigation is available. Each destination still checks authorization on the server.'
      : 'Node-wide changes require a server-authorized administrator. Account and Compute settings are separate.');
    visible('nodeSettingsCode', code);
    visible('nodeSettingsOperations', admin);
    visible('nodeSettingsRestricted', !code && !admin);
    text('nodeSettingsCodeNotice', code && !s.codeEnabled
      ? 'Code administration is not advertised as enabled. Open its workspace for configuration diagnostics; no settings are changed here.'
      : 'Open the existing learning, repository and review-gate settings. Saves remain in that administrator workspace.');
    text('nodeSettingsVersion', $('ecaiConsole')?.dataset.nodeVersion || 'Not reported');
    // Never probe an admin endpoint just to draw navigation or an account page.
  }

  function focusSection(view, id) {
    hooks.navigate(view);
    requestAnimationFrame(() => {
      const target = $(id);
      if (!target || target.closest('[data-panel]')?.hidden) return;
      if (target.tagName === 'DETAILS') target.open = true;
      target.scrollIntoView({block: 'start', behavior: 'auto'});
      const focus = target.querySelector('summary, h2, h3') || target;
      if (!focus.hasAttribute('tabindex')) focus.setAttribute('tabindex', '-1');
      focus.focus({preventScroll: true});
    });
  }

  function action(name) {
    const s = current();
    switch (name) {
      case 'login': hooks.openLogin(); break;
      case 'signup': hooks.openLogin('', 'signup'); break;
      case 'wallet': hooks.openLogin('', 'wallet'); break;
      case 'switch': hooks.openLogin('Switching replaces this browser session; it does not link accounts.'); break;
      case 'logout': if (s.authenticated) $('logoutBtn')?.click(); break;
      case 'mint':
        if (!s.authenticated || s.mode !== 'custodial') return;
        hooks.navigate('indexing');
        window.EcaiIndexMintSettings?.open?.();
        break;
      case 'code-settings':
        if (s.mode === 'custodial' && (s.nodeAdmin || s.codeAdmin)) focusSection('code', 'codeSettingsPanel');
        break;
      case 'diagnostics': focusSection('overview', 'overviewServiceSection'); break;
    }
  }

  function syncDrawer() {
    const drawer = $('consoleSidebar');
    const isMobile = mobile();
    const open = drawer.classList.contains('is-open');
    // Off-screen drawer controls must not remain in the keyboard focus order.
    drawer.inert = isMobile && !open;
    $('openNav')?.setAttribute('aria-expanded', String(isMobile && open));
    const body = document.querySelector('.console-body');
    if (body) body.inert = isMobile && open;
    document.body.classList.toggle('ecai-sidebar-open', isMobile && open);
    if (!isMobile) $('mobileScrim').hidden = true;
  }

  function visibleDrawerControls() {
    return [...$('consoleSidebar').querySelectorAll('button, a[href], summary')]
      .filter(node => !node.disabled && node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden');
  }

  function navigated(view, previous) {
    if (!initialized) return;
    const active = [...$('consoleNav').querySelectorAll('[data-view]')].find(node => node.dataset.view === view);
    const more = active?.closest('details');
    if (more) more.open = true; // Deep links must reveal the active destination.
    refresh();
    syncDrawer();
    // Do not steal focus for polls or same-page refreshes; do reset page scroll
    // after a route switch so the new title is not stranded under the topbar.
    if (view !== previous) {
      window.scrollTo({top: 0, behavior: 'instant'});
      requestAnimationFrame(() => {
        const panel = [...document.querySelectorAll('[data-panel]')].find(node => node.dataset.panel === view);
        const title = panel?.querySelector('h1');
        if (title) { title.tabIndex = -1; title.focus({preventScroll: true}); }
      });
    }
  }

  function init(api) {
    if (initialized || !$('accountSettingsTitle') || !$('nodeSettingsTitle')) return;
    hooks = api; initialized = true;
    document.addEventListener('click', event => {
      const control = event.target.closest('[data-settings-action], [data-settings-go]');
      if (!control || control.disabled) return;
      if (control.dataset.settingsGo) {
        if (control.hasAttribute('data-settings-managed') && current().mode !== 'custodial') return;
        if (control.dataset.settingsGo === 'operations' && !(current().mode === 'custodial' && current().nodeAdmin)) return;
        hooks.navigate(control.dataset.settingsGo);
      } else action(control.dataset.settingsAction);
    });
    $('openNav').setAttribute('aria-controls', 'consoleSidebar');
    $('openNav').addEventListener('click', () => {
      syncDrawer();
      requestAnimationFrame(() => $('closeNav')?.focus());
    });
    for (const id of ['closeNav', 'mobileScrim']) $(id).addEventListener('click', () => {
      syncDrawer();
      if (mobile()) $('openNav')?.focus();
    });
    $('consoleSidebar').addEventListener('keydown', event => {
      if (!mobile() || !$('consoleSidebar').classList.contains('is-open')) return;
      if (event.key === 'Escape') { event.preventDefault(); $('closeNav').click(); return; }
      if (event.key !== 'Tab') return;
      const controls = visibleDrawerControls();
      const first = controls[0], last = controls[controls.length - 1];
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
    });
    const media = matchMedia('(max-width: 800px)');
    media.addEventListener('change', () => {
      $('consoleSidebar').classList.remove('is-open'); $('mobileScrim').hidden = true; syncDrawer();
    });
    refresh(); syncDrawer();
  }
  window.EcaiConsoleSettings = {init, refresh, navigated, assetVersion: 'sidebar-settings-v1'};
})();
