(function initTychoRemoteHelpers(global) {
  function normalizeAgentSort(value, config = {}) {
    const raw = String(value || "").trim();
    const aliases = config.aliases || {};
    const normalized = aliases[raw] || raw;
    const options = Array.isArray(config.options) ? config.options : [];
    const fallback = config.defaultSort || "";
    return options.some((option) => option.value === normalized) ? normalized : fallback;
  }

  function currentAgentSortOption(sort, config = {}) {
    const options = Array.isArray(config.options) ? config.options : [];
    const normalized = normalizeAgentSort(sort, config);
    return options.find((option) => option.value === normalized) ||
      options.find((option) => option.value === config.defaultSort) ||
      null;
  }

  function agentSortUsesProjectGroups(sort, config = {}) {
    return currentAgentSortOption(sort, config)?.scope !== "agents";
  }

  function agentActivityTimestamp(agent) {
    return Date.parse(agent?.updated_at || agent?.finished_at || agent?.started_at || agent?.created_at || "") || 0;
  }

  function compareDisplayText(a, b) {
    return String(a || "").localeCompare(String(b || ""), undefined, { sensitivity: "base", numeric: true });
  }

  function compareAgentsByName(a, b) {
    const byName = compareDisplayText(a?.name || a?.key, b?.name || b?.key);
    if (byName !== 0) return byName;

    return compareDisplayText(a?.key, b?.key);
  }

  function compareAgentsByNameDesc(a, b) {
    return -compareAgentsByName(a, b);
  }

  function compareAgentsByUpdatedAt(a, b, direction) {
    const left = agentActivityTimestamp(a);
    const right = agentActivityTimestamp(b);
    const byUpdatedAt = direction === "asc" ? left - right : right - left;
    if (byUpdatedAt !== 0) return byUpdatedAt;

    return compareAgentsByName(a, b);
  }

  function compareAgentsBySort(a, b, sort, config = {}) {
    switch (normalizeAgentSort(sort, config)) {
      case "agent_name_desc":
        return compareAgentsByNameDesc(a, b);
      case "agent_updated_desc":
        return compareAgentsByUpdatedAt(a, b, "desc");
      case "agent_updated_asc":
        return compareAgentsByUpdatedAt(a, b, "asc");
      default:
        return compareAgentsByName(a, b);
    }
  }

  function parseRoute(hash, config = {}) {
    const { parts, params } = parsedHashRoute(hash);
    const topTabs = Array.isArray(config.topTabs) ? config.topTabs : [];
    if (parts[0] === "agent" && parts[1] && parts[2] === "edit") {
      return { type: "agentForm", mode: "edit", key: parts[1] };
    }
    if (parts[0] === "agent" && parts[1] && parts[2] === "clone") {
      return { type: "agentForm", mode: "clone", key: parts[1] };
    }
    if (parts[0] === "agent" && parts[1] && parts[2] === "archive") {
      return { type: "agentArchive", key: parts[1] };
    }
    if (parts[0] === "agent" && parts[1] && parts[2] === "summary") {
      return { type: "agentSummary", key: parts[1], summaryId: parts[3] || "" };
    }
    if (parts[0] === "agent" && parts[1] && parts[2] === "pr-diffs") {
      return { type: "agentPullRequests", key: parts[1], pullRequestId: parts[3] || "" };
    }
    if (parts[0] === "agent" && parts[1] && parts[2] === "attachment" && parts[3]) {
      return { type: "agentAttachment", key: parts[1], attachmentId: parts[3] };
    }
    if (parts[0] === "agent" && parts[1]) return { type: "agent", key: parts[1] };
    if (parts[0] === "attachment" && parts[1]) return { type: "attachment", id: parts[1] };
    if (parts[0] === "project" && parts[1] && parts[2] === "diff") {
      const route = { type: "projectDiff", key: parts[1], scope: normalizeDiffScope(params.get("scope") || parts[3]) };
      const backTo = parseBackToRoute(params.get("back_to") || params.get("return_to"));
      if (backTo) route.backTo = backTo;
      return route;
    }
    if (parts[0] === "project" && parts[1] && parts[2] === "agent" && parts[3] === "new") {
      return { type: "agentForm", mode: "create", projectKey: parts[1] };
    }
    if (parts[0] === "project" && parts[1] && parts[2] === "edit") {
      return { type: "projectForm", key: parts[1] };
    }
    if (parts[0] === "project" && parts[1] && parts[2] === "action" && parts[3]) {
      return { type: "guard", key: parts[1], action: parts[3] };
    }
    if (parts[0] === "project" && parts[1]) {
      const route = { type: "project", key: parts[1] };
      const backTo = parseBackToRoute(params.get("back_to") || params.get("return_to"));
      if (backTo) route.backTo = backTo;
      return route;
    }
    if (parts[0] === "schedule" && parts[1] === "new") {
      return { type: "scheduleForm", mode: "create", projectKey: params.get("project") || "" };
    }
    if (parts[0] === "schedule" && parts[1] && parts[2] === "message") {
      return { type: "scheduleMessage", key: parts[1] };
    }
    if (parts[0] === "schedule" && parts[1] && parts[2] === "edit") {
      return { type: "scheduleForm", mode: "edit", key: parts[1] };
    }
    if ((parts[0] === "settings" || parts[0] === "setup") && parts[1] === "hidden") return { type: "hiddenSettings" };
    if (parts[0] === "setup") return { type: "tab", tab: "settings" };
    if (parts[0] === "search" || parts[0] === "projects") return { type: "tab", tab: "agents" };
    if (topTabs.includes(parts[0])) return { type: "tab", tab: parts[0] };
    return { type: "tab", tab: "now" };
  }

  function parsedHashRoute(hash) {
    const text = String(hash || "").replace(/^#/, "");
    const [path, query = ""] = text.split("?", 2);
    return {
      parts: path.split("/").filter(Boolean).map(decodeURIComponent),
      params: new URLSearchParams(query),
    };
  }

  function parseBackToRoute(value) {
    const text = String(value || "").replace(/^#/, "");
    const parts = text.split("/").filter(Boolean).map(decodeURIComponent);
    if (parts[0] === "agent" && parts[1]) return { type: "agent", key: parts[1] };
    return null;
  }

  function normalizeDiffScope(value) {
    const scope = String(value || "").trim();
    return ["worktree", "staged", "all"].includes(scope) ? scope : "worktree";
  }

  function routeHash(route) {
    if (route.type === "agent") return `#agent/${encodeURIComponent(route.key)}`;
    if (route.type === "agentSummary") {
      const suffix = route.summaryId ? `/${encodeURIComponent(route.summaryId)}` : "";
      return `#agent/${encodeURIComponent(route.key)}/summary${suffix}`;
    }
    if (route.type === "agentPullRequests") {
      const suffix = route.pullRequestId ? `/${encodeURIComponent(route.pullRequestId)}` : "";
      return `#agent/${encodeURIComponent(route.key)}/pr-diffs${suffix}`;
    }
    if (route.type === "agentForm" && route.mode === "edit") {
      return `#agent/${encodeURIComponent(route.key)}/edit`;
    }
    if (route.type === "agentForm" && route.mode === "clone") {
      return `#agent/${encodeURIComponent(route.key)}/clone`;
    }
    if (route.type === "agentForm" && route.mode === "create") {
      return `#project/${encodeURIComponent(route.projectKey)}/agent/new`;
    }
    if (route.type === "agentArchive") return `#agent/${encodeURIComponent(route.key)}/archive`;
    if (route.type === "agentAttachment") {
      return `#agent/${encodeURIComponent(route.key)}/attachment/${encodeURIComponent(route.attachmentId)}`;
    }
    if (route.type === "attachment") return `#attachment/${encodeURIComponent(route.id)}`;
    if (route.type === "projectDiff") {
      const params = new URLSearchParams();
      params.set("scope", normalizeDiffScope(route.scope));
      const backTo = backRouteValue(route.backTo);
      if (backTo) params.set("back_to", backTo);
      return `#project/${encodeURIComponent(route.key)}/diff?${params.toString()}`;
    }
    if (route.type === "projectForm") return `#project/${encodeURIComponent(route.key)}/edit`;
    if (route.type === "project") {
      return `#project/${encodeURIComponent(route.key)}${routeBackQuery(route)}`;
    }
    if (route.type === "guard") {
      return `#project/${encodeURIComponent(route.key)}/action/${encodeURIComponent(route.action)}`;
    }
    if (route.type === "scheduleForm" && route.mode === "create") {
      const params = new URLSearchParams();
      if (route.projectKey) params.set("project", route.projectKey);
      const query = params.toString();
      return `#schedule/new${query ? `?${query}` : ""}`;
    }
    if (route.type === "scheduleForm" && route.mode === "edit") return `#schedule/${encodeURIComponent(route.key)}/edit`;
    if (route.type === "scheduleMessage") return `#schedule/${encodeURIComponent(route.key)}/message`;
    if (route.type === "hiddenSettings") return "#settings/hidden";
    return `#${route.tab}`;
  }

  function routeBackQuery(route) {
    const value = backRouteValue(route.backTo);
    return value ? `?back_to=${encodeURIComponent(value)}` : "";
  }

  function backRouteValue(route) {
    if (route?.type === "agent" && route.key) return `agent/${route.key}`;
    return "";
  }

  function routeStateKey(route) {
    if (route.type === "agent") return `agent:${route.key}`;
    if (route.type === "agentSummary") return `agent-summary:${route.key}:${route.summaryId || ""}`;
    if (route.type === "agentAttachment") return `agent-attachment:${route.key}:${route.attachmentId}`;
    if (route.type === "agentPullRequests") return `agent-pull-requests:${route.key}:${route.pullRequestId || ""}`;
    if (route.type === "attachment") return `attachment:${route.id}`;
    if (route.type === "agentForm" && route.mode === "create") return `agent-form:create:${route.projectKey}`;
    if (route.type === "agentForm" && route.mode === "edit") return `agent-form:edit:${route.key}`;
    if (route.type === "agentForm" && route.mode === "clone") return `agent-form:clone:${route.key}`;
    if (route.type === "agentArchive") return `agent-archive:${route.key}`;
    if (route.type === "projectForm") return `project-form:${route.key}`;
    if (route.type === "project") return `project:${route.key}`;
    if (route.type === "projectDiff") return `project-diff:${route.key}:${normalizeDiffScope(route.scope)}:${backRouteValue(route.backTo)}`;
    if (route.type === "guard") return `guard:${route.key}:${route.action}`;
    if (route.type === "scheduleForm" && route.mode === "create") return `schedule-form:create:${route.projectKey || ""}`;
    if (route.type === "scheduleForm" && route.mode === "edit") return `schedule-form:edit:${route.key}`;
    if (route.type === "scheduleMessage") return `schedule-message:${route.key}`;
    if (route.type === "hiddenSettings") return "settings:hidden";
    return `tab:${route.tab}`;
  }

  function shouldPreserveControl(control, active) {
    if (control.type === "file") return false;
    if (control === active) return true;
    if (control.type === "checkbox" || control.type === "radio") {
      return control.checked !== control.defaultChecked;
    }
    return control.value !== control.defaultValue;
  }

  function elementStateKey(element, index) {
    if (element.dataset.stateKey) return element.dataset.stateKey;
    if (element.id) return `id:${element.id}`;
    if (element.name) return `${element.tagName.toLowerCase()}:name:${element.name}`;
    if (element.tagName.toLowerCase() === "details") {
      const summary = element.querySelector("summary")?.textContent?.trim() || "";
      return `details:${summary}:${index}`;
    }
    return `${element.tagName.toLowerCase()}:${index}`;
  }

  function draftableTextControl(control, inputTypes) {
    if (control.disabled || control.type === "hidden") return false;
    if (control.tagName.toLowerCase() === "textarea") return true;
    if (control.tagName.toLowerCase() !== "input") return false;

    return inputTypes.has(String(control.type || "text").toLowerCase());
  }

  function controlState(control) {
    if (control.type === "checkbox" || control.type === "radio") {
      return { checked: control.checked };
    }
    return {
      value: control.value,
      selection: textSelectionFor(control),
      scroll: controlScrollFor(control),
    };
  }

  function restoreControlState(control, stored) {
    if (control.type === "checkbox" || control.type === "radio") {
      control.checked = !!stored.checked;
    } else if (Object.prototype.hasOwnProperty.call(stored, "value")) {
      control.value = stored.value;
      restoreTextSelection(control, stored.selection);
      restoreControlScroll(control, stored.scroll);
    }
  }

  function controlScrollFor(control) {
    return {
      top: Math.max(0, control.scrollTop || 0),
      left: Math.max(0, control.scrollLeft || 0),
    };
  }

  function restoreControlScroll(control, scroll) {
    if (!scroll) return;

    control.scrollTop = scroll.top || 0;
    control.scrollLeft = scroll.left || 0;
  }

  function textSelectionFor(control) {
    if (typeof control.selectionStart !== "number") return null;
    return {
      start: control.selectionStart,
      end: control.selectionEnd ?? control.selectionStart,
    };
  }

  function restoreTextSelection(control, selection) {
    if (!selection || typeof control.setSelectionRange !== "function") return;

    const start = Math.min(selection.start, control.value.length);
    const end = Math.min(selection.end, control.value.length);
    control.setSelectionRange(start, end);
  }

  function safeLocalStorageGet(key) {
    try {
      return localStorage.getItem(key);
    } catch (_error) {
      return null;
    }
  }

  function safeLocalStorageSet(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (_error) {
      return false;
    }
    return true;
  }

  function safeLocalStorageRemove(key) {
    try {
      localStorage.removeItem(key);
    } catch (_error) {
      return false;
    }
    return true;
  }

  function markdownHeadingSlug(text) {
    return String(text || "")
      .trim()
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[^\p{Letter}\p{Number}\s-]/gu, "")
      .replace(/\s/g, "-");
  }

  function decodeHashFragment(value) {
    try {
      return decodeURIComponent(value);
    } catch (_error) {
      return value;
    }
  }

  function attachmentId(attachment) {
    return String(attachment?.id || "").trim();
  }

  function attachmentKind(attachment) {
    const type = String(attachment?.type || "").trim().toLowerCase();
    if (type === "file" || type === "link") return type;

    const target = String(attachment?.url || attachment?.path || "").trim();
    if (/^https?:\/\//i.test(target)) return "link";

    const legacyKind = String(attachment?.kind || "").trim().toLowerCase();
    return legacyKind === "link" ? "link" : "file";
  }

  function attachmentKindLabel(kind) {
    if (kind === "file") return "file";
    return "link";
  }

  function attachmentHref(attachment) {
    const target = attachmentTarget(attachment);
    if (attachmentKind(attachment) !== "link") {
      const id = attachmentId(attachment);
      if (!id) return "";

      const agentKey = String(attachment?.agent_key || "").trim();
      return agentKey ? routeHash({ type: "agentAttachment", key: agentKey, attachmentId: id }) : routeHash({ type: "attachment", id });
    }

    return /^https?:\/\//i.test(target) ? target : "";
  }

  function attachmentTarget(attachment) {
    return String(attachmentKind(attachment) === "link" ? attachment?.url || "" : attachment?.path || attachment?.url || "").trim();
  }

  function attachmentTargetForMatch(attachment) {
    const direct = attachmentTarget(attachment);
    if (direct) return normalizeAttachmentTargetForMatch(direct);
    if (attachmentKind(attachment) === "link") {
      return normalizeAttachmentTargetForMatch(attachment?.path || attachment?.url || "");
    }
    return "";
  }

  function normalizeAttachmentTargetForMatch(value) {
    return String(value || "")
      .trim()
      .replace(/\/+$/, "");
  }

  function attachmentTargetsMatch(left, right) {
    const leftTarget = normalizeAttachmentTargetForMatch(left);
    const rightTarget = normalizeAttachmentTargetForMatch(right);
    if (!leftTarget || !rightTarget) return false;
    if (leftTarget === rightTarget) return true;

    const leftLower = leftTarget.toLowerCase();
    const rightLower = rightTarget.toLowerCase();
    if (leftLower === rightLower) return true;
    return leftLower.endsWith(`/${rightLower}`) || rightLower.endsWith(`/${leftLower}`);
  }

  function attachmentBlobPath(id, options = {}) {
    const path = `/attachments/${encodeURIComponent(id)}/blob`;
    return options.cacheBust ? `${path}?v=${Date.now()}` : path;
  }

  function attachmentContentVersion(attachment) {
    const timestamp = Date.parse(String(attachment?.content_mtime || ""));
    return Number.isNaN(timestamp) ? 0 : timestamp;
  }

  function attachmentTargetLabel(target) {
    if (!target) return "";

    try {
      const url = new URL(target);
      return `${url.host}${url.pathname}`.replace(/\/$/, "");
    } catch (_error) {
      return target;
    }
  }

  global.TychoRemoteHelpers = Object.freeze({
    agentActivityTimestamp,
    agentSortUsesProjectGroups,
    attachmentBlobPath,
    attachmentContentVersion,
    attachmentHref,
    attachmentId,
    attachmentKind,
    attachmentKindLabel,
    attachmentTarget,
    attachmentTargetForMatch,
    attachmentTargetLabel,
    attachmentTargetsMatch,
    backRouteValue,
    compareAgentsBySort,
    compareDisplayText,
    controlState,
    currentAgentSortOption,
    decodeHashFragment,
    draftableTextControl,
    elementStateKey,
    markdownHeadingSlug,
    normalizeAttachmentTargetForMatch,
    normalizeDiffScope,
    normalizeAgentSort,
    parseRoute,
    routeHash,
    routeStateKey,
    restoreControlState,
    restoreTextSelection,
    safeLocalStorageGet,
    safeLocalStorageRemove,
    safeLocalStorageSet,
    shouldPreserveControl,
    textSelectionFor,
  });
})(window);
