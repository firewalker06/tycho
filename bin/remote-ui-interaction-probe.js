/* Load in the browser console. This file does not run an action. */
(() => {
  "use strict";

  window.tychoInteractionProbe?.stop();
  let cleanup = () => {};
  let result = null;

  window.tychoInteractionProbe = {
    arm({ selector, triggerSelector = selector, expectedText = "Pause", expect = { text: expectedText }, timeoutMs = 30000, immediateMs = 100 }) {
      cleanup();
      if (document.querySelectorAll(triggerSelector).length !== 1 || document.querySelectorAll(selector).length > 1) {
        throw new Error("The trigger must match one control and the target must match at most one element.");
      }
      const value = () => {
        const element = document.querySelector(selector);
        if (Object.hasOwn(expect, "visible")) {
          if (!element) return "hidden";
          const style = getComputedStyle(element);
          const visible = style.visibility !== "hidden" && style.visibility !== "collapse" && element.getClientRects().length > 0;
          return visible ? "visible" : "hidden";
        }
        if (expect.attribute) return element ? element.getAttribute(expect.attribute.name) : undefined;
        return element?.textContent.trim() ?? null;
      };
      const expected = Object.hasOwn(expect, "visible") ? (expect.visible ? "visible" : "hidden") : expect.attribute ? expect.attribute.value : expect.text;
      if (value() === expected) throw new Error("The expected state is already present. No measurement was started.");
      const record = { expectedText: expected, immediateMs, outcome: "armed", events: [], requests: [] };
      result = record;
      let started = null;
      let timer;
      let frame;
      let pollFrame;
      let observer;
      let resources;
      const elapsed = () => Math.round((performance.now() - started) * 10) / 10;
      let previous = value();
      const sample = () => {
        if (document.querySelectorAll(selector).length > 1) {
          record.outcome = "ambiguous";
          stop();
          return;
        }
        const text = value();
        if (text !== previous) {
          record.events.push({ ms: elapsed(), text });
          previous = text;
        }
        if (text === expected && record.labelMs === undefined) {
          record.labelMs = elapsed();
          record.immediate = record.labelMs <= immediateMs;
          record.outcome = "observed";
          frame = requestAnimationFrame(() => {
            record.frameMs = elapsed();
          });
        }
      };
      const click = (event) => {
        if (!event.target.closest?.(triggerSelector) || started !== null) return;
        started = performance.now();
        record.outcome = "measuring";
        record.events.push({ ms: 0, text: value() });
        observer = new MutationObserver(sample);
        observer.observe(document.body, { subtree: true, childList: true, characterData: true, attributes: true });
        resources = new PerformanceObserver((list) => {
          for (const entry of list.getEntries()) {
            if (entry.startTime < started || !["fetch", "xmlhttprequest"].includes(entry.initiatorType)) continue;
            const url = new URL(entry.name);
            // Exclude all query strings, headers, bodies, credentials, and resource IDs.
            record.requests.push({
              route: url.pathname.split("/").map((part, index) => index > 1 ? ":segment" : part).join("/"),
              startMs: Math.round((entry.startTime - started) * 10) / 10,
              durationMs: Math.round(entry.duration * 10) / 10,
              status: entry.responseStatus || null
            });
          }
        });
        resources.observe({ type: "resource", buffered: false });
        queueMicrotask(sample);
        const poll = () => {
          sample();
          if (record.outcome === "measuring") pollFrame = requestAnimationFrame(poll);
        };
        if (Object.hasOwn(expect, "visible")) pollFrame = requestAnimationFrame(poll);
        timer = setTimeout(() => {
          sample();
          if (record.outcome === "measuring") record.outcome = "timeout";
          stop();
        }, timeoutMs);
      };
      document.addEventListener("click", click, true);
      const stop = () => {
        document.removeEventListener("click", click, true);
        observer?.disconnect();
        resources?.disconnect();
        clearTimeout(timer);
        cancelAnimationFrame(frame);
        cancelAnimationFrame(pollFrame);
      };
      cleanup = stop;
      return "Armed. Click the selected control, then call tychoInteractionProbe.read().";
    },
    read() { return result ? JSON.parse(JSON.stringify(result)) : null; },
    stop() { cleanup(); }
  };
})();
