// Dashboard public onboarding. Authentication stays in auth-ui.js; do not
// create a separate sign-in flow or attempt to execute tests from this view.
function bindGuestActions() {
  const guest = document.getElementById('guest-landing');
  if (!guest || guest.dataset.bound) return;
  guest.dataset.bound = 'true';
  guest.querySelectorAll('[data-guest-auth]').forEach((button) => {
    button.addEventListener('click', () => {
      const mode = button.dataset.guestAuth;
      if (mode === 'login' || mode === 'signup') {
        window.DamageAuth?.open(mode);
      }
    });
  });
}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', bindGuestActions, {once:true});
} else {
  bindGuestActions();
}
export {bindGuestActions};
