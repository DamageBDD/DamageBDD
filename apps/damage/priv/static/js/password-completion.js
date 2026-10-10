import {errorMessage} from './auth-model.js';
const form = document.getElementById('resetPasswdForm');
if (form) {
  // The rendered hidden field retains the token. Remove it from address/history.
  if (location.search) history.replaceState(null, '', location.pathname);
  let busy = false;
  const result = document.getElementById('password-result');
  const status = (message, kind) => { result.textContent = message; result.dataset.kind = kind; };
  document.querySelectorAll('[data-password-toggle]').forEach(button => button.addEventListener('click', () => {
    const input = document.getElementById(button.dataset.passwordToggle);
    const visible = input.type === 'password';
    input.type = visible ? 'text' : 'password';
    button.textContent = visible ? 'Hide' : 'Show';
    button.setAttribute('aria-pressed', String(visible));
  }));
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !form.reportValidity()) return;
    const body = Object.fromEntries(new FormData(form));
    if (body.new_password !== body.new_password_confirm) return status('The passwords do not match.', 'error');
    const path = new URL(form.action);
    if (path.origin !== location.origin || !['/accounts/confirm', '/accounts/reset_password'].includes(path.pathname))
      return status('The password form has an invalid action.', 'error');
    busy = true;
    const controls = [...form.querySelectorAll('input,button')];
    controls.forEach(el => {el.disabled = true;});
    form.setAttribute('aria-busy', 'true');
    status('Saving your password…', 'info');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 60000);
    try {
      const response = await fetch(path.pathname, {method:'POST', credentials:'omit', cache:'no-store', mode:'same-origin', redirect:'error', referrerPolicy:'no-referrer',
        signal:controller.signal, headers:{'Content-Type':'application/json', Accept:'application/json'}, body:JSON.stringify(body)});
      const data = await response.json();
      if (!response.ok) throw new Error(errorMessage(data, response.status));
      if (data.status !== 'ok') throw new Error('The password change was not confirmed. Please retry.');
      form.reset(); form.hidden = true;
      status('Password saved. Sign in with your email to continue.', 'success');
      document.getElementById('password-sign-in').hidden = false;
    } catch(error) {
      status(error.name === 'AbortError' ? 'The request timed out. Try signing in before submitting again.' : error.message, 'error');
    } finally {
      clearTimeout(timeout); busy = false;
      controls.forEach(el => {el.disabled = false;});
      form.removeAttribute('aria-busy');
    }
  });
}
