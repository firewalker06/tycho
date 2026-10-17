"use strict";
let token = "";
let timer;
let pending = false;
const element = (id) => document.getElementById(id);
const error = (message) => { element("error").textContent = message; };

async function request(path, body) {
  const response = await fetch(path, {
    method: body === undefined ? "GET" : "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
  });
  if (response.status >= 500) {
    throw new Error(`Server unavailable (HTTP ${response.status}). Try again shortly.`);
  }
  let data;
  try { data = await response.json(); }
  catch { throw new Error("Server returned an invalid response. Reload the page and try again."); }
  if (!response.ok) throw new Error(data.error || "Request failed");
  return data;
}

function render(data) {
  const active = ["running", "stopping"].includes(data.status);
  element("status").textContent = data.status;
  element("start").disabled = active;
  element("stop").disabled = !active || data.status === "stopping";
  element("harness").textContent = data.harness === "fixture" ? "Test fixture. No model call." : "Codex · Read-only sandbox · 3-minute run limit";
  element("result").textContent = data.result || "No result yet.";
  element("output").textContent = data.output || "Waiting for output.";
}

async function refresh() {
  if (pending || !token) return;
  pending = true;
  try { render(await request("/api/run")); error(""); }
  catch (failure) { error(failure.message); }
  finally { pending = false; }
}

element("login").addEventListener("submit", async (event) => {
  event.preventDefault();
  token = element("token").value.trim();
  try {
    render(await request("/api/run"));
    element("token").value = "";
    element("login-panel").hidden = true;
    element("workspace").hidden = false;
    error("");
    clearInterval(timer);
    timer = setInterval(refresh, 700);
    element("prompt").focus();
  } catch (failure) { token = ""; error(failure.message); }
});

element("run-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  element("start").disabled = true;
  try { render(await request("/api/run", { prompt: element("prompt").value })); error(""); }
  catch (failure) { error(failure.message); element("start").disabled = false; }
});

element("stop").addEventListener("click", async () => {
  try { render(await request("/api/stop", {})); error(""); }
  catch (failure) { error(failure.message); }
});

element("disconnect").addEventListener("click", () => {
  token = "";
  clearInterval(timer);
  element("login-panel").hidden = false;
  element("workspace").hidden = true;
  element("output").textContent = "";
  element("result").textContent = "";
  error("");
});
