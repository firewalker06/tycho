/* Inline, before app scripts: the saved message and recovery need no network. */
(function (window) {
  "use strict";
  const key = "hq.remote.startup-message";
  const fallback = "Loading Tycho\u2026";
  const normalize = (value) => typeof value === "string" ? value.trim().slice(0, 240) : "";
  let message = "";
  let persistent = true;
  try { message = normalize(window.localStorage.getItem(key)); }
  catch (_error) { persistent = false; }
  const shell = window.document.getElementById("tycho-boot-shell");
  const label = window.document.getElementById("tycho-boot-message");
  const retry = window.document.getElementById("tycho-boot-retry");
  label.textContent = message || fallback;
  retry.onclick = () => window.location.reload();
  const timer = window.setTimeout(() => {
    if (shell.hidden || shell.classList.contains("is-leaving")) return;
    shell.dataset.state = "failed";
    label.textContent = "Tycho could not finish loading. Check your connection, then try again.";
    shell.setAttribute("aria-label", label.textContent);
    retry.hidden = false;
  }, 15000);
  window.TychoStartup = {
    getState: () => ({ message, persistent }),
    setMessage(value) {
      message = normalize(value);
      try { window.localStorage.setItem(key, message); persistent = true; }
      catch (_error) { persistent = false; }
    },
    handoff(onRetry) {
      window.clearTimeout(timer);
      retry.onclick = onRetry;
    },
  };
})(window);
