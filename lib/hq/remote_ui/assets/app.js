const TOP_TABS = ["now", "agents", "settings"];
const PROJECT_ACTIONS = ["deploy", "maintenance", "live"];
const BUILTIN_AGENT_HARNESSES = ["codex", "claude"];
const DEFAULT_REFRESH_INTERVALS = {
  runningAgentMs: 2_000,
  activeAgentMs: 3_000,
  idleMs: 10_000,
  hiddenMs: 30_000,
};
const PROMPT_ATTACHMENT_LIMITS = {
  maxFiles: 5,
  maxBytes: 10 * 1024 * 1024,
  accept: "image/*,video/*,audio/*,.txt,.md,.markdown,.pdf,.rtf,.doc,.docx,.json,.jsonl,.csv,.tsv,.log",
};
const CLIPBOARD_ATTACHMENT_EXTENSIONS = {
  "application/json": ".json",
  "application/pdf": ".pdf",
  "application/rtf": ".rtf",
  "audio/mp4": ".m4a",
  "audio/mpeg": ".mp3",
  "audio/ogg": ".ogg",
  "audio/wav": ".wav",
  "image/gif": ".gif",
  "image/heic": ".heic",
  "image/jpeg": ".jpg",
  "image/png": ".png",
  "image/svg+xml": ".svg",
  "image/webp": ".webp",
  "text/markdown": ".md",
  "text/plain": ".txt",
  "video/mp4": ".mp4",
  "video/quicktime": ".mov",
  "video/webm": ".webm",
};
const FORM_DRAFT_STORAGE_PREFIX = "hq.remote.formDraft.";
const FORM_DRAFT_TEXT_INPUT_TYPES = new Set(["text", "search", "email", "url", "tel", "password", "number"]);
const MARKDOWN_SCRIPT_URLS = {
  dompurify: "https://cdn.jsdelivr.net/npm/dompurify@3.2.7/dist/purify.min.js",
  marked: "https://cdn.jsdelivr.net/npm/marked@18.0.3/lib/marked.umd.js",
};

const ICONS = {
  archive: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <rect width="20" height="5" x="2" y="3" rx="1"></rect>
      <path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"></path>
      <path d="M10 12h4"></path>
    </svg>
  `,
  activity: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M22 12h-4l-3 9L9 3l-3 9H2"></path>
    </svg>
  `,
  badgeQuestionMark: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"></path>
      <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"></path>
      <line x1="12" x2="12.01" y1="17" y2="17"></line>
    </svg>
  `,
  calendarCheck2: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M8 2v4"></path>
      <path d="M16 2v4"></path>
      <path d="M21 14V6a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h8"></path>
      <path d="M3 10h18"></path>
      <path d="m16 20 2 2 4-4"></path>
    </svg>
  `,
  chevronDown: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m6 9 6 6 6-6"></path>
    </svg>
  `,
  arrowLeft: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m12 19-7-7 7-7"></path>
      <path d="M19 12H5"></path>
    </svg>
  `,
  check: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M20 6 9 17l-5-5"></path>
    </svg>
  `,
  copy: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <rect width="14" height="14" x="8" y="8" rx="2"></rect>
      <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path>
    </svg>
  `,
  copyPlus: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <rect width="14" height="14" x="8" y="8" rx="2"></rect>
      <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path>
      <path d="M15 12v6"></path>
      <path d="M12 15h6"></path>
    </svg>
  `,
  code: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m16 18 6-6-6-6"></path>
      <path d="m8 6-6 6 6 6"></path>
    </svg>
  `,
  botMessageSquare: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12 6V2H8"></path>
      <path d="M15 11v2"></path>
      <path d="M2 12h2"></path>
      <path d="M20 12h2"></path>
      <path d="M20 16a2 2 0 0 1-2 2H8.828a2 2 0 0 0-1.414.586l-2.202 2.202A.71.71 0 0 1 4 20.286V8a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2z"></path>
      <path d="M9 11v2"></path>
    </svg>
  `,
  gitCommit: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <circle cx="12" cy="12" r="3"></circle>
      <path d="M3 12h6"></path>
      <path d="M15 12h6"></path>
    </svg>
  `,
  fileText: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"></path>
      <path d="M14 2v4a2 2 0 0 0 2 2h4"></path>
      <path d="M10 9H8"></path>
      <path d="M16 13H8"></path>
      <path d="M16 17H8"></path>
    </svg>
  `,
  home: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"></path>
      <path d="M9 22V12h6v10"></path>
    </svg>
  `,
  info: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <circle cx="12" cy="12" r="10"></circle>
      <path d="M12 16v-4"></path>
      <path d="M12 8h.01"></path>
    </svg>
  `,
  hourglass: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M5 22h14"></path>
      <path d="M5 2h14"></path>
      <path d="M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22"></path>
      <path d="M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"></path>
    </svg>
  `,
  image: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <rect width="18" height="18" x="3" y="3" rx="2"></rect>
      <circle cx="9" cy="9" r="2"></circle>
      <path d="m21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21"></path>
    </svg>
  `,
  eye: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"></path>
      <circle cx="12" cy="12" r="3"></circle>
    </svg>
  `,
  eyeOff: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"></path>
      <path d="M14.084 14.158a3 3 0 0 1-4.242-4.242"></path>
      <path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"></path>
      <path d="m2 2 20 20"></path>
    </svg>
  `,
  link: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"></path>
      <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"></path>
    </svg>
  `,
  paperclip: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m16 6-8.414 8.586a2 2 0 0 0 2.829 2.829l8.414-8.586a4 4 0 1 0-5.657-5.657l-8.379 8.551a6 6 0 1 0 8.485 8.485l8.379-8.551"></path>
    </svg>
  `,
  upload: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
      <polyline points="17 8 12 3 7 8"></polyline>
      <line x1="12" x2="12" y1="3" y2="15"></line>
    </svg>
  `,
  loaderPinwheel: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M22 12a1 1 0 0 1-10 0 1 1 0 0 0-10 0"></path>
      <path d="M7 20.7a1 1 0 1 1 5-8.7 1 1 0 1 0 5-8.6"></path>
      <path d="M7 3.3a1 1 0 1 1 5 8.6 1 1 0 1 0 5 8.6"></path>
      <circle cx="12" cy="12" r="10"></circle>
    </svg>
  `,
  folder: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9l-.81-1.2A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"></path>
    </svg>
  `,
  folders: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M20 17a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3.9a2 2 0 0 1-1.69-.9l-.81-1.2A2 2 0 0 0 11.93 4H8a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2Z"></path>
      <path d="M2 8v11a2 2 0 0 0 2 2h14"></path>
    </svg>
  `,
  hammer: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m15 12-9.373 9.373a1 1 0 0 1-3.001-3L12 9"></path>
      <path d="m18 15 4-4"></path>
      <path d="m21.5 11.5-1.914-1.914A2 2 0 0 1 19 8.172v-.344a2 2 0 0 0-.586-1.414l-1.657-1.657A6 6 0 0 0 12.516 3H9l1.243 1.243A6 6 0 0 1 12 8.485V10l2 2h1.172a2 2 0 0 1 1.414.586L18.5 14.5"></path>
    </svg>
  `,
  pencil: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12 20h9"></path>
      <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"></path>
    </svg>
  `,
  plus: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M5 12h14"></path>
      <path d="M12 5v14"></path>
    </svg>
  `,
  rocket: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M4.5 16.5c-1.5 1.3-2 3.5-2 3.5s2.2-.5 3.5-2c.7-.8.7-2 0-2.7a2 2 0 0 0-1.5-.8z"></path>
      <path d="m9 15-3-3a22 22 0 0 1 2-4.5A12 12 0 0 1 20 2s.5 6-5.5 12a22 22 0 0 1-4.5 2z"></path>
      <path d="M15 9h.01"></path>
    </svg>
  `,
  rotateCcw: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"></path>
      <path d="M3 3v5h5"></path>
    </svg>
  `,
  robot: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12 8V4H8"></path>
      <rect width="16" height="12" x="4" y="8" rx="2"></rect>
      <path d="M2 14h2"></path>
      <path d="M20 14h2"></path>
      <path d="M9 13v2"></path>
      <path d="M15 13v2"></path>
    </svg>
  `,
  search: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <circle cx="11" cy="11" r="8"></circle>
      <path d="m21 21-4.3-4.3"></path>
    </svg>
  `,
  scanText: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M3 7V5a2 2 0 0 1 2-2h2"></path>
      <path d="M17 3h2a2 2 0 0 1 2 2v2"></path>
      <path d="M21 17v2a2 2 0 0 1-2 2h-2"></path>
      <path d="M7 21H5a2 2 0 0 1-2-2v-2"></path>
      <path d="M7 8h8"></path>
      <path d="M7 12h10"></path>
      <path d="M7 16h6"></path>
    </svg>
  `,
  settings: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"></path>
      <circle cx="12" cy="12" r="3"></circle>
    </svg>
  `,
  slash: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M22 2 2 22"></path>
    </svg>
  `,
  squareSlash: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <rect width="18" height="18" x="3" y="3" rx="2"></rect>
      <path d="m9 15 6-6"></path>
    </svg>
  `,
  squareUserRound: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M18 21a6 6 0 0 0-12 0"></path>
      <circle cx="12" cy="11" r="4"></circle>
      <rect width="18" height="18" x="3" y="3" rx="2"></rect>
    </svg>
  `,
  trash2: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M3 6h18"></path>
      <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path>
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"></path>
      <path d="M10 11v6"></path>
      <path d="M14 11v6"></path>
    </svg>
  `,
  x: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M18 6 6 18"></path>
      <path d="m6 6 12 12"></path>
    </svg>
  `,
};

const state = {
  agents: [],
  projects: [],
  schedules: [],
  scheduleDaemon: null,
  projectDetails: {},
  hiddenSettings: null,
  setup: null,
  conversations: {},
  attachmentDetails: {},
  attachmentImageUrls: {},
  attachmentImageErrors: {},
  pendingPromptAttachments: {},
  openedAttachmentLinks: {},
  conversationTailMarkers: {},
  skills: {},
  preflights: {},
  filters: {
    agents: "",
  },
  bulkArchiveMode: false,
  bulkArchiveSelection: new Set(),
  failureCount: 0,
  timer: null,
  lastUpdatedAt: null,
  connection: "Connecting",
  headerSubtitle: "Connecting",
  headerSubtitleIcon: "folder",
  refreshing: false,
  loadingConversation: false,
  lastScrollY: 0,
  navHidden: false,
  scrollTicking: false,
  openSummaryAfterAutoScroll: false,
  preserveSummaryOnAutoScroll: false,
  renderedRouteKey: null,
  renderedViewHtml: "",
  agentSettingsOpen: false,
  unreadPanelOpen: false,
  readMarkTimer: null,
};

const markdownParser = {
  promise: null,
  failed: false,
};

const els = {
  header: document.querySelector(".app-header"),
  title: document.getElementById("screen-title"),
  subtitle: document.getElementById("screen-subtitle"),
  mark: document.getElementById("header-mark"),
  back: document.getElementById("back-button"),
  agentProject: document.getElementById("agent-project-button"),
  agentSettings: document.getElementById("agent-settings-button"),
  agentSettingsPanel: document.getElementById("agent-settings-panel"),
  unreadPanel: document.getElementById("unread-agents-panel"),
  authPanel: document.getElementById("auth-panel"),
  tokenInput: document.getElementById("token-input"),
  saveToken: document.getElementById("save-token-button"),
  view: document.getElementById("view"),
  nav: document.getElementById("bottom-nav"),
};

syncPlatformClasses();

function syncPlatformClasses() {
  const standalone = window.navigator.standalone === true ||
    window.matchMedia?.("(display-mode: standalone)")?.matches;
  const platform = window.navigator.platform || "";
  const iPadLike = platform === "iPad" || (platform === "MacIntel" && window.navigator.maxTouchPoints > 1);
  document.documentElement.classList.toggle("ipad-standalone", Boolean(standalone && iPadLike));
}

function token() {
  return localStorage.getItem("hq.remote.token") || "";
}

function setToken(value) {
  localStorage.setItem("hq.remote.token", value.trim());
}

function apiHeaders() {
  const headers = { "Accept": "application/json" };
  const savedToken = token();
  if (savedToken) headers["Authorization"] = `Bearer ${savedToken}`;
  return headers;
}

async function apiGet(path) {
  const response = await fetch(path, { headers: apiHeaders() });
  return readJson(response);
}

async function apiBlob(path) {
  const response = await fetch(path, { headers: { ...apiHeaders(), "Accept": "*/*" } });
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    const message = data.error || `${response.status} ${response.statusText}`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return response.blob();
}

async function apiPost(path, body = {}) {
  const response = await fetch(path, {
    method: "POST",
    headers: { ...apiHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return readJson(response);
}

async function apiPatch(path, body = {}) {
  const response = await fetch(path, {
    method: "PATCH",
    headers: { ...apiHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return readJson(response);
}

async function apiPut(path, body = {}) {
  const response = await fetch(path, {
    method: "PUT",
    headers: { ...apiHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return readJson(response);
}

async function apiDelete(path, body = {}) {
  const response = await fetch(path, {
    method: "DELETE",
    headers: { ...apiHeaders(), "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return readJson(response);
}

async function readJson(response) {
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const message = data.error || `${response.status} ${response.statusText}`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return data;
}

function parseRoute() {
  const hash = location.hash.replace(/^#/, "");
  const parts = hash.split("/").filter(Boolean).map(decodeURIComponent);
  if (parts[0] === "agent" && parts[1] && parts[2] === "edit") {
    return { type: "agentForm", mode: "edit", key: parts[1] };
  }
  if (parts[0] === "agent" && parts[1] && parts[2] === "clone") {
    return { type: "agentForm", mode: "clone", key: parts[1] };
  }
  if (parts[0] === "agent" && parts[1] && parts[2] === "archive") {
    return { type: "agentArchive", key: parts[1] };
  }
  if (parts[0] === "agent" && parts[1] && parts[2] === "attachment" && parts[3]) {
    return { type: "agentAttachment", key: parts[1], attachmentId: parts[3] };
  }
  if (parts[0] === "agent" && parts[1]) return { type: "agent", key: parts[1] };
  if (parts[0] === "attachment" && parts[1]) return { type: "attachment", id: parts[1] };
  if (parts[0] === "project" && parts[1] && parts[2] === "agent" && parts[3] === "new") {
    return { type: "agentForm", mode: "create", projectKey: parts[1] };
  }
  if (parts[0] === "project" && parts[1] && parts[2] === "action" && parts[3]) {
    return { type: "guard", key: parts[1], action: parts[3] };
  }
  if (parts[0] === "project" && parts[1]) return { type: "project", key: parts[1] };
  if ((parts[0] === "settings" || parts[0] === "setup") && parts[1] === "hidden") return { type: "hiddenSettings" };
  if (parts[0] === "setup") return { type: "tab", tab: "settings" };
  if (parts[0] === "search" || parts[0] === "projects") return { type: "tab", tab: "agents" };
  if (TOP_TABS.includes(parts[0])) return { type: "tab", tab: parts[0] };
  return { type: "tab", tab: "now" };
}

function routeHash(route) {
  if (route.type === "agent") return `#agent/${encodeURIComponent(route.key)}`;
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
  if (route.type === "project") return `#project/${encodeURIComponent(route.key)}`;
  if (route.type === "guard") {
    return `#project/${encodeURIComponent(route.key)}/action/${encodeURIComponent(route.action)}`;
  }
  if (route.type === "hiddenSettings") return "#settings/hidden";
  return `#${route.tab}`;
}

function navigate(route) {
  const hash = routeHash(route);
  if (location.hash === hash) {
    render();
  } else {
    location.hash = hash;
  }
}

function activateNavTab(tab) {
  const route = parseRoute();
  if (route.type === "tab" && route.tab === tab) {
    const hash = routeHash({ type: "tab", tab });
    if (location.hash !== hash) history.replaceState(null, "", hash);
    scrollPageToTop();
    return;
  }

  navigate({ type: "tab", tab });
}

function scrollPageToTop() {
  const root = document.scrollingElement || document.documentElement;
  root.scrollTo({ top: 0, left: 0, behavior: "auto" });
  state.lastScrollY = 0;
  showNav();
}

function currentTopTab(route) {
  if (route.type === "tab") return route.tab;
  if (route.type === "project" || route.type === "guard") return "agents";
  if (route.type === "agentForm") return "agents";
  if (route.type === "agent" || route.type === "agentAttachment" || route.type === "agentArchive" || route.type === "attachment") return "agents";
  if (route.type === "hiddenSettings") return "settings";
  return "now";
}

function agentShellRoute(route) {
  return route.type === "agent" || route.type === "agentAttachment";
}

function pollDelay() {
  const intervals = refreshIntervals();
  if (document.hidden) return intervals.hiddenMs;
  if (state.failureCount > 0) return Math.min(3_000 * (2 ** state.failureCount), 20_000);
  const route = parseRoute();
  const routeAgent = route.type === "agent" || route.type === "agentAttachment" ? findAgent(route.key) : null;
  if (routeAgent?.running) return intervals.runningAgentMs;
  if (state.agents.some((agent) => agent.running)) return intervals.activeAgentMs;
  return intervals.idleMs;
}

function refreshIntervals() {
  const configured = state.setup?.refresh_intervals || {};
  return {
    runningAgentMs: configured.running_agent_ms || DEFAULT_REFRESH_INTERVALS.runningAgentMs,
    activeAgentMs: configured.active_agent_ms || DEFAULT_REFRESH_INTERVALS.activeAgentMs,
    idleMs: configured.idle_ms || DEFAULT_REFRESH_INTERVALS.idleMs,
    hiddenMs: configured.hidden_ms || DEFAULT_REFRESH_INTERVALS.hiddenMs,
  };
}

function schedule(ms = pollDelay()) {
  clearTimeout(state.timer);
  state.timer = setTimeout(refresh, ms);
}

async function refresh(options = {}) {
  clearTimeout(state.timer);
  if (document.hidden && !options.force) {
    schedule();
    return;
  }

  try {
    setConnection("Refreshing");
    const [agentsData, projectsData, setupData, schedulesData] = await Promise.all([
      apiGet("/agents"),
      apiGet("/projects"),
      apiGet("/setup"),
      apiGet("/schedules"),
    ]);
    const nextAgents = agentsData.agents || [];
    if (shouldOpenSummaryForSucceededAgent(state.agents, nextAgents)) {
      state.openSummaryAfterAutoScroll = true;
    }
    state.agents = nextAgents;
    syncBulkArchiveSelection();
    state.projects = projectsData.projects || [];
    state.setup = setupData.setup || null;
    state.schedules = schedulesData.schedules || [];
    state.scheduleDaemon = schedulesData.daemon || null;
    state.lastUpdatedAt = new Date();
    state.failureCount = 0;
    els.authPanel.classList.add("hidden");
    await ensureRouteData(options);
    setConnection(refreshedText());
    render();
  } catch (error) {
    state.failureCount += 1;
    if (error.status === 401) {
      setConnection("Token required");
      els.authPanel.classList.remove("hidden");
    } else {
      setConnection(`Offline: ${error.message}`);
    }
    render();
  } finally {
    schedule();
  }
}

async function ensureRouteData(options = {}) {
  const route = parseRoute();
  if (route.type === "agent" || route.type === "agentAttachment") {
    const agent = findAgent(route.key);
    if (agent) {
      await Promise.all([
        ensureConversation(agent, options.forceConversation),
        ensureSkills(agent),
        ensureProject(agent.project_key),
      ]);
    }
  }
  if (route.type === "agentAttachment") {
    await ensureAttachment(route.attachmentId, options.forceAttachment);
    await ensureAttachmentPreview(route.attachmentId, options.forceAttachment);
  }
  if (route.type === "agentForm" && route.mode === "create") {
    await ensureProject(route.projectKey, true);
  }
  if (route.type === "agentForm" && route.mode === "edit") {
    const agent = findAgent(route.key);
    if (agent) await ensureProject(agent.project_key, true);
  }
  if (route.type === "agentForm" && route.mode === "clone") {
    const agent = findAgent(route.key);
    if (agent) await ensureProject(agent.project_key, true);
  }
  if (route.type === "agentArchive") {
    const agent = findAgent(route.key);
    if (agent) await ensureProject(agent.project_key, true);
  }
  if (route.type === "attachment") {
    await ensureAttachment(route.id, options.forceAttachment);
    const attachment = state.attachmentDetails[route.id] || attachmentById(route.id);
    const agent = findAgent(attachment?.agent_key);
    if (agent) {
      await Promise.all([
        ensureConversation(agent, options.forceConversation),
        ensureSkills(agent),
        ensureProject(agent.project_key),
      ]);
    }
    await ensureAttachmentPreview(route.id, options.forceAttachment);
  }
  if (route.type === "project" || route.type === "guard") {
    await ensureProject(route.key, true);
  }
  if (route.type === "guard") {
    await ensurePreflight(route.key, route.action, options.forcePreflight);
  }
  if (route.type === "hiddenSettings") {
    await ensureHiddenSettings(options.forceHiddenSettings || options.force);
  }
}

async function ensureAttachmentPreview(id, force = false) {
  if (!id) return;

  const attachment = state.attachmentDetails[id] || attachmentById(id);
  if (attachmentKind(attachment) === "file" && attachmentFormat(attachment) === "image") {
    await ensureAttachmentImage(id, force);
  }
}

async function ensureProject(projectKey, force = false) {
  if (!force && state.projectDetails[projectKey]) return;
  const data = await apiGet(`/projects/${encodeURIComponent(projectKey)}`);
  if (data.project) state.projectDetails[projectKey] = data.project;
}

async function ensureConversation(agent, force = false) {
  const cached = state.conversations[agent.key];
  if (state.loadingConversation) return;
  if (!force && cached && cached.revision === agent.revision) return;

  state.loadingConversation = true;
  try {
    const data = await apiGet(`/agents/${encodeURIComponent(agent.key)}/conversation`);
    state.conversations[agent.key] = {
      revision: agent.revision,
      blocks: data.conversation || [],
    };
  } finally {
    state.loadingConversation = false;
  }
}

async function markAgentReading(agent) {
  if (!agent?.unread) return;

  const data = await apiPut(`/agents/${encodeURIComponent(agent.key)}/reading`);
  if (data.agent) upsertAgent(data.agent);
}

async function ensureSkills(agent) {
  const key = skillKey(agent.project_key, agent.agent);
  if (state.skills[key]) return;
  const data = await apiGet(`/projects/${encodeURIComponent(agent.project_key)}/skills/${encodeURIComponent(agent.agent)}`);
  state.skills[key] = data.skills || [];
}

async function ensurePreflight(projectKey, action, force = false) {
  const key = preflightKey(projectKey, action);
  if (!force && state.preflights[key]) return;
  const data = await apiGet(`/projects/${encodeURIComponent(projectKey)}/actions/${encodeURIComponent(action)}`);
  state.preflights[key] = data;
}

async function ensureHiddenSettings(force = false) {
  if (!force && state.hiddenSettings) return;
  const data = await apiGet("/settings/hidden");
  state.hiddenSettings = data.hidden || null;
}

async function ensureAttachment(id, force = false) {
  if (!id) return;
  if (!force && Object.prototype.hasOwnProperty.call(state.attachmentDetails, id)) return;

  try {
    const data = await apiGet(`/attachments/${encodeURIComponent(id)}`);
    state.attachmentDetails[id] = data.attachment || null;
  } catch (error) {
    if (error.status !== 404) throw error;
    state.attachmentDetails[id] = null;
  }
}

async function ensureAttachmentImage(id, force = false) {
  if (!id) return;
  if (!force && state.attachmentImageUrls[id]) return;
  if (force) revokeAttachmentImage(id);

  delete state.attachmentImageErrors[id];
  try {
    const blob = await apiBlob(attachmentBlobPath(id, { cacheBust: force }));
    state.attachmentImageUrls[id] = URL.createObjectURL(blob);
  } catch (error) {
    state.attachmentImageErrors[id] = error.message;
  }
}

function revokeAttachmentImage(id) {
  const current = state.attachmentImageUrls[id];
  if (current) URL.revokeObjectURL(current);
  delete state.attachmentImageUrls[id];
}

function render() {
  const route = parseRoute();
  const onboarding = onboardingActive();
  const subpage = route.type !== "tab";
  if (route.type !== "agent") cancelAgentReading();
  els.back.classList.toggle("hidden", !subpage);
  els.header.classList.toggle("hidden", onboarding);
  els.nav.classList.toggle("hidden", subpage || onboarding);
  els.view.classList.toggle("no-nav", subpage || onboarding);
  els.view.classList.toggle("onboarding-content", onboarding);
  els.view.classList.toggle("detail-page", subpage && !onboarding);
  els.view.classList.toggle("agent-detail", !onboarding && (route.type === "agent" || route.type === "agentAttachment"));
  els.header.classList.toggle("detail-header", subpage && !onboarding);
  els.header.classList.remove("header-hidden");
  if (route.type !== "agent" && route.type !== "agentAttachment") setAgentSettings(null);
  syncDetailHeaderLayout();
  if (onboarding) {
    setNavHidden(false);
    renderOnboarding();
    return;
  }
  if (subpage) {
    setNavHidden(false);
  } else if (window.scrollY < 80) {
    setNavHidden(false);
  }
  setActiveNav(currentTopTab(route));

  if (route.type === "agent") {
    if (state.renderedRouteKey !== routeStateKey(route)) state.openSummaryAfterAutoScroll = true;
    const shouldScrollConversation = shouldAutoScrollAgentConversation(route.key);
    renderAgent(route.key);
    if (shouldScrollConversation) queueAgentConversationBottomScroll();
  } else if (route.type === "agentAttachment") {
    state.openSummaryAfterAutoScroll = false;
    renderAgent(route.key, { attachmentId: route.attachmentId });
  } else if (route.type === "attachment") {
    state.openSummaryAfterAutoScroll = false;
    const attachment = state.attachmentDetails[route.id] || attachmentById(route.id);
    if (attachment?.agent_key && findAgent(attachment.agent_key)) {
      els.view.classList.add("agent-detail");
      renderAgent(attachment.agent_key, { attachmentId: route.id, legacyAttachmentRoute: true });
    } else {
      renderAttachmentViewer(route.id);
    }
  } else if (route.type === "project") {
    state.openSummaryAfterAutoScroll = false;
    renderProject(route.key);
  } else if (route.type === "agentForm") {
    state.openSummaryAfterAutoScroll = false;
    renderAgentForm(route);
  } else if (route.type === "agentArchive") {
    state.openSummaryAfterAutoScroll = false;
    renderAgentArchive(route.key);
  } else if (route.type === "guard") {
    state.openSummaryAfterAutoScroll = false;
    renderGuardedAction(route.key, route.action);
  } else if (route.type === "hiddenSettings") {
    state.openSummaryAfterAutoScroll = false;
    renderHiddenSettings();
  } else if (route.tab === "agents") {
    state.openSummaryAfterAutoScroll = false;
    renderAgents();
  } else if (route.tab === "settings") {
    state.openSummaryAfterAutoScroll = false;
    renderSetup();
  } else {
    state.openSummaryAfterAutoScroll = false;
    renderNow();
  }
}

function replaceView(html) {
  const routeKey = routeStateKey(parseRoute());
  const sameRoute = state.renderedRouteKey === routeKey;
  if (sameRoute && state.renderedViewHtml === html) {
    syncViewControls();
    syncAgentDockLayout();
    return;
  }

  const snapshot = sameRoute ? captureViewState() : null;
  els.view.innerHTML = html;
  state.renderedRouteKey = routeKey;
  state.renderedViewHtml = html;
  syncMarkdownHeadingAnchors();
  restoreFormDrafts();
  restoreViewState(snapshot);
  syncViewControls();
  syncAgentDockLayout();
}

function routeStateKey(route) {
  if (route.type === "agent") return `agent:${route.key}`;
  if (route.type === "agentAttachment") return `agent-attachment:${route.key}:${route.attachmentId}`;
  if (route.type === "attachment") return `attachment:${route.id}`;
  if (route.type === "agentForm" && route.mode === "create") return `agent-form:create:${route.projectKey}`;
  if (route.type === "agentForm" && route.mode === "edit") return `agent-form:edit:${route.key}`;
  if (route.type === "agentForm" && route.mode === "clone") return `agent-form:clone:${route.key}`;
  if (route.type === "agentArchive") return `agent-archive:${route.key}`;
  if (route.type === "project") return `project:${route.key}`;
  if (route.type === "guard") return `guard:${route.key}:${route.action}`;
  if (route.type === "hiddenSettings") return "settings:hidden";
  return `tab:${route.tab}`;
}

function captureViewState() {
  const active = document.activeElement;
  const snapshot = {
    activeKey: null,
    activeSelection: null,
    controls: {},
    details: {},
    openElements: {},
    scrollContainers: {},
  };

  els.view.querySelectorAll("input, textarea, select").forEach((control, index) => {
    const key = elementStateKey(control, index);
    if (control === active) {
      snapshot.activeKey = key;
      snapshot.activeSelection = textSelectionFor(control);
    }
    if (!shouldPreserveControl(control, active)) return;

    snapshot.controls[key] = controlState(control);
  });

  els.view.querySelectorAll("details").forEach((detail, index) => {
    snapshot.details[elementStateKey(detail, index)] = detail.open;
  });

  els.view.querySelectorAll("[data-preserve-open]").forEach((element, index) => {
    snapshot.openElements[elementStateKey(element, index)] = !element.classList.contains("hidden");
  });

  els.view.querySelectorAll("[data-preserve-scroll]").forEach((element, index) => {
    snapshot.scrollContainers[elementStateKey(element, index)] = {
      top: element.scrollTop,
      left: element.scrollLeft,
    };
  });

  return snapshot;
}

function restoreViewState(snapshot) {
  if (!snapshot) return;

  els.view.querySelectorAll("input, textarea, select").forEach((control, index) => {
    const key = elementStateKey(control, index);
    const stored = snapshot.controls[key];
    if (stored) restoreControlState(control, stored);
    if (snapshot.activeKey === key) {
      control.focus({ preventScroll: true });
      restoreTextSelection(control, snapshot.activeSelection);
    }
  });

  els.view.querySelectorAll("details").forEach((detail, index) => {
    const key = elementStateKey(detail, index);
    if (Object.prototype.hasOwnProperty.call(snapshot.details, key)) {
      detail.open = snapshot.details[key];
    }
  });

  els.view.querySelectorAll("[data-preserve-open]").forEach((element, index) => {
    const key = elementStateKey(element, index);
    if (Object.prototype.hasOwnProperty.call(snapshot.openElements, key)) {
      const open = snapshot.openElements[key];
      element.classList.toggle("hidden", !open);
      syncPreservedOpenState(element, open);
    }
  });

  els.view.querySelectorAll("[data-preserve-scroll]").forEach((element, index) => {
    const stored = snapshot.scrollContainers[elementStateKey(element, index)];
    if (!stored) return;

    element.scrollTop = stored.top || 0;
    element.scrollLeft = stored.left || 0;
  });
}

function syncPreservedOpenState(element, open) {
  if (element.matches("[data-attachment-flyout]")) {
    document.querySelector("[data-toggle-attachments]")?.setAttribute("aria-expanded", open ? "true" : "false");
  } else if (element.matches("[data-skill-flyout]")) {
    document.querySelector("[data-toggle-skills]")?.setAttribute("aria-expanded", open ? "true" : "false");
  } else if (element.matches("[data-agent-summary]")) {
    document.querySelector("[data-toggle-summary]")?.setAttribute("aria-expanded", open ? "true" : "false");
  }
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

function textFormControls(form) {
  return Array.from(form.querySelectorAll("input, textarea")).filter(draftableTextControl);
}

function draftableTextControl(control) {
  if (control.disabled || control.type === "hidden") return false;
  if (control.tagName.toLowerCase() === "textarea") return true;
  if (control.tagName.toLowerCase() !== "input") return false;

  return FORM_DRAFT_TEXT_INPUT_TYPES.has(String(control.type || "text").toLowerCase());
}

function formStateKey(form) {
  const formIndex = Array.from(els.view.querySelectorAll("form")).indexOf(form);
  const parts = [elementStateKey(form, formIndex)];
  if (form.dataset.mode) parts.push(`mode:${form.dataset.mode}`);
  if (form.dataset.projectKey) parts.push(`project:${form.dataset.projectKey}`);
  if (form.dataset.agentKey) parts.push(`agent:${form.dataset.agentKey}`);
  if (form.dataset.inquiryId) parts.push(`inquiry:${form.dataset.inquiryId}`);
  return parts.join("|");
}

function formDraftStorageKey(form) {
  return `${FORM_DRAFT_STORAGE_PREFIX}${formDraftRouteKey(form)}|${formStateKey(form)}`;
}

function formDraftRouteKey(form) {
  const agentKey = form?.dataset?.agentKey;
  if (agentKey && (form.id === "composer" || form.id === "inquiry-form")) return `agent:${agentKey}`;

  return routeStateKey(parseRoute());
}

function saveAgentShellFormDrafts() {
  els.view.querySelectorAll("#composer, #inquiry-form").forEach(saveFormDraft);
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

function saveFormDraft(form) {
  if (!form || !els.view.contains(form)) return;

  const controls = {};
  textFormControls(form).forEach((control, index) => {
    controls[elementStateKey(control, index)] = control.value;
  });

  if (!Object.keys(controls).length) return;
  const hasValue = Object.values(controls).some((value) => String(value || "").length > 0);
  if (!hasValue) {
    clearFormDraft(form);
    return;
  }

  safeLocalStorageSet(formDraftStorageKey(form), JSON.stringify({ controls }));
}

function restoreFormDrafts() {
  els.view.querySelectorAll("form").forEach((form) => {
    const raw = safeLocalStorageGet(formDraftStorageKey(form));
    if (!raw) return;

    let draft;
    try {
      draft = JSON.parse(raw);
    } catch (_error) {
      clearFormDraft(form);
      return;
    }

    if (!draft || typeof draft.controls !== "object") return;
    textFormControls(form).forEach((control, index) => {
      const key = elementStateKey(control, index);
      if (Object.prototype.hasOwnProperty.call(draft.controls, key)) {
        control.value = String(draft.controls[key] ?? "");
      }
    });
  });
}

function clearFormDraft(form) {
  if (!form) return;

  safeLocalStorageRemove(formDraftStorageKey(form));
}

function syncMarkdownHeadingAnchors() {
  els.view.querySelectorAll(".markdown-viewer").forEach((viewer) => {
    const seen = new Map();
    viewer.querySelectorAll("h1, h2, h3, h4, h5, h6").forEach((heading) => {
      if (heading.id) {
        seen.set(heading.id, (seen.get(heading.id) || 0) + 1);
        return;
      }

      const slug = markdownHeadingSlug(heading.textContent);
      if (!slug) return;

      const count = seen.get(slug) || 0;
      seen.set(slug, count + 1);
      heading.id = count ? `${slug}-${count}` : slug;
    });
  });
}

function markdownHeadingSlug(text) {
  return String(text || "")
    .trim()
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\p{Letter}\p{Number}\s-]/gu, "")
    .replace(/\s/g, "-");
}

function handleMarkdownAnchorClick(anchor, event) {
  const route = parseRoute();
  if (!["agent", "agentAttachment", "attachment"].includes(route.type)) return false;

  const href = String(anchor.getAttribute("href") || "");
  if (!href.startsWith("#") || href === "#") return false;

  event.preventDefault();
  history.replaceState(null, "", routeHash(route));

  const viewer = anchor.closest(".markdown-viewer");
  const targetId = decodeHashFragment(href.slice(1));
  const target = Array.from(viewer?.querySelectorAll("[id]") || []).find((element) => element.id === targetId);
  if (!target) return true;

  const headerHeight = els.header.getBoundingClientRect().height || 0;
  const top = Math.max(0, target.getBoundingClientRect().top + window.scrollY - headerHeight - 12);
  window.scrollTo({ top, behavior: "smooth" });
  return true;
}

function decodeHashFragment(value) {
  try {
    return decodeURIComponent(value);
  } catch (_error) {
    return value;
  }
}

function controlState(control) {
  if (control.type === "checkbox" || control.type === "radio") {
    return { checked: control.checked };
  }
  return {
    value: control.value,
    selection: textSelectionFor(control),
  };
}

function restoreControlState(control, stored) {
  if (control.type === "checkbox" || control.type === "radio") {
    control.checked = !!stored.checked;
  } else if (Object.prototype.hasOwnProperty.call(stored, "value")) {
    control.value = stored.value;
    restoreTextSelection(control, stored.selection);
  }
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

function syncViewControls() {
  const confirm = document.getElementById("confirm-action");
  const submit = document.querySelector("#guard-form button[type='submit']");
  if (confirm && submit) {
    submit.disabled = confirm.disabled || !confirm.checked;
  }
}

function syncAgentDockLayout() {
  const dock = els.view.querySelector("[data-agent-dock]");
  if (!dock) {
    els.view.style.removeProperty("--agent-dock-height");
    updateGoRecentVisibility();
    return;
  }

  els.view.style.setProperty("--agent-dock-height", `${Math.ceil(dock.getBoundingClientRect().height)}px`);
  updateGoRecentVisibility();
}

function updateGoRecentVisibility() {
  const button = els.view.querySelector("[data-go-recent]");
  if (!button) return;

  const root = document.scrollingElement || document.documentElement;
  const maxScroll = Math.max(0, root.scrollHeight - window.innerHeight);
  const atBottom = maxScroll <= 1 || maxScroll - window.scrollY <= 80;
  button.classList.toggle("hidden", atBottom);
}

function renderNow() {
  const waiting = state.agents.filter((agent) => agent.awaiting_input);
  const blocked = state.agents.filter((agent) => agent.blocked);
  const running = state.agents.filter((agent) => agent.running);
  const unread = state.agents.filter((agent) => agent.unread && !agent.awaiting_input && !agent.blocked && !agent.running);
  const scheduleSection = renderScheduleNowSection();
  setHeader("Needs attention", connectionText(), "HQ");

  if (waiting.length === 0 && blocked.length === 0 && running.length === 0 && unread.length === 0 && !scheduleSection) {
    replaceView(`
      <section class="summary-card attention">
        <p class="summary-text">Nothing to do, hooray!</p>
      </section>
    `);
    return;
  }

  const summary = waiting.length > 0
    ? `
      <section class="summary-card attention">
        <div class="big-number"><strong>${waiting.length}</strong><span>items waiting on you</span></div>
        <p class="summary-text">Answer paused agents first. Running work and project health stay visible below.</p>
        <button class="primary" type="button" data-first-waiting>Review first item</button>
      </section>
    `
    : "";
  const nowItems = [...waiting, ...blocked];
  const nowSection = nowItems.length > 0
    ? renderAgentSection("Now", "highest priority", nowItems, "No paused or blocked agents.")
    : "";
  const runningSection = running.length > 0
    ? renderAgentSection("Running", "background", running, "No running agents.")
    : "";
  const unreadSection = unread.length > 0
    ? renderAgentSection("Unread", "new activity", unread, "No unread agents.")
    : "";

  replaceView(`
    ${summary}
    ${scheduleSection}
    ${nowSection}
    ${unreadSection}
    ${runningSection}
  `);
}

function renderScheduleNowSection() {
  const daemon = state.scheduleDaemon || {};
  const schedules = state.schedules || [];
  if (!schedules.length && !daemon.status) return "";
  if (!schedules.length && daemon.status === "stopped") return "";

  const attention = attentionSchedules();
  const rows = attention.length ? attention : upcomingSchedules().slice(0, 4);
  const daemonStatus = daemon.status || "unknown";
  const daemonClass = scheduleDaemonClass(daemonStatus);
  const summaryClass = attention.length ? "need" : daemonClass;

  return `
    <section class="detail-card schedule-card">
      <div class="detail-card-body schedule-card-body">
        <details class="schedule-details" data-state-key="schedule-now-details">
          <summary class="schedule-summary-row">
            <span class="schedule-summary-grid">
              <span class="status-mark ${summaryClass}" aria-hidden="true">${iconSvg("calendarCheck2")}</span>
              <span class="schedule-summary-copy">
                <strong>Schedules</strong>
                <span>${escapeHtml(scheduleSummaryText(daemonStatus, schedules, attention, rows))}</span>
              </span>
            </span>
            <span class="schedule-disclosure" aria-hidden="true">${iconSvg("chevronDown")}</span>
          </summary>
          <div class="schedule-details-body">
            ${renderScheduleDaemonActions(daemon, schedules)}
            ${rows.length ? rows.map(renderScheduleRow).join("") : emptyRow("No schedules", "Create config/schedules.yml to add recurring agents.")}
          </div>
        </details>
      </div>
    </section>
  `;
}

function renderScheduleRow(schedule) {
  const className = scheduleStatusClass(schedule);
  const paused = schedule.paused || schedule.enabled === false;
  const toggleAction = paused ? "resume" : "pause";
  const toggleLabel = paused ? "Resume" : "Pause";
  const toggleIcon = paused ? "check" : "squareSlash";
  return `
    <div class="detail-row schedule-row">
      <span class="status-mark ${className}" aria-hidden="true">${iconSvg("calendarCheck2")}</span>
      <div><strong>${escapeHtml(schedule.name || schedule.key)}</strong><span>${escapeHtml(scheduleSubtext(schedule))}</span></div>
      <div class="schedule-row-end">
        <span class="pill ${className}">${escapeHtml(scheduleStatusLabel(schedule))}</span>
        <div class="compact-actions schedule-row-actions">
          <button class="inline-icon-button schedule-run-button" type="button" data-schedule-action="run" data-schedule-key="${escapeAttr(schedule.key)}" aria-label="Run schedule now" title="Run schedule now">${iconSvg("activity")}<span>Run now</span></button>
          <button class="inline-icon-button schedule-toggle-button" type="button" data-schedule-action="${toggleAction}" data-schedule-key="${escapeAttr(schedule.key)}" aria-label="${escapeAttr(toggleLabel)} schedule" title="${escapeAttr(toggleLabel)} schedule">${iconSvg(toggleIcon)}<span>${toggleLabel}</span></button>
        </div>
      </div>
    </div>
  `;
}

function scheduleSummaryText(daemonStatus, schedules, attention, rows) {
  const count = schedules.length;
  const status = daemonStatus || "unknown";
  if (!count) return status === "stopped" ? "stopped / no schedules" : `${status} / no schedules`;
  if (attention.length) {
    return `${status} / ${attention.length} need attention / ${count} configured`;
  }

  const next = rows[0]?.next_due_at ? `next ${timeShort(rows[0].next_due_at)}` : "next n/a";
  return `${status} / ${count} configured / ${next}`;
}

function renderScheduleDaemonActions(daemon, schedules) {
  const status = daemon?.status || "stopped";
  const hasSchedules = schedules.length > 0;
  if (["running", "stale", "untracked"].includes(status)) {
    return `
      <div class="compact-actions schedule-daemon-actions">
        <button class="inline-icon-button" type="button" data-scheduler-action="restart" data-confirm="Restart scheduler daemon?">${iconSvg("rotateCcw")}<span>Restart daemon</span></button>
        <button class="danger inline-icon-button" type="button" data-scheduler-action="stop" data-confirm="Stop scheduler daemon?">${iconSvg("x")}<span>Stop daemon</span></button>
      </div>
    `;
  }

  return `
    <div class="compact-actions schedule-daemon-actions">
      <button class="primary inline-icon-button" type="button" data-scheduler-action="start" ${hasSchedules ? "" : "disabled"}>${iconSvg("loaderPinwheel")}<span>Start daemon</span></button>
    </div>
  `;
}

function renderAgents() {
  const query = state.filters.agents.trim().toLowerCase();
  const groups = agentProjectGroups(query);
  const unread = state.agents.filter((agent) => agent.unread).length;
  setHeader("Agents", `${state.agents.length} managed / ${state.projects.length} projects / ${unread} unread`, "A");

  replaceView(`
    <div class="top-actions">
      <label class="search-box" for="agent-filter">
        <span class="nav-mark" aria-hidden="true">${iconSvg("search")}</span>
        <input id="agent-filter" type="search" value="${escapeAttr(state.filters.agents)}" placeholder="Filter agents and projects" aria-label="Filter agents and projects" data-filter="agents">
      </label>
      <button class="inline-icon-button" type="button" data-toggle-bulk-archive ${state.agents.length ? "" : "disabled"}>${iconSvg(state.bulkArchiveMode ? "x" : "archive")}<span>${state.bulkArchiveMode ? "Cancel" : "Select"}</span></button>
    </div>
    ${renderBulkArchiveBar()}
    ${groups.length ? groups.map((group) => renderAgentGroup(group.projectKey, group.agents)).join("") : renderAgentsEmpty(query)}
  `);
  focusFilterInput("agents", "agent-filter");
}

function renderBulkArchiveBar() {
  if (!state.bulkArchiveMode) return "";

  const selected = selectedBulkArchiveKeys();
  return `
    <section class="bulk-action-bar" aria-label="Bulk archive">
      <div>
        <strong>${selected.length} selected</strong>
        <span>${archiveableAgents().length} archiveable agents</span>
      </div>
      <div class="button-row">
        <button type="button" data-clear-bulk-archive ${selected.length ? "" : "disabled"}>Clear</button>
        <button class="danger inline-icon-button" type="button" data-run-bulk-archive ${selected.length ? "" : "disabled"}>${iconSvg("archive")}<span>Archive selected</span></button>
      </div>
    </section>
  `;
}

function renderAgentsEmpty(query) {
  if (query) return emptyState("No matches", "Try an agent name, project name, status, branch, or summary.");
  return emptyState("No projects configured", "Project setup still happens in the TUI because it needs local filesystem access.");
}

function onboardingActive() {
  if (!state.setup) return false;
  if (state.setup.onboarding?.active) return true;
  return state.projects.length === 0 && (state.setup.counts?.projects || 0) === 0;
}

function renderOnboarding() {
  const setup = state.setup || {};
  const welcomePath = setup.onboarding?.welcome_workspace_path || "~/.tycho/workspaces/welcome";
  const title = "Coding agent orchestrations using your own harness";
  const subtitle = "Each session with coding agent lives inside a project workspace.";
  setHeader(title, subtitle, "S");
  replaceView(`
    <section class="onboarding-page">
      <div class="onboarding-panel">
        <img class="onboarding-logo onboarding-logo-horizontal" src="/remote-logo-horizontal.png?v=${escapeAttr(document.documentElement.dataset.assetVersion || "")}" alt="">
        <h1>${escapeHtml(title)}</h1>
        <p>${escapeHtml(subtitle)}</p>
        <div class="onboarding-actions">
          <button class="primary inline-icon-button" type="button" data-create-welcome-sandbox>${iconSvg("folder")}<span>Create Welcome Sandbox</span></button>
        </div>
        <div class="onboarding-workspace">
          <span>Safe local workspace at</span>
          <code>${escapeHtml(welcomePath)}</code>
        </div>
        <p class="onboarding-hint">${iconSvg("info")}<span>To add a local project instead, open Tycho in the terminal and choose Add Local Project.</span></p>
      </div>
    </section>
  `);
}

function focusFilterInput(tab, inputId) {
  window.requestAnimationFrame(() => {
    const route = parseRoute();
    if (route.type !== "tab" || route.tab !== tab) return;

    const input = document.getElementById(inputId);
    if (!input) return;
    if (document.activeElement === input) return;

    input.focus({ preventScroll: true });
    const position = input.value.length;
    input.setSelectionRange(position, position);
  });
}

function renderSetup() {
  const setup = state.setup;
  setHeader("Settings", connectionText(), "S");
  if (!setup) {
    replaceView(emptyState("Settings unavailable", "Refresh to load Remote UI readiness."));
    return;
  }

  const displayUrl = setup.public_ui_url || setup.ui_url || location.href;
  replaceView(`
    <section class="summary-card">
      <div class="card-title">
        <strong>Remote UI ${setup.auth?.required ? "token protected" : "connected"}</strong>
        <span class="wrap-anywhere">${escapeHtml(displayUrl || "local browser")}</span>
      </div>
      <div class="chip-row">
        <span class="chip done">API ok</span>
        <span class="chip ${setup.tailscale?.available ? "info" : "detail"}">${setup.tailscale?.available ? "Tailscale" : "Local"}</span>
        <span class="chip ${setup.tailscale?.magic_dns ? "info" : "detail"}">${setup.tailscale?.magic_dns ? "MagicDNS" : "Direct URL"}</span>
        ${setup.auth?.warning ? `<span class="chip need">Token recommended</span>` : ""}
      </div>
      <div class="button-row">
        <button type="button" data-copy="${escapeAttr(displayUrl || "")}">Copy URL</button>
        <button class="primary" type="button" data-refresh>Recheck</button>
      </div>
    </section>
    ${renderPushSetup(setup)}
    <section class="detail-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Automation readiness</strong><span>${setup.harnesses?.length || 0} harnesses</span></div>
        ${(setup.harnesses || []).map((item) => `
          <div class="detail-row">
            <span class="status-mark ${item.ready ? "done" : "fail"}" aria-hidden="true">${statusIcon(item.ready)}</span>
            <div><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.detail)}</span></div>
            <span class="pill ${item.ready ? "done" : "fail"}">${item.ready ? "Ready" : "Missing"}</span>
          </div>
        `).join("")}
        <div class="section-label"><strong>Optional tools</strong><span>${setup.tools?.length || 0} tools</span></div>
        ${(setup.tools || []).map((item) => `
          <div class="detail-row">
            <span class="status-mark ${item.ready ? "done" : "fail"}" aria-hidden="true">${statusIcon(item.ready)}</span>
            <div><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(item.detail)}</span></div>
            <span class="pill ${item.ready ? "done" : "fail"}">${item.ready ? "Ready" : "Missing"}</span>
          </div>
        `).join("")}
        <div class="detail-row">
          <span class="status-mark ${setup.schema?.valid ? "done" : "fail"}" aria-hidden="true">${statusIcon(setup.schema?.valid)}</span>
          <div><strong>Result schema</strong><span class="wrap-anywhere">${escapeHtml(setup.schema?.path || "config/schemas/agent_result.json")}</span></div>
          <span class="pill ${setup.schema?.valid ? "done" : "fail"}">${setup.schema?.valid ? "Valid" : "Invalid"}</span>
        </div>
      </div>
    </section>
    <section class="detail-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Configuration</strong><span>local files</span></div>
        <div class="kv-grid">
          ${kv("Projects", `${setup.counts?.projects || 0} active`)}
          ${kv("Hidden", `${setup.counts?.hidden_projects || 0} projects`)}
          ${kv("Archived", `${setup.counts?.archived_projects || 0} archived`)}
          ${kv("Config", setup.config?.loaded ? "hq.yml loaded" : "not loaded")}
          ${kv("Prompts", `${setup.config?.prompt_template_count || 0} templates`)}
        </div>
        <div class="button-row">
          <button type="button" data-open-hidden-settings>Hidden projects</button>
          <button type="button" disabled>Open TUI setup</button>
        </div>
      </div>
    </section>
    <section class="notice">
      <strong>Safety defaults</strong>
      <p>${escapeHtml((setup.safety || []).join(" "))}</p>
    </section>
    <details class="detail-card">
      <summary>Logs and storage</summary>
      <div class="kv-grid">
        ${kv("Root", setup.logs?.root)}
        ${kv("Agent runs", setup.logs?.agent_runs)}
        ${kv("Agent logs", setup.logs?.agent_log_files)}
        ${kv("Action logs", setup.logs?.project_action_logs)}
      </div>
    </details>
    <details class="detail-card">
      <summary>Refresh and preferences</summary>
      <div class="kv-grid">
        ${kv("Running", `${setup.refresh_intervals?.running_agent_ms || 0}ms`)}
        ${kv("Idle", `${setup.refresh_intervals?.idle_ms || 0}ms`)}
        ${kv("Hidden", `${setup.refresh_intervals?.hidden_ms || 0}ms`)}
        ${kv("Auth", setup.auth?.status)}
      </div>
    </details>
    <section class="detail-card server-lifecycle-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Server lifecycle</strong><span>${setup.server?.restartable ? "restartable" : "unavailable"}</span></div>
        <div class="button-row">
          <button class="danger inline-icon-button restart-server-button" type="button" data-restart-server ${setup.server?.restartable ? "" : "disabled"}>${iconSvg("loaderPinwheel")}<span>Restart Remote</span></button>
        </div>
      </div>
    </section>
  `);
}

function renderHiddenSettings() {
  const settings = state.hiddenSettings;
  setHeader("Hidden", "Project visibility settings", "settings");
  if (!settings) {
    replaceView(emptyState("Loading hidden settings", "Fetching project visibility configuration."));
    return;
  }

  const groups = settings.groups || [];
  const projects = settings.projects || [];
  const counts = settings.counts || {};
  replaceView(`
    <section class="summary-card">
      <div class="card-title">
        <strong>Project visibility</strong>
        <span>${escapeHtml(`${counts.hidden_projects || 0} hidden projects / ${counts.hidden_agents || 0} hidden agents`)}</span>
      </div>
      <div class="chip-row">
        <span class="chip detail">${escapeHtml(`${counts.projects || 0} projects`)}</span>
        <span class="chip detail">${escapeHtml(`${counts.groups || 0} groups`)}</span>
        <span class="chip ${counts.hidden_groups ? "need" : "done"}">${escapeHtml(`${counts.hidden_groups || 0} hidden groups`)}</span>
      </div>
    </section>
    <section class="detail-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Groups</strong><span>${groups.length} configured or active</span></div>
        ${groups.length ? groups.map(renderHiddenGroupRow).join("") : emptyRow("No groups", "Project groups will appear here when configured.")}
      </div>
    </section>
    <section class="detail-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Projects</strong><span>${projects.length} total</span></div>
        ${projects.length ? projects.map(renderHiddenProjectRow).join("") : emptyRow("No projects", "Add projects in hq.yml before configuring visibility.")}
      </div>
    </section>
  `);
}

function renderHiddenGroupRow(group) {
  const statusClassName = group.hidden ? "need" : "done";
  return `
    <div class="detail-row">
      <span class="status-mark ${statusClassName}" aria-hidden="true">${iconSvg("folders")}</span>
      <div>
        <strong>${escapeHtml(group.name || "Ungrouped")}</strong>
        <span>${escapeHtml(`${group.project_count || 0} projects / ${group.hidden_project_count || 0} hidden / ${group.agent_count || 0} agents`)}</span>
      </div>
      ${hiddenSettingControl("group", group.name, group.hidden_config, `Group visibility for ${group.name || "Ungrouped"}`)}
    </div>
  `;
}

function renderHiddenProjectRow(project) {
  const statusClassName = project.hidden ? "need" : "done";
  const source = project.visibility_source || "default";
  const status = project.hidden ? "Hidden" : "Visible";
  return `
    <div class="detail-row">
      <span class="status-mark ${statusClassName}" aria-hidden="true">${iconSvg("folder")}</span>
      <div>
        <strong>${escapeHtml(project.name || project.key)}</strong>
        <span>${escapeHtml(`${status} by ${source} / ${project.group || "ungrouped"} / ${project.agent_count || 0} agents`)}</span>
      </div>
      ${hiddenSettingControl("project", project.key, project.hidden_config, `Project visibility for ${project.name || project.key}`)}
    </div>
  `;
}

function hiddenSettingControl(scope, key, currentValue, label) {
  return `
    <div class="hidden-toggle compact-actions" role="group" aria-label="${escapeAttr(label)}">
      ${hiddenSettingButton(scope, key, true, "Hidden", "eyeOff", "hidden-state", currentValue === true)}
      ${hiddenSettingButton(scope, key, null, "Inherit", "slash", "inherit-state", currentValue == null)}
      ${hiddenSettingButton(scope, key, false, "Visible", "eye", "visible-state", currentValue === false)}
    </div>
  `;
}

function hiddenSettingButton(scope, key, value, label, icon, stateName, active) {
  const encodedValue = value === null ? "inherit" : String(value);
  return `
    <button
      class="hidden-toggle-button ${escapeAttr(stateName)} ${active ? "active" : ""}"
      type="button"
      data-hidden-scope="${escapeAttr(scope)}"
      data-hidden-key="${escapeAttr(key || "")}"
      data-hidden-value="${escapeAttr(encodedValue)}"
      aria-label="${escapeAttr(label)}"
      aria-pressed="${active ? "true" : "false"}"
      title="${escapeAttr(label)}"
    >${iconSvg(icon)}<span class="sr-only">${escapeHtml(label)}</span></button>
  `;
}

function renderPushSetup(setup) {
  const push = setup.push || {};
  const support = pushSupport();
  const originWarning = pushOriginWarning();
  const configured = !!push.configured && !!push.public_key;
  const denied = "Notification" in window && Notification.permission === "denied";
  const enabledCount = push.subscription_count || 0;
  const canEnable = configured && support.supported && !denied;
  const statusClassName = canEnable ? "done" : denied ? "fail" : configured ? "info" : "fail";
  const status = !support.supported ? "Unsupported" : denied ? "Blocked" : configured ? "Ready" : "Missing keys";
  const detail = !support.supported
    ? support.detail
    : denied ? "Notification permission is blocked in this browser" : configured ? `${enabledCount} subscription${enabledCount === 1 ? "" : "s"}` : "VAPID keys are unavailable";

  return `
    <section class="detail-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Push notifications</strong><span>browser alerts</span></div>
        <div class="detail-row">
          <span class="status-mark ${statusClassName}" aria-hidden="true">${statusIcon(canEnable)}</span>
          <div><strong>${escapeHtml(status)}</strong><span>${escapeHtml(detail)}</span></div>
          <span class="pill ${statusClassName}">${escapeHtml(notificationPermissionLabel())}</span>
        </div>
        <div class="button-row form-actions">
          <button class="primary inline-icon-button" type="button" data-enable-push ${canEnable ? "" : "disabled"}>${iconSvg("check")}<span>Enable notifications</span></button>
          <button type="button" data-test-push ${canEnable && enabledCount > 0 ? "" : "disabled"}>Send test</button>
          <button type="button" data-disable-push ${support.supported ? "" : "disabled"}>Disable</button>
        </div>
        ${originWarning ? `<p class="field-hint">${escapeHtml(originWarning)}</p>` : ""}
      </div>
    </section>
  `;
}

function renderAgent(key, options = {}) {
  const agent = findAgent(key);
  if (!agent) {
    setAgentSettings(null);
    if (initialDataPending()) {
      setHeader("Loading agent", "Fetching remote state", "A");
      replaceView(emptyState("Loading agent", "Fetching the selected managed-agent session."));
      return;
    }

    setHeader("Agent not found", "It may have been archived.", "A");
    replaceView(emptyState("Agent not found", "Return to the Agents tab and choose an active session."));
    return;
  }

  const blocks = state.conversations[key]?.blocks || [];
  const skills = skillsForAgent(agent);
  const attachmentId = options.attachmentId || "";
  setHeader(agent.name || agent.key, agentHeaderLabel(agent), "A");
  setAgentSettings(agent);
  replaceView(`
    ${attachmentId ? renderAgentAttachmentView(agent, attachmentId) : renderAgentConversationView(agent, blocks)}
    <section class="agent-dock" data-agent-dock>
      <section class="agent-summary-panel" data-agent-summary data-preserve-open data-preserve-scroll data-state-key="agent-summary" aria-label="Summary">
        ${renderAgentSummaryContent(agent)}
      </section>
      ${agent.latest_inquiry ? renderInquiryForm(agent, { attachmentMode: Boolean(attachmentId) }) : renderAgentComposer(agent, skills, { attachmentMode: Boolean(attachmentId) })}
    </section>
  `);
  if (!attachmentId) scheduleAgentReading(agent);
}

function renderAgentSummaryContent(agent) {
  return renderMarkdown(agentSummaryText(agent), {
    viewerClassName: "markdown-viewer summary-markdown-viewer",
    fallbackClassName: "summary-markdown-fallback",
    emptyText: "No run summary yet.",
  });
}

function renderAgentConversationView(agent, blocks) {
  return `
    <div class="message-list">
      ${blocks.length ? renderConversationBlocks(blocks) : emptyState("No conversation yet", "Send a prompt to start or continue the agent.")}
    </div>
    <div data-conversation-recent aria-hidden="true"></div>
    ${renderAgentFloatingActions({ recent: true })}
  `;
}

function renderAgentAttachmentView(agent, attachmentId) {
  const attachment = attachmentDetail(attachmentId);
  const navigation = renderAttachmentNavigationDrawer(agent, attachmentId);
  let body;
  if (!attachment) {
    body = `
      <section class="agent-attachment-shell">
        ${navigation}
        ${emptyState("Attachment not found", "Choose another attachment from this agent.")}
      </section>
    `;
  } else if (attachment.agent_key && attachment.agent_key !== agent.key) {
    body = `
      <section class="agent-attachment-shell">
        ${navigation}
        ${emptyState("Attachment belongs to another agent", "Open the owning agent to inspect this attachment.")}
      </section>
    `;
  } else {
    body = `
      <section class="agent-attachment-shell" data-agent-attachment="${escapeAttr(attachmentId)}">
        ${navigation}
        ${attachmentViewerHtml(attachmentId, { embedded: true })}
      </section>
    `;
  }

  return `
    ${body}
    ${renderAgentFloatingActions()}
  `;
}

function renderAttachmentNavigationDrawer(agent, currentAttachmentId) {
  const attachments = agentAttachments(agent).filter((attachment) => attachmentId(attachment));
  if (attachments.length < 2) return "";

  const currentIndex = attachments.findIndex((attachment) => attachmentId(attachment) === currentAttachmentId);
  const current = currentIndex >= 0 ? attachments[currentIndex] : null;
  const currentTitle = String(current?.title || attachmentTarget(current) || "Choose an attachment").trim();
  const count = currentIndex >= 0 ? `${currentIndex + 1}/${attachments.length}` : String(attachments.length);

  return `
    <details class="attachment-nav-drawer" data-state-key="attachment-nav">
      <summary>
        <span class="attachment-nav-summary-main">
          ${iconSvg("paperclip")}
          <span class="attachment-nav-summary-text">
            <strong>Attachments</strong>
            <span>${escapeHtml(currentTitle)}</span>
          </span>
        </span>
        <span class="attachment-nav-count">${escapeHtml(count)}</span>
        <span class="attachment-nav-chevron" aria-hidden="true">${iconSvg("chevronDown")}</span>
      </summary>
      <nav class="attachment-nav-list" aria-label="Attachment navigation">
        ${attachments.map((attachment, index) => renderAttachmentNavigationItem(agent, attachment, currentAttachmentId, index)).join("")}
      </nav>
    </details>
  `;
}

function renderAttachmentNavigationItem(agent, attachment, currentAttachmentId, index) {
  const id = attachmentId(attachment);
  const active = id === currentAttachmentId;
  const kind = attachmentKind(attachment);
  const target = attachmentTarget(attachment);
  const title = String(attachment?.title || target || "Untitled attachment").trim();
  const meta = [attachmentKindLabel(kind), formatBytes(attachment?.size_bytes) || attachmentTargetLabel(target)].filter(Boolean).join(" / ");
  const href = routeHash({ type: "agentAttachment", key: agent.key, attachmentId: id });

  return `
    <a class="attachment-nav-item${active ? " active" : ""}" href="${escapeAttr(href)}" ${active ? 'aria-current="page"' : ""}>
      <span class="attachment-nav-index">${escapeHtml(String(index + 1))}</span>
      <span class="attachment-nav-icon" aria-hidden="true">${attachmentIcon(attachment)}</span>
      <span class="attachment-nav-copy">
        <strong>${escapeHtml(title || "Untitled attachment")}</strong>
        ${meta ? `<span>${escapeHtml(meta)}</span>` : ""}
      </span>
    </a>
  `;
}

function renderAgentFloatingActions(options = {}) {
  const recent = options.recent
    ? `<button class="agent-floating-pill go-recent-fab hidden" type="button" data-go-recent>Go to recent</button>`
    : "";
  return `
    <div class="agent-floating-actions" aria-label="Agent shortcuts">
      ${renderAgentSummaryToggle()}
      ${recent}
    </div>
  `;
}

function renderAgentSummaryToggle() {
  return `
    <button class="agent-floating-pill summary-fab" type="button" data-toggle-summary aria-expanded="true">
      ${iconSvg("scanText")}
      <span>Summary</span>
    </button>
  `;
}

function renderAgentComposer(agent, skills, options = {}) {
  return `
    <form id="composer" class="composer" data-agent-key="${escapeAttr(agent.key)}">
      <textarea id="prompt-input" rows="4" placeholder="Send a prompt" aria-label="Prompt" enterkeyhint="enter"></textarea>
      ${renderPromptAttachmentInput(agent)}
      ${renderPendingAttachments(agent)}
      ${renderAgentAttachments(agent)}
      <div class="skill-flyout hidden" data-skill-flyout ${agentIsRunning(agent) ? "" : 'data-preserve-open data-state-key="agent-skill-flyout"'}>
        <div class="skill-flyout-body">
          ${skills.length ? skills.map((skill) => `<button type="button" data-insert-skill="${escapeAttr(skill.name || skill["name"])}" data-agent-key="${escapeAttr(agent.key)}">${escapeHtml((agent.skill_trigger || "$") + (skill.name || skill["name"]))}</button>`).join("") : `<span class="meta-line">No skills discovered for this workspace.</span>`}
        </div>
      </div>
      <div class="send-row">
        <div class="send-tools">
          ${renderPromptAttachmentButton(agent)}
          ${renderAttachmentToggle(agent)}
          ${renderAgentViewToggle(agent, options)}
          <button class="skill-toggle-button" type="button" data-toggle-skills aria-label="Insert skill" title="Insert skill" ${agentIsRunning(agent) ? "disabled" : ""}>${iconSvg("squareSlash")}</button>
        </div>
        <div class="send-actions">
          ${agentIsRunning(agent) ? `<span class="agent-running-indicator" aria-label="Agent running" title="Agent running">${iconSvg("loaderPinwheel")}</span>` : ""}
          ${agentComposerAction(agent)}
        </div>
      </div>
    </form>
  `;
}

function renderInquiryForm(agent, options = {}) {
  const inquiry = agent.latest_inquiry || {};
  const inquiryId = String(inquiry.id || "").trim();
  const fields = inquiryFields(inquiry);
  return `
    <form id="inquiry-form" class="inquiry-form" data-agent-key="${escapeAttr(agent.key)}" data-inquiry-id="${escapeAttr(inquiryId)}" novalidate>
      <section class="inquiry-banner">
        <span class="inquiry-mark" aria-hidden="true">${iconSvg("badgeQuestionMark")}</span>
        <p>${escapeHtml(inquiry.message || "Respond to the agent before it continues.")}</p>
      </section>
      <div class="inquiry-fields">
        ${fields.map(renderInquiryField).join("")}
      </div>
      <section class="inquiry-review">
        <label class="check-label" for="confirm-inquiry">
          <input id="confirm-inquiry" type="checkbox" data-inquiry-confirm>
          <span>I have reviewed this answer and want to send it.</span>
        </label>
      </section>
      ${renderPromptAttachmentInput(agent)}
      ${renderPendingAttachments(agent)}
      ${renderAgentAttachments(agent)}
      <div class="send-row">
        <div class="send-tools">
          ${renderPromptAttachmentButton(agent)}
          ${renderAttachmentToggle(agent)}
          ${renderAgentViewToggle(agent, options)}
        </div>
        <div class="send-actions">
          <button class="primary inline-icon-button" type="submit" data-agent-key="${escapeAttr(agent.key)}">${iconSvg("check")}<span>Send answer</span></button>
        </div>
      </div>
    </form>
  `;
}

function renderAgentViewToggle(agent, options = {}) {
  if (!options.attachmentMode) return "";

  return `<button class="agent-view-toggle-button" type="button" data-open-agent="${escapeAttr(agent.key)}" aria-label="Show conversation" title="Conversation">${iconSvg("botMessageSquare")}</button>`;
}

function renderInquiryField(field, index) {
  const key = field.key || `response_${index}`;
  const id = `inquiry-${cssIdent(key)}-${index}`;
  const required = field.required ? "required" : "";
  const requirement = field.required ? "required" : "optional";
  const input = renderInquiryInput(field, id, key, required);
  return `
    <section class="field-card inquiry-field" data-inquiry-field="${escapeAttr(key)}">
      <label for="${escapeAttr(id)}">${escapeHtml(field.label || key)} <span>${escapeHtml(requirement)}</span></label>
      ${field.description ? `<span class="field-hint">${escapeHtml(field.description)}</span>` : ""}
      ${input}
    </section>
  `;
}

function renderInquiryInput(field, id, key, required) {
  const type = normalizeInquiryInputType(field.input_type);
  const options = inquiryOptions(field);
  if (type === "multi_select") {
    const items = options.length ? options : ["Yes"];
    return `
      <div class="choice-list inquiry-choice-list" data-inquiry-multi="${escapeAttr(key)}">
        ${items.map((option, index) => `
          <label class="choice inquiry-choice" for="${escapeAttr(`${id}-${index}`)}">
            <input id="${escapeAttr(`${id}-${index}`)}" type="checkbox" name="${escapeAttr(key)}" value="${escapeAttr(option)}">
            <span>${escapeHtml(option)}</span>
          </label>
        `).join("")}
      </div>
    `;
  }

  if (type === "select" || type === "boolean") {
    const items = type === "boolean" && !options.length ? ["Yes", "No"] : options;
    return `
      <select id="${escapeAttr(id)}" name="${escapeAttr(key)}" ${required}>
        <option value="">Choose...</option>
        ${items.map((option) => `<option value="${escapeAttr(option)}">${escapeHtml(option)}</option>`).join("")}
      </select>
    `;
  }

  if (type === "number" || type === "integer") {
    return `<input id="${escapeAttr(id)}" name="${escapeAttr(key)}" type="number" ${type === "integer" ? 'step="1"' : ""} ${required}>`;
  }

  if (type === "multiline") {
    return `<textarea id="${escapeAttr(id)}" name="${escapeAttr(key)}" rows="4" ${required}></textarea>`;
  }

  return `<input id="${escapeAttr(id)}" name="${escapeAttr(key)}" type="text" ${required}>`;
}

function scheduleAgentReading(agent) {
  cancelAgentReading();
  if (!agent?.unread) return;
  if (!state.conversations[agent.key]) return;
  if (document.hidden) return;

  state.readMarkTimer = window.setTimeout(() => {
    state.readMarkTimer = null;
    const route = parseRoute();
    if (route.type !== "agent" || route.key !== agent.key) return;
    if (document.hidden) return;
    if (!document.querySelector("[data-conversation-recent]")) return;

    const currentAgent = findAgent(agent.key);
    if (!currentAgent?.unread) return;
    markAgentReading(currentAgent).catch((error) => setConnection(error.message));
  }, 1200);
}

function agentComposerAction(agent) {
  if (agentIsRunning(agent)) {
    return `<button class="danger" type="button" data-agent-action="stop" data-agent-key="${escapeAttr(agent.key)}">Stop agent</button>`;
  }

  return `<button class="primary" type="submit" data-agent-key="${escapeAttr(agent.key)}">Send prompt</button>`;
}

function touchKeyboardLikely() {
  if (navigator.maxTouchPoints > 0) return true;
  if (typeof window.matchMedia !== "function") return false;

  return window.matchMedia("(pointer: coarse)").matches;
}

function submitPromptFormFromKeyboard(event) {
  const form = event.target.closest("#composer");
  const submitButton = form?.querySelector("button[type='submit']");
  if (!form || !submitButton || submitButton.disabled) return;

  event.preventDefault();
  if (typeof form.requestSubmit === "function") {
    form.requestSubmit(submitButton);
  } else {
    submitButton.click();
  }
}

function cancelAgentReading() {
  if (!state.readMarkTimer) return;

  window.clearTimeout(state.readMarkTimer);
  state.readMarkTimer = null;
}

function renderAgentForm(route) {
  const editing = route.mode === "edit";
  const cloning = route.mode === "clone";
  const agent = editing || cloning ? findAgent(route.key) : null;

  if ((editing || cloning) && !agent) {
    setHeader("Agent not found", "It may have been archived.", "A");
    replaceView(emptyState("Agent not found", "Return to the Agents tab and choose an active session."));
    return;
  }

  const projectKey = editing || cloning ? agent.project_key : route.projectKey;
  const project = findProject(projectKey);
  if (!project) {
    setHeader(editing ? "Loading agent" : "Loading project", "Fetching remote state", "A");
    replaceView(emptyState("Loading", "Fetching project templates before the agent form can render."));
    return;
  }

  if ((editing || cloning) && agentIsRunning(agent)) {
    const action = editing ? "editing" : "cloning";
    setHeader("Agent is running", agentHeaderLabel(agent), "A");
    replaceView(`
      <section class="notice">
        <strong>Stop before ${action}</strong>
        <p>Running agents keep their current process state locked. Stop this agent before ${action} it.</p>
        <div class="button-row">
          <button type="button" data-open-agent="${escapeAttr(agent.key)}">Open agent</button>
          <button class="primary" type="button" data-agent-action="stop" data-agent-key="${escapeAttr(agent.key)}">Stop agent</button>
        </div>
      </section>
    `);
    return;
  }

  const templates = agentTemplateSummaries(project);
  if (!templates.length) {
    setHeader("No templates", project.name || project.key, "A");
    replaceView(emptyState("No agent templates", "This project does not expose an agent template for Remote UI creation."));
    return;
  }

  const selectedTemplate = agentTemplateFor(project, editing || cloning ? agent.template_key : null) || templates[0];
  const prompt = editing || cloning ? agent.prompt : selectedTemplate.prompt;
  const values = {
    name: editing || cloning ? agent.name : defaultAgentName(project, selectedTemplate),
    templateKey: selectedTemplate.key,
    harness: normalizeAgentHarness(editing || cloning ? agent.agent : selectedTemplate.agent),
    sandboxMode: editing || cloning ? (agent.sandbox_mode || selectedTemplate.sandbox_mode) : selectedTemplate.sandbox_mode,
    workspace: editing || cloning ? agent.workspace : project.path,
    prompt: prompt || "",
  };

  setHeader(
    editing ? "Edit agent" : cloning ? "Clone agent" : "Add agent",
    editing || cloning ? agentHeaderLabel(agent) : project.name || project.key,
    "A"
  );
  replaceView(`
    <form id="agent-form" class="agent-form" data-mode="${editing ? "edit" : cloning ? "clone" : "create"}" data-project-key="${escapeAttr(project.key)}" data-agent-key="${escapeAttr(agent?.key || "")}" data-project-name="${escapeAttr(project.name || project.key)}">
      <section class="field-card">
        <label class="field-label" for="agent-template">Template</label>
        <select id="agent-template" name="template_key" data-agent-template-select>
          ${templates.map((template) => agentTemplateOptionHtml(template, template.key === values.templateKey)).join("")}
        </select>
        <span class="field-hint">${escapeHtml(selectedTemplate.prompt_preview || "Template defaults are loaded from the project configuration.")}</span>
      </section>
      <section class="field-card">
        <label class="field-label" for="agent-harness">Harness</label>
        <select id="agent-harness" name="agent">
          ${agentHarnessOptions().map((harness) => `<option value="${escapeAttr(harness)}" ${harness === values.harness ? "selected" : ""}>${escapeHtml(harness)}</option>`).join("")}
        </select>
        <input id="agent-sandbox-mode" type="hidden" name="sandbox_mode" value="${escapeAttr(values.sandboxMode)}">
      </section>
      <section class="field-card">
        <label class="field-label" for="agent-name">Name</label>
        <input id="agent-name" name="name" type="text" value="${escapeAttr(values.name)}" autocomplete="off" required>
      </section>
      <section class="detail-card">
        <div class="detail-card-body" style="padding-top: 12px;">
          <div class="detail-row">
            <span class="status-mark detail" aria-hidden="true">${iconSvg("folder")}</span>
            <div><strong>Workspace</strong><span class="wrap-anywhere">${escapeHtml(values.workspace)}</span></div>
            <span class="pill detail">${editing || cloning ? "Current path" : "Project path"}</span>
          </div>
        </div>
      </section>
      <section class="field-card">
        <label class="field-label" for="agent-prompt">Prompt</label>
        <textarea id="agent-prompt" name="prompt" rows="9" required>${escapeHtml(values.prompt)}</textarea>
      </section>
      <div class="button-row form-actions">
        <button type="button" data-cancel-agent-form>Cancel</button>
        ${editing ? `
          <button class="primary inline-icon-button" type="submit" value="save">${iconSvg("pencil")}<span>Save agent</span></button>
        ` : cloning ? `
          <button class="primary inline-icon-button" type="submit" value="clone">${iconSvg("copyPlus")}<span>Clone and archive</span></button>
        ` : `
          <button class="inline-icon-button" type="submit" value="create">${iconSvg("plus")}<span>Create agent</span></button>
          <button class="primary inline-icon-button" type="submit" value="create-run">${iconSvg("loaderPinwheel")}<span>Create and run</span></button>
        `}
      </div>
    </form>
  `);
}

function renderAgentArchive(key) {
  const agent = findAgent(key);
  if (!agent) {
    setHeader("Agent not found", "It may have been archived.", "A");
    replaceView(emptyState("Agent not found", "Return to the Agents tab and choose an active session."));
    return;
  }

  if (agentIsRunning(agent)) {
    setHeader("Agent is running", agentHeaderLabel(agent), "A");
    replaceView(`
      <section class="notice">
        <strong>Stop before archiving</strong>
        <p>Running agents keep their current process state locked. Stop this agent before archiving or cloning it.</p>
        <div class="button-row">
          <button type="button" data-open-agent="${escapeAttr(agent.key)}">Open agent</button>
          <button class="primary" type="button" data-agent-action="stop" data-agent-key="${escapeAttr(agent.key)}">Stop agent</button>
        </div>
      </section>
    `);
    return;
  }

  setHeader("Archive agent", agentHeaderLabel(agent), "A");
  replaceView(`
    <section class="notice archive-dialog">
      <strong>${escapeHtml(agent.name || agent.key)}</strong>
      <p>Archive this agent now, or clone it into a fresh editable agent before the source is archived.</p>
      <div class="kv-grid">
        ${kv("Template", agentTemplateLabel(agent))}
        ${kv("Harness", agent.agent || "agent")}
        ${kv("Status", statusLabel(agent))}
        ${kv("Runs", agent.run_count)}
      </div>
      <div class="button-row form-actions archive-actions">
        <button class="danger inline-icon-button" type="button" data-agent-action="archive" data-agent-key="${escapeAttr(agent.key)}">${iconSvg("archive")}<span>Archive</span></button>
        <button class="primary inline-icon-button" type="button" data-clone-agent="${escapeAttr(agent.key)}">${iconSvg("copyPlus")}<span>Clone instead</span></button>
        <button type="button" data-open-agent="${escapeAttr(agent.key)}">Cancel</button>
      </div>
    </section>
  `);
}

function renderProject(key) {
  const project = findProject(key);
  if (!project) {
    if (initialDataPending()) {
      setHeader("Loading project", "Fetching remote state", "folder");
      replaceView(emptyState("Loading project", "Fetching the selected project state."));
      return;
    }

    setHeader("Project not found", "It may have been removed from config.", "folder");
    replaceView(emptyState("Project not found", "Return to the Agents tab and choose an active project."));
    return;
  }

  setHeader(project.name || project.key, `${project.group || "ungrouped"} / key ${project.key}`, "folder");
  const agents = agentsForProject(project.key);
  replaceView(`
    <div class="chip-row">
      ${project.pr_number ? `<span class="chip info">PR #${escapeHtml(project.pr_number)}</span>` : ""}
      <span class="chip detail">${escapeHtml(project.branch || "branch n/a")}</span>
      <span class="chip ${project.dirty ? "need" : "done"}">${project.dirty ? `${project.dirty_files} dirty` : "clean"}</span>
    </div>
    <section class="agent-group project-overview-list">
      <div class="agent-row project-overview-row">
        <span class="status-mark ${projectStatusClass(project)}" aria-hidden="true">${iconSvg("folder")}</span>
        <div class="row-title"><strong>${escapeHtml(capitalize(project.status || "configured"))}</strong><span>${escapeHtml(project.health_status || "health unknown")} / ${latencyText(project)}</span></div>
        <span class="pill ${projectStatusClass(project)}">${escapeHtml(project.maintenance ? "Maintenance" : project.health_status || "Status")}</span>
      </div>
      <div class="agent-row project-overview-row">
        <span class="status-mark ${project.action_state ? "running" : "done"}" aria-hidden="true">${iconSvg("rocket")}</span>
        <div class="row-title"><strong>Current action</strong><span>${escapeHtml(actionText(project.action_state))}</span></div>
        <span class="pill ${project.action_state?.status === "running" ? "running" : "detail"}">${escapeHtml(project.action_state?.status || "None")}</span>
      </div>
      <div class="agent-row project-overview-row">
        <span class="status-mark detail" aria-hidden="true">${iconSvg("gitCommit")}</span>
        <div class="row-title"><strong>Revision</strong><span>${escapeHtml([project.commit_hash, project.branch].filter(Boolean).join(" on ") || "not available")}</span></div>
        <button type="button" data-copy="${escapeAttr(project.commit_hash || "")}" ${project.commit_hash ? "" : "disabled"}>Copy</button>
      </div>
    </section>
    ${renderProjectAgents(project, agents)}
    <details class="detail-card">
      <summary>Deploy details</summary>
      <div class="kv-grid">
        ${kv("Service", project.service)}
        ${kv("Image", project.image)}
        ${kv("Hosts", (project.hosts || []).join(", ") || "n/a")}
        ${kv("Proxy", project.proxy)}
        ${kv("Action log", project.action_log_path)}
        ${kv("Health path", project.healthcheck_path)}
      </div>
    </details>
    <details class="detail-card">
      <summary>Versions and templates</summary>
      <div class="kv-grid">
        ${kv("Kamal", project.kamal_version)}
        ${kv("Rails", project.rails_version)}
        ${kv("Templates", (project.agent_template_summaries || []).map((item) => item.name).join(", ") || "n/a")}
        ${kv("Path", project.path)}
      </div>
    </details>
    <section class="field-card">
      <span class="field-label">Guarded actions</span>
      <div class="button-row">
        ${PROJECT_ACTIONS.map((action) => `<button type="button" data-guard-action="${action}" data-project-key="${escapeAttr(project.key)}" ${project.apps_enabled ? "" : "disabled"}>${capitalize(action)}</button>`).join("")}
      </div>
    </section>
    <section class="notice">
      <strong>Project editing opens in the TUI</strong>
      <p>Mobile project modification is disabled because setup still needs terminal directory access.</p>
    </section>
  `);
}

function renderGuardedAction(projectKey, action) {
  const project = findProject(projectKey);
  const preflight = state.preflights[preflightKey(projectKey, action)];
  setHeader(`${capitalize(action)} confirmation`, project ? `${project.name || project.key} / guarded action` : "guarded action", "folder");

  if (!project && initialDataPending()) {
    replaceView(emptyState("Loading project", "Fetching project state before the guarded action can run."));
    return;
  }

  if (!project) {
    replaceView(emptyState("Project not found", "Return to the Agents tab and choose an active project."));
    return;
  }

  if (!preflight) {
    replaceView(emptyState("Loading preflight", "Checking project state before the guarded action can run."));
    ensurePreflight(projectKey, action).then(render).catch((error) => setConnection(error.message));
    return;
  }

  replaceView(`
    <section class="summary-card attention">
      <div class="card-title">
        <strong>${escapeHtml(project.name || project.key)}</strong>
        <span>${escapeHtml(project.status || "status unknown")} / ${escapeHtml(project.health_status || "health unknown")}</span>
      </div>
      <p class="summary-text">${escapeHtml((preflight.consequences || []).join(" "))}</p>
    </section>
    <section class="detail-card">
      <div class="detail-card-body" style="padding-top: 12px;">
        <div class="section-label"><strong>Preflight checks</strong><span>${preflight.can_start ? "ready" : "blocked"}</span></div>
        ${(preflight.checks || []).map((check) => `
          <div class="detail-row">
            <span class="status-mark ${check.passed ? "done" : "fail"}" aria-hidden="true">${statusIcon(check.passed)}</span>
            <div><strong>${escapeHtml(check.label)}</strong><span>${escapeHtml(check.detail || "")}</span></div>
            <span class="pill ${check.passed ? "done" : "fail"}">${check.passed ? "Pass" : "Block"}</span>
          </div>
        `).join("")}
      </div>
    </section>
    <details class="detail-card" open>
      <summary>Expected flow and log behavior</summary>
      <div class="kv-grid">
        ${kv("Action", preflight.label)}
        ${kv("Log", preflight.log_path)}
        ${kv("Health", project.health_status)}
        ${kv("Git", project.dirty ? `${project.dirty_files} dirty files` : "clean or unavailable")}
      </div>
    </details>
    <form id="guard-form" class="field-card">
      <label class="check-label">
        <input id="confirm-action" type="checkbox" ${preflight.can_start ? "" : "disabled"}>
        I understand this starts a detached Kamal ${escapeHtml(action)} command.
      </label>
      <button class="primary" type="submit" data-project-key="${escapeAttr(project.key)}" data-action="${escapeAttr(action)}" disabled>Start ${escapeHtml(preflight.label)}</button>
    </form>
  `);
}

function renderProjectAgents(project, agents) {
  const countLabel = `${agents.length} ${agents.length === 1 ? "agent" : "agents"}`;
  return `
    <section class="agent-group project-agent-group">
      <div class="group-title">
        <div class="agent-group-project">
          <strong>Managed agents</strong>
          <span>${escapeHtml(countLabel)} on this project</span>
        </div>
        <button class="inline-icon-button agent-group-create" type="button" data-create-agent="${escapeAttr(project.key)}">${iconSvg("plus")}<span>Add agent</span></button>
      </div>
      ${agents.length ? agents.map(renderAgentRow).join("") : renderProjectAgentEmpty()}
    </section>
  `;
}

function renderProjectAgentEmpty() {
  return `
    <div class="agent-row project-agent-empty">
      <span class="status-mark info" aria-hidden="true">${iconSvg("robot")}</span>
      <div class="row-title">
        <strong>No managed agents</strong>
        <span>Add the first managed agent for this project.</span>
      </div>
      <span class="pill detail">None</span>
    </div>
  `;
}

function renderAgentSection(title, subtitle, agents, emptyText) {
  return `
    <div class="section-label"><strong>${escapeHtml(title)}</strong><span>${escapeHtml(subtitle)}</span></div>
    <div class="list">
      ${agents.length ? agents.map(renderAgentCard).join("") : emptyRow(emptyText, "")}
    </div>
  `;
}

function renderAgentGroup(projectKey, agents) {
  const project = findProject(projectKey);
  const projectName = project?.name || projectKey;
  const projectMeta = project ? `${agents.length} agents / ${project.health_status || project.status || "configured"}` : `${agents.length} agents`;
  return `
    <section class="agent-group">
      <div class="group-title">
        <div class="agent-group-project">
          ${renderAgentGroupProjectTitle(projectKey, projectName, !!project)}
          <span>${escapeHtml(projectMeta)}</span>
        </div>
        ${project ? `<button class="inline-icon-button agent-group-create" type="button" data-create-agent="${escapeAttr(projectKey)}" aria-label="Create agent for ${escapeAttr(projectName)}">${iconSvg("plus")}<span>Agent</span></button>` : ""}
      </div>
      ${agents.length ? agents.map(renderAgentRow).join("") : renderProjectAgentEmpty()}
    </section>
  `;
}

function renderAgentGroupProjectTitle(projectKey, projectName, linked) {
  if (!linked) return `<strong>${escapeHtml(projectName)}</strong>`;

  const projectHref = routeHash({ type: "project", key: projectKey });
  return `<a href="${escapeAttr(projectHref)}" data-open-project="${escapeAttr(projectKey)}">${escapeHtml(projectName)}</a>`;
}

function renderAgentCard(agent) {
  return `
    <button class="card" type="button" data-open-agent="${escapeAttr(agent.key)}">
      <div class="card-title">
        <strong>${escapeHtml(agent.name || agent.key)}</strong>
        <span>${escapeHtml(agentMeta(agent))}</span>
      </div>
      <span class="pill ${statusClass(agent)}">${escapeHtml(statusLabel(agent))}</span>
      <p class="card-copy">${escapeHtml(truncate(agent.summary || agent.last_result || "No run summary yet.", 140))}</p>
      <div class="meta"><span>${escapeHtml(timeAgo(agent.started_at || agent.created_at))}</span></div>
    </button>
  `;
}

function renderAgentRow(agent) {
  if (state.bulkArchiveMode) return renderSelectableAgentRow(agent);

  return `
    <button class="agent-row" type="button" data-open-agent="${escapeAttr(agent.key)}">
      <span class="status-mark ${statusClass(agent)}" aria-hidden="true">${iconSvg("robot")}</span>
      <div class="row-title">
        <strong>${escapeHtml(agent.name || agent.key)}</strong>
        <span>${agentListSubtextHtml(agent)}</span>
      </div>
      ${agent.unread ? `<span class="pill need">Unread</span>` : `<span class="pill ${statusClass(agent)}">${escapeHtml(agent.last_result || "open")}</span>`}
    </button>
  `;
}

function renderSelectableAgentRow(agent) {
  const selected = state.bulkArchiveSelection.has(agent.key);
  const disabled = !agentArchiveable(agent);
  return `
    <label class="agent-row selectable-agent-row ${selected ? "selected" : ""} ${disabled ? "disabled" : ""}">
      <input class="agent-select-box" type="checkbox" data-select-agent="${escapeAttr(agent.key)}" ${selected ? "checked" : ""} ${disabled ? "disabled" : ""}>
      <div class="row-title">
        <strong>${escapeHtml(agent.name || agent.key)}</strong>
        <span>${agentListSubtextHtml(agent)}</span>
      </div>
      <span class="pill ${disabled ? "detail" : statusClass(agent)}">${escapeHtml(disabled ? "Running" : (agent.last_result || "archiveable"))}</span>
    </label>
  `;
}

function renderConversationBlocks(blocks) {
  const rendered = [];
  let index = 0;
  let groupIndex = 0;

  while (index < blocks.length) {
    const block = blocks[index];
    if (primaryConversationBlock(block)) {
      rendered.push(renderMessage(block));
      index += 1;
      continue;
    }

    const group = [];
    while (index < blocks.length && !primaryConversationBlock(blocks[index])) {
      group.push(blocks[index]);
      index += 1;
    }
    rendered.push(renderMessageGroup(group, groupIndex));
    groupIndex += 1;
  }

  return rendered.join("");
}

function primaryConversationBlock(block) {
  if (block?.kind === "run_summary") return true;
  return block?.kind === "message" && ["user", "assistant"].includes(block.role);
}

function renderMessageGroup(blocks, index) {
  const label = messageGroupLabel(blocks);
  const summary = messageGroupSummary(blocks);
  const stateKey = messageGroupStateKey(blocks, index);
  return `
    <details class="message-group" data-state-key="${escapeAttr(stateKey)}">
      <summary><span class="message-group-label">${messageGroupIcon(blocks)}<span>${escapeHtml(label)}</span></span><span>${escapeHtml(summary)}</span></summary>
      <div class="message-group-body">
        ${blocks.map(renderMessage).join("")}
      </div>
    </details>
  `;
}

function messageGroupLabel(blocks) {
  if (blocks.every((block) => block.kind === "message" && block.role === "system")) return "System context";
  if (blocks.every((block) => ["tool_call", "tool_result"].includes(block.kind))) return "Tool activity";
  return "Agent activity";
}

function messageGroupIcon(blocks) {
  return blocks.some((block) => ["tool_call", "tool_result"].includes(block.kind)) ? iconSvg("hammer") : "";
}

function messageGroupSummary(blocks) {
  const last = blocks[blocks.length - 1] || {};
  return `${blocks.length} ${blocks.length === 1 ? "event" : "events"} / ${blockLabel(last)}`;
}

function messageGroupStateKey(blocks, index) {
  const first = blocks[0] || {};
  const last = blocks[blocks.length - 1] || {};
  return `message-group:${index}:${blockStateToken(first)}:${blockStateToken(last)}`;
}

function blockStateToken(block) {
  const metadata = block.metadata || {};
  return [
    block.id || block.created_at || metadata.id || metadata.event_id || metadata.created_at || metadata.timestamp || metadata.completed_at || metadata.tool_use_id || metadata.tool_call_id || "",
    block.kind || "",
    block.role || "",
    block.tool_name || "",
    String(block.content || "").length,
    String(block.content || "").slice(-80),
  ].join(":");
}

function renderMessage(block) {
  return `
    <article class="${escapeAttr(messageClassName(block))}">
      <div class="message-role">${messageIcon(block)}<span>${escapeHtml(messageRoleLabel(block))}</span></div>
      ${renderMessageContent(block)}
      ${renderMessageAttachments(block)}
    </article>
  `;
}

function messageClassName(block) {
  return ["message", block.role || block.kind || "", inquiryResponseBlock(block) ? "inquiry-response" : ""]
    .filter(Boolean)
    .join(" ");
}

function messageRoleLabel(block) {
  return inquiryResponseBlock(block) ? "user answers" : blockLabel(block);
}

function inquiryResponseBlock(block) {
  return block?.metadata?.inquiry_response === true;
}

function renderMessageContent(block) {
  const content = String(block.content || "");
  if (markdownMessageBlock(block)) {
    return `
      <div class="message-content markdown-message-content">
        ${renderMarkdown(content, {
          viewerClassName: "markdown-viewer message-markdown-viewer",
          fallbackClassName: "message-markdown-fallback",
          emptyText: "",
        })}
      </div>
    `;
  }

  const formatted = block.role === "user" ? formatJsonObjectMessage(content) : "";
  if (formatted) return `<div class="message-content parsed-json-message">${formatted}</div>`;

  return `<div class="message-content">${escapeHtml(content)}</div>`;
}

function markdownMessageBlock(block) {
  if (block?.kind === "run_summary") return true;
  return block?.kind === "message" && block.role === "assistant";
}

function formatJsonObjectMessage(content) {
  let parsed;
  try {
    parsed = JSON.parse(String(content || ""));
  } catch (_error) {
    return "";
  }
  if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") return "";

  const entries = Object.entries(parsed);
  if (!entries.length) return "";

  return entries
    .map(([key, value]) => {
      const label = escapeHtml(humanizeJsonKey(key));
      const renderedValue = escapeHtml(jsonObjectValueText(value));
      return `<div class="parsed-json-field"><span class="parsed-json-key">${label}</span>\n<em class="parsed-json-value">${renderedValue}</em></div>`;
    })
    .join("\n");
}

function jsonObjectValueText(value) {
  if (typeof value === "string") return value;

  const rendered = JSON.stringify(value, null, 2);
  return rendered === undefined ? String(value) : rendered;
}

function humanizeJsonKey(key) {
  const words = String(key || "")
    .trim()
    .split(/[_\s-]+/)
    .filter(Boolean)
    .join(" ");
  if (!words) return String(key || "");

  return words.toUpperCase();
}

function renderMessageAttachments(block) {
  const attachments = blockAttachments(block);
  if (!attachments.length) return "";

  return `
    <div class="message-attachments">
      ${attachments.map(renderMessageAttachment).join("")}
    </div>
  `;
}

function renderMessageAttachment(attachment) {
  const kind = attachmentKind(attachment);
  const title = String(attachment?.title || attachmentTarget(attachment) || "Attachment").trim();
  const href = attachmentHref(attachment);
  const content = `
    <span class="attachment-icon" aria-hidden="true">${attachmentIcon(attachment)}</span>
    <span class="attachment-copy">
      <strong>${escapeHtml(title || "Attachment")}</strong>
      <span>${escapeHtml(attachmentMessageMeta(attachment))}</span>
    </span>
  `;

  if (href) {
    const external = kind === "link";
    return `<a class="message-attachment" href="${escapeAttr(href)}" ${external ? 'target="_blank" rel="noreferrer"' : ""}>${content}</a>`;
  }

  return `<span class="message-attachment">${content}</span>`;
}

function blockAttachments(block) {
  const attachments = block?.metadata?.attachments;
  return Array.isArray(attachments) ? attachments : [];
}

function attachmentMessageMeta(attachment) {
  return [attachmentKindLabel(attachmentKind(attachment)), formatBytes(attachment?.size_bytes)].filter(Boolean).join(" / ");
}

function renderPromptAttachmentInput(agent) {
  return `
    <input
      id="prompt-attachment-input"
      class="sr-only"
      type="file"
      data-prompt-attachment-input
      data-agent-key="${escapeAttr(agent.key)}"
      accept="${escapeAttr(PROMPT_ATTACHMENT_LIMITS.accept)}"
      multiple
      ${agentIsRunning(agent) ? "disabled" : ""}
    >
  `;
}

function renderPromptAttachmentButton(agent) {
  const pending = pendingAttachmentsFor(agent.key);
  const disabled = agentIsRunning(agent) || pending.length >= PROMPT_ATTACHMENT_LIMITS.maxFiles;
  return `<button class="attachment-upload-button" type="button" data-add-prompt-attachment data-agent-key="${escapeAttr(agent.key)}" aria-label="Upload file" title="Upload file" ${disabled ? "disabled" : ""}>${iconSvg("upload")}</button>`;
}

function renderPendingAttachments(agent) {
  const pending = pendingAttachmentsFor(agent.key);
  if (!pending.length) return "";

  return `
    <section class="pending-attachments" aria-label="Pending prompt attachments">
      <div class="pending-attachment-header">
        <strong>Ready to attach</strong>
        <span>${escapeHtml(`${pending.length}/${PROMPT_ATTACHMENT_LIMITS.maxFiles}`)}</span>
      </div>
      <div class="pending-attachment-list">
        ${pending.map((attachment) => renderPendingAttachment(agent.key, attachment)).join("")}
      </div>
    </section>
  `;
}

function renderPendingAttachment(agentKey, attachment) {
  const preview = attachment.previewUrl
    ? `<img class="pending-attachment-thumb" src="${escapeAttr(attachment.previewUrl)}" alt="">`
    : `<span class="pending-attachment-thumb" aria-hidden="true">${attachmentKindIcon(attachment.type)}</span>`;
  return `
    <div class="pending-attachment" data-pending-attachment="${escapeAttr(attachment.id)}">
      ${preview}
      <span class="attachment-copy">
        <strong>${escapeHtml(attachment.filename)}</strong>
        <span>${escapeHtml([attachmentKindLabel(attachment.type), formatBytes(attachment.size)].filter(Boolean).join(" / "))}</span>
      </span>
      <button class="icon-button" type="button" data-remove-prompt-attachment="${escapeAttr(attachment.id)}" data-agent-key="${escapeAttr(agentKey)}" aria-label="Remove attachment" title="Remove attachment">${iconSvg("x")}</button>
    </div>
  `;
}

function renderAgentAttachments(agent) {
  const attachments = agentAttachments(agent);
  if (!attachments.length) return "";

  return `
    <section class="attachment-flyout hidden" data-attachment-flyout data-preserve-open data-preserve-scroll data-state-key="agent-attachment-flyout" aria-label="Attachments">
      <div class="attachment-panel-header">
        <strong>Attachments</strong>
        <span>${escapeHtml(attachmentSummary(attachments))}</span>
      </div>
      <div class="attachment-list">
        ${attachments.map(renderAttachment).join("")}
      </div>
    </section>
  `;
}

function renderAttachmentToggle(agent) {
  const attachments = agentAttachments(agent);
  if (!attachments.length) return "";

  return `<button class="attachment-toggle-button" type="button" data-toggle-attachments aria-label="Show attachments" title="Attachments" aria-expanded="false">${iconSvg("paperclip")}<span class="attachment-count">${escapeHtml(String(attachments.length))}</span></button>`;
}

function renderAttachment(attachment) {
  const kind = attachmentKind(attachment);
  const target = attachmentTarget(attachment);
  const title = String(attachment?.title || target || "Untitled attachment").trim();
  const meta = [attachmentKindLabel(kind), attachmentTargetLabel(target)].filter(Boolean).join(" / ");
  const href = attachmentHref(attachment);
  const external = kind === "link" && href;
  const id = attachmentId(attachment);
  const content = `
    <span class="attachment-icon" aria-hidden="true">${attachmentIcon(attachment)}</span>
    <span class="attachment-copy">
      <strong>${escapeHtml(title || "Untitled attachment")}</strong>
      ${meta ? `<span class="wrap-anywhere">${escapeHtml(meta)}</span>` : ""}
    </span>
  `;
  const main = href
    ? `<a class="attachment-main" href="${escapeAttr(href)}" ${external ? 'target="_blank" rel="noreferrer"' : ""}>${content}</a>`
    : `<span class="attachment-main">${content}</span>`;
  const actions = id
    ? `<span class="attachment-actions"><button class="icon-button danger" type="button" data-delete-attachment="${escapeAttr(id)}" aria-label="Delete attachment" title="Delete attachment">${iconSvg("trash2")}</button></span>`
    : "";

  return `<div class="attachment-item">${main}${actions}</div>`;
}

function agentAttachments(agent) {
  return dedupeAgentAttachments(Array.isArray(agent?.attachments) ? agent.attachments : []);
}

function dedupeAgentAttachments(attachments) {
  const seen = new Set();
  const deduped = [];
  attachments.forEach((attachment) => {
    const key = attachmentDedupeKey(attachment);
    if (!key || seen.has(key)) return;

    seen.add(key);
    deduped.push(attachment);
  });
  return deduped;
}

function attachmentDedupeKey(attachment) {
  const target = attachmentTarget(attachment);
  if (!target) return "";

  return `${attachmentKind(attachment)}\u001f${target}`;
}

function attachmentId(attachment) {
  return String(attachment?.id || "").trim();
}

function attachmentById(id) {
  const targetId = String(id || "");
  if (!targetId) return null;

  for (const agent of state.agents) {
    const match = agentAttachments(agent).find((attachment) => attachmentId(attachment) === targetId);
    if (match) return match;
  }
  return null;
}

function attachmentSummary(attachments) {
  const counts = attachments.reduce((memo, attachment) => {
    const kind = attachmentKind(attachment);
    memo[kind] = (memo[kind] || 0) + 1;
    return memo;
  }, {});
  return ["file", "link"]
    .filter((kind) => counts[kind])
    .map((kind) => `${counts[kind]} ${counts[kind] === 1 ? attachmentKindLabel(kind) : `${attachmentKindLabel(kind)}s`}`)
    .join(" / ");
}

function attachmentKind(attachment) {
  const type = String(attachment?.type || "").trim().toLowerCase();
  if (type === "file" || type === "link") return type;

  const legacyKind = String(attachment?.kind || "").trim().toLowerCase();
  return legacyKind === "link" ? "link" : "file";
}

function attachmentKindLabel(kind) {
  if (kind === "file") return "file";
  return "link";
}

function attachmentKindIcon(kind) {
  if (kind === "file") return iconSvg("fileText");
  return iconSvg("link");
}

function attachmentIcon(attachment) {
  if (attachmentKind(attachment) === "file" && attachmentFormat(attachment) === "image") return iconSvg("image");
  return attachmentKindIcon(attachmentKind(attachment));
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

function attachmentBlobPath(id, options = {}) {
  const path = `/attachments/${encodeURIComponent(id)}/blob`;
  return options.cacheBust ? `${path}?v=${Date.now()}` : path;
}

function attachmentRefreshAvailable(id) {
  const cached = state.attachmentDetails[id];
  const runtime = attachmentById(id);
  if (!cached || !runtime) return false;
  if (attachmentKind(cached) !== "file" || attachmentKind(runtime) !== "file") return false;

  const cachedVersion = attachmentContentVersion(cached);
  const runtimeVersion = attachmentContentVersion(runtime);
  return runtimeVersion > 0 && cachedVersion > 0 && runtimeVersion > cachedVersion;
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

function pendingAttachmentsFor(agentKey) {
  const key = String(agentKey || "");
  if (!key) return [];
  state.pendingPromptAttachments[key] ||= [];
  return state.pendingPromptAttachments[key];
}

function handlePromptAttachmentFiles(agentKey, files) {
  const pending = pendingAttachmentsFor(agentKey);
  const accepted = [];
  const rejected = [];
  const existingKeys = new Set(pending.map(pendingAttachmentDedupeKey));
  const acceptedKeys = new Set();

  Array.from(files || []).forEach((file) => {
    const normalized = normalizePromptAttachmentFile(file);
    if (normalized.error) {
      rejected.push(`${file.name}: ${normalized.error}`);
      return;
    }

    const key = pendingAttachmentDedupeKey(normalized);
    if (existingKeys.has(key) || acceptedKeys.has(key)) {
      rejected.push(`${normalized.filename}: duplicate`);
      revokePendingAttachment(normalized);
      return;
    }

    if (pending.length + accepted.length >= PROMPT_ATTACHMENT_LIMITS.maxFiles) {
      rejected.push(`${normalized.filename}: limit ${PROMPT_ATTACHMENT_LIMITS.maxFiles}`);
      revokePendingAttachment(normalized);
    } else {
      acceptedKeys.add(key);
      accepted.push(normalized);
    }
  });

  if (accepted.length) {
    state.pendingPromptAttachments[agentKey] = accepted.concat(pending);
    state.renderedViewHtml = "";
    render();
    window.requestAnimationFrame(syncAgentDockLayout);
  }
  if (rejected.length) setConnection(`Attachment skipped: ${rejected[0]}`);
}

function handleClipboardAttachmentPaste(event) {
  const agentKey = clipboardAttachmentAgentKey(event);
  if (!agentKey) return;

  const files = clipboardAttachmentFiles(event);
  if (!files.length) return;

  const beforeCount = pendingAttachmentsFor(agentKey).length;
  handlePromptAttachmentFiles(agentKey, files);
  if (pendingAttachmentsFor(agentKey).length > beforeCount) event.preventDefault();
}

function clipboardAttachmentAgentKey(event) {
  const route = parseRoute();
  if (!agentShellRoute(route)) return "";

  const agent = findAgent(route.key);
  if (!agent || agentIsRunning(agent)) return "";
  if (typeof event.target?.closest !== "function") return "";
  if (!event.target.closest("#composer, #inquiry-form")) return "";

  return agent.key;
}

function clipboardAttachmentFiles(event) {
  const data = event.clipboardData;
  if (!data) return [];

  const directFiles = Array.from(data.files || []);
  if (directFiles.length) return directFiles.map((file, index) => normalizeClipboardAttachmentFile(file, index));

  return Array.from(data.items || []).filter((item) => item.kind === "file").map((item, index) => {
    const file = item.getAsFile?.();
    return file ? normalizeClipboardAttachmentFile(file, index) : null;
  }).filter(Boolean);
}

function normalizeClipboardAttachmentFile(file, index) {
  if (!file || file.name) return file;

  const filename = clipboardAttachmentFilename(file, index);
  try {
    return new File([file], filename, { type: file.type || "", lastModified: Date.now() });
  } catch (_error) {
    return file;
  }
}

function clipboardAttachmentFilename(file, index) {
  const extension = CLIPBOARD_ATTACHMENT_EXTENSIONS[String(file?.type || "").toLowerCase()] || ".bin";
  const suffix = index > 0 ? `-${index + 1}` : "";
  return `clipboard-${clipboardAttachmentTimestamp()}${suffix}${extension}`;
}

function clipboardAttachmentTimestamp(date = new Date()) {
  const pad = (value) => String(value).padStart(2, "0");
  return [
    date.getFullYear(),
    pad(date.getMonth() + 1),
    pad(date.getDate()),
    "-",
    pad(date.getHours()),
    pad(date.getMinutes()),
    pad(date.getSeconds()),
  ].join("");
}

function normalizePromptAttachmentFile(file) {
  if (file.size > PROMPT_ATTACHMENT_LIMITS.maxBytes) {
    return { error: `larger than ${formatBytes(PROMPT_ATTACHMENT_LIMITS.maxBytes)}` };
  }

  const image = promptAttachmentIsImage(file);
  return {
    id: `pending-${Date.now()}-${Math.random().toString(16).slice(2)}`,
    file,
    filename: file.name || "attachment",
    mimeType: file.type || "",
    type: "file",
    size: file.size,
    previewUrl: image ? URL.createObjectURL(file) : "",
  };
}

function pendingAttachmentDedupeKey(attachment) {
  const file = attachment?.file;
  return [
    attachment?.type || "file",
    String(attachment?.filename || "").trim().toLowerCase(),
    String(attachment?.mimeType || "").trim().toLowerCase(),
    String(attachment?.size || ""),
    String(file?.lastModified || "")
  ].join("\u001f");
}

function promptAttachmentIsImage(file) {
  const name = String(file?.name || "").toLowerCase();
  const type = String(file?.type || "").toLowerCase();
  return /^image\/(png|jpeg|gif|webp|svg\+xml|avif|heic)$/.test(type) || /\.(avif|gif|heic|jpe?g|png|svg|webp)$/.test(name);
}

function removePendingAttachment(agentKey, attachmentId) {
  const pending = pendingAttachmentsFor(agentKey);
  const attachment = pending.find((item) => item.id === attachmentId);
  if (attachment) revokePendingAttachment(attachment);
  state.pendingPromptAttachments[agentKey] = pending.filter((item) => item.id !== attachmentId);
  state.renderedViewHtml = "";
  render();
  window.requestAnimationFrame(syncAgentDockLayout);
}

function clearPendingAttachments(agentKey) {
  pendingAttachmentsFor(agentKey).forEach(revokePendingAttachment);
  delete state.pendingPromptAttachments[agentKey];
}

function revokePendingAttachment(attachment) {
  if (attachment?.previewUrl) URL.revokeObjectURL(attachment.previewUrl);
}

async function pendingAttachmentPayloads(agentKey) {
  const pending = pendingAttachmentsFor(agentKey);
  const payloads = [];
  for (const attachment of pending) {
    payloads.push({
      filename: attachment.filename,
      mime_type: attachment.mimeType,
      type: attachment.type,
      size_bytes: attachment.size,
      content_base64: await readFileBase64(attachment.file),
    });
  }
  return payloads;
}

function readFileBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener("load", () => {
      const result = String(reader.result || "");
      resolve(result.includes(",") ? result.split(",", 2)[1] : result);
    }, { once: true });
    reader.addEventListener("error", () => reject(reader.error || new Error("File read failed")), { once: true });
    reader.readAsDataURL(file);
  });
}

function renderAttachmentViewer(id) {
  const attachment = attachmentDetail(id);
  if (!attachment) {
    setHeader("Attachment", "Not found", "paperclip");
    replaceView(emptyState("Attachment not found", "Return to the agent and choose another attachment."));
    return;
  }

  const kind = attachmentKind(attachment);
  const title = String(attachment.title || attachmentTarget(attachment) || "Attachment").trim();
  const agent = findAgent(attachment.agent_key);
  setHeader(title || "Attachment", agent ? agent.name : attachmentKindLabel(kind), attachmentIconName(attachment));
  replaceView(attachmentViewerHtml(id));
}

function attachmentDetail(id) {
  return state.attachmentDetails[id] || attachmentById(id);
}

function attachmentViewerHtml(id, options = {}) {
  const attachment = attachmentDetail(id);
  if (!attachment) return emptyState("Attachment not found", "Return to the agent and choose another attachment.");

  const kind = attachmentKind(attachment);
  const format = String(attachment.format || attachmentFormat(attachment)).toLowerCase();
  const title = String(attachment.title || attachmentTarget(attachment) || "Attachment").trim();
  const target = attachmentTarget(attachment);
  const agent = findAgent(attachment.agent_key);
  const sectionClass = options.embedded ? "attachment-viewer agent-attachment-viewer" : "detail-card attachment-viewer";
  const bodyClass = options.embedded ? "agent-attachment-body" : "detail-card-body";
  const actions = attachmentViewerActions(id, attachment);

  if (kind === "file" && format === "image") {
    const imageUrl = state.attachmentImageUrls[id];
    const error = state.attachmentImageErrors[id] || attachment.content_error;
    const imageHtml = error
      ? `<p class="field-hint">${escapeHtml(error)}</p>`
      : imageUrl
        ? `<img class="attachment-image-viewer" src="${escapeAttr(imageUrl)}" alt="${escapeAttr(title || "Attachment image")}">`
        : `<p class="field-hint">Loading image...</p>`;

    return `
      <section class="${sectionClass}">
        <div class="${bodyClass}">
          <div class="section-label"><strong>Image</strong><span>${escapeHtml(agent?.name || attachmentKindLabel(kind))}</span></div>
          ${target ? `<p class="attachment-target wrap-anywhere">${escapeHtml(attachmentTargetLabel(target))}</p>` : ""}
          ${actions}
          ${imageHtml}
        </div>
      </section>
    `;
  }

  if (kind === "link") {
    const href = attachmentHref(attachment);
    if (href) openAttachmentLinkOnce(id, href);
    return `
      <section class="${sectionClass}">
        <div class="${bodyClass}">
          <div class="section-label"><strong>Link</strong><span>${escapeHtml(agent?.name || "external")}</span></div>
          <p class="attachment-target wrap-anywhere">${escapeHtml(target || "No URL")}</p>
          ${actions}
          ${href ? `<a class="button primary button-link" href="${escapeAttr(href)}" target="_blank" rel="noreferrer">Open link</a>` : ""}
        </div>
      </section>
    `;
  }

  const content = String(attachment.content || "");
  const contentHtml = attachmentContentLoading(id, attachment, format)
    ? `<p class="field-hint">Loading file preview...</p>`
    : attachment.content_error
    ? `<p class="field-hint">${escapeHtml(attachment.content_error)}</p>`
    : format === "binary"
      ? `<p class="field-hint">Preview unavailable for this file.</p>${attachment.blob_path ? `<a class="button primary button-link" href="${escapeAttr(attachment.blob_path)}" target="_blank" rel="noreferrer">Open file</a>` : ""}`
    : format === "markdown"
      ? renderMarkdown(content)
      : `<pre class="attachment-text-viewer">${escapeHtml(content || "No content")}</pre>`;

  return `
    <section class="${sectionClass}">
      <div class="${bodyClass}">
        <div class="section-label"><strong>${escapeHtml(format === "markdown" ? "Markdown" : "File")}</strong><span>${escapeHtml(agent?.name || attachmentKindLabel(kind))}</span></div>
        ${target ? `<p class="attachment-target wrap-anywhere">${escapeHtml(attachmentTargetLabel(target))}</p>` : ""}
        ${actions}
        ${attachment.content_truncated ? `<p class="field-hint">Showing the first 512 KB.</p>` : ""}
        ${contentHtml}
      </div>
    </section>
  `;
}

function attachmentViewerActions(id, attachment) {
  const target = attachmentTarget(attachment);
  const copyLabel = attachmentKind(attachment) === "link" ? "Copy link" : "Copy path";
  const copy = target
    ? `<button class="inline-icon-button" type="button" data-copy="${escapeAttr(target)}">${iconSvg("copy")}<span>${copyLabel}</span></button>`
    : "";
  const refresh = attachmentRefreshAvailable(id)
    ? `<button class="inline-icon-button" type="button" data-refresh-attachment="${escapeAttr(id)}">${iconSvg("rotateCcw")}<span>Load latest</span></button>`
    : "";
  const remove = id
    ? `<button class="danger inline-icon-button" type="button" data-delete-attachment="${escapeAttr(id)}">${iconSvg("trash2")}<span>Delete</span></button>`
    : "";
  if (!copy && !refresh && !remove) return "";

  return `<div class="attachment-viewer-actions">${copy}${refresh}${remove}</div>`;
}

function attachmentContentLoading(id, attachment, format) {
  if (attachmentKind(attachment) !== "file") return false;
  if (!["markdown", "text"].includes(format)) return false;
  if (Object.prototype.hasOwnProperty.call(state.attachmentDetails, id)) return false;

  return !Object.prototype.hasOwnProperty.call(attachment, "content") && !attachment.content_error;
}

function attachmentKindIconName(kind) {
  if (kind === "file") return "fileText";
  return "link";
}

function attachmentIconName(attachment) {
  if (attachmentKind(attachment) === "file" && attachmentFormat(attachment) === "image") return "image";
  return attachmentKindIconName(attachmentKind(attachment));
}

function attachmentFormat(attachment) {
  const format = String(attachment?.format || "").toLowerCase();
  if (format) return format;

  const target = attachmentTarget(attachment).toLowerCase();
  const mimeType = String(attachment?.mime_type || "").toLowerCase();
  if (mimeType.startsWith("image/") || /\.(avif|gif|heic|jpe?g|png|svg|webp)$/.test(target)) return "image";
  if (/\.(md|markdown)(?:[?#].*)?$/.test(target)) return "markdown";
  if (mimeType.startsWith("text/") || /^application\/(json|x-ndjson)$/.test(mimeType) || /\.(csv|json|jsonl|log|txt|tsv)(?:[?#].*)?$/.test(target)) {
    return "text";
  }
  return "binary";
}

function openAttachmentLinkOnce(id, href) {
  if (!href || state.openedAttachmentLinks[id]) return;

  state.openedAttachmentLinks[id] = true;
  window.setTimeout(() => window.open(href, "_blank", "noopener"), 0);
}

function renderMarkdown(text, options = {}) {
  const source = String(text || "");
  if (markdownParserReady()) return renderParsedMarkdown(source, options);

  ensureMarkdownParserLoaded();
  return renderPlainTextMarkdown(source, options);
}

function markdownParserReady() {
  return Boolean(window.marked?.parse && window.DOMPurify?.sanitize);
}

function ensureMarkdownParserLoaded() {
  if (markdownParserReady()) return Promise.resolve(true);
  if (markdownParser.failed) return Promise.resolve(false);
  if (markdownParser.promise) return markdownParser.promise;

  markdownParser.promise = Promise.all([
    loadExternalScript(MARKDOWN_SCRIPT_URLS.dompurify),
    loadExternalScript(MARKDOWN_SCRIPT_URLS.marked),
  ]).then(() => {
    if (!markdownParserReady()) throw new Error("Markdown parser globals unavailable");
    renderMarkdownRoute();
    return true;
  }).catch((error) => {
    markdownParser.failed = true;
    console.warn("Markdown parser load failed", error);
    return false;
  });

  return markdownParser.promise;
}

function loadExternalScript(src) {
  const existing = Array.from(document.scripts).find((script) => script.src === src);
  if (existing) {
    return existing.dataset.loaded === "true"
      ? Promise.resolve(true)
      : new Promise((resolve, reject) => {
          existing.addEventListener("load", () => resolve(true), { once: true });
          existing.addEventListener("error", () => reject(new Error(`Failed to load ${src}`)), { once: true });
        });
  }

  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.crossOrigin = "anonymous";
    script.addEventListener("load", () => {
      script.dataset.loaded = "true";
      resolve(true);
    }, { once: true });
    script.addEventListener("error", () => reject(new Error(`Failed to load ${src}`)), { once: true });
    document.head.appendChild(script);
  });
}

function renderMarkdownRoute() {
  const route = parseRoute();
  if (route.type === "agent" || route.type === "agentAttachment") {
    state.renderedViewHtml = "";
    render();
    return;
  }

  if (route.type !== "attachment" && route.type !== "agentAttachment") return;

  const attachmentId = route.type === "agentAttachment" ? route.attachmentId : route.id;
  const attachment = state.attachmentDetails[attachmentId] || attachmentById(attachmentId);
  if (!attachment || attachmentKind(attachment) !== "file") return;
  const format = String(attachment.format || attachmentFormat(attachment)).toLowerCase();
  if (format !== "markdown") return;

  state.renderedViewHtml = "";
  render();
}

function renderParsedMarkdown(text, options = {}) {
  const unsafe = window.marked.parse(text, { gfm: true });
  const safe = window.DOMPurify.sanitize(unsafe, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: ["embed", "iframe", "img", "object", "script", "style"],
    FORBID_ATTR: ["style", "srcset"],
  });
  return `<div class="${escapeAttr(markdownViewerClassName(options))}">${safe}</div>`;
}

function renderPlainTextMarkdown(text, options = {}) {
  const className = String(options.fallbackClassName || "attachment-text-viewer").trim() || "attachment-text-viewer";
  const emptyText = Object.prototype.hasOwnProperty.call(options, "emptyText") ? options.emptyText : "No content";
  return `<pre class="${escapeAttr(className)}">${escapeHtml(text || emptyText)}</pre>`;
}

function markdownViewerClassName(options = {}) {
  return String(options.viewerClassName || "markdown-viewer").trim() || "markdown-viewer";
}

function messageIcon(block) {
  if (inquiryResponseBlock(block)) return iconSvg("badgeQuestionMark");
  if (block.kind === "run_summary") return iconSvg("scanText");
  if (block.role === "user") return iconSvg("squareUserRound");
  if (block.role === "assistant") return iconSvg("botMessageSquare");
  if (["tool_call", "tool_result"].includes(block.kind)) return iconSvg("hammer");
  return "";
}

function emptyState(title, body) {
  return `
    <section class="empty-state">
      <strong>${escapeHtml(title)}</strong>
      <p>${escapeHtml(body)}</p>
    </section>
  `;
}

function emptyRow(title, body) {
  return `
    <div class="card">
      <div class="card-title"><strong>${escapeHtml(title)}</strong><span>${escapeHtml(body)}</span></div>
    </div>
  `;
}

function kv(label, value) {
  const display = value === null || value === undefined || value === "" ? "n/a" : String(value);
  return `<div class="kv"><span>${escapeHtml(label)}</span><strong class="wrap-anywhere">${escapeHtml(display)}</strong></div>`;
}

function unreadAgents() {
  return state.agents
    .filter((agent) => agent.unread)
    .sort(compareUnreadAgents);
}

function compareUnreadAgents(a, b) {
  const byPriority = agentPriority(b) - agentPriority(a);
  if (byPriority !== 0) return byPriority;

  const byActivity = agentActivityTimestamp(b) - agentActivityTimestamp(a);
  if (byActivity !== 0) return byActivity;

  return compareDisplayText(a.name || a.key, b.name || b.key);
}

function agentActivityTimestamp(agent) {
  return Date.parse(agent.updated_at || agent.finished_at || agent.started_at || agent.created_at || "") || 0;
}

function agentProjectGroups(query) {
  const agentsByProject = groupBy(state.agents, (agent) => agent.project_key || "unassigned");
  const projectKeys = new Set([
    ...state.projects.map((project) => project.key),
    ...Object.keys(agentsByProject),
  ]);

  return [...projectKeys]
    .sort(compareAgentProjectKeys)
    .map((projectKey) => agentProjectGroup(projectKey, agentsByProject[projectKey] || [], query))
    .filter(Boolean);
}

function agentProjectGroup(projectKey, agents, query) {
  const project = findProject(projectKey);
  const projectMatch = project ? projectMatches(project, query) : String(projectKey || "").toLowerCase().includes(query);
  const filteredAgents = agents
    .filter((agent) => !query || projectMatch || agentMatches(agent, query))
    .sort(compareAgentsByName);

  if (query && !projectMatch && filteredAgents.length === 0) return null;
  if (!query && !project && filteredAgents.length === 0) return null;

  return { projectKey, agents: filteredAgents };
}

function agentsForProject(projectKey) {
  return state.agents
    .filter((agent) => agent.project_key === projectKey)
    .sort(compareAgentsByName);
}

function agentArchiveable(agent) {
  return !!agent && !agent.running && agent.status !== "running";
}

function archiveableAgents() {
  return state.agents.filter(agentArchiveable);
}

function selectedBulkArchiveKeys() {
  syncBulkArchiveSelection();
  return [...state.bulkArchiveSelection];
}

function syncBulkArchiveSelection() {
  const activeKeys = new Set(state.agents.map((agent) => agent.key));
  state.bulkArchiveSelection.forEach((key) => {
    const agent = state.agents.find((item) => item.key === key);
    if (!activeKeys.has(key) || !agentArchiveable(agent)) state.bulkArchiveSelection.delete(key);
  });
}

function compareAgentProjectKeys(a, b) {
  const project = findProject(a);
  const otherProject = findProject(b);
  const byProject = compareDisplayText(
    project?.name || project?.key || a,
    otherProject?.name || otherProject?.key || b
  );
  if (byProject !== 0) return byProject;

  return compareDisplayText(a, b);
}

function compareAgentsByName(a, b) {
  const byName = compareDisplayText(a.name || a.key, b.name || b.key);
  if (byName !== 0) return byName;

  return compareDisplayText(a.key, b.key);
}

function compareDisplayText(a, b) {
  return String(a || "").localeCompare(String(b || ""), undefined, { sensitivity: "base", numeric: true });
}

function agentPriority(agent) {
  if (agent.awaiting_input) return 5;
  if (agent.unread) return 4;
  if (agent.blocked) return 3;
  if (agent.running) return 2;
  return 1;
}

function agentMatches(agent, query) {
  if (!query) return true;
  return [
    agent.name,
    agent.key,
    agent.project_key,
    agent.template_key,
    agent.agent,
    agent.status,
    agent.last_result,
    agent.summary,
  ].some((value) => String(value || "").toLowerCase().includes(query));
}

function projectMatches(project, query) {
  if (!query) return true;
  return [
    project.name,
    project.key,
    project.group,
    project.status,
    project.health_status,
    project.app_status,
    project.branch,
    project.commit_hash,
    project.service,
    project.image,
  ].some((value) => String(value || "").toLowerCase().includes(query));
}

function setHeader(title, subtitle, subtitleIcon = "folder") {
  els.title.textContent = title;
  setHeaderSubtitleIcon(subtitleIcon);
  setHeaderSubtitle(subtitle);
  syncUnreadAlert();
  syncDetailHeaderLayout();
}

function setHeaderSubtitleIcon(icon) {
  state.headerSubtitleIcon = headerSubtitleIconName(icon);
}

function setHeaderSubtitle(text) {
  state.headerSubtitle = String(text || "");
  renderHeaderSubtitle();
}

function renderHeaderSubtitle() {
  const value = state.headerSubtitle;
  const icon = state.refreshing ? iconSvg("hourglass") : iconSvg(state.headerSubtitleIcon);
  const className = state.refreshing ? "subtitle-status subtitle-refresh" : "subtitle-status";
  els.subtitle.innerHTML = `<span class="${className}"><span class="subtitle-icon" aria-hidden="true">${icon}</span><span class="subtitle-status-text">${escapeHtml(value)}</span></span>`;
}

function headerSubtitleIconName(icon) {
  const requested = String(icon || "").trim();
  const aliases = {
    A: "folder",
    HQ: "activity",
  };
  const name = aliases[requested] || requested || "folder";
  return ICONS[name] ? name : "folder";
}

function syncUnreadAlert() {
  const agents = unreadAgents();
  const count = agents.length;
  if (count === 0) state.unreadPanelOpen = false;

  els.mark.innerHTML = brandLogoHtml(count);
  els.mark.classList.toggle("has-unread", count > 0);
  els.mark.classList.toggle("unread-panel-open", state.unreadPanelOpen && count > 0);
  els.mark.setAttribute("aria-label", unreadLogoLabel(count));
  els.mark.setAttribute("title", unreadLogoLabel(count));
  els.mark.setAttribute("aria-expanded", state.unreadPanelOpen && count > 0 ? "true" : "false");
  els.mark.setAttribute("aria-disabled", count > 0 ? "false" : "true");
  renderUnreadAgentsPanel(agents);
}

function unreadLogoLabel(count) {
  if (count === 0) return "No unread agents";
  const noun = count === 1 ? "agent" : "agents";
  return `${count} unread ${noun}`;
}

function brandLogoHtml(count = 0) {
  const version = document.documentElement.dataset.assetVersion || "";
  const suffix = version ? `?v=${encodeURIComponent(version)}` : "";
  const badge = count > 0
    ? `<span class="logo-alert-badge" aria-hidden="true">${escapeHtml(compactCount(count))}</span>`
    : "";
  return `<img class="brand-logo" src="/remote-logo.png${suffix}" alt="">${badge}`;
}

function compactCount(count) {
  return count > 99 ? "99+" : String(count);
}

function toggleUnreadPanel() {
  if (unreadAgents().length === 0) {
    closeUnreadPanel();
    return;
  }

  state.unreadPanelOpen = !state.unreadPanelOpen;
  if (state.unreadPanelOpen) {
    state.agentSettingsOpen = false;
    const route = parseRoute();
    const currentAgent = route.type === "agent" || route.type === "agentAttachment" ? findAgent(route.key) : null;
    setAgentSettings(currentAgent);
  }
  syncUnreadAlert();
}

function closeUnreadPanel() {
  if (!state.unreadPanelOpen) return;
  state.unreadPanelOpen = false;
  syncUnreadAlert();
}

function eventPathIncludes(event, element) {
  if (!element) return false;
  if (typeof event.composedPath === "function") {
    return event.composedPath().includes(element);
  }

  const target = event.target;
  return target instanceof Node && (target === element || element.contains(target));
}

function renderUnreadAgentsPanel(agents = unreadAgents()) {
  if (!els.unreadPanel) return;
  const open = state.unreadPanelOpen && agents.length > 0;
  els.unreadPanel.classList.toggle("hidden", !open);
  if (!open) {
    els.unreadPanel.innerHTML = "";
    return;
  }

  els.unreadPanel.innerHTML = `
    <div class="unread-panel-header">
      <strong>Unread agents</strong>
      <span>${escapeHtml(unreadLogoLabel(agents.length))}</span>
    </div>
    <div class="unread-panel-list">
      ${agents.map(renderAgentRow).join("")}
    </div>
  `;
}

function iconSvg(name) {
  return ICONS[name]?.trim() || "";
}

function statusIcon(passed) {
  return iconSvg(passed ? "check" : "x");
}

function pushSupport() {
  const missing = [];
  if (!("serviceWorker" in navigator)) missing.push("Service Worker");
  if (!("PushManager" in window)) missing.push("Push API");
  if (!("Notification" in window)) missing.push("Notifications");
  return {
    supported: missing.length === 0,
    detail: missing.length ? `${missing.join(", ")} unavailable in this browser` : "Browser supports push notifications",
  };
}

function pushOriginWarning() {
  if (window.isSecureContext) return "";
  if (isMagicDnsHost()) return "MagicDNS push requires Tailscale HTTPS. Open Tycho through the HTTPS .ts.net URL before enabling notifications.";
  return "Browser push requires HTTPS except localhost.";
}

function isMagicDnsHost() {
  return location.hostname.endsWith(".ts.net");
}

function notificationPermissionLabel() {
  if (!("Notification" in window)) return "n/a";
  return Notification.permission;
}

function setAgentSettings(agent) {
  if (!agent) {
    state.agentSettingsOpen = false;
    setAgentProjectButton(null);
    els.agentSettings.classList.add("hidden");
    els.agentSettings.setAttribute("aria-expanded", "false");
    els.agentSettingsPanel.classList.add("hidden");
    els.agentSettingsPanel.innerHTML = "";
    syncDetailHeaderLayout();
    return;
  }

  setAgentProjectButton(agent);
  els.agentSettings.classList.remove("hidden");
  els.agentSettings.setAttribute("aria-expanded", state.agentSettingsOpen ? "true" : "false");
  els.agentSettingsPanel.innerHTML = agentSettingsHtml(agent);
  els.agentSettingsPanel.classList.toggle("hidden", !state.agentSettingsOpen);
  syncDetailHeaderLayout();
}

function setAgentProjectButton(agent) {
  if (!agent?.project_key) {
    els.agentProject.classList.add("hidden");
    delete els.agentProject.dataset.openProject;
    els.agentProject.setAttribute("aria-label", "Open project");
    els.agentProject.setAttribute("title", "Open project");
    return;
  }

  const label = `Open project ${agentProjectLabel(agent)}`;
  els.agentProject.classList.remove("hidden");
  els.agentProject.dataset.openProject = agent.project_key;
  els.agentProject.setAttribute("aria-label", label);
  els.agentProject.setAttribute("title", label);
}

function toggleAgentSettings() {
  const route = parseRoute();
  const agent = route.type === "agent" || route.type === "agentAttachment" ? findAgent(route.key) : null;
  if (!agent) return;

  state.agentSettingsOpen = !state.agentSettingsOpen;
  if (state.agentSettingsOpen) closeUnreadPanel();
  setAgentSettings(agent);
}

function agentSettingsHtml(agent) {
  const disabled = agentIsRunning(agent) ? "disabled" : "";
  return `
    <div class="agent-settings-grid">
      ${kv("Project", agentProjectLabel(agent))}
      ${kv("Template", agentTemplateLabel(agent))}
      ${kv("Harness", agent.agent || "agent")}
      ${kv("Status", statusLabel(agent))}
      ${kv("Runs", agent.run_count)}
      ${kv("Exit", agent.last_exit_code ?? "n/a")}
      ${kv("Started", timeShort(agent.started_at))}
      ${kv("Finished", timeShort(agent.finished_at))}
      ${kv("Workspace", agent.workspace)}
      ${kv("Sandbox", agent.sandbox_mode)}
      ${kv("Raw log", agent.log_path)}
    </div>
    <div class="agent-settings-actions">
      <button class="inline-icon-button" type="button" data-edit-agent="${escapeAttr(agent.key)}" ${disabled}>${iconSvg("pencil")}<span>Edit agent</span></button>
      <button class="danger inline-icon-button" type="button" data-archive-agent="${escapeAttr(agent.key)}" ${disabled}>${iconSvg("archive")}<span>Archive agent</span></button>
    </div>
    ${agentIsRunning(agent) ? `<p class="field-hint">Stop the agent before editing or archiving it.</p>` : ""}
  `;
}

function setConnection(text) {
  state.connection = text;
  state.refreshing = text === "Refreshing";
  if (state.refreshing) {
    renderHeaderSubtitle();
  } else {
    setHeaderSubtitle(text);
  }
}

function connectionText() {
  return state.connection;
}

function initialDataPending() {
  return !state.lastUpdatedAt && state.failureCount === 0;
}

function refreshedText() {
  if (!state.lastUpdatedAt) return "Connecting";
  return `Connected / refreshed ${timeAgo(state.lastUpdatedAt.toISOString())}`;
}

function setActiveNav(tab) {
  els.nav.querySelectorAll("button[data-tab]").forEach((button) => {
    button.classList.toggle("active", button.dataset.tab === tab);
  });
}

function setNavHidden(hidden) {
  state.navHidden = hidden;
  els.nav.classList.toggle("nav-hidden", hidden);
}

function syncDetailHeaderLayout() {
  if (!els.header.classList.contains("detail-header")) {
    els.view.style.removeProperty("--detail-header-height");
    return;
  }

  els.view.style.setProperty("--detail-header-height", `${Math.ceil(els.header.getBoundingClientRect().height)}px`);
}

function showNav() {
  setNavHidden(false);
}

function handleScrollDirection() {
  state.scrollTicking = false;
  updateGoRecentVisibility();
  const route = parseRoute();
  const currentY = Math.max(0, window.scrollY);
  const delta = currentY - state.lastScrollY;
  if (Math.abs(delta) > 0 && !state.preserveSummaryOnAutoScroll) closeAgentSummary();
  if (route.type !== "tab") {
    state.lastScrollY = window.scrollY;
    setNavHidden(false);
    return;
  }

  if (currentY < 16) {
    setNavHidden(false);
    state.lastScrollY = currentY;
    return;
  }
  if (Math.abs(delta) < 8) return;

  if (delta > 0 && currentY > 96) {
    setNavHidden(true);
  } else if (delta < 0) {
    setNavHidden(false);
  }
  state.lastScrollY = currentY;
}

function onScroll() {
  if (state.scrollTicking) return;
  state.scrollTicking = true;
  window.requestAnimationFrame(handleScrollDirection);
}

function findAgent(key) {
  return state.agents.find((agent) => agent.key === key) || null;
}

function upsertAgent(agent) {
  if (!agent?.key) return;

  const index = state.agents.findIndex((item) => item.key === agent.key);
  if (index >= 0) state.agents[index] = agent;
  else state.agents.unshift(agent);
}

function removeAgent(key) {
  state.agents = state.agents.filter((agent) => agent.key !== key);
}

function findProject(key) {
  return state.projectDetails[key] || state.projects.find((project) => project.key === key) || null;
}

function agentTemplateSummaries(project) {
  return Array.isArray(project?.agent_template_summaries) ? project.agent_template_summaries : [];
}

function agentTemplateFor(project, templateKey) {
  const templates = agentTemplateSummaries(project);
  return templates.find((template) => template.key === templateKey) || templates[0] || null;
}

function agentTemplateOptionHtml(template, selected) {
  return `
    <option
      value="${escapeAttr(template.key)}"
      data-template-name="${escapeAttr(template.name || template.key)}"
      data-agent="${escapeAttr(normalizeAgentHarness(template.agent))}"
      data-sandbox-mode="${escapeAttr(template.sandbox_mode || "danger-full-access")}"
      data-prompt="${escapeAttr(template.prompt || "")}"
      data-prompt-preview="${escapeAttr(template.prompt_preview || "")}"
      ${selected ? "selected" : ""}
    >${escapeHtml(template.name || template.key)}</option>
  `;
}

function defaultAgentName(project, template) {
  const templateName = String(template?.name || "agent").toLowerCase();
  return `${project?.name || project?.key || "Project"} ${templateName}`;
}

function agentHarnessOptions() {
  const names = (state.setup?.harnesses || []).map((item) => item.name).filter(Boolean);
  return names.length ? names : BUILTIN_AGENT_HARNESSES;
}

function normalizeAgentHarness(value) {
  const options = agentHarnessOptions();
  const normalized = String(value || "").trim().toLowerCase();
  return options.includes(normalized) ? normalized : options[0];
}

function skillsForAgent(agent) {
  const discovered = state.skills[skillKey(agent.project_key, agent.agent)] || [];
  if (discovered.length) return discovered;
  return Array.isArray(agent.skills) ? agent.skills : [];
}

function agentProjectLabel(agent) {
  const project = findProject(agent.project_key);
  return project?.name || agent.project_key || "Project";
}

function agentHarnessLabel(agent) {
  return String(agent?.agent || "agent").trim() || "agent";
}

function agentHeaderLabel(agent) {
  return `${agentProjectLabel(agent)} / ${agentHarnessLabel(agent)}`;
}

function agentTemplateLabel(agent) {
  const project = findProject(agent.project_key);
  const template = agentTemplateSummaries(project).find((item) => item.key === agent.template_key);
  return template?.name || agent.template_key || "Template";
}

function agentSummaryText(agent) {
  return agent.summary || agent.last_result || "No run summary yet.";
}

function inquiryFields(inquiry) {
  const direct = Array.isArray(inquiry?.fields)
    ? inquiry.fields.map(normalizeInquiryField).filter(Boolean)
    : [];
  if (direct.length) return direct;

  const schema = inquiry?.requested_schema || {};
  const properties = schema.properties && typeof schema.properties === "object" ? schema.properties : {};
  const required = new Set(Array.isArray(schema.required) ? schema.required.map(String) : []);
  const fromSchema = Object.entries(properties).map(([key, definition]) => {
    if (!definition || typeof definition !== "object") return null;
    return normalizeInquiryField({
      key,
      label: definition.title || titleFromKey(key),
      description: definition.description || "",
      input_type: schemaInputType(definition),
      required: required.has(key),
      options: schemaOptions(definition),
    });
  }).filter(Boolean);
  if (fromSchema.length) return fromSchema;

  return [{
    key: "response",
    label: "Response",
    description: "",
    input_type: "multiline",
    required: true,
    options: [],
  }];
}

function normalizeInquiryField(field) {
  if (!field || typeof field !== "object") return null;
  const key = String(field.key || "").trim();
  if (!key) return null;

  return {
    key,
    label: String(field.label || titleFromKey(key)).trim() || key,
    description: String(field.description || "").trim(),
    input_type: normalizeInquiryInputType(field.input_type),
    required: field.required === true,
    options: inquiryOptions(field),
  };
}

function normalizeInquiryInputType(value) {
  const type = String(value || "text").trim().toLowerCase();
  if (["textarea", "text_area", "long_text"].includes(type)) return "multiline";
  if (["boolean", "select", "multi_select", "number", "integer", "multiline", "text"].includes(type)) return type;
  return "text";
}

function inquiryOptions(field) {
  return Array.isArray(field?.options) ? field.options.map(String).filter(Boolean) : [];
}

function schemaInputType(definition) {
  const explicit = String(definition["x-input-type"] || "").trim();
  if (explicit) return explicit;
  if (definition.type === "array" && schemaOptions(definition).length) return "multi_select";
  if (Array.isArray(definition.enum) && definition.enum.length) return "select";
  if (definition.type === "boolean") return "boolean";
  if (definition.type === "number") return "number";
  if (definition.type === "integer") return "integer";
  return "text";
}

function schemaOptions(definition) {
  if (Array.isArray(definition.enum)) return definition.enum.map(String).filter(Boolean);
  const items = definition.items;
  if (items && typeof items === "object" && Array.isArray(items.enum)) {
    return items.enum.map(String).filter(Boolean);
  }
  return [];
}

function titleFromKey(key) {
  return String(key || "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .split(" ")
    .map(capitalize)
    .join(" ");
}

function skillKey(projectKey, agent) {
  return `${projectKey || ""}:${agent || ""}`;
}

function preflightKey(projectKey, action) {
  return `${projectKey || ""}:${action || ""}`;
}

function groupBy(list, callback) {
  return list.reduce((groups, item) => {
    const key = callback(item);
    groups[key] ||= [];
    groups[key].push(item);
    return groups;
  }, {});
}

function statusLabel(agent) {
  if (agent.awaiting_input) return "answer";
  if (agent.running) return "running";
  if (agent.blocked) return "blocked";
  if (agent.unread) return "unread";
  return agent.status || "idle";
}

function statusClass(agent) {
  if (agent.awaiting_input || agent.unread) return "need";
  if (agent.running) return "running";
  if (agent.blocked || agent.status === "failed") return "fail";
  if (agent.status === "succeeded" || agent.last_result === "success") return "done";
  return "info";
}

function attentionSchedules() {
  const schedules = state.schedules || [];
  const daemon = state.scheduleDaemon || {};
  const daemonProblem = ["stopped", "stale", "untracked"].includes(daemon.status);
  return schedules.filter((schedule) => daemonProblem || scheduleNeedsAttention(schedule));
}

function upcomingSchedules() {
  return [...(state.schedules || [])].sort((left, right) => {
    const leftTime = Date.parse(left.next_due_at || "") || Number.MAX_SAFE_INTEGER;
    const rightTime = Date.parse(right.next_due_at || "") || Number.MAX_SAFE_INTEGER;
    return leftTime - rightTime || String(left.key).localeCompare(String(right.key));
  });
}

function scheduleNeedsAttention(schedule) {
  if (!schedule) return false;
  if (schedule.paused || schedule.enabled === false) return true;
  if (schedule.last_error === "interactive") return true;
  if (["failed", "error"].includes(schedule.last_status)) return true;
  if (schedule.next_due_at && Date.parse(schedule.next_due_at) < Date.now()) return true;
  return false;
}

function scheduleStatusLabel(schedule) {
  if (schedule.paused || schedule.enabled === false) return "paused";
  if (schedule.last_error === "interactive") return "interactive";
  if (schedule.last_status) return schedule.last_status;
  if (schedule.next_due_at && Date.parse(schedule.next_due_at) < Date.now()) return "due";
  return "scheduled";
}

function scheduleStatusClass(schedule) {
  const label = scheduleStatusLabel(schedule);
  if (label === "paused" || label === "interactive" || label === "due") return "need";
  if (label === "failed" || label === "error") return "fail";
  if (label === "started" || label === "running" || label === "queued") return "running";
  if (label === "succeeded") return "done";
  return "info";
}

function scheduleSubtext(schedule) {
  const project = schedule.project_key || "unknown project";
  const next = schedule.next_due_at ? `next ${timeShort(schedule.next_due_at)}` : "next n/a";
  return `${project} / ${next} / ${humanizeCron(schedule.cron)}`;
}

function scheduleDaemonHeaderPills(daemon) {
  const pills = [];
  if (daemon?.pid) {
    pills.push(`<span class="pill info">pid ${escapeHtml(String(daemon.pid))}</span>`);
  }
  const tick = daemon?.last_tick_finished_at ? `tick ${timeAgo(daemon.last_tick_finished_at)}` : "tick n/a";
  pills.push(`<span class="pill info">${escapeHtml(tick)}</span>`);
  return pills.join("");
}

function humanizeCron(cron) {
  const value = String(cron || "").trim();
  const parts = value.split(/\s+/);
  if (parts.length !== 5) return value || "custom schedule";

  const [minute, hour, dayOfMonth, month, dayOfWeek] = parts;
  const minuteStep = cronStep(minute);
  const hourStep = cronStep(hour);
  const time = cronFixedTime(minute, hour);
  const hourRange = cronRange(hour, 0, 23);
  const minuteWindow = cronValueWindow(minute, 0, 59);
  const everyDay = dayOfMonth === "*" && month === "*" && dayOfWeek === "*";
  const daySuffix = dayOfWeek === "*" ? "" : ` on ${humanizeCronDayOfWeek(dayOfWeek)}`;

  if (minute === "*" && hour === "*" && dayOfMonth === "*" && month === "*") {
    return `every minute${daySuffix}`;
  }
  if (minuteStep && hour === "*" && dayOfMonth === "*" && month === "*") {
    return `${everyUnit(minuteStep, "minute")}${daySuffix}`;
  }
  if (cronFixedNumber(minute, 0, 59) !== null && hour === "*" && everyDay) {
    return `hourly at :${String(minute).padStart(2, "0")}`;
  }
  if (hourStep && cronFixedNumber(minute, 0, 59) !== null && everyDay) {
    return `${everyUnit(hourStep, "hour")} at :${String(minute).padStart(2, "0")}`;
  }
  if (hourRange && minuteWindow && dayOfMonth === "*" && month === "*") {
    return `${humanizeCronMinuteCadence(minute, minuteWindow)}${daySuffix}, ${humanizeCronHourWindow(hourRange, minuteWindow)}`;
  }
  if (time && everyDay) {
    return `daily at ${time}`;
  }
  if (time && dayOfMonth === "*" && month === "*" && dayOfWeek !== "*") {
    return `${humanizeCronDayOfWeek(dayOfWeek)} at ${time}`;
  }
  if (time && dayOfMonth !== "*" && month === "*" && dayOfWeek === "*") {
    return `${humanizeCronDayOfMonth(dayOfMonth)} at ${time}`;
  }
  if (time && dayOfMonth !== "*" && month !== "*" && dayOfWeek === "*") {
    return `${humanizeCronMonth(month)} ${humanizeCronDayNumber(dayOfMonth)} at ${time}`;
  }
  return `cron ${value}`;
}

function cronStep(value) {
  const match = String(value).match(/^\*\/(\d+)$/);
  if (!match) return null;
  const count = Number(match[1]);
  return count > 0 ? count : null;
}

function cronRange(value, min, max) {
  const match = String(value).match(/^(\d+)-(\d+)$/);
  if (!match) return null;
  const first = Number(match[1]);
  const last = Number(match[2]);
  if (first < min || last > max || first > last) return null;
  return { first, last };
}

function cronValueWindow(value, min, max) {
  const text = String(value);
  if (text === "*") return { first: min, last: max };
  const step = cronStep(text);
  if (step) return { first: min, last: max - ((max - min) % step), step };
  const fixed = cronFixedNumber(text, min, max);
  if (fixed !== null) return { first: fixed, last: fixed };
  return cronRange(text, min, max);
}

function humanizeCronMinuteCadence(minute, minuteWindow) {
  if (minute === "*") return "every minute";
  const step = cronStep(minute);
  if (step) return everyUnit(step, "minute");
  if (minuteWindow.first === minuteWindow.last) return `hourly at :${String(minuteWindow.first).padStart(2, "0")}`;
  return `minutes ${minuteWindow.first}-${minuteWindow.last}`;
}

function humanizeCronHourWindow(hourRange, minuteWindow) {
  const start = `${String(hourRange.first).padStart(2, "0")}:${String(minuteWindow.first).padStart(2, "0")}`;
  const finish = `${String(hourRange.last).padStart(2, "0")}:${String(minuteWindow.last).padStart(2, "0")}`;
  return `${start}-${finish}`;
}

function cronFixedTime(minute, hour) {
  const minuteValue = cronFixedNumber(minute, 0, 59);
  const hourValue = cronFixedNumber(hour, 0, 23);
  if (minuteValue === null || hourValue === null) return null;
  return `${String(hourValue).padStart(2, "0")}:${String(minuteValue).padStart(2, "0")}`;
}

function cronFixedNumber(value, min, max) {
  if (!/^\d+$/.test(String(value))) return null;
  const number = Number(value);
  if (number < min || number > max) return null;
  return number;
}

function everyUnit(count, unit) {
  return count === 1 ? `every ${unit}` : `every ${count} ${unit}s`;
}

function humanizeCronDayOfWeek(value) {
  if (value === "1-5") return "weekdays";
  if (value === "0,6" || value === "6,0" || value === "6-7") return "weekends";
  const names = cronNamedList(value, ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], true);
  return names || `days ${value}`;
}

function humanizeCronDayOfMonth(value) {
  const step = cronStep(value);
  if (step) return everyUnit(step, "day");
  return `monthly on day ${humanizeCronDayNumber(value)}`;
}

function humanizeCronDayNumber(value) {
  return String(value).replace(/,/g, ", ");
}

function humanizeCronMonth(value) {
  const names = cronNamedList(value, ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"], false, true);
  return names || `month ${value}`;
}

function cronNamedList(value, names, allowSevenAsSunday = false, oneBased = false) {
  const raw = String(value);
  if (/^\d+$/.test(raw)) {
    const index = cronNameIndex(Number(raw), names.length, allowSevenAsSunday, oneBased);
    return index === null ? null : `${names[index]}${allowSevenAsSunday ? "s" : ""}`;
  }
  if (/^\d+(,\d+)+$/.test(raw)) {
    const labels = raw.split(",").map((item) => {
      const index = cronNameIndex(Number(item), names.length, allowSevenAsSunday, oneBased);
      return index === null ? null : names[index].slice(0, 3);
    });
    return labels.includes(null) ? null : labels.join(", ");
  }
  if (/^\d+-\d+$/.test(raw)) {
    const [start, end] = raw.split("-").map(Number);
    const startIndex = cronNameIndex(start, names.length, allowSevenAsSunday, oneBased);
    const endIndex = cronNameIndex(end, names.length, allowSevenAsSunday, oneBased);
    if (startIndex === null || endIndex === null) return null;
    return `${names[startIndex].slice(0, 3)}-${names[endIndex].slice(0, 3)}`;
  }
  return null;
}

function cronNameIndex(number, length, allowSevenAsSunday, oneBased = false) {
  if (allowSevenAsSunday && number === 7) return 0;
  if (oneBased) number -= 1;
  if (number < 0 || number >= length) return null;
  return number;
}

function scheduleDaemonClass(status) {
  if (status === "running") return "done";
  if (status === "untracked") return "need";
  if (status === "stale") return "need";
  if (status === "stopped") return "fail";
  return "info";
}

function agentIsRunning(agent) {
  return !!agent?.running || agent?.status === "running";
}

function agentSucceeded(agent) {
  return agent?.status === "succeeded" || agent?.status === "success" || agent?.last_result === "success";
}

function shouldOpenSummaryForSucceededAgent(previousAgents, nextAgents) {
  const route = parseRoute();
  if (route.type !== "agent") return false;

  const previous = previousAgents.find((agent) => agent.key === route.key);
  const next = nextAgents.find((agent) => agent.key === route.key);
  return !!previous && !!next && !agentSucceeded(previous) && agentSucceeded(next);
}

function conversationTailMarker(agentKey) {
  const blocks = state.conversations[agentKey]?.blocks;
  if (!Array.isArray(blocks)) return null;
  if (blocks.length === 0) return "empty";

  const block = blocks[blocks.length - 1] || {};
  const metadata = block.metadata || {};
  return JSON.stringify([
    blocks.length,
    block.id || block.created_at || metadata.id || metadata.event_id || metadata.created_at || metadata.timestamp || metadata.completed_at || metadata.tool_use_id || metadata.tool_call_id || "",
    block.kind || "",
    block.role || "",
    block.tool_name || "",
    String(block.content || "").length,
    String(block.content || "").slice(-240),
  ]);
}

function shouldAutoScrollAgentConversation(agentKey) {
  const marker = conversationTailMarker(agentKey);
  const previous = state.conversationTailMarkers[agentKey];
  if (marker !== null) state.conversationTailMarkers[agentKey] = marker;

  if (state.openSummaryAfterAutoScroll) return true;
  return marker !== null && previous !== undefined && marker !== previous;
}

function projectStatusClass(project) {
  if (project.maintenance) return "need";
  if (project.action_state?.status === "running") return "running";
  if (String(project.health_status || "").includes("down") || String(project.health_status || "").includes("error")) return "fail";
  if (project.health_status === "healthy" || project.app_status === "running") return "done";
  return "info";
}

function agentMeta(agent) {
  return [agent.project_key, agent.agent].filter(Boolean).join(" / ");
}

function agentUpdatedAt(agent) {
  return agent?.updated_at || agent?.finished_at || agent?.started_at || agent?.created_at;
}

function agentListSubtextHtml(agent) {
  return [relativeTimeHtml(agentUpdatedAt(agent)), escapeHtml(agentMeta(agent))].filter(Boolean).join(" / ");
}

function actionText(actionState) {
  if (!actionState) return "No active or recent action";
  return [actionState.label, actionState.status, timeShort(actionState.started_at)].filter(Boolean).join(" / ");
}

function latencyText(project) {
  return project.latency_ms === null || project.latency_ms === undefined ? "latency n/a" : `${project.latency_ms}ms`;
}

function blockLabel(block) {
  if (block.kind === "run_summary") return "summary";
  if (block.tool_name) return block.tool_name;
  if (block.role) return block.role;
  return block.kind || "entry";
}

function timeShort(value) {
  if (!value) return "n/a";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "n/a";
  return date.toLocaleString([], {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function timeAgo(value) {
  if (!value) return "not started";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "unknown";
  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 10) return "just now";
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  const days = Math.round(hours / 24);
  return `${days}d ago`;
}

function relativeTimeShort(value) {
  if (!value) return "n/a";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "n/a";

  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.max(1, Math.round(seconds / 60));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.max(1, Math.round(minutes / 60));
  if (hours < 24) return `${hours}h`;
  const days = Math.max(1, Math.round(hours / 24));
  if (days < 30) return `${days}d`;
  const months = Math.max(1, Math.round(days / 30));
  if (months < 12) return `${months}mo`;
  return `${Math.max(1, Math.round(months / 12))}y`;
}

function relativeTimeBucket(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";

  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 15 * 60) return "fresh";
  if (seconds < 60 * 60) return "recent";
  return "";
}

function relativeTimeHtml(value) {
  const bucket = relativeTimeBucket(value);
  return `<span class="relative-time ${escapeAttr(bucket)}">${escapeHtml(relativeTimeShort(value))}</span>`;
}

function capitalize(value) {
  const text = String(value || "");
  return text ? `${text[0].toUpperCase()}${text.slice(1)}` : "";
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

function escapeAttr(value) {
  return escapeHtml(value);
}

function cssIdent(value) {
  const text = String(value || "").toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^-+|-+$/g, "");
  return text || "field";
}

function truncate(value, max = 140) {
  const str = String(value ?? "");
  if (str.length <= max) return str;
  return str.slice(0, Math.max(0, max - 1)).trimEnd() + "…";
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return "";
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(bytes >= 10 * 1024 * 1024 ? 0 : 1)} MB`;
}

async function copyToClipboard(value) {
  if (!value) {
    setConnection("Nothing to copy");
    return;
  }

  if (!navigator.clipboard) {
    setConnection("Copy unavailable in this browser");
    return;
  }

  try {
    await navigator.clipboard.writeText(value);
    setConnection("Copied to clipboard");
  } catch (_error) {
    setConnection("Copy failed");
  }
}

async function enablePushNotifications() {
  const support = pushSupport();
  if (!support.supported) {
    setConnection(support.detail);
    return;
  }
  const originWarning = pushOriginWarning();
  if (originWarning) setConnection(originWarning);

  mutate(async () => {
    const config = await apiGet("/push/config");
    if (!config.configured || !config.public_key) throw new Error("Push notifications are not configured");
    const registration = await navigator.serviceWorker.register("/service-worker.js", { updateViaCache: "none" });
    await registration.update().catch(() => null);
    const permission = await Notification.requestPermission();
    if (permission !== "granted") throw new Error(`Notification permission ${permission}`);
    const existing = await registration.pushManager.getSubscription();
    const subscription = existing || await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(config.public_key),
    });
    await apiPost("/push/subscriptions", subscription.toJSON());
    setConnection("Notifications enabled");
  });
}

async function disablePushNotifications() {
  const support = pushSupport();
  if (!support.supported) {
    setConnection(support.detail);
    return;
  }

  mutate(async () => {
    const subscription = await currentPushSubscription();
    if (subscription) {
      await apiDelete("/push/subscriptions", subscription.toJSON());
      await subscription.unsubscribe();
    }
    setConnection("Notifications disabled");
  });
}

async function sendTestPushNotification() {
  mutate(async () => {
    const subscription = await currentPushSubscription();
    const payload = subscription ? { endpoint: subscription.endpoint } : {};
    const result = await apiPost("/push/test", payload);
    setConnection(result.sent > 0 ? "Test notification sent" : "No notification sent");
  });
}

async function restartRemoteServer() {
  if (!state.setup?.server?.restartable) {
    setConnection("Restart unavailable");
    return;
  }
  if (!window.confirm("Restart HQ Remote server?")) return;

  clearTimeout(state.timer);
  try {
    setConnection("Restarting Remote");
    await apiPost("/server/restart", {});
    await resetRemoteCaches();
    await waitForRemoteRestart();
    state.failureCount = 0;
    setConnection("Remote restarted");
    reloadRemoteUiAfterRestart();
  } catch (error) {
    state.failureCount += 1;
    setConnection(`Restart failed: ${error.message}`);
    render();
    schedule();
  }
}

async function resetRemoteCaches() {
  const tasks = [];
  if ("caches" in window) {
    tasks.push(caches.keys().then((keys) => Promise.all(keys.map((key) => caches.delete(key)))));
  }
  if ("serviceWorker" in navigator) {
    tasks.push(navigator.serviceWorker.getRegistrations()
      .then((registrations) => Promise.all(registrations.map((registration) => registration.update().catch(() => null)))));
  }
  await Promise.all(tasks).catch(() => null);
}

function reloadRemoteUiAfterRestart() {
  const url = new URL(window.location.href);
  url.searchParams.set("hq_restart", String(Date.now()));
  window.location.replace(url.toString());
}

async function waitForRemoteRestart(timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  await delay(500);
  while (Date.now() < deadline) {
    try {
      await apiGet("/health");
      return;
    } catch (_error) {
      await delay(700);
    }
  }
  throw new Error("Remote did not come back online");
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function currentPushSubscription() {
  if (!("serviceWorker" in navigator)) return null;
  const registration = await navigator.serviceWorker.getRegistration("/service-worker.js") ||
    await navigator.serviceWorker.getRegistration("/");
  return registration ? registration.pushManager.getSubscription() : null;
}

function urlBase64ToUint8Array(value) {
  const padding = "=".repeat((4 - value.length % 4) % 4);
  const base64 = `${value}${padding}`.replaceAll("-", "+").replaceAll("_", "/");
  const rawData = atob(base64);
  const output = new Uint8Array(rawData.length);
  for (let index = 0; index < rawData.length; index += 1) {
    output[index] = rawData.charCodeAt(index);
  }
  return output;
}

async function mutate(callback) {
  clearTimeout(state.timer);
  try {
    setConnection("Saving");
    await callback();
    state.failureCount = 0;
    await refresh({ force: true, forceConversation: true, forcePreflight: true, forceProject: true });
  } catch (error) {
    state.failureCount += 1;
    setConnection(error.message);
    render();
    schedule();
  }
}

function createWelcomeSandbox() {
  mutate(async () => {
    const data = await apiPost("/setup/welcome", {});
    const project = data.project;
    if (project?.key) {
      state.projectDetails[project.key] = project;
      navigate({ type: "project", key: project.key });
    }
  });
}

els.nav.addEventListener("click", (event) => {
  showNav();
  const button = event.target.closest("button[data-tab]");
  if (!button) return;
  activateNavTab(button.dataset.tab);
});

els.back.addEventListener("click", () => {
  const route = parseRoute();
  if (route.type === "agent") navigate({ type: "tab", tab: "agents" });
  else if (route.type === "agentAttachment") navigate({ type: "agent", key: route.key });
  else if (route.type === "attachment") {
    const attachment = attachmentById(route.id) || state.attachmentDetails[route.id];
    if (attachment?.agent_key) navigate({ type: "agent", key: attachment.agent_key });
    else navigate({ type: "tab", tab: "agents" });
  }
  else if (route.type === "agentForm" && route.mode === "edit") navigate({ type: "agent", key: route.key });
  else if (route.type === "agentForm" && route.mode === "clone") navigate({ type: "agentArchive", key: route.key });
  else if (route.type === "agentForm" && route.mode === "create") navigate({ type: "project", key: route.projectKey });
  else if (route.type === "agentArchive") navigate({ type: "agent", key: route.key });
  else if (route.type === "project" || route.type === "guard") navigate({ type: "tab", tab: "agents" });
  else if (route.type === "hiddenSettings") navigate({ type: "tab", tab: "settings" });
  else navigate({ type: "tab", tab: "now" });
});

els.agentProject.addEventListener("click", () => {
  const projectKey = els.agentProject.dataset.openProject;
  if (projectKey) navigate({ type: "project", key: projectKey });
});

els.agentSettings.addEventListener("click", toggleAgentSettings);

els.mark.addEventListener("click", toggleUnreadPanel);

els.unreadPanel.addEventListener("click", (event) => {
  const agentButton = event.target.closest("[data-open-agent]");
  if (agentButton) {
    closeUnreadPanel();
    navigate({ type: "agent", key: agentButton.dataset.openAgent });
    return;
  }

  const tabButton = event.target.closest("[data-open-tab]");
  if (tabButton) {
    closeUnreadPanel();
    navigate({ type: "tab", tab: tabButton.dataset.openTab });
  }
});

els.agentSettingsPanel.addEventListener("click", (event) => {
  const editAgentButton = event.target.closest("[data-edit-agent]");
  if (editAgentButton) {
    navigate({ type: "agentForm", mode: "edit", key: editAgentButton.dataset.editAgent });
    return;
  }

  const archiveAgentButton = event.target.closest("[data-archive-agent]");
  if (archiveAgentButton) {
    navigate({ type: "agentArchive", key: archiveAgentButton.dataset.archiveAgent });
    return;
  }

  const agentAction = event.target.closest("[data-agent-action]");
  if (agentAction) runAgentAction(agentAction);
});

function saveRemoteToken() {
  setToken(els.tokenInput.value);
  state.failureCount = 0;
  refresh({ force: true, forceConversation: true });
}

els.authPanel.addEventListener("submit", (event) => {
  event.preventDefault();
  saveRemoteToken();
});

els.saveToken.addEventListener("click", saveRemoteToken);

els.view.addEventListener("click", (event) => {
  showNav();
  if (!event.target.closest("[data-attachment-flyout]") && !event.target.closest("[data-toggle-attachments]")) {
    closeAttachmentFlyout();
  }
  if (!event.target.closest("[data-skill-flyout]") && !event.target.closest("[data-toggle-skills]")) {
    closeSkillFlyout();
  }

  const summaryToggle = event.target.closest("[data-toggle-summary]");
  if (summaryToggle) {
    toggleAgentSummary();
    return;
  }
  if (!event.target.closest("[data-agent-summary]")) closeAgentSummary();

  const markdownAnchor = event.target.closest(".markdown-viewer a[href^=\"#\"]");
  if (markdownAnchor && handleMarkdownAnchorClick(markdownAnchor, event)) return;

  const firstWaiting = event.target.closest("[data-first-waiting]");
  if (firstWaiting) {
    const agent = state.agents.find((item) => item.awaiting_input);
    if (agent) navigate({ type: "agent", key: agent.key });
    return;
  }

  if (event.target.closest("[data-toggle-bulk-archive]")) {
    toggleBulkArchiveMode();
    return;
  }

  if (event.target.closest("[data-clear-bulk-archive]")) {
    state.bulkArchiveSelection.clear();
    render();
    return;
  }

  if (event.target.closest("[data-run-bulk-archive]")) {
    archiveSelectedAgents();
    return;
  }

  const tabButton = event.target.closest("[data-open-tab]");
  if (tabButton) {
    navigate({ type: "tab", tab: tabButton.dataset.openTab });
    return;
  }

  if (event.target.closest("[data-create-welcome-sandbox]")) {
    createWelcomeSandbox();
    return;
  }

  const agentButton = event.target.closest("[data-open-agent]");
  if (agentButton) {
    navigate({ type: "agent", key: agentButton.dataset.openAgent });
    return;
  }

  const projectButton = event.target.closest("[data-open-project]");
  if (projectButton) {
    navigate({ type: "project", key: projectButton.dataset.openProject });
    return;
  }

  const createAgentButton = event.target.closest("[data-create-agent]");
  if (createAgentButton) {
    navigate({ type: "agentForm", mode: "create", projectKey: createAgentButton.dataset.createAgent });
    return;
  }

  const editAgentButton = event.target.closest("[data-edit-agent]");
  if (editAgentButton) {
    navigate({ type: "agentForm", mode: "edit", key: editAgentButton.dataset.editAgent });
    return;
  }

  const archiveAgentButton = event.target.closest("[data-archive-agent]");
  if (archiveAgentButton) {
    navigate({ type: "agentArchive", key: archiveAgentButton.dataset.archiveAgent });
    return;
  }

  const cloneAgentButton = event.target.closest("[data-clone-agent]");
  if (cloneAgentButton) {
    navigate({ type: "agentForm", mode: "clone", key: cloneAgentButton.dataset.cloneAgent });
    return;
  }

  const cancelAgentForm = event.target.closest("[data-cancel-agent-form]");
  if (cancelAgentForm) {
    const route = parseRoute();
    const form = cancelAgentForm.closest("form");
    if (form) clearFormDraft(form);
    if (route.type === "agentForm" && route.mode === "edit") navigate({ type: "agent", key: route.key });
    else if (route.type === "agentForm" && route.mode === "clone") navigate({ type: "agentArchive", key: route.key });
    else if (route.type === "agentForm" && route.mode === "create") navigate({ type: "project", key: route.projectKey });
    return;
  }

  const guardButton = event.target.closest("[data-guard-action]");
  if (guardButton) {
    navigate({ type: "guard", key: guardButton.dataset.projectKey, action: guardButton.dataset.guardAction });
    return;
  }

  const agentAction = event.target.closest("[data-agent-action]");
  if (agentAction) {
    runAgentAction(agentAction);
    return;
  }

  const schedulerAction = event.target.closest("[data-scheduler-action]");
  if (schedulerAction) {
    runSchedulerAction(schedulerAction);
    return;
  }

  const scheduleAction = event.target.closest("[data-schedule-action]");
  if (scheduleAction) {
    runScheduleAction(scheduleAction);
    return;
  }

  const skillButton = event.target.closest("[data-insert-skill]");
  if (skillButton) {
    insertSkill(skillButton.dataset.agentKey, skillButton.dataset.insertSkill);
    closeSkillFlyout();
    return;
  }

  const skillToggle = event.target.closest("[data-toggle-skills]");
  if (skillToggle) {
    toggleSkillFlyout();
    return;
  }

  const addPromptAttachment = event.target.closest("[data-add-prompt-attachment]");
  if (addPromptAttachment) {
    closeSkillFlyout();
    closeAttachmentFlyout();
    document.querySelector("[data-prompt-attachment-input]")?.click();
    return;
  }

  const removePromptAttachment = event.target.closest("[data-remove-prompt-attachment]");
  if (removePromptAttachment) {
    removePendingAttachment(removePromptAttachment.dataset.agentKey, removePromptAttachment.dataset.removePromptAttachment);
    return;
  }

  const attachmentToggle = event.target.closest("[data-toggle-attachments]");
  if (attachmentToggle) {
    toggleAttachmentFlyout();
    return;
  }

  const refreshAttachmentButton = event.target.closest("[data-refresh-attachment]");
  if (refreshAttachmentButton) {
    refreshAttachment(refreshAttachmentButton.dataset.refreshAttachment);
    return;
  }

  const deleteAttachmentButton = event.target.closest("[data-delete-attachment]");
  if (deleteAttachmentButton) {
    deleteAttachment(deleteAttachmentButton.dataset.deleteAttachment);
    return;
  }

  const copyButton = event.target.closest("[data-copy]");
  if (copyButton) {
    const value = copyButton.dataset.copy || "";
    copyToClipboard(value);
    return;
  }

  if (event.target.closest("[data-enable-push]")) {
    enablePushNotifications();
    return;
  }

  if (event.target.closest("[data-disable-push]")) {
    disablePushNotifications();
    return;
  }

  if (event.target.closest("[data-test-push]")) {
    sendTestPushNotification();
    return;
  }

  if (event.target.closest("[data-restart-server]")) {
    restartRemoteServer();
    return;
  }

  if (event.target.closest("[data-open-hidden-settings]")) {
    navigate({ type: "hiddenSettings" });
    return;
  }

  const hiddenSetting = event.target.closest("[data-hidden-scope]");
  if (hiddenSetting) {
    updateHiddenSetting(hiddenSetting);
    return;
  }

  const refreshButton = event.target.closest("[data-refresh]");
  if (refreshButton) refresh({ force: true });

  const recentButton = event.target.closest("[data-go-recent]");
  if (recentButton) {
    scrollConversationToRecent();
    return;
  }
});

document.addEventListener("click", (event) => {
  if (eventPathIncludes(event, els.mark) || eventPathIncludes(event, els.unreadPanel)) return;
  closeUnreadPanel();
});

document.addEventListener("click", (event) => {
  if (!agentShellRoute(parseRoute())) return;

  if (!event.target.closest("[data-agent-summary]") && !event.target.closest("[data-toggle-summary]")) {
    closeAgentSummary();
  }
  if (!event.target.closest("[data-attachment-flyout]") && !event.target.closest("[data-toggle-attachments]")) {
    closeAttachmentFlyout();
  }
  if (!event.target.closest("[data-skill-flyout]") && !event.target.closest("[data-toggle-skills]")) {
    closeSkillFlyout();
  }
});

els.view.addEventListener("keydown", (event) => {
  if (event.key !== "Enter") return;
  if (event.target?.id === "prompt-input") {
    if (event.shiftKey || event.isComposing) return;
    if (event.metaKey || event.ctrlKey) return submitPromptFormFromKeyboard(event);
    if (touchKeyboardLikely()) return;

    submitPromptFormFromKeyboard(event);
    return;
  }

  if (event.target?.id === "agent-filter") {
    event.preventDefault();
    const query = state.filters.agents.toLowerCase();
    const firstGroup = agentProjectGroups(query)[0];
    const firstAgent = firstGroup?.agents[0];
    if (firstAgent) navigate({ type: "agent", key: firstAgent.key });
    else if (firstGroup?.projectKey && findProject(firstGroup.projectKey)) navigate({ type: "project", key: firstGroup.projectKey });
  }
});

els.view.addEventListener("paste", (event) => {
  handleClipboardAttachmentPaste(event);
});

els.view.addEventListener("input", (event) => {
  const filter = event.target.closest("[data-filter]");
  if (filter) {
    state.filters[filter.dataset.filter] = filter.value;
    const id = filter.id;
    const selectionStart = filter.selectionStart ?? filter.value.length;
    const selectionEnd = filter.selectionEnd ?? selectionStart;
    render();
    const next = document.getElementById(id);
    if (next) {
      next.focus();
      const start = Math.min(selectionStart, next.value.length);
      const end = Math.min(selectionEnd, next.value.length);
      next.setSelectionRange(start, end);
    }
    return;
  }

  if (event.target.id === "confirm-action") {
    const submit = document.querySelector("#guard-form button[type='submit']");
    if (submit) submit.disabled = !event.target.checked;
  }

  if (event.target.closest("#inquiry-form")) {
    syncViewControls();
  }
});

els.view.addEventListener("focusout", (event) => {
  const control = event.target.closest("input, textarea");
  if (!control || !draftableTextControl(control)) return;
  const form = control.closest("form");
  if (form) saveFormDraft(form);
});

els.view.addEventListener("change", (event) => {
  if (event.target.closest("#inquiry-form")) {
    syncViewControls();
  }

  const agentSelection = event.target.closest("[data-select-agent]");
  if (agentSelection) {
    const key = agentSelection.dataset.selectAgent;
    if (agentSelection.checked) state.bulkArchiveSelection.add(key);
    else state.bulkArchiveSelection.delete(key);
    render();
    return;
  }

  const attachmentInput = event.target.closest("[data-prompt-attachment-input]");
  if (attachmentInput) {
    handlePromptAttachmentFiles(attachmentInput.dataset.agentKey, attachmentInput.files);
    attachmentInput.value = "";
    return;
  }

  const templateSelect = event.target.closest("[data-agent-template-select]");
  if (!templateSelect) return;

  applyAgentTemplateSelection(templateSelect);
});

els.view.addEventListener("submit", (event) => {
  event.preventDefault();
  if (event.target.id === "composer") {
    const form = event.target;
    const button = event.submitter;
    const key = button?.dataset.agentKey || form.dataset.agentKey;
    const promptValue = document.getElementById("prompt-input")?.value.trim() || "";
    const pendingAttachments = pendingAttachmentsFor(key);
    const prompt = promptValue || (pendingAttachments.length ? "Please review the attached files." : "");
    if (!key || !prompt) return;
    closeSkillFlyout();
    mutate(async () => {
      const attachments = await pendingAttachmentPayloads(key);
      await apiPost(`/agents/${encodeURIComponent(key)}/messages`, { prompt, start: true, attachments });
      clearPendingAttachments(key);
      const input = document.getElementById("prompt-input");
      if (input) input.value = "";
      clearFormDraft(form);
    });
  }

  if (event.target.id === "inquiry-form") {
    const form = event.target;
    const key = form.dataset.agentKey;
    const inquiryId = form.dataset.inquiryId;
    const error = validateInquiryForm(form);
    if (error) {
      setConnection(error);
      syncViewControls();
      return;
    }
    if (!key || !inquiryId) return;

    const answer = inquiryAnswerPayload(form);
    closeAttachmentFlyout();
    mutate(async () => {
      const attachments = await pendingAttachmentPayloads(key);
      await apiPost(`/agents/${encodeURIComponent(key)}/inquiries/${encodeURIComponent(inquiryId)}/answer`, { answer, start: true, attachments });
      clearPendingAttachments(key);
      clearFormDraft(form);
    });
  }

  if (event.target.id === "guard-form") {
    const button = event.submitter;
    const projectKey = button?.dataset.projectKey;
    const action = button?.dataset.action;
    if (!projectKey || !action) return;
    mutate(async () => {
      await apiPost(`/projects/${encodeURIComponent(projectKey)}/actions/${encodeURIComponent(action)}`, { confirm: true });
      navigate({ type: "project", key: projectKey });
    });
  }

  if (event.target.id === "agent-form") {
    const form = event.target;
    const mode = form.dataset.mode;
    const agentKey = form.dataset.agentKey;
    const projectKey = form.dataset.projectKey;
    const submitAction = event.submitter?.value || (mode === "edit" ? "save" : "create");
    const payload = agentFormPayload(form);

    mutate(async () => {
      const data = mode === "edit"
        ? await apiPatch(`/agents/${encodeURIComponent(agentKey)}`, payload)
        : mode === "clone"
          ? await apiPost(`/agents/${encodeURIComponent(agentKey)}/clone`, { ...payload, archive_source: true })
          : await apiPost("/agents", { ...payload, project_key: projectKey, start: submitAction === "create-run" });
      const nextAgent = data.agent;
      if (nextAgent?.key) {
        if (mode === "clone") removeAgent(agentKey);
        upsertAgent(nextAgent);
        clearFormDraft(form);
        navigate({ type: "agent", key: nextAgent.key });
      }
    });
  }
});

function runAgentAction(agentAction) {
  const key = agentAction.dataset.agentKey;
  const action = agentAction.dataset.agentAction;
  const confirmation = agentAction.dataset.confirm;
  if (!key || !action) return;
  if (confirmation && !window.confirm(confirmation)) return;

  mutate(async () => {
    await apiPost(`/agents/${encodeURIComponent(key)}/${action}`);
    if (action === "archive") {
      removeAgent(key);
      navigate({ type: "tab", tab: "agents" });
    }
  });
}

function toggleBulkArchiveMode() {
  state.bulkArchiveMode = !state.bulkArchiveMode;
  if (!state.bulkArchiveMode) state.bulkArchiveSelection.clear();
  render();
}

function archiveSelectedAgents() {
  const keys = selectedBulkArchiveKeys();
  if (keys.length === 0) return;

  const noun = keys.length === 1 ? "agent" : "agents";
  if (!window.confirm(`Archive ${keys.length} selected ${noun}? Running agents are not included.`)) return;

  mutate(async () => {
    const result = await apiPost("/agents/archive", { keys });
    const archivedKeys = (result.archived || []).map((item) => item.agent_key).filter(Boolean);
    archivedKeys.forEach(removeAgent);
    state.bulkArchiveSelection.clear();
    state.bulkArchiveMode = false;

    const skipped = result.skipped?.length || 0;
    const failed = result.failed?.length || 0;
    const detail = [skipped ? `${skipped} skipped` : null, failed ? `${failed} failed` : null].filter(Boolean).join(" / ");
    setConnection(detail ? `Archived ${archivedKeys.length} / ${detail}` : `Archived ${archivedKeys.length} ${noun}`);
  });
}

function runSchedulerAction(schedulerAction) {
  const action = schedulerAction.dataset.schedulerAction;
  const confirmation = schedulerAction.dataset.confirm;
  if (!action) return;
  if (confirmation && !window.confirm(confirmation)) return;

  mutate(async () => {
    await apiPost(`/schedules/daemon/${action}`);
    setConnection(`Scheduler daemon ${action} requested`);
  });
}

function runScheduleAction(scheduleAction) {
  const key = scheduleAction.dataset.scheduleKey;
  const action = scheduleAction.dataset.scheduleAction;
  if (!key || !action) return;

  mutate(async () => {
    await apiPost(`/schedules/${encodeURIComponent(key)}/${action}`);
    setConnection(`Schedule ${action} requested`);
  });
}

async function refreshAttachment(id) {
  if (!id) return;

  try {
    setConnection("Refreshing attachment");
    await ensureAttachment(id, true);
    await ensureAttachmentPreview(id, true);
    state.renderedViewHtml = "";
    setConnection("Attachment refreshed");
    render();
  } catch (error) {
    setConnection(error.message);
    render();
  }
}

async function deleteAttachment(id) {
  if (!id) return;

  const attachment = attachmentDetail(id) || attachmentById(id);
  const title = String(attachment?.title || attachmentTarget(attachment) || "this attachment").trim();
  const confirmed = window.confirm(`Delete ${title}? This removes it from the agent. Source files outside Tycho are kept.`);
  if (!confirmed) return;

  clearTimeout(state.timer);
  try {
    setConnection("Deleting attachment");
    const route = parseRoute();
    const data = await apiDelete(`/attachments/${encodeURIComponent(id)}`);
    clearAttachmentCache(id);
    if (data.agent) upsertAgent(data.agent);

    const fallback = deletedAttachmentFallbackRoute(route, id, data.agent || attachment);
    if (fallback) navigate(fallback);
    else {
      state.renderedViewHtml = "";
      render();
    }
    state.failureCount = 0;
    await refresh({ force: true, forceConversation: true, forceProject: true });
  } catch (error) {
    state.failureCount += 1;
    setConnection(error.message);
    render();
    schedule();
  }
}

function clearAttachmentCache(id) {
  revokeAttachmentImage(id);
  delete state.attachmentDetails[id];
  delete state.attachmentImageErrors[id];
  delete state.openedAttachmentLinks[id];
}

function deletedAttachmentFallbackRoute(route, id, agentOrAttachment) {
  const routeAttachmentId = route.type === "agentAttachment" ? route.attachmentId : route.type === "attachment" ? route.id : "";
  if (routeAttachmentId !== id) return null;

  const agentKey = route.type === "agentAttachment" ? route.key : String(agentOrAttachment?.key || agentOrAttachment?.agent_key || "").trim();
  return agentKey ? { type: "agent", key: agentKey } : { type: "tab", tab: "agents" };
}

function updateHiddenSetting(button) {
  const scope = button.dataset.hiddenScope;
  const key = button.dataset.hiddenKey;
  const hidden = hiddenValueFromDataset(button.dataset.hiddenValue);
  if (!scope || !key) return;
  if (button.getAttribute("aria-pressed") === "true") return;

  mutate(async () => {
    const data = await apiPatch("/settings/hidden", { scope, key, hidden });
    state.hiddenSettings = data.hidden || null;
  });
}

function hiddenValueFromDataset(value) {
  if (value === "true") return true;
  if (value === "false") return false;
  return null;
}

function applyAgentTemplateSelection(select) {
  const option = select.selectedOptions[0];
  const form = select.closest("#agent-form");
  if (!option || !form) return;

  const mode = form.dataset.mode;
  const promptInput = form.querySelector("#agent-prompt");
  const harnessSelect = form.querySelector("#agent-harness");
  const sandboxInput = form.querySelector("#agent-sandbox-mode");
  const nameInput = form.querySelector("#agent-name");
  const hint = form.querySelector(".field-hint");

  if (promptInput) promptInput.value = option.dataset.prompt || "";
  if (harnessSelect) harnessSelect.value = normalizeAgentHarness(option.dataset.agent);
  if (sandboxInput) sandboxInput.value = option.dataset.sandboxMode || "danger-full-access";
  if (hint) hint.textContent = option.dataset.promptPreview || "Template defaults are loaded from the project configuration.";
  if (mode === "create" && nameInput) {
    const projectName = form.dataset.projectName || "Project";
    const templateName = String(option.dataset.templateName || "agent").toLowerCase();
    nameInput.value = `${projectName} ${templateName}`;
  }
  saveFormDraft(form);
}

function agentFormPayload(form) {
  const formData = new FormData(form);
  const payload = {
    name: String(formData.get("name") || "").trim(),
    template_key: String(formData.get("template_key") || "").trim(),
    agent: normalizeAgentHarness(formData.get("agent")),
    prompt: String(formData.get("prompt") || "").trim(),
    sandbox_mode: String(formData.get("sandbox_mode") || "").trim(),
  };
  return payload;
}

function inquiryAnswerPayload(form) {
  const agent = findAgent(form.dataset.agentKey);
  const fields = inquiryFields(agent?.latest_inquiry || {});
  const formData = new FormData(form);
  const values = {};

  fields.forEach((field) => {
    const type = normalizeInquiryInputType(field.input_type);
    if (type === "multi_select") {
      const selected = formData.getAll(field.key).map(String).filter(Boolean);
      values[field.key] = selected.length ? selected : null;
      return;
    }

    const raw = String(formData.get(field.key) || "").trim();
    if (!raw) {
      values[field.key] = null;
      return;
    }
    if (type === "boolean") {
      values[field.key] = raw.toLowerCase() === "yes" || raw.toLowerCase() === "true";
    } else if (type === "number") {
      values[field.key] = Number(raw);
    } else if (type === "integer") {
      values[field.key] = Number.parseInt(raw, 10);
    } else {
      values[field.key] = raw;
    }
  });

  return JSON.stringify(values, null, 2);
}

function validateInquiryForm(form) {
  const agent = findAgent(form.dataset.agentKey);
  const fields = inquiryFields(agent?.latest_inquiry || {});
  const formData = new FormData(form);

  for (const field of fields) {
    if (!field.required) continue;
    const type = normalizeInquiryInputType(field.input_type);
    if (type === "multi_select") {
      if (!formData.getAll(field.key).length) return `${field.label} is required`;
    } else if (!String(formData.get(field.key) || "").trim()) {
      return `${field.label} is required`;
    }
  }

  if (!form.querySelector("[data-inquiry-confirm]")?.checked) {
    return "Review the answer before sending";
  }
  return "";
}

function insertSkill(agentKey, skillName) {
  const agent = findAgent(agentKey);
  const input = document.getElementById("prompt-input");
  if (!agent || !input || !skillName) return;
  const insert = `${agent.skill_trigger || "$"}${skillName} `;
  const start = input.selectionStart ?? input.value.length;
  const end = input.selectionEnd ?? input.value.length;
  input.value = `${input.value.slice(0, start)}${insert}${input.value.slice(end)}`;
  input.focus();
  input.setSelectionRange(start + insert.length, start + insert.length);
}

function toggleSkillFlyout() {
  const flyout = document.querySelector("[data-skill-flyout]");
  if (!flyout) return;

  setSkillFlyoutOpen(flyout.classList.contains("hidden"));
}

function closeSkillFlyout() {
  setSkillFlyoutOpen(false);
}

function setSkillFlyoutOpen(open) {
  const flyout = document.querySelector("[data-skill-flyout]");
  const button = document.querySelector("[data-toggle-skills]");
  if (!flyout || !button) return;
  if (open && button.disabled) return;
  if (open) closeAttachmentFlyout();

  flyout.classList.toggle("hidden", !open);
  button.setAttribute("aria-expanded", open ? "true" : "false");
}

function toggleAttachmentFlyout() {
  const flyout = document.querySelector("[data-attachment-flyout]");
  if (!flyout) return;

  setAttachmentFlyoutOpen(flyout.classList.contains("hidden"));
}

function closeAttachmentFlyout() {
  setAttachmentFlyoutOpen(false);
}

function setAttachmentFlyoutOpen(open) {
  const flyout = document.querySelector("[data-attachment-flyout]");
  const button = document.querySelector("[data-toggle-attachments]");
  if (!flyout || !button) return;
  if (open) closeSkillFlyout();

  flyout.classList.toggle("hidden", !open);
  button.setAttribute("aria-expanded", open ? "true" : "false");
}

function toggleAgentSummary() {
  const summary = document.querySelector("[data-agent-summary]");
  if (!summary) return;

  setAgentSummaryOpen(summary.classList.contains("hidden"));
}

function closeAgentSummary() {
  setAgentSummaryOpen(false);
}

function setAgentSummaryOpen(open) {
  const summary = document.querySelector("[data-agent-summary]");
  const button = document.querySelector("[data-toggle-summary]");
  if (!summary || !button) return;

  summary.classList.toggle("hidden", !open);
  button.setAttribute("aria-expanded", open ? "true" : "false");
  window.requestAnimationFrame(syncAgentDockLayout);
}

function scrollConversationToRecent() {
  if (!document.querySelector("[data-conversation-recent]")) return;

  const root = document.scrollingElement || document.documentElement;
  root.scrollTo({ top: root.scrollHeight, behavior: "smooth" });
  window.setTimeout(updateGoRecentVisibility, 600);
}

function queueAgentConversationBottomScroll() {
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(scrollAgentConversationToBottom);
  });
}

function scrollAgentConversationToBottom() {
  if (parseRoute().type !== "agent") return;
  if (!document.querySelector("[data-conversation-recent]")) return;

  const root = document.scrollingElement || document.documentElement;
  const openSummary = state.openSummaryAfterAutoScroll;
  state.preserveSummaryOnAutoScroll = true;
  root.scrollTo({ top: root.scrollHeight, behavior: "auto" });
  state.lastScrollY = Math.max(0, window.scrollY);
  window.requestAnimationFrame(() => {
    if (openSummary) {
      setAgentSummaryOpen(true);
      state.openSummaryAfterAutoScroll = false;
      syncAgentDockLayout();
      root.scrollTo({ top: root.scrollHeight, behavior: "auto" });
    }
    state.lastScrollY = Math.max(0, window.scrollY);
    window.requestAnimationFrame(() => {
      state.lastScrollY = Math.max(0, window.scrollY);
      window.setTimeout(() => {
        state.preserveSummaryOnAutoScroll = false;
        updateGoRecentVisibility();
      }, 0);
    });
  });
}

window.addEventListener("hashchange", () => {
  saveAgentShellFormDrafts();
  closeUnreadPanel();
  state.lastScrollY = window.scrollY;
  showNav();
  render();
  ensureRouteData({ forceConversation: true, forceProject: true }).then(render).catch((error) => setConnection(error.message));
});

window.addEventListener("scroll", onScroll, { passive: true });

window.addEventListener("focusin", () => {
  showNav();
  if (agentShellRoute(parseRoute()) &&
      !document.activeElement?.closest?.("[data-agent-summary]") &&
      !document.activeElement?.closest?.("[data-toggle-summary]")) {
    closeAgentSummary();
  }
  if (agentShellRoute(parseRoute()) &&
      !document.activeElement?.closest?.("[data-attachment-flyout]") &&
      !document.activeElement?.closest?.("[data-toggle-attachments]")) {
    closeAttachmentFlyout();
  }
  if (agentShellRoute(parseRoute()) &&
      !document.activeElement?.closest?.("[data-skill-flyout]") &&
      !document.activeElement?.closest?.("[data-toggle-skills]")) {
    closeSkillFlyout();
  }
});

window.addEventListener("resize", () => {
  syncDetailHeaderLayout();
  syncAgentDockLayout();
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    state.failureCount = 0;
    state.lastScrollY = window.scrollY;
    showNav();
    refresh({ force: true });
  }
});

els.tokenInput.value = token();
render();
refresh({ force: true });

(function setupPullToRefresh() {
  const indicator = document.getElementById("pull-refresh");
  if (!indicator) return;

  const TRIGGER = 70;
  const MAX = 110;
  let startY = null;
  let pulling = false;
  let refreshing = false;

  function atTop() {
    const root = document.scrollingElement || document.documentElement;
    return (root.scrollTop || window.scrollY || 0) <= 0;
  }

  function setHeight(px) {
    indicator.style.height = `${px}px`;
    indicator.classList.toggle("visible", px > 8);
  }

  function reset() {
    pulling = false;
    startY = null;
    indicator.classList.remove("active");
    indicator.style.height = "";
    indicator.classList.remove("visible");
  }

  window.addEventListener("touchstart", (event) => {
    if (refreshing) return;
    if (event.touches.length !== 1) return;
    if (!atTop()) {
      startY = null;
      return;
    }
    startY = event.touches[0].clientY;
    pulling = false;
  }, { passive: true });

  window.addEventListener("touchmove", (event) => {
    if (refreshing || startY === null) return;
    const delta = event.touches[0].clientY - startY;
    if (delta <= 0) {
      if (pulling) reset();
      return;
    }
    if (!atTop()) {
      if (pulling) reset();
      return;
    }
    if (delta > 6) {
      if (!pulling) {
        pulling = true;
        indicator.classList.add("active");
      }
      const eased = Math.min(MAX, delta * 0.5);
      setHeight(eased);
    }
  }, { passive: true });

  window.addEventListener("touchend", () => {
    if (refreshing || !pulling) {
      reset();
      return;
    }
    const height = parseFloat(indicator.style.height) || 0;
    if (height >= TRIGGER * 0.5) {
      refreshing = true;
      indicator.classList.remove("active");
      indicator.classList.add("refreshing", "visible");
      indicator.style.height = "";
      Promise.resolve(refresh({ force: true })).finally(() => {
        refreshing = false;
        indicator.classList.remove("refreshing", "visible");
      });
    } else {
      reset();
    }
    startY = null;
    pulling = false;
  }, { passive: true });

  window.addEventListener("touchcancel", () => {
    if (!refreshing) reset();
    startY = null;
    pulling = false;
  }, { passive: true });
})();
