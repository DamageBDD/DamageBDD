// Static exports keep local light/dark defaults when no node theme is served.
// A successful node palette is authoritative; the local toggle must not claim
// to change a palette it can no longer override. No state is sent to the server.
(function () {
  let saved;
  try { saved = localStorage.getItem("theme"); } catch (_) { /* Private storage. */ }
  const dark = saved === "dark" || (!saved && matchMedia("(prefers-color-scheme: dark)").matches);
  document.body.classList.toggle("dark", dark);

  function syncThemeControl() {
    const active = !!getComputedStyle(document.documentElement).getPropertyValue("--theme-color-scheme").trim();
    document.documentElement.dataset.nodeTheme = active ? "active" : "unavailable";
    const button = document.getElementById("theme-button");
    if (button) {
      button.disabled = active;
      button.title = active ? "Theme selected by this node's administrator" : "Toggle Light/Dark";
      button.setAttribute("aria-label", button.title);
    }
  }
  let link = document.getElementById("node-theme");
  if (!link) {
    // Old signed exports already include theme.js. Add the stylesheet at runtime
    // so deploying these assets does not rewrite or invalidate signed HTML.
    link = document.createElement("link");
    link.id = "node-theme";
    link.rel = "stylesheet";
    link.href = "/api/themes/css?app=bop";
    link.addEventListener("load", syncThemeControl);
    link.addEventListener("error", syncThemeControl);
    document.head.append(link);
  } else {
    link.addEventListener("load", syncThemeControl);
    link.addEventListener("error", syncThemeControl);
  }
  syncThemeControl();
})();

function toggleTheme() {
  if (getComputedStyle(document.documentElement).getPropertyValue("--theme-color-scheme").trim()) return;
  const dark = document.body.classList.toggle("dark");
  try { localStorage.setItem("theme", dark ? "dark" : "light"); } catch (_) { /* Private storage. */ }
}
