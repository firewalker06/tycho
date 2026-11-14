/* Inline, before app scripts: the saved message and recovery need no network. */
(function (window) {
  "use strict";
  const key = "hq.remote.startup-message";
  const defaults = ["The factory must grow", "Orchestrating the orchestrator"];
  const normalize = (value) => typeof value === "string" ? value.slice(0, 8000) : "";
  let message = "";
  let persistent = true;
  try { message = normalize(window.localStorage.getItem(key)); }
  catch (_error) { persistent = false; }
  const shell = window.document.getElementById("tycho-boot-shell");
  const label = window.document.getElementById("tycho-boot-message");
  const retry = window.document.getElementById("tycho-boot-retry");
  const candidates = message.split(/\r?\n/).map(line => line.trim().slice(0, 240)).filter(Boolean);
  const choices = candidates.length ? candidates : defaults;
  label.textContent = choices[Math.floor(Math.random() * choices.length)];
  // Choose once; Retry and reduced-motion changes keep the same variant.
  const animation = Math.random() < 0.5 ? "legacy" : "curves";
  shell.dataset.animation = animation;
  const particles = window.document.getElementById("tycho-boot-particles");
  const motionPreference = window.matchMedia("(prefers-reduced-motion: reduce)");
  let bootParticleTimer = null;
  function randomBootParticleValue(minimum, maximum) {
    return minimum + (Math.random() * (maximum - minimum));
  }

  function emitBootParticles() {
    if (!particles || shell.hidden || shell.classList.contains("is-leaving") || shell.dataset.state !== "loading" || animation !== "legacy" || motionPreference.matches) return;

    const count = 3 + Math.floor(Math.random() * 3);
    const fragment = window.document.createDocumentFragment();
    for (let index = 0; index < count; index += 1) {
      const particle = window.document.createElement("span");
      const angle = randomBootParticleValue(0, Math.PI * 2);
      const distance = randomBootParticleValue(104, 184);
      particle.className = "tycho-boot-particle";
      particle.style.setProperty("--tycho-particle-size", `${randomBootParticleValue(4.5, 10.5).toFixed(1)}px`);
      particle.style.setProperty("--tycho-particle-duration", `${Math.round(randomBootParticleValue(600, 900))}ms`);
      particle.style.setProperty("--tycho-particle-x", `${(Math.cos(angle) * distance).toFixed(1)}px`);
      particle.style.setProperty("--tycho-particle-y", `${(Math.sin(angle) * distance).toFixed(1)}px`);
      particle.addEventListener("animationend", () => particle.remove(), { once: true });
      fragment.appendChild(particle);
    }
    particles.appendChild(fragment);
    bootParticleTimer = window.setTimeout(emitBootParticles, Math.round(randomBootParticleValue(100, 200)));
  }

  function stopBootParticles() {
    window.clearTimeout(bootParticleTimer);
    bootParticleTimer = null;
    particles?.replaceChildren();
  }
  function syncMotion() {
    stopBootParticles();
    emitBootParticles();
  }
  motionPreference.addEventListener("change", syncMotion);
  syncMotion();
  retry.onclick = () => window.location.reload();
  const timer = window.setTimeout(() => {
    if (shell.hidden || shell.classList.contains("is-leaving")) return;
    shell.dataset.state = "failed";
    stopBootParticles();
    label.textContent = "Tycho could not finish loading. Check your connection, then try again.";
    shell.setAttribute("aria-label", label.textContent);
    retry.hidden = false;
  }, 15000);
  window.TychoStartup = {
    getState: () => ({ message, persistent, animation }),
    syncMotion,
    finish() {
      stopBootParticles();
      motionPreference.removeEventListener("change", syncMotion);
    },
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
