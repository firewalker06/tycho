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
const AGENT_SORT_STORAGE_KEY = "hq.remote.agentSort";
const DEFAULT_AGENT_SORT = "project_asc";
const AGENT_SORT_OPTIONS = [
  { value: "agent_name_asc", label: "Agents A-Z", icon: "arrowDownAZ", scope: "agents" },
  { value: "agent_name_desc", label: "Agents Z-A", icon: "arrowDownZA", scope: "agents" },
  { value: "agent_updated_desc", label: "Agents latest update", icon: "clockArrowDown", scope: "agents" },
  { value: "agent_updated_asc", label: "Agents oldest update", icon: "clockArrowUp", scope: "agents" },
  { value: "project_asc", label: "Projects ascending", icon: "arrowDownWideNarrow", scope: "projects" },
  { value: "project_desc", label: "Projects descending", icon: "arrowUpWideNarrow", scope: "projects" },
];
const AGENT_SORT_ALIASES = {
  alphabetical: "agent_name_asc",
  updated_desc: "agent_updated_desc",
  updated_asc: "agent_updated_asc",
};
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
  arrowDownAZ: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m3 16 4 4 4-4"></path>
      <path d="M7 20V4"></path>
      <path d="M20 8h-5"></path>
      <path d="M15 10V6.5a2.5 2.5 0 0 1 5 0V10"></path>
      <path d="M15 14h5l-5 6h5"></path>
    </svg>
  `,
  arrowDownZA: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m3 16 4 4 4-4"></path>
      <path d="M7 4v16"></path>
      <path d="M15 4h5l-5 6h5"></path>
      <path d="M15 20v-3.5a2.5 2.5 0 0 1 5 0V20"></path>
      <path d="M20 18h-5"></path>
    </svg>
  `,
  arrowDownWideNarrow: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m3 16 4 4 4-4"></path>
      <path d="M7 20V4"></path>
      <path d="M11 4h10"></path>
      <path d="M11 8h7"></path>
      <path d="M11 12h4"></path>
    </svg>
  `,
  arrowUpWideNarrow: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="m3 8 4-4 4 4"></path>
      <path d="M7 4v16"></path>
      <path d="M11 4h10"></path>
      <path d="M11 8h7"></path>
      <path d="M11 12h4"></path>
    </svg>
  `,
  badgeQuestionMark: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"></path>
      <path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"></path>
      <line x1="12" x2="12.01" y1="17" y2="17"></line>
    </svg>
  `,
  bell: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M10.268 21a2 2 0 0 0 3.464 0"></path>
      <path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8a6 6 0 0 0-12 0c0 4.499-1.411 5.956-2.738 7.326"></path>
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
  clockArrowDown: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12.338 21.994A10 10 0 1 1 21.925 13.227"></path>
      <path d="M12 6v6l2 1"></path>
      <path d="m14 18 4 4 4-4"></path>
      <path d="M18 14v8"></path>
    </svg>
  `,
  clockArrowUp: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <path d="M12.338 21.994A10 10 0 1 1 21.925 13.227"></path>
      <path d="M12 6v6l2 1"></path>
      <path d="m14 18 4-4 4 4"></path>
      <path d="M18 22v-8"></path>
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
  ellipsis: `
    <svg class="ui-icon" aria-hidden="true" viewBox="0 0 24 24">
      <circle cx="12" cy="12" r="1"></circle>
      <circle cx="19" cy="12" r="1"></circle>
      <circle cx="5" cy="12" r="1"></circle>
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
  projectDiffs: {},
  pullRequests: {},
  pullRequestDiffs: {},
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
  scheduleMessages: {},
  filters: {
    agents: "",
  },
  agentSort: initialAgentSort(),
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
  renderedRouteKey: null,
  renderedViewHtml: "",
  agentSettingsOpen: false,
  headerMoreOpen: false,
  headerMoreBadge: "",
  headerMoreContent: "",
  headerMoreKey: "none",
  headerMoreLabel: "More actions",
  unreadPanelOpen: false,
  readMarkTimer: null,
  lastAppBadgeCount: null,
  growlTimer: null,
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
  headerMore: document.getElementById("header-more-button"),
  headerMoreBadge: document.getElementById("header-more-badge"),
  headerMorePanel: document.getElementById("header-more-panel"),
  agentSettingsPanel: document.getElementById("agent-settings-panel"),
  unreadPanel: document.getElementById("unread-agents-panel"),
  authPanel: document.getElementById("auth-panel"),
  growl: document.getElementById("growl"),
  tokenInput: document.getElementById("token-input"),
  saveToken: document.getElementById("save-token-button"),
  view: document.getElementById("view"),
  nav: document.getElementById("bottom-nav"),
};

syncPlatformClasses();

function initialAgentSort() {
  return normalizeAgentSort(sessionStorageValue(AGENT_SORT_STORAGE_KEY, DEFAULT_AGENT_SORT));
}

function normalizeAgentSort(value) {
  const raw = String(value || "").trim();
  const normalized = AGENT_SORT_ALIASES[raw] || raw;
  return AGENT_SORT_OPTIONS.some((option) => option.value === normalized) ? normalized : DEFAULT_AGENT_SORT;
}

function sessionStorageValue(key, fallback = "") {
  try {
    return window.sessionStorage?.getItem(key) || fallback;
  } catch (_error) {
    return fallback;
  }
}

function setSessionStorageValue(key, value) {
  try {
    window.sessionStorage?.setItem(key, value);
  } catch (_error) {
    // Session storage can be unavailable in locked-down browser contexts.
  }
}

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
  const { parts, params } = parsedHashRoute();
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
    return { type: "agentSummary", key: parts[1] };
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
  if (TOP_TABS.includes(parts[0])) return { type: "tab", tab: parts[0] };
  return { type: "tab", tab: "now" };
}

function parsedHashRoute() {
  const hash = location.hash.replace(/^#/, "");
  const [path, query = ""] = hash.split("?", 2);
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
  if (route.type === "agentSummary") return `#agent/${encodeURIComponent(route.key)}/summary`;
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

function navigate(route) {
  const hash = routeHash(route);
  if (location.hash === hash) {
    render();
  } else {
    location.hash = hash;
  }
}

function navigateProjectDiff(button) {
  const route = parseRoute();
  const backTo = agentShellRoute(route)
    ? { type: "agent", key: route.key }
    : route.type === "projectDiff" ? route.backTo : null;
  navigate({
    type: "projectDiff",
    key: button.dataset.openProjectDiff,
    scope: button.dataset.diffScope || "worktree",
    backTo,
  });
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
  if (route.type === "project" || route.type === "projectDiff" || route.type === "projectForm" || route.type === "guard") return "agents";
  if (route.type === "agentForm") return "agents";
  if (route.type === "agent" || route.type === "agentSummary" || route.type === "agentAttachment" || route.type === "agentPullRequests" || route.type === "agentArchive" || route.type === "attachment") return "agents";
  if (route.type === "hiddenSettings") return "settings";
  if (route.type === "scheduleForm" || route.type === "scheduleMessage") return "now";
  return "now";
}

function agentShellRoute(route) {
  return route.type === "agent" || route.type === "agentSummary" || route.type === "agentAttachment" || route.type === "agentPullRequests";
}

function agentWorkspaceRoute(route) {
  if (agentShellRoute(route)) return { type: "agent", key: route.key };
  if (route.type === "projectDiff" && route.backTo?.type === "agent") return route.backTo;
  return null;
}

function agentSplitRoute(route) {
  if (route.type === "agentSummary" || route.type === "agentAttachment" || route.type === "agentPullRequests") return true;
  return route.type === "projectDiff" && route.backTo?.type === "agent";
}

function pollDelay() {
  const intervals = refreshIntervals();
  if (document.hidden) return intervals.hiddenMs;
  if (state.failureCount > 0) return Math.min(3_000 * (2 ** state.failureCount), 20_000);
  const route = parseRoute();
  const workspaceRoute = agentWorkspaceRoute(route);
  const routeAgent = workspaceRoute ? findAgent(workspaceRoute.key) : null;
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
    const routeBeforeRefresh = parseRoute();
    const shouldOpenSucceededSummary = shouldOpenSummaryForSucceededAgent(state.agents, nextAgents, routeBeforeRefresh);
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
    const currentRoute = parseRoute();
    if (shouldOpenSucceededSummary && currentRoute.type === "agent" && currentRoute.key === routeBeforeRefresh.key) {
      navigate({ type: "agentSummary", key: currentRoute.key });
      return;
    }
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
  if (agentShellRoute(route)) {
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
  if (route.type === "agentPullRequests") {
    await ensureAgentPullRequests(route.key, options.forcePullRequests);
    const refs = state.pullRequests[route.key]?.items || [];
    const selected = selectedPullRequestId(route.key, route.pullRequestId);
    const hasSnapshot = refs.find((item) => item.id === selected)?.snapshot;
    if (selected && hasSnapshot) await ensurePullRequestDiff(route.key, selected, options.forcePullRequestDiff);
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
  if (route.type === "projectForm") {
    await ensureProject(route.key, true);
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
  if (route.type === "projectDiff") {
    const workspaceAgent = route.backTo?.type === "agent" ? findAgent(route.backTo.key) : null;
    await Promise.all([
      ensureProject(route.key, true),
      ensureProjectDiff(route.key, route.scope, true),
      workspaceAgent ? ensureConversation(workspaceAgent, options.forceConversation) : null,
      workspaceAgent ? ensureSkills(workspaceAgent) : null,
      workspaceAgent?.project_key ? ensureProject(workspaceAgent.project_key) : null,
    ].filter(Boolean));
  }
  if (route.type === "guard") {
    await ensurePreflight(route.key, route.action, options.forcePreflight);
  }
  if (route.type === "scheduleMessage") {
    await ensureScheduleMessage(route.key, options.forceScheduleMessage || options.force);
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

async function ensureProjectDiff(projectKey, scope = "worktree", force = false) {
  const normalizedScope = normalizeDiffScope(scope);
  const key = projectDiffKey(projectKey, normalizedScope);
  if (!force && state.projectDiffs[key] && !state.projectDiffs[key].loading) return;

  state.projectDiffs[key] = { project_key: projectKey, scope: normalizedScope, loading: true };
  try {
    const data = await apiGet(`/projects/${encodeURIComponent(projectKey)}/git/diff?scope=${encodeURIComponent(normalizedScope)}`);
    state.projectDiffs[key] = data.diff || { project_key: projectKey, scope: normalizedScope, files: [] };
  } catch (error) {
    state.projectDiffs[key] = {
      project_key: projectKey,
      scope: normalizedScope,
      error: error.message,
      files: [],
    };
  }
}

async function ensureAgentPullRequests(agentKey, force = false) {
  if (!agentKey) return;
  const cached = state.pullRequests[agentKey];
  if (!force && cached && !cached.loading) return;

  state.pullRequests[agentKey] = { loading: true, items: cached?.items || [] };
  try {
    const data = await apiGet(`/agents/${encodeURIComponent(agentKey)}/pull-requests`);
    state.pullRequests[agentKey] = { loading: false, items: data.pull_requests || [] };
  } catch (error) {
    state.pullRequests[agentKey] = { loading: false, error: error.message, items: [] };
  }
}

async function ensurePullRequestDiff(agentKey, pullRequestId, force = false) {
  if (!agentKey || !pullRequestId) return;
  const key = pullRequestDiffKey(agentKey, pullRequestId);
  if (!force && state.pullRequestDiffs[key] && !state.pullRequestDiffs[key].loading) return;

  state.pullRequestDiffs[key] = { loading: true };
  try {
    const data = await apiGet(`/agents/${encodeURIComponent(agentKey)}/pull-requests/${encodeURIComponent(pullRequestId)}/diff`);
    state.pullRequestDiffs[key] = data.diff || { id: pullRequestId, files: [] };
  } catch (error) {
    state.pullRequestDiffs[key] = { error: error.message, files: [] };
  }
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
  if (data.agent) {
    upsertAgent(data.agent);
    syncUnreadAlert();
  }
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

async function ensureScheduleMessage(key, force = false) {
  if (!key) return;
  if (!force && state.scheduleMessages[key] && !state.scheduleMessages[key].loading) return;

  state.scheduleMessages[key] = { key, loading: true };
  try {
    const data = await apiGet(`/schedules/${encodeURIComponent(key)}/message`);
    state.scheduleMessages[key] = data.message || { key, content: "" };
  } catch (error) {
    state.scheduleMessages[key] = { key, error: error.message, content: "" };
  }
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
  const workspaceRoute = agentWorkspaceRoute(route);
  if (route.type !== "agent" && !workspaceRoute) cancelAgentReading();
  els.back.classList.toggle("hidden", !subpage);
  els.header.classList.toggle("hidden", onboarding);
  els.nav.classList.toggle("hidden", subpage || onboarding);
  els.view.classList.toggle("no-nav", subpage || onboarding);
  els.view.classList.toggle("onboarding-content", onboarding);
  els.view.classList.toggle("detail-page", subpage && !onboarding);
  els.view.classList.toggle("agent-detail", !onboarding && Boolean(workspaceRoute));
  els.view.classList.toggle("agent-split-active", !onboarding && agentSplitRoute(route));
  els.view.classList.toggle("agent-split-diff", !onboarding && route.type === "projectDiff" && Boolean(workspaceRoute));
  els.header.classList.toggle("detail-header", subpage && !onboarding);
  els.header.classList.remove("header-hidden");
  if (!workspaceRoute) setAgentSettings(null);
  syncHeaderMoreRoute(route);
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
    const shouldScrollConversation = shouldAutoScrollAgentConversation(route.key);
    renderAgent(route.key);
    if (shouldScrollConversation) queueAgentConversationBottomScroll();
  } else if (route.type === "agentSummary") {
    renderAgent(route.key, { summaryMode: true, splitWorkspace: true });
  } else if (route.type === "agentAttachment") {
    renderAgent(route.key, { attachmentId: route.attachmentId, splitWorkspace: true });
  } else if (route.type === "agentPullRequests") {
    renderAgent(route.key, { pullRequestId: route.pullRequestId, splitWorkspace: true });
  } else if (route.type === "attachment") {
    const attachment = state.attachmentDetails[route.id] || attachmentById(route.id);
    if (attachment?.agent_key && findAgent(attachment.agent_key)) {
      els.view.classList.add("agent-detail");
      renderAgent(attachment.agent_key, { attachmentId: route.id, legacyAttachmentRoute: true });
    } else {
      renderAttachmentViewer(route.id);
    }
  } else if (route.type === "project") {
    renderProject(route.key);
  } else if (route.type === "projectDiff") {
    if (route.backTo?.type === "agent" && findAgent(route.backTo.key)) {
      renderAgentProjectDiff(route.backTo.key, route.key, route.scope);
    } else {
      renderProjectDiff(route.key, route.scope);
    }
  } else if (route.type === "projectForm") {
    renderProjectForm(route.key);
  } else if (route.type === "agentForm") {
    renderAgentForm(route);
  } else if (route.type === "agentArchive") {
    renderAgentArchive(route.key);
  } else if (route.type === "guard") {
    renderGuardedAction(route.key, route.action);
  } else if (route.type === "scheduleForm") {
    renderScheduleForm(route);
  } else if (route.type === "scheduleMessage") {
    renderScheduleMessageForm(route);
  } else if (route.type === "hiddenSettings") {
    renderHiddenSettings();
  } else if (route.tab === "agents") {
    renderAgents();
  } else if (route.tab === "settings") {
    renderSetup();
  } else {
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
  if (route.type === "agentSummary") return `agent-summary:${route.key}`;
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
  if (!["agent", "agentSummary", "agentAttachment", "agentPullRequests", "attachment"].includes(route.type)) return false;

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

  const root = conversationScrollRoot();
  const viewportHeight = root === document.scrollingElement || root === document.documentElement ? window.innerHeight : root.clientHeight;
  const currentTop = root === document.scrollingElement || root === document.documentElement ? window.scrollY : root.scrollTop;
  const maxScroll = Math.max(0, root.scrollHeight - viewportHeight);
  const atBottom = maxScroll <= 1 || maxScroll - currentTop <= 80;
  button.classList.toggle("hidden", atBottom);
}

function conversationScrollRoot() {
  const pane = els.view.querySelector("[data-agent-conversation-scroll]");
  if (pane && pane.offsetParent !== null && pane.scrollHeight > pane.clientHeight + 1) return pane;
  return document.scrollingElement || document.documentElement;
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

  const attention = attentionSchedules();
  const rows = scheduleSectionRows(attention);
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
            <div class="compact-actions schedule-management-actions">
              <button class="primary inline-icon-button" type="button" data-new-schedule>${iconSvg("plus")}<span>New schedule</span></button>
            </div>
            ${renderScheduleDaemonActions(daemon, schedules)}
            ${rows.length ? rows.map(renderScheduleRow).join("") : emptyRow("No schedules", "Create a recurring agent schedule from this panel.")}
          </div>
        </details>
      </div>
    </section>
  `;
}

function scheduleSectionRows(attention = attentionSchedules()) {
  const upcoming = upcomingSchedules();
  if (!attention.length) return upcoming;

  const attentionKeys = new Set(attention.map((schedule) => String(schedule.key || "")));
  return [
    ...attention,
    ...upcoming.filter((schedule) => !attentionKeys.has(String(schedule.key || ""))),
  ];
}

function renderScheduleRow(schedule) {
  const className = scheduleStatusClass(schedule);
  const blocked = ["paused", "stopped"].includes(scheduleStatusLabel(schedule)) || schedule.paused || schedule.enabled === false;
  const toggleAction = blocked ? "resume" : "pause";
  const toggleLabel = blocked ? "Resume" : "Pause";
  const toggleIcon = blocked ? "check" : "squareSlash";
  return `
    <div class="detail-row schedule-row">
      <span class="status-mark ${className}" aria-hidden="true">${iconSvg("calendarCheck2")}</span>
      <div class="schedule-row-main">
        <div class="schedule-row-title">
          <strong>${escapeHtml(schedule.name || schedule.key)}</strong>
          <span class="pill ${className}">${escapeHtml(scheduleStatusLabel(schedule))}</span>
        </div>
        <span>${escapeHtml(scheduleSubtext(schedule))}</span>
      </div>
      <div class="schedule-row-end">
        <div class="compact-actions schedule-row-actions">
          <button class="inline-icon-button schedule-run-button" type="button" data-schedule-action="run" data-schedule-key="${escapeAttr(schedule.key)}" aria-label="Run schedule now" title="Run schedule now">${iconSvg("activity")}<span>Run now</span></button>
          <button class="inline-icon-button schedule-toggle-button" type="button" data-schedule-action="${toggleAction}" data-schedule-key="${escapeAttr(schedule.key)}" aria-label="${escapeAttr(toggleLabel)} schedule" title="${escapeAttr(toggleLabel)} schedule">${iconSvg(toggleIcon)}<span>${toggleLabel}</span></button>
          <button class="inline-icon-button" type="button" data-edit-schedule="${escapeAttr(schedule.key)}" aria-label="Edit schedule" title="Edit schedule">${iconSvg("pencil")}<span>Edit</span></button>
          ${schedule.message_source === "file" ? `<button class="inline-icon-button" type="button" data-edit-schedule-message="${escapeAttr(schedule.key)}" aria-label="Edit schedule message" title="Edit schedule message">${iconSvg("fileText")}<span>Message</span></button>` : ""}
          <button class="danger inline-icon-button" type="button" data-delete-schedule="${escapeAttr(schedule.key)}" aria-label="Delete schedule" title="Delete schedule">${iconSvg("trash2")}<span>Delete</span></button>
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

function renderScheduleForm(route) {
  const editing = route.mode === "edit";
  const schedule = editing ? findSchedule(route.key) : null;
  if (editing && !schedule) {
    setHeader("Schedule not found", "It may have been deleted.", "calendarCheck2");
    replaceView(emptyState("Schedule not found", "Return to Now and choose an active schedule."));
    return;
  }

  const projectKey = editing ? schedule.project_key : (route.projectKey || state.projects[0]?.key || "");
  const values = {
    key: editing ? schedule.key : defaultScheduleKey(projectKey),
    name: editing ? (schedule.name || "") : "",
    enabled: editing ? schedule.enabled !== false : true,
    cron: editing ? (schedule.cron || "") : "0 9 * * 1-5",
    timezone: editing ? (schedule.timezone || "local") : "local",
    projectKey,
    agentName: editing ? (schedule.agent_name || "") : "",
    messageSource: editing ? (schedule.message_source || "inline") : "inline",
    message: editing ? (schedule.message || "") : "",
    messageFile: editing ? (schedule.message_file || "") : "",
    overlap: editing ? (schedule.policy?.overlap || "skip") : "skip",
    missed: editing ? (schedule.policy?.missed || "run_once_on_start") : "run_once_on_start",
    archivePreviousAgent: editing ? schedule.policy?.archive_previous_agent !== false : true,
  };

  setHeader(editing ? "Edit schedule" : "Add schedule", editing ? schedule.name || schedule.key : "Recurring agent", "calendarCheck2");
  replaceView(`
    <form id="schedule-form" class="agent-form schedule-form" data-mode="${editing ? "edit" : "create"}" data-schedule-key="${escapeAttr(schedule?.key || "")}">
      <section class="field-card">
        <label class="field-label" for="schedule-key">Key</label>
        <input id="schedule-key" name="key" type="text" value="${escapeAttr(values.key)}" autocomplete="off" ${editing ? "readonly" : "required"}>
        <span class="field-hint">${editing ? "Schedule keys are fixed after creation." : "Use a short stable key, such as weekly-maintenance."}</span>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-name">Name</label>
        <input id="schedule-name" name="name" type="text" value="${escapeAttr(values.name)}" autocomplete="off" placeholder="Weekly maintenance">
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-project">Project</label>
        <select id="schedule-project" name="project_key" required>
          ${scheduleProjectOptions(values.projectKey)}
        </select>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-cron">Cron</label>
        <input id="schedule-cron" name="cron" type="text" value="${escapeAttr(values.cron)}" autocomplete="off" required>
        <span class="field-hint">${escapeHtml(humanizeCron(values.cron))}</span>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-timezone">Timezone</label>
        <select id="schedule-timezone" name="timezone">
          <option value="local" ${values.timezone === "local" ? "selected" : ""}>Local</option>
          <option value="UTC" ${values.timezone === "UTC" ? "selected" : ""}>UTC</option>
        </select>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-agent-name">Agent name</label>
        <input id="schedule-agent-name" name="agent_name" type="text" value="${escapeAttr(values.agentName)}" autocomplete="off" placeholder="Defaults to schedule name">
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-message-source">Message source</label>
        <select id="schedule-message-source" name="message_source" data-schedule-message-source>
          <option value="inline" ${values.messageSource === "inline" ? "selected" : ""}>Inline message</option>
          <option value="file" ${values.messageSource === "file" ? "selected" : ""}>Message file</option>
        </select>
      </section>
      <section class="field-card" data-schedule-message-mode="inline">
        <label class="field-label" for="schedule-message">Message</label>
        <textarea id="schedule-message" name="message" rows="8">${escapeHtml(values.message)}</textarea>
      </section>
      <section class="field-card" data-schedule-message-mode="file">
        <label class="field-label" for="schedule-message-file">Message file</label>
        <input id="schedule-message-file" name="message_file" type="text" value="${escapeAttr(values.messageFile)}" autocomplete="off" placeholder="schedules/weekly-maintenance.md">
        <span class="field-hint">Path must be relative and under schedules/.</span>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-overlap">Overlap policy</label>
        <select id="schedule-overlap" name="overlap">
          ${scheduleOptionHtml(["skip", "queue", "parallel"], values.overlap)}
        </select>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-missed">Missed policy</label>
        <select id="schedule-missed" name="missed">
          ${scheduleOptionHtml(["skip_missed", "run_once_on_start", "run_all_missed"], values.missed)}
        </select>
      </section>
      <section class="field-card checkbox-card">
        <label>
          <input name="enabled" type="checkbox" value="true" ${values.enabled ? "checked" : ""}>
          <span>Enabled</span>
        </label>
        <label>
          <input name="archive_previous_agent" type="checkbox" value="true" ${values.archivePreviousAgent ? "checked" : ""}>
          <span>Archive previous scheduled agent</span>
        </label>
      </section>
      <div class="button-row form-actions">
        <button type="button" data-cancel-schedule-form>Cancel</button>
        <button class="primary inline-icon-button" type="submit" value="save">${iconSvg(editing ? "pencil" : "plus")}<span>${editing ? "Save schedule" : "Create schedule"}</span></button>
      </div>
    </form>
  `);
  syncScheduleMessageFields(document.getElementById("schedule-form"));
}

function renderScheduleMessageForm(route) {
  const schedule = findSchedule(route.key);
  if (!schedule) {
    setHeader("Schedule not found", "It may have been deleted.", "calendarCheck2");
    replaceView(emptyState("Schedule not found", "Return to Now and choose an active schedule."));
    return;
  }

  if (schedule.message_source !== "file" || !schedule.message_file) {
    setHeader("Inline schedule message", schedule.name || schedule.key, "calendarCheck2");
    replaceView(emptyState("No message file", "Inline schedule messages are edited from the schedule form."));
    return;
  }

  const message = state.scheduleMessages[schedule.key];
  setHeader("Edit schedule message", `${schedule.name || schedule.key} / ${schedule.message_file}`, "fileText");
  if (!message || message.loading) {
    replaceView(emptyState("Loading message file", "Fetching the configured markdown file."));
    return;
  }
  if (message.error) {
    replaceView(emptyState("Message file unavailable", message.error));
    return;
  }

  replaceView(`
    <form id="schedule-message-form" class="agent-form schedule-message-form" data-schedule-key="${escapeAttr(schedule.key)}">
      <section class="detail-card">
        <div class="detail-card-body" style="padding-top: 12px;">
          <div class="detail-row">
            <span class="status-mark detail" aria-hidden="true">${iconSvg("fileText")}</span>
            <div><strong>${escapeHtml(schedule.message_file)}</strong><span class="wrap-anywhere">${escapeHtml(message.path || "")}</span></div>
            <span class="pill detail">Markdown</span>
          </div>
        </div>
      </section>
      <section class="field-card">
        <label class="field-label" for="schedule-message-content">Markdown</label>
        <textarea id="schedule-message-content" name="content" rows="18" spellcheck="true">${escapeHtml(message.content || "")}</textarea>
      </section>
      <div class="button-row form-actions">
        <button type="button" data-cancel-schedule-message-form>Cancel</button>
        <button class="primary inline-icon-button" type="submit" value="save">${iconSvg("pencil")}<span>Save markdown</span></button>
      </div>
    </form>
  `);
}

function scheduleProjectOptions(selectedKey) {
  if (!state.projects.length) return `<option value="">No projects available</option>`;
  return state.projects.map((project) => `
    <option value="${escapeAttr(project.key)}" ${project.key === selectedKey ? "selected" : ""}>${escapeHtml(project.name || project.key)}</option>
  `).join("");
}

function scheduleOptionHtml(options, selected) {
  return options.map((option) => `<option value="${escapeAttr(option)}" ${option === selected ? "selected" : ""}>${escapeHtml(option.replaceAll("_", " "))}</option>`).join("");
}

function defaultScheduleKey(projectKey) {
  const base = cssIdent(`${projectKey || "project"}-schedule`);
  const existing = new Set((state.schedules || []).map((schedule) => String(schedule.key || "")));
  if (!existing.has(base)) return base;
  for (let index = 2; index < 100; index += 1) {
    const candidate = `${base}-${index}`;
    if (!existing.has(candidate)) return candidate;
  }
  return `${base}-${Date.now()}`;
}

function findSchedule(key) {
  return (state.schedules || []).find((schedule) => String(schedule.key || "") === String(key || ""));
}

function renderAgents(options = {}) {
  const query = state.filters.agents.trim().toLowerCase();
  const groupMode = agentSortUsesProjectGroups();
  const groups = groupMode ? agentProjectGroups(query) : [];
  const flatAgents = groupMode ? [] : sortedAgentList(query);
  const unread = state.agents.filter((agent) => agent.unread).length;
  const selectedCount = selectedBulkArchiveKeys().length;
  const moreLabel = selectedCount ? `Agent list actions, ${selectedCount} selected` : "Agent list actions";
  const moreBadge = selectedCount ? compactCount(selectedCount) : "";
  setHeader("Agents", `${state.agents.length} managed / ${state.projects.length} projects / ${unread} unread`, "A");
  setHeaderMore(agentsMoreMenuHtml(), moreLabel, "agents", moreBadge);

  replaceView(`
    <div class="top-actions">
      <label class="search-box" for="agent-filter">
        <span class="nav-mark" aria-hidden="true">${iconSvg("search")}</span>
        <input id="agent-filter" type="search" value="${escapeAttr(state.filters.agents)}" placeholder="Filter agents and projects" aria-label="Filter agents and projects" data-filter="agents">
      </label>
      ${agentSortMenuHtml()}
    </div>
    ${renderBulkArchiveBar()}
    ${groupMode
      ? (groups.length ? groups.map((group) => renderAgentGroup(group.projectKey, group.agents)).join("") : renderAgentsEmpty(query))
      : renderFlatAgentList(flatAgents, query)}
  `);
  if (options.focusFilter !== false) focusFilterInput("agents", "agent-filter");
}

function agentSortMenuHtml() {
  const current = currentAgentSortOption();
  const options = AGENT_SORT_OPTIONS.map((option) => {
    const active = state.agentSort === option.value;
    return `
      <button class="agent-sort-option ${active ? "active" : ""}" type="button" role="menuitemradio" data-agent-sort-choice="${escapeAttr(option.value)}" aria-checked="${active ? "true" : "false"}">
        <span>${escapeHtml(option.label)}</span>
      </button>
    `;
  }).join("");

  return `
    <details class="agent-sort-menu" data-agent-sort-menu>
      <summary class="agent-sort-trigger" aria-label="Sort agents: ${escapeAttr(current.label)}" title="${escapeAttr(current.label)}">
        ${iconSvg(current.icon)}
        <span class="sr-only">Sort agents</span>
      </summary>
      <div class="agent-sort-options" role="menu" aria-label="Sort agents">
        ${options}
      </div>
    </details>
  `;
}

function agentsMoreMenuHtml() {
  if (!state.agents.length) return "";

  const selected = selectedBulkArchiveKeys();
  const toggleLabel = state.bulkArchiveMode ? "Cancel selection" : "Select agents";
  const toggleIcon = state.bulkArchiveMode ? "x" : "archive";
  const selectedLabel = selected.length === 1 ? "1 selected" : `${selected.length} selected`;

  return moreMenuHtml([
    moreMenuButton({
      label: toggleLabel,
      icon: toggleIcon,
      attrs: "data-toggle-bulk-archive",
    }),
    state.bulkArchiveMode
      ? moreMenuButton({
          label: "Archive selected",
          sublabel: selectedLabel,
          icon: "archive",
          attrs: "data-run-bulk-archive",
          danger: true,
          disabled: selected.length === 0,
        })
      : "",
  ]);
}

function settingsMoreMenuHtml(setup) {
  const restartable = !!setup?.server?.restartable;
  const hiddenCount = setup?.counts?.hidden_projects || 0;
  return moreMenuHtml([
    moreMenuButton({
      label: "Push notifications",
      sublabel: "Jump to browser alerts",
      icon: "bell",
      attrs: 'data-scroll-settings-section="settings-push-notifications"',
    }),
    moreMenuButton({
      label: "Hidden projects",
      sublabel: `${hiddenCount} hidden`,
      icon: "eyeOff",
      attrs: "data-open-hidden-settings",
    }),
    moreMenuButton({
      label: "Recheck status",
      sublabel: "Refresh readiness",
      icon: "rotateCcw",
      attrs: "data-refresh",
    }),
    moreMenuSeparator(),
    moreMenuButton({
      label: "Restart server",
      sublabel: restartable ? "Reload Remote UI" : "Unavailable",
      icon: "loaderPinwheel",
      attrs: "data-restart-server",
      danger: true,
      disabled: !restartable,
    }),
  ]);
}

function renderFlatAgentList(agents, query) {
  if (!agents.length) return renderAgentsEmpty(query);

  return `
    <section class="agent-group agent-flat-list" aria-label="Agents">
      ${agents.map(renderAgentRow).join("")}
    </section>
  `;
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
    setHeaderMore(null, "Settings actions", "settings");
    replaceView(emptyState("Settings unavailable", "Refresh to load Remote UI readiness."));
    return;
  }

  setHeaderMore(settingsMoreMenuHtml(setup), "Settings actions", "settings");
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
        <div class="section-label"><strong>Server lifecycle</strong><span>${setup.server?.restartable ? "restartable" : "unavailable"}</span></div>
        <div class="detail-row">
          <span class="status-mark ${setup.server?.restartable ? "done" : "fail"}" aria-hidden="true">${statusIcon(setup.server?.restartable)}</span>
          <div><strong>Remote restart</strong><span>${setup.server?.restartable ? "Restart is available from the Settings menu." : "Start Tycho Remote with a restart command to enable restart."}</span></div>
          <span class="pill ${setup.server?.restartable ? "done" : "fail"}">${setup.server?.restartable ? "Ready" : "Off"}</span>
        </div>
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
          ${copyableKv("Projects", `${setup.counts?.projects || 0} active`)}
          ${copyableKv("Hidden", `${setup.counts?.hidden_projects || 0} projects`)}
          ${copyableKv("Archived", `${setup.counts?.archived_projects || 0} archived`)}
          ${copyableKv("Config", setup.config?.loaded ? "hq.yml loaded" : "not loaded")}
          ${copyableKv("Prompts", `${setup.config?.prompt_template_count || 0} templates`)}
          ${copyableKv("Tycho build", tychoBuildLabel(setup))}
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
        ${copyableKv("Root", setup.logs?.root)}
        ${copyableKv("Agent runs", setup.logs?.agent_runs)}
        ${copyableKv("Agent logs", setup.logs?.agent_log_files)}
        ${copyableKv("Action logs", setup.logs?.project_action_logs)}
      </div>
    </details>
    <details class="detail-card">
      <summary>Refresh and preferences</summary>
      <div class="kv-grid">
        ${copyableKv("Running", `${setup.refresh_intervals?.running_agent_ms || 0}ms`)}
        ${copyableKv("Idle", `${setup.refresh_intervals?.idle_ms || 0}ms`)}
        ${copyableKv("Hidden", `${setup.refresh_intervals?.hidden_ms || 0}ms`)}
        ${copyableKv("Auth", setup.auth?.status)}
      </div>
    </details>
  `);
}

function tychoBuildLabel(setup) {
  const version = String(setup?.build?.version || "").trim();
  const assetVersion = String(setup?.build?.asset_version || document.documentElement.dataset.assetVersion || "").trim();
  if (version && assetVersion) return `${version} / UI ${assetVersion}`;
  return version || assetVersion || "unknown";
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
    <section class="detail-card" id="settings-push-notifications">
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
  const pullRequestId = options.pullRequestId || "";
  const summaryMode = options.summaryMode === true;
  const pullRequestMode = Boolean(options.pullRequestId !== undefined);
  const focusedMode = Boolean(attachmentId) || summaryMode || pullRequestMode;
  if (options.splitWorkspace && focusedMode) {
    const detailHtml = summaryMode
      ? renderAgentSummaryView(agent, { floatingActions: false })
      : pullRequestMode
        ? renderAgentPullRequestDiffView(agent, pullRequestId, { floatingActions: false })
        : renderAgentAttachmentView(agent, attachmentId, { floatingActions: false });
    const detailKind = summaryMode ? "summary" : pullRequestMode ? "pull-requests" : "attachment";

    setHeader(agent.name || agent.key, agentHeaderLabel(agent), "A");
    setAgentSettings(agent);
    setHeaderMore(agentMoreMenuHtml(agent), "Conversation actions", agentHeaderMoreKey(agent.key));
    replaceView(renderAgentWorkspace(agent, blocks, {
      detailHtml,
      detailKind,
      focusedMode: true,
    }));
    return;
  }

  const body = summaryMode
    ? renderAgentSummaryView(agent)
    : pullRequestMode
      ? renderAgentPullRequestDiffView(agent, pullRequestId)
    : attachmentId
      ? renderAgentAttachmentView(agent, attachmentId)
      : renderAgentConversationView(agent, blocks);
  setHeader(agent.name || agent.key, agentHeaderLabel(agent), "A");
  setAgentSettings(agent);
  setHeaderMore(agentMoreMenuHtml(agent), "Conversation actions", agentHeaderMoreKey(agent.key));
  replaceView(`
    ${body}
    <section class="agent-dock" data-agent-dock>
      ${agent.latest_inquiry ? renderInquiryForm(agent, { attachmentMode: focusedMode }) : renderAgentComposer(agent, skills, { attachmentMode: focusedMode })}
    </section>
  `);
  if (!focusedMode) scheduleAgentReading(agent);
}

function renderAgentWorkspace(agent, blocks, options = {}) {
  const skills = skillsForAgent(agent);
  const detailKind = options.detailKind || "detail";
  const focusedMode = options.focusedMode !== false;
  const detailHtml = String(options.detailHtml || "").trim();
  const classNames = [
    "agent-workspace",
    detailHtml ? "has-detail" : "conversation-only",
    `agent-workspace-${cssIdent(detailKind)}`,
  ].join(" ");
  const floatingOptions = { recent: true };
  if (detailKind === "summary") floatingOptions.summary = false;

  return `
    <section class="${escapeAttr(classNames)}" data-agent-workspace>
      <section class="agent-conversation-pane" data-agent-conversation-pane aria-label="Conversation">
        <div class="agent-conversation-scroll" data-agent-conversation-scroll data-preserve-scroll data-state-key="agent-conversation:${escapeAttr(agent.key)}">
          ${renderAgentConversationView(agent, blocks, { floatingActions: false })}
        </div>
        ${renderAgentFloatingActions(agent, floatingOptions)}
      </section>
      ${detailHtml ? `<aside class="agent-detail-pane" aria-label="${escapeAttr(detailKind)}">${detailHtml}</aside>` : ""}
      <section class="agent-dock" data-agent-dock>
        ${agent.latest_inquiry ? renderInquiryForm(agent, { attachmentMode: focusedMode }) : renderAgentComposer(agent, skills, { attachmentMode: focusedMode })}
      </section>
    </section>
  `;
}

function renderAgentSummaryView(agent, options = {}) {
  const meta = [statusLabel(agent), timeShort(agent.finished_at || agent.updated_at || agent.created_at)].filter(Boolean).join(" / ");
  return `
    <section class="agent-attachment-shell agent-summary-shell" data-agent-summary-page>
      <section class="attachment-viewer agent-attachment-viewer agent-summary-viewer" aria-label="Summary">
        <div class="agent-attachment-body">
          <div class="section-label"><strong>Summary</strong><span>${escapeHtml(meta || agent.name || agent.key)}</span></div>
          ${renderAgentSummaryContent(agent)}
        </div>
      </section>
    </section>
    ${options.floatingActions === false ? "" : renderAgentFloatingActions(agent, { summary: false })}
  `;
}

function renderAgentSummaryContent(agent) {
  return renderMarkdown(agentSummaryText(agent), {
    viewerClassName: "markdown-viewer agent-summary-markdown-viewer",
    fallbackClassName: "attachment-text-viewer agent-summary-fallback",
    emptyText: "No run summary yet.",
  });
}

function renderAgentConversationView(agent, blocks, options = {}) {
  return `
    <div class="message-list">
      ${blocks.length ? renderConversationBlocks(blocks) : emptyState("No conversation yet", "Send a prompt to start or continue the agent.")}
    </div>
    <div data-conversation-recent aria-hidden="true"></div>
    ${options.floatingActions === false ? "" : renderAgentFloatingActions(agent, { recent: true })}
  `;
}

function renderAgentAttachmentView(agent, attachmentId, options = {}) {
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
    ${options.floatingActions === false ? "" : `${renderAgentFloatingActions(agent, { pullRequests: false })}`}
  `;
}

function renderAgentPullRequestDiffView(agent, pullRequestId, options = {}) {
  const data = state.pullRequests[agent.key] || { loading: true, items: [] };
  const refs = Array.isArray(data.items) ? data.items : [];
  const selectedId = selectedPullRequestId(agent.key, pullRequestId);
  const selected = refs.find((item) => item.id === selectedId) || null;
  const diff = selected ? state.pullRequestDiffs[pullRequestDiffKey(agent.key, selected.id)] : null;
  const body = `
    <section class="agent-pr-diff-shell">
      ${renderPullRequestDiffToolbar(agent, data)}
      ${data.error ? `<section class="notice"><strong>Pull requests unavailable</strong><p>${escapeHtml(data.error)}</p></section>` : ""}
      ${data.loading && !refs.length ? emptyState("Loading pull requests", "Reading pull request attachments from this agent.") : ""}
      ${!data.loading && !data.error && !refs.length ? emptyState("No pull requests", "This agent has no GitHub pull request links or attachments yet.") : ""}
      ${refs.length ? `
        <section class="agent-pr-diff-layout">
          <nav class="pr-diff-list" aria-label="Pull requests">
            ${refs.map((item) => renderPullRequestDiffNavItem(agent, item, selectedId)).join("")}
          </nav>
          <section class="pr-diff-detail" aria-label="Pull request diff">
            ${renderPullRequestDiffDetail(agent, selected, diff)}
          </section>
        </section>
      ` : ""}
    </section>
  `;

  return `
    ${body}
    ${options.floatingActions === false ? "" : `${renderAgentFloatingActions(agent)}`}
  `;
}

function renderPullRequestDiffToolbar(agent, data) {
  const loading = data?.loading;
  return `
    <section class="diff-toolbar pr-diff-toolbar" aria-label="Pull request diff actions">
      <button class="inline-icon-button" type="button" data-refresh-agent-prs="${escapeAttr(agent.key)}" ${loading ? "disabled" : ""}>${iconSvg("rotateCcw")}<span>Refresh list</span></button>
      <button class="inline-icon-button" type="button" data-refresh-all-pr-diffs="${escapeAttr(agent.key)}" ${loading ? "disabled" : ""}>${iconSvg("code")}<span>Refresh diffs</span></button>
    </section>
  `;
}

function renderPullRequestDiffNavItem(agent, item, selectedId) {
  const active = item.id === selectedId;
  const snapshot = item.snapshot || null;
  const meta = [
    item.repository ? `${item.repository}#${item.number}` : `PR #${item.number}`,
    pullRequestFreshnessLabel(item),
  ].filter(Boolean).join(" / ");
  return `
    <a class="pr-diff-nav-item${active ? " active" : ""}" href="${escapeAttr(routeHash({ type: "agentPullRequests", key: agent.key, pullRequestId: item.id }))}" ${active ? 'aria-current="page"' : ""}>
      <span class="status-mark ${snapshot?.fresh === false ? "need" : snapshot ? "done" : "idle"}" aria-hidden="true">${iconSvg("code")}</span>
      <span class="pr-diff-nav-copy">
        <strong>${escapeHtml(item.title || item.url || "Pull request")}</strong>
        <span>${escapeHtml(meta)}</span>
        ${item.error ? `<span>${escapeHtml(item.error)}</span>` : ""}
      </span>
    </a>
  `;
}

function renderPullRequestDiffDetail(agent, item, diff) {
  if (!item) return emptyState("Choose a pull request", "Select a pull request to inspect its diff.");

  const snapshot = item.snapshot || null;
  const stale = snapshot?.fresh === false;
  const header = `
    <section class="summary-card diff-summary-card pr-diff-summary">
      <div class="card-title">
        <strong>${escapeHtml(item.title || `${item.repository}#${item.number}`)}</strong>
        <span>${escapeHtml([item.repository, item.number ? `#${item.number}` : "", pullRequestFreshnessLabel(item)].filter(Boolean).join(" / "))}</span>
      </div>
      <div class="button-row">
        <button class="inline-icon-button" type="button" data-refresh-pr-diff="${escapeAttr(item.id)}" data-agent-key="${escapeAttr(agent.key)}">${iconSvg("rotateCcw")}<span>${snapshot ? "Refresh diff" : "Fetch diff"}</span></button>
        ${item.url ? `<a class="button-link" href="${escapeAttr(item.url)}" target="_blank" rel="noreferrer">Open PR</a>` : ""}
      </div>
      <div class="chip-row">
        ${snapshot ? `<span class="chip ${stale ? "need" : "done"}">${stale ? "stale" : snapshot.fresh === true ? "fresh" : "snapshot"}</span>` : `<span class="chip need">not fetched</span>`}
        ${snapshot?.head_sha ? `<span class="chip detail">${escapeHtml(shortSha(snapshot.head_sha))}</span>` : ""}
        ${snapshot?.truncated ? `<span class="chip need">truncated</span>` : ""}
      </div>
    </section>
  `;

  if (!snapshot) return `${header}${emptyState("Diff not fetched", "Fetch this pull request diff to inspect it in Tycho.")}`;
  if (!diff || diff.loading) return `${header}${emptyState("Loading diff", "Reading the saved pull request diff snapshot.")}`;
  if (diff.error) return `${header}<section class="notice"><strong>Diff unavailable</strong><p>${escapeHtml(diff.error)}</p></section>`;

  const files = Array.isArray(diff.files) ? diff.files : [];
  const summary = `${files.length} ${files.length === 1 ? "file" : "files"} / +${diff.additions || 0} -${diff.deletions || 0}`;
  return `
    ${header}
    <section class="summary-card diff-summary-card">
      <div class="card-title">
        <strong>${escapeHtml(summary)}</strong>
        <span>${escapeHtml([diff.head_sha ? `head ${shortSha(diff.head_sha)}` : "", diff.fetched_at ? `fetched ${timeShort(diff.fetched_at)}` : ""].filter(Boolean).join(" / "))}</span>
      </div>
    </section>
    <section class="diff-viewer" aria-label="Pull request diff">
      ${files.length ? files.map(renderProjectDiffFile).join("") : emptyState("No file changes", "This pull request diff snapshot has no textual file changes.")}
    </section>
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

function renderAgentFloatingActions(agent, options = {}) {
  const summary = options.summary === false ? "" : renderAgentSummaryToggle(agent);
  const pullRequests = options.pullRequests === false ? "" : renderAgentPullRequestsToggle(agent);
  const recent = options.recent
    ? `<button class="agent-floating-pill go-recent-fab hidden" type="button" data-go-recent>Go to recent</button>`
    : "";
  const actions = `${summary}${pullRequests}${recent}`;
  if (!actions) return "";

  return `
    <div class="agent-floating-actions" aria-label="Agent shortcuts">
      ${actions}
    </div>
  `;
}

function renderAgentSummaryToggle(agent) {
  return `
    <button class="agent-floating-pill summary-fab" type="button" data-open-agent-summary="${escapeAttr(agent.key)}">
      ${iconSvg("scanText")}
      <span>Summary</span>
    </button>
  `;
}

function renderAgentPullRequestsToggle(agent) {
  const count = agentPullRequestCount(agent);
  if (count < 1) return "";

  return `
    <button class="agent-floating-pill" type="button" data-open-agent-pr-diffs="${escapeAttr(agent.key)}">
      ${iconSvg("code")}
      <span>PR Diffs</span>
    </button>
  `;
}

function renderAgentComposer(agent, skills, options = {}) {
  return `
    <form id="composer" class="composer" data-agent-key="${escapeAttr(agent.key)}">
      <textarea id="prompt-input" rows="4" placeholder="Send a prompt" aria-label="Prompt" enterkeyhint="enter"></textarea>
      <div class="composer-drop-overlay" data-composer-drop-overlay aria-hidden="true">
        <span>Drop files to attach</span>
      </div>
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
    model: editing || cloning ? (agent.model || "") : (selectedTemplate.model || ""),
    reasoningEffort: editing || cloning ? (agent.reasoning_effort || "") : (selectedTemplate.reasoning_effort || ""),
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
        <select id="agent-harness" name="agent" data-agent-harness-select>
          ${agentHarnessOptions().map((harness) => `<option value="${escapeAttr(harness)}" ${harness === values.harness ? "selected" : ""}>${escapeHtml(harness)}</option>`).join("")}
        </select>
        <input id="agent-sandbox-mode" type="hidden" name="sandbox_mode" value="${escapeAttr(values.sandboxMode)}">
      </section>
      <section class="field-card">
        <label class="field-label" for="agent-model">Model</label>
        <select id="agent-model" name="model" data-agent-model-select>
          ${modelChoiceOptions(values.harness, values.model)}
        </select>
      </section>
      <section class="field-card">
        <label class="field-label" for="agent-reasoning-effort">Effort</label>
        <select id="agent-reasoning-effort" name="reasoning_effort" data-agent-reasoning-effort-select>
          ${reasoningEffortChoiceOptions(values.harness, values.model, values.reasoningEffort)}
        </select>
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
        ${kv("Model", agent.model || "default")}
        ${kv("Effort", agent.reasoning_effort || "default")}
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
  setHeaderMore(projectMoreMenuHtml(project), "Project actions", projectHeaderMoreKey(project.key));
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
      <div class="agent-row project-overview-row">
        <span class="status-mark ${project.dirty ? "need" : "done"}" aria-hidden="true">${iconSvg("code")}</span>
        <div class="row-title"><strong>Changes</strong><span>${escapeHtml(project.dirty ? `${project.dirty_files} dirty files in this workspace` : "No tracked or untracked changes reported")}</span></div>
      </div>
    </section>
    ${renderProjectAgents(project, agents)}
    <details class="detail-card">
      <summary>Deploy details</summary>
      <div class="kv-grid">
        ${copyableKv("Service", project.service)}
        ${copyableKv("Image", project.image)}
        ${copyableKv("Hosts", (project.hosts || []).join(", ") || "n/a")}
        ${copyableKv("Proxy", project.proxy)}
        ${copyableKv("Action log", project.action_log_path)}
        ${copyableKv("Health path", project.healthcheck_path)}
      </div>
    </details>
    <details class="detail-card">
      <summary>Versions and templates</summary>
      <div class="kv-grid">
        ${copyableKv("Kamal", project.kamal_version)}
        ${copyableKv("Rails", project.rails_version)}
        ${copyableKv("Templates", (project.agent_template_summaries || []).map((item) => item.name).join(", ") || "n/a")}
        ${copyableKv("Path", project.path)}
      </div>
    </details>
    <section class="field-card">
      <span class="field-label">Guarded actions</span>
      <div class="button-row">
        ${PROJECT_ACTIONS.map((action) => `<button type="button" data-guard-action="${action}" data-project-key="${escapeAttr(project.key)}" ${project.apps_enabled ? "" : "disabled"}>${capitalize(action)}</button>`).join("")}
      </div>
    </section>
  `);
}

function renderProjectDiff(key, scope = "worktree") {
  const normalizedScope = normalizeDiffScope(scope);
  const project = findProject(key);
  if (!project && initialDataPending()) {
    setHeader("Loading project", "Fetching remote state", "gitCommit");
    replaceView(emptyState("Loading project", "Fetching project state before rendering changes."));
    return;
  }

  if (!project) {
    setHeader("Project not found", "It may have been removed from config.", "gitCommit");
    replaceView(emptyState("Project not found", "Return to the Agents tab and choose an active project."));
    return;
  }

  setHeader(`${project.name || project.key} changes`, `${diffScopeLabel(normalizedScope)} / ${project.branch || "branch n/a"}`, "gitCommit");
  replaceView(renderProjectDiffContent(key, normalizedScope));
}

function renderAgentProjectDiff(agentKey, projectKey, scope = "worktree") {
  const agent = findAgent(agentKey);
  if (!agent) {
    renderProjectDiff(projectKey, scope);
    return;
  }

  const blocks = state.conversations[agent.key]?.blocks || [];
  setHeader(agent.name || agent.key, agentHeaderLabel(agent), "A");
  setAgentSettings(agent);
  setHeaderMore(agentMoreMenuHtml(agent), "Conversation actions", agentHeaderMoreKey(agent.key));
  replaceView(renderAgentWorkspace(agent, blocks, {
    detailHtml: renderProjectDiffContent(projectKey, scope, { embedded: true }),
    detailKind: "project-diff",
    focusedMode: true,
  }));
}

function renderProjectDiffContent(key, scope = "worktree", options = {}) {
  const normalizedScope = normalizeDiffScope(scope);
  const project = findProject(key);
  const diff = state.projectDiffs[projectDiffKey(key, normalizedScope)];

  if (!project) {
    return emptyState("Project not found", "Return to the Agents tab and choose an active project.");
  }

  const heading = options.embedded
    ? `
      <section class="diff-pane-header">
        <div class="section-label">
          <strong>${escapeHtml(project.name || project.key)} changes</strong>
          <span>${escapeHtml(`${diffScopeLabel(normalizedScope)} / ${project.branch || "branch n/a"}`)}</span>
        </div>
      </section>
    `
    : "";

  if (!diff || diff.loading) {
    return `
      ${heading}
      ${renderProjectDiffScopeSwitch(project, normalizedScope)}
      ${emptyState("Loading diff", "Reading Git changes for this project.")}
    `;
  }

  if (diff.error) {
    return `
      ${heading}
      ${renderProjectDiffScopeSwitch(project, normalizedScope)}
      <section class="notice">
        <strong>Diff unavailable</strong>
        <p>${escapeHtml(diff.error)}</p>
      </section>
    `;
  }

  const files = Array.isArray(diff.files) ? diff.files : [];
  const summary = `${files.length} ${files.length === 1 ? "file" : "files"} / +${diff.additions || 0} -${diff.deletions || 0}`;
  return `
    ${heading}
    ${renderProjectDiffScopeSwitch(project, normalizedScope)}
    <section class="summary-card diff-summary-card">
      <div class="card-title">
        <strong>${escapeHtml(summary)}</strong>
        <span>${escapeHtml([diff.head, diff.branch].filter(Boolean).join(" on ") || "Git revision unavailable")}</span>
      </div>
      <div class="chip-row">
        <span class="chip ${diff.dirty ? "need" : "done"}">${diff.dirty ? `${diff.dirty_files || 0} dirty` : "clean"}</span>
        <span class="chip detail">${escapeHtml(diffScopeLabel(normalizedScope))}</span>
        ${diff.truncated ? `<span class="chip need">truncated</span>` : ""}
      </div>
    </section>
    <section class="diff-viewer" aria-label="Git diff">
      ${files.length ? files.map(renderProjectDiffFile).join("") : emptyState("No changes", "This diff scope has no file changes.")}
    </section>
  `;
}

function renderProjectDiffScopeSwitch(project, currentScope) {
  const scopes = [
    ["worktree", "Worktree"],
    ["staged", "Staged"],
    ["all", "All"],
  ];
  return `
    <section class="diff-toolbar" aria-label="Diff scope">
      <div class="diff-scope-switch" role="group" aria-label="Diff scope">
        ${scopes.map(([scope, label]) => `
          <button class="${scope === currentScope ? "active" : ""}" type="button" data-open-project-diff="${escapeAttr(project.key)}" data-diff-scope="${escapeAttr(scope)}" aria-pressed="${scope === currentScope ? "true" : "false"}">${escapeHtml(label)}</button>
        `).join("")}
      </div>
      <button class="inline-icon-button" type="button" data-refresh>${iconSvg("rotateCcw")}<span>Refresh</span></button>
    </section>
  `;
}

function renderProjectDiffFile(file, index) {
  const path = file.path || file.old_path || "unknown path";
  const status = diffStatusLabel(file.status);
  const className = diffStatusClass(file.status);
  const meta = diffFileMeta(file);
  const hunks = Array.isArray(file.hunks) ? file.hunks : [];
  const body = file.binary
    ? `<div class="diff-file-message">Binary file is not expanded.</div>`
    : hunks.length
      ? hunks.map(renderDiffHunk).join("")
      : `<div class="diff-file-message">${escapeHtml(file.message || "No textual hunks for this file.")}</div>`;

  return `
    <details class="diff-file detail-card" ${index === 0 ? "open" : ""} data-state-key="diff-file:${escapeAttr(path)}">
      <summary>
        <span class="status-mark ${className}" aria-hidden="true">${iconSvg(file.binary ? "fileText" : "code")}</span>
        <span class="diff-file-title">
          <strong class="wrap-anywhere">${escapeHtml(path)}</strong>
          <span>${escapeHtml(meta)}</span>
        </span>
        <span class="pill ${className}">${escapeHtml(status)}</span>
      </summary>
      <div class="diff-file-body" data-preserve-scroll data-state-key="diff-scroll:${escapeAttr(path)}">
        ${body}
      </div>
    </details>
  `;
}

function renderDiffHunk(hunk, index) {
  const lines = Array.isArray(hunk.lines) ? hunk.lines : [];
  return `
    <section class="diff-hunk" aria-label="Hunk ${index + 1}">
      <div class="diff-hunk-header"><code>${escapeHtml(hunk.header || "@@")}</code></div>
      <div class="diff-lines">
        ${lines.map(renderDiffLine).join("")}
      </div>
    </section>
  `;
}

function renderDiffLine(line) {
  const kind = String(line.kind || "context");
  const marker = kind === "added" ? "+" : kind === "removed" ? "-" : kind === "meta" ? "\\" : " ";
  return `
    <div class="diff-line ${escapeAttr(kind)}">
      <span class="diff-line-no">${diffLineNumber(line.old_number)}</span>
      <span class="diff-line-no">${diffLineNumber(line.new_number)}</span>
      <span class="diff-marker">${escapeHtml(marker)}</span>
      <code>${escapeHtml(line.content || "")}</code>
    </div>
  `;
}

function diffLineNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? escapeHtml(String(number)) : "";
}

function projectDiffKey(projectKey, scope) {
  return `${projectKey || ""}:${normalizeDiffScope(scope)}`;
}

function pullRequestDiffKey(agentKey, pullRequestId) {
  return `${agentKey || ""}:${pullRequestId || ""}`;
}

function selectedPullRequestId(agentKey, requestedId = "") {
  const items = state.pullRequests[agentKey]?.items || [];
  if (requestedId && items.some((item) => item.id === requestedId)) return requestedId;
  return items[0]?.id || "";
}

function pullRequestFreshnessLabel(item) {
  const snapshot = item?.snapshot;
  if (!snapshot) return item?.error ? "metadata unavailable" : "not fetched";
  if (snapshot.fresh === false) return "stale";
  if (snapshot.fresh === true) return "fresh";
  return snapshot.fetched_at ? `fetched ${timeShort(snapshot.fetched_at)}` : "snapshot";
}

function shortSha(value) {
  const text = String(value || "");
  return text.length > 8 ? text.slice(0, 8) : text;
}

function diffScopeLabel(scope) {
  return {
    worktree: "Worktree",
    staged: "Staged",
    all: "All changes",
  }[normalizeDiffScope(scope)];
}

function diffStatusLabel(status) {
  return capitalize(String(status || "modified"));
}

function diffStatusClass(status) {
  const value = String(status || "");
  if (["added", "untracked", "copied"].includes(value)) return "done";
  if (["deleted"].includes(value)) return "fail";
  if (["renamed"].includes(value)) return "info";
  return "need";
}

function diffFileMeta(file) {
  const counts = [];
  if (file.additions) counts.push(`+${file.additions}`);
  if (file.deletions) counts.push(`-${file.deletions}`);
  if (file.binary) counts.push("binary");
  if (file.truncated) counts.push("truncated");
  if (file.old_path && file.old_path !== file.path) counts.push(`from ${file.old_path}`);
  return counts.join(" / ") || "metadata only";
}

function renderProjectForm(key) {
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

  const harness = normalizeAgentHarness(project.agent || agentTemplateFor(project)?.agent);
  const values = {
    name: project.name || "",
    group: project.group || "",
    agent: harness,
    model: project.model || "",
    reasoningEffort: project.reasoning_effort || "",
  };
  const groups = [...new Set(state.projects.map((item) => item.group).filter(Boolean))].sort(compareDisplayText);

  setHeader("Edit project", `${project.name || project.key} / key ${project.key}`, "folder");
  replaceView(`
    <form id="project-form" class="agent-form project-form" data-project-key="${escapeAttr(project.key)}">
      <section class="detail-card">
        <div class="card-title project-info-title">
          <strong>Project Information</strong>
        </div>
        <div class="detail-card-body read-only-project-fields">
          <div class="detail-row">
            <span class="status-mark detail" aria-hidden="true">${iconSvg("folder")}</span>
            <div><strong>Key</strong><span class="wrap-anywhere">${escapeHtml(project.key)}</span></div>
            <span class="pill detail">Fixed</span>
          </div>
          <div class="detail-row">
            <span class="status-mark detail" aria-hidden="true">${iconSvg("folder")}</span>
            <div><strong>Workspace</strong><span class="wrap-anywhere">${escapeHtml(project.path || "n/a")}</span></div>
            <span class="pill detail">Fixed</span>
          </div>
          <div class="detail-row">
            <span class="status-mark detail" aria-hidden="true">${iconSvg("gitCommit")}</span>
            <div><strong>PR URL</strong><span class="wrap-anywhere">${escapeHtml(project.pr_url || "n/a")}</span></div>
            <span class="pill detail">Read only</span>
          </div>
          <div class="detail-row">
            <span class="status-mark ${project.apps_enabled ? "done" : "detail"}" aria-hidden="true">${iconSvg("rocket")}</span>
            <div><strong>Kamal deploy</strong><span>${escapeHtml(kamalDeploymentText(project))}</span></div>
            <span class="pill ${project.apps_enabled ? "done" : "detail"}">${project.apps_enabled ? "Available" : "Unavailable"}</span>
          </div>
        </div>
      </section>
      <section class="field-card">
        <label class="field-label" for="project-name">Name</label>
        <input id="project-name" name="name" type="text" value="${escapeAttr(values.name)}" autocomplete="off" required>
      </section>
      <section class="field-card">
        <label class="field-label" for="project-group">Group</label>
        <input id="project-group" name="group" type="text" value="${escapeAttr(values.group)}" autocomplete="off" list="project-group-options">
        <datalist id="project-group-options">
          ${groups.map((group) => `<option value="${escapeAttr(group)}"></option>`).join("")}
        </datalist>
      </section>
      <section class="field-card">
        <label class="field-label" for="project-harness">Default harness</label>
        <select id="project-harness" name="agent" data-project-harness-select>
          ${agentHarnessOptions().map((option) => `<option value="${escapeAttr(option)}" ${option === values.agent ? "selected" : ""}>${escapeHtml(option)}</option>`).join("")}
        </select>
      </section>
      <section class="field-card">
        <label class="field-label" for="project-model">Default model</label>
        <select id="project-model" name="model" data-project-model-select>
          ${modelChoiceOptions(values.agent, values.model)}
        </select>
      </section>
      <section class="field-card">
        <label class="field-label" for="project-reasoning-effort">Default effort</label>
        <select id="project-reasoning-effort" name="reasoning_effort" data-project-reasoning-effort-select>
          ${reasoningEffortChoiceOptions(values.agent, values.model, values.reasoningEffort)}
        </select>
      </section>
      <div class="button-row form-actions">
        <button type="button" data-cancel-project-form>Cancel</button>
        <button class="primary inline-icon-button" type="submit" value="save">${iconSvg("pencil")}<span>Save project</span></button>
      </div>
    </form>
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

function agentPullRequestCount(agent) {
  return agentAttachments(agent).filter((attachment) => githubPullRequestUrl(attachmentTarget(attachment))).length;
}

function githubPullRequestUrl(value) {
  return /^https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/\d+(?:[/?#].*)?$/i.test(String(value || "").trim());
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

function handlePromptAttachmentDrag(event) {
  const targetComposer = promptAttachmentFileComposer(event);
  if (!targetComposer) return;

  const composer = promptAttachmentDropComposer(event);
  event.preventDefault();
  event.dataTransfer.dropEffect = composer ? "copy" : "none";
  if (!composer) return;

  setComposerDropActive(composer, true);
}

function handlePromptAttachmentDragLeave(event) {
  const composer = event.target?.closest?.("#composer");
  if (!composer) return;
  if (dragEventInsideElement(event, composer)) return;

  setComposerDropActive(composer, false);
}

function handlePromptAttachmentDrop(event) {
  const targetComposer = promptAttachmentFileComposer(event);
  clearComposerDropTargets();
  if (!targetComposer) return;

  event.preventDefault();
  const composer = promptAttachmentDropComposer(event);
  if (!composer) return;

  const files = promptAttachmentDropFiles(event);
  if (!files.length) return;

  handlePromptAttachmentFiles(composer.dataset.agentKey, files);
}

function promptAttachmentFileComposer(event) {
  if (!dataTransferHasFiles(event.dataTransfer)) return null;
  return event.target?.closest?.("#composer") || null;
}

function promptAttachmentDropComposer(event) {
  const composer = promptAttachmentFileComposer(event);
  if (!composer) return null;

  const agent = findAgent(composer.dataset.agentKey);
  if (!agent || agentIsRunning(agent)) return null;

  return composer;
}

function dataTransferHasFiles(dataTransfer) {
  if (!dataTransfer) return false;
  if (Array.from(dataTransfer.types || []).includes("Files")) return true;
  return Array.from(dataTransfer.items || []).some((item) => item.kind === "file");
}

function promptAttachmentDropFiles(event) {
  return Array.from(event.dataTransfer?.files || []).filter(Boolean);
}

function setComposerDropActive(composer, active) {
  composer.classList.toggle("drop-active", active);
}

function clearComposerDropTargets() {
  els.view.querySelectorAll("#composer.drop-active").forEach((composer) => setComposerDropActive(composer, false));
}

function dragEventInsideElement(event, element) {
  const rect = element.getBoundingClientRect();
  return event.clientX >= rect.left && event.clientX <= rect.right && event.clientY >= rect.top && event.clientY <= rect.bottom;
}

function clipboardAttachmentAgentKey(event) {
  const route = parseRoute();
  const workspaceRoute = agentWorkspaceRoute(route);
  if (!workspaceRoute) return "";

  const agent = findAgent(workspaceRoute.key);
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
  if (route.type === "agent" || route.type === "agentSummary" || route.type === "agentAttachment") {
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

function kv(label, value, options = {}) {
  const display = value === null || value === undefined || value === "" ? "n/a" : String(value);
  const copyValue = options.copyValue === undefined ? display : String(options.copyValue || "");
  const copyDisabled = !copyValue || display === "n/a";
  const copyData = escapeAttr(copyDisabled ? "" : copyValue);
  const copyLabel = escapeAttr(label);
  const disabledAttr = copyDisabled ? "disabled" : "";
  const copyButton = options.copyable
    ? `
      <button class="icon-button kv-copy-button" type="button" data-copy="${copyData}" aria-label="Copy ${copyLabel}" title="Copy ${copyLabel}" ${disabledAttr}>
        ${iconSvg("copy")}
      </button>
    `
    : "";
  return `
    <div class="kv ${options.copyable ? "kv-copyable" : ""}">
      <span>${escapeHtml(label)}</span>
      <strong class="wrap-anywhere">${escapeHtml(display)}</strong>
      ${copyButton}
    </div>
  `;
}

function copyableKv(label, value) {
  return kv(label, value, { copyable: true });
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
    .sort(compareAgentProjectKeysForCurrentSort)
    .map((projectKey) => agentProjectGroup(projectKey, agentsByProject[projectKey] || [], query))
    .filter(Boolean);
}

function sortedAgentList(query) {
  return state.agents
    .filter((agent) => {
      const project = findProject(agent.project_key);
      return !query || (project && projectMatches(project, query)) || agentMatches(agent, query);
    })
    .sort(compareAgentsForCurrentSort);
}

function agentSortUsesProjectGroups() {
  return currentAgentSortOption()?.scope !== "agents";
}

function currentAgentSortOption() {
  return AGENT_SORT_OPTIONS.find((option) => option.value === state.agentSort) ||
    AGENT_SORT_OPTIONS.find((option) => option.value === DEFAULT_AGENT_SORT);
}

function agentProjectGroup(projectKey, agents, query) {
  const project = findProject(projectKey);
  const projectMatch = project ? projectMatches(project, query) : String(projectKey || "").toLowerCase().includes(query);
  const filteredAgents = agents
    .filter((agent) => !query || projectMatch || agentMatches(agent, query))
    .sort(compareAgentsForCurrentSort);

  if (query && !projectMatch && filteredAgents.length === 0) return null;
  if (!query && !project && filteredAgents.length === 0) return null;

  return { projectKey, agents: filteredAgents };
}

function agentsForProject(projectKey) {
  return state.agents
    .filter((agent) => agent.project_key === projectKey)
    .sort(compareAgentsForCurrentSort);
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

function compareAgentProjectKeysForCurrentSort(a, b) {
  const comparison = compareAgentProjectKeys(a, b);
  return state.agentSort === "project_desc" ? -comparison : comparison;
}

function compareAgentsByName(a, b) {
  const byName = compareDisplayText(a.name || a.key, b.name || b.key);
  if (byName !== 0) return byName;

  return compareDisplayText(a.key, b.key);
}

function compareAgentsByNameDesc(a, b) {
  return -compareAgentsByName(a, b);
}

function compareAgentsForCurrentSort(a, b) {
  return compareAgentsBySort(a, b, state.agentSort);
}

function compareAgentsBySort(a, b, sort) {
  switch (normalizeAgentSort(sort)) {
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

function compareAgentsByUpdatedAt(a, b, direction) {
  const left = agentActivityTimestamp(a);
  const right = agentActivityTimestamp(b);
  const byUpdatedAt = direction === "asc" ? left - right : right - left;
  if (byUpdatedAt !== 0) return byUpdatedAt;

  return compareAgentsByName(a, b);
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
    agent.model,
    agent.reasoning_effort,
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

function moreMenuHtml(items) {
  const content = items.filter(Boolean).join("");
  if (!content) return "";
  return `<div class="more-menu" role="menu">${content}</div>`;
}

function moreMenuSeparator() {
  return `<span class="more-menu-separator" role="separator" aria-hidden="true"></span>`;
}

function moreMenuButton({ label, sublabel = "", icon = "ellipsis", attrs = "", danger = false, disabled = false }) {
  const className = [
    "more-menu-item",
    sublabel ? "" : "single-line",
    danger ? "danger" : "",
  ].filter(Boolean).join(" ");
  const sublabelHtml = sublabel ? `<span>${escapeHtml(sublabel)}</span>` : "";
  return `
    <button class="${className}" type="button" role="menuitem" ${attrs} ${disabled ? "disabled" : ""}>
      ${iconSvg(icon)}
      <strong>${escapeHtml(label)}</strong>
      ${sublabelHtml}
    </button>
  `;
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
  syncAppBadge(count);

  els.mark.innerHTML = brandLogoHtml(count);
  els.mark.classList.toggle("has-unread", count > 0);
  els.mark.classList.toggle("unread-panel-open", state.unreadPanelOpen && count > 0);
  els.mark.setAttribute("aria-label", unreadLogoLabel(count));
  els.mark.setAttribute("title", unreadLogoLabel(count));
  els.mark.setAttribute("aria-expanded", state.unreadPanelOpen && count > 0 ? "true" : "false");
  els.mark.setAttribute("aria-disabled", count > 0 ? "false" : "true");
  renderUnreadAgentsPanel(agents);
}

function syncAppBadge(count) {
  const nextCount = Math.max(0, Math.trunc(Number(count) || 0));
  if (state.lastAppBadgeCount === nextCount) return;

  state.lastAppBadgeCount = nextCount;
  if (!("setAppBadge" in navigator) || !("clearAppBadge" in navigator)) return;

  const promise = nextCount > 0 ? navigator.setAppBadge(nextCount) : navigator.clearAppBadge();
  Promise.resolve(promise).catch(() => {});
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
    closeHeaderMore();
    const route = parseRoute();
    const workspaceRoute = agentWorkspaceRoute(route);
    const currentAgent = workspaceRoute ? findAgent(workspaceRoute.key) : null;
    setAgentSettings(currentAgent);
  }
  syncUnreadAlert();
}

function closeUnreadPanel() {
  if (!state.unreadPanelOpen) return;
  state.unreadPanelOpen = false;
  syncUnreadAlert();
}

function syncHeaderMoreRoute(route) {
  const key = headerMoreKeyForRoute(route);
  if (state.headerMoreKey !== key) setHeaderMore(null, "More actions", key);
}

function headerMoreKeyForRoute(route) {
  if (route.type === "tab" && route.tab === "agents") return "agents";
  if (route.type === "tab" && route.tab === "settings") return "settings";
  const workspaceRoute = agentWorkspaceRoute(route);
  if (workspaceRoute) return agentHeaderMoreKey(workspaceRoute.key);
  if (route.type === "project") return projectHeaderMoreKey(route.key);
  return "none";
}

function agentHeaderMoreKey(key) {
  return `agent:${key}`;
}

function projectHeaderMoreKey(key) {
  return `project:${key}`;
}

function setHeaderMore(content, label = "More actions", key = state.headerMoreKey, badge = "") {
  if (state.headerMoreKey !== key) state.headerMoreOpen = false;
  state.headerMoreContent = String(content || "").trim();
  state.headerMoreBadge = String(badge || "").trim();
  state.headerMoreKey = key || "none";
  state.headerMoreLabel = label || "More actions";
  if (!state.headerMoreContent) state.headerMoreOpen = false;
  renderHeaderMore();
  syncDetailHeaderLayout();
}

function renderHeaderMore() {
  const hasMenu = Boolean(state.headerMoreContent);
  els.headerMore.classList.toggle("hidden", !hasMenu);
  els.headerMore.setAttribute("aria-label", state.headerMoreLabel);
  els.headerMore.setAttribute("title", state.headerMoreLabel);
  els.headerMore.setAttribute("aria-expanded", hasMenu && state.headerMoreOpen ? "true" : "false");
  els.headerMoreBadge.textContent = state.headerMoreBadge;
  els.headerMoreBadge.classList.toggle("hidden", !state.headerMoreBadge);
  els.headerMorePanel.setAttribute("aria-label", state.headerMoreLabel);

  if (!hasMenu || !state.headerMoreOpen) {
    els.headerMorePanel.classList.add("hidden");
    els.headerMorePanel.innerHTML = "";
    return;
  }

  els.headerMorePanel.innerHTML = state.headerMoreContent;
  els.headerMorePanel.classList.remove("hidden");
}

function toggleHeaderMore() {
  if (!state.headerMoreContent) return;
  state.headerMoreOpen = !state.headerMoreOpen;
  if (state.headerMoreOpen) closeUnreadPanel();
  renderHeaderMore();
}

function closeHeaderMore() {
  if (!state.headerMoreOpen) return;
  state.headerMoreOpen = false;
  renderHeaderMore();
}

function scrollSettingsSection(id) {
  const section = document.getElementById(id);
  if (!section) return;

  section.scrollIntoView({ behavior: "smooth", block: "start" });
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
    els.agentSettingsPanel.classList.add("hidden");
    els.agentSettingsPanel.innerHTML = "";
    syncDetailHeaderLayout();
    return;
  }

  els.agentSettingsPanel.innerHTML = agentSettingsHtml(agent);
  els.agentSettingsPanel.classList.toggle("hidden", !state.agentSettingsOpen);
  syncDetailHeaderLayout();
}

function toggleAgentSettings() {
  const route = parseRoute();
  const workspaceRoute = agentWorkspaceRoute(route);
  const agent = workspaceRoute ? findAgent(workspaceRoute.key) : null;
  if (!agent) return;

  state.agentSettingsOpen = !state.agentSettingsOpen;
  if (state.agentSettingsOpen) closeUnreadPanel();
  setAgentSettings(agent);
  setHeaderMore(agentMoreMenuHtml(agent), "Conversation actions", agentHeaderMoreKey(agent.key));
}

function agentMoreMenuHtml(agent) {
  const running = agentIsRunning(agent);
  const lifecycleSublabel = running ? "Stop agent first" : agent.name || agent.key;
  const project = agent.project_key ? findProject(agent.project_key) : null;
  return moreMenuHtml([
    agent.project_key
      ? moreMenuButton({
          label: "Open project",
          sublabel: agentProjectLabel(agent),
          icon: "folder",
          attrs: `data-open-project="${escapeAttr(agent.project_key)}"`,
        })
      : "",
    agent.project_key
      ? moreMenuButton({
          label: "See diff",
          sublabel: projectDiffSublabel(project, agentProjectLabel(agent)),
          icon: "fileText",
          attrs: `data-open-project-diff="${escapeAttr(agent.project_key)}" data-diff-scope="worktree"`,
        })
      : "",
    moreMenuButton({
      label: state.agentSettingsOpen ? "Hide conversation settings" : "Conversation settings",
      sublabel: running ? "Agent is running" : agentTemplateLabel(agent),
      icon: "settings",
      attrs: "data-toggle-agent-settings",
    }),
    moreMenuSeparator(),
    moreMenuButton({
      label: "Edit agent",
      sublabel: lifecycleSublabel,
      icon: "pencil",
      attrs: `data-edit-agent="${escapeAttr(agent.key)}"`,
      disabled: running,
    }),
    moreMenuSeparator(),
    moreMenuButton({
      label: "Archive agent",
      sublabel: lifecycleSublabel,
      icon: "archive",
      attrs: `data-archive-agent="${escapeAttr(agent.key)}"`,
      danger: true,
      disabled: running,
    }),
  ]);
}

function projectMoreMenuHtml(project) {
  if (!project?.key) return "";
  return moreMenuHtml([
    moreMenuButton({
      label: "Edit project",
      sublabel: project.name || project.key,
      icon: "pencil",
      attrs: `data-edit-project="${escapeAttr(project.key)}"`,
    }),
    moreMenuButton({
      label: "See diff",
      sublabel: projectDiffSublabel(project),
      icon: "fileText",
      attrs: `data-open-project-diff="${escapeAttr(project.key)}" data-diff-scope="worktree"`,
    }),
  ]);
}

function projectDiffSublabel(project, fallback = "Workspace changes") {
  if (!project) return fallback;
  if (project.dirty) {
    const count = Number(project.dirty_files) || 0;
    return `${count} dirty ${count === 1 ? "file" : "files"}`;
  }
  return "Workspace clean";
}

function agentSettingsHtml(agent) {
  return `
    <div class="agent-settings-grid">
      ${copyableKv("Project", agentProjectLabel(agent))}
      ${copyableKv("Template", agentTemplateLabel(agent))}
      ${copyableKv("Harness", agent.agent || "agent")}
      ${copyableKv("Model", agent.model || "default")}
      ${copyableKv("Effort", agent.reasoning_effort || "default")}
      ${copyableKv("Status", statusLabel(agent))}
      ${copyableKv("Runs", agent.run_count)}
      ${copyableKv("Exit", agent.last_exit_code ?? "n/a")}
      ${copyableKv("Started", timeShort(agent.started_at))}
      ${copyableKv("Finished", timeShort(agent.finished_at))}
      ${copyableKv("Workspace", agent.workspace)}
      ${copyableKv("Sandbox", agent.sandbox_mode)}
      ${copyableKv("Raw log", agent.log_path)}
    </div>
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

function showGrowl(message, kind = "info") {
  const text = String(message || "").trim();
  if (!text || !els.growl) return;

  window.clearTimeout(state.growlTimer);
  els.growl.textContent = text;
  els.growl.className = `growl ${kind}`;
  state.growlTimer = window.setTimeout(() => {
    els.growl.classList.add("hidden");
    state.growlTimer = null;
  }, 2400);
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

function upsertProject(project) {
  if (!project?.key) return;

  const index = state.projects.findIndex((item) => item.key === project.key);
  if (index >= 0) state.projects[index] = { ...state.projects[index], ...project };
  else state.projects.push(project);
  state.projectDetails[project.key] = project;
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
      data-model="${escapeAttr(template.model || "")}"
      data-reasoning-effort="${escapeAttr(template.reasoning_effort || "")}"
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

function harnessSetupItem(name) {
  const normalized = String(name || "").trim().toLowerCase();
  return (state.setup?.harnesses || []).find((item) => item.name === normalized) || null;
}

function modelSuggestionsForHarness(name) {
  const suggestions = harnessSetupItem(name)?.model_suggestions;
  return Array.isArray(suggestions) ? suggestions : [];
}

function reasoningEffortSuggestionsForHarness(name) {
  const suggestions = harnessSetupItem(name)?.reasoning_effort_suggestions;
  return Array.isArray(suggestions) ? suggestions : [];
}

function modelChoiceOptions(harness, selectedModel = "") {
  const selected = String(selectedModel || "").trim();
  const suggestions = modelSuggestionsForHarness(harness);
  const hasSelected = suggestions.some((item) => String(item?.value || item || "").trim() === selected);
  return [
    `<option value="" ${selected ? "" : "selected"}>Default</option>`,
    ...suggestions.map((item) => {
      const value = String(item?.value || item || "").trim();
      if (!value) return "";
      const label = String(item?.label || "").trim();
      const text = label && label !== value ? `${label} (${value})` : value;
      return `<option value="${escapeAttr(value)}" ${value === selected ? "selected" : ""}>${escapeHtml(text)}</option>`;
    }),
    selected && !hasSelected ? `<option value="${escapeAttr(selected)}" selected>Custom (${escapeHtml(selected)})</option>` : "",
  ].join("");
}

function modelSuggestionForValue(harness, model) {
  const value = String(model || "").trim();
  if (!value) return null;
  return modelSuggestionsForHarness(harness).find((item) => String(item?.value || item || "").trim() === value) || null;
}

function reasoningEffortSuggestionsForModel(harness, model) {
  const suggestion = modelSuggestionForValue(harness, model);
  const efforts = suggestion?.reasoning_efforts;
  return Array.isArray(efforts) && efforts.length ? efforts : reasoningEffortSuggestionsForHarness(harness);
}

function defaultReasoningEffortForModel(harness, model) {
  return String(modelSuggestionForValue(harness, model)?.default_reasoning_effort || "").trim();
}

function reasoningEffortChoiceOptions(harness, model = "", selectedEffort = "") {
  const selected = String(selectedEffort || "").trim().toLowerCase();
  const suggestions = reasoningEffortSuggestionsForModel(harness, model);
  const hasSelected = suggestions.some((item) => String(item || "").trim().toLowerCase() === selected);
  return [
    `<option value="" ${selected ? "" : "selected"}>Default</option>`,
    ...suggestions.map((item) => {
      const value = String(item || "").trim();
      return value ? `<option value="${escapeAttr(value)}" ${value === selected ? "selected" : ""}>${escapeHtml(value)}</option>` : "";
    }),
    selected && !hasSelected ? `<option value="${escapeAttr(selected)}" selected>Custom (${escapeHtml(selected)})</option>` : "",
  ].join("");
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
  return [agentProjectLabel(agent), agentHarnessLabel(agent), agent.model, agent.reasoning_effort].filter(Boolean).join(" / ");
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
  return ["paused", "stopped"].includes(scheduleStatusLabel(schedule));
}

function scheduleStatusLabel(schedule) {
  return schedule.status || "scheduled";
}

function scheduleStatusClass(schedule) {
  const label = scheduleStatusLabel(schedule);
  if (label === "paused") return "need";
  if (label === "stopped") return "fail";
  if (label === "scheduled") return "done";
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

function shouldOpenSummaryForSucceededAgent(previousAgents, nextAgents, route = parseRoute()) {
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
  return [agent.project_key, agent.agent, agent.model, agent.reasoning_effort].filter(Boolean).join(" / ");
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

function kamalDeploymentText(project) {
  return project?.apps_enabled ? "Can be deployed with Kamal" : "Kamal deploy actions are not configured";
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
    showGrowl("Nothing to copy", "need");
    return;
  }

  if (!navigator.clipboard) {
    showGrowl("Copy unavailable in this browser", "need");
    return;
  }

  try {
    await navigator.clipboard.writeText(value);
    showGrowl("Copied to clipboard", "done");
  } catch (_error) {
    showGrowl("Copy failed", "fail");
  }
}

function handleDocumentCopyClick(event) {
  const copyButton = event.target.closest("[data-copy]");
  if (!copyButton) return false;

  event.preventDefault();
  copyToClipboard(copyButton.dataset.copy || "");
  return true;
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
  else if (route.type === "agentSummary") navigate({ type: "agent", key: route.key });
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
  else if (route.type === "projectForm") navigate({ type: "project", key: route.key });
  else if (route.type === "projectDiff") navigate(route.backTo || { type: "project", key: route.key });
  else if (route.type === "project" && route.backTo) navigate(route.backTo);
  else if (route.type === "project" || route.type === "guard") navigate({ type: "tab", tab: "agents" });
  else if (route.type === "scheduleForm") navigate({ type: "tab", tab: "now" });
  else if (route.type === "scheduleMessage") navigate({ type: "tab", tab: "now" });
  else if (route.type === "hiddenSettings") navigate({ type: "tab", tab: "settings" });
  else navigate({ type: "tab", tab: "now" });
});

els.headerMore.addEventListener("click", toggleHeaderMore);

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

els.headerMorePanel.addEventListener("click", (event) => {
  const toggleBulk = event.target.closest("[data-toggle-bulk-archive]");
  if (toggleBulk) {
    closeHeaderMore();
    toggleBulkArchiveMode();
    return;
  }

  const runBulk = event.target.closest("[data-run-bulk-archive]");
  if (runBulk) {
    closeHeaderMore();
    archiveSelectedAgents();
    return;
  }

  const projectButton = event.target.closest("[data-open-project]");
  if (projectButton) {
    closeHeaderMore();
    const route = parseRoute();
    const workspaceRoute = agentWorkspaceRoute(route);
    const backTo = workspaceRoute ? { type: "agent", key: workspaceRoute.key } : null;
    navigate({ type: "project", key: projectButton.dataset.openProject, backTo });
    return;
  }

  const editAgentButton = event.target.closest("[data-edit-agent]");
  if (editAgentButton) {
    closeHeaderMore();
    navigate({ type: "agentForm", mode: "edit", key: editAgentButton.dataset.editAgent });
    return;
  }

  const editProjectButton = event.target.closest("[data-edit-project]");
  if (editProjectButton) {
    closeHeaderMore();
    navigate({ type: "projectForm", key: editProjectButton.dataset.editProject });
    return;
  }

  const archiveAgentButton = event.target.closest("[data-archive-agent]");
  if (archiveAgentButton) {
    closeHeaderMore();
    navigate({ type: "agentArchive", key: archiveAgentButton.dataset.archiveAgent });
    return;
  }

  if (event.target.closest("[data-toggle-agent-settings]")) {
    closeHeaderMore();
    toggleAgentSettings();
    return;
  }

  const projectDiffButton = event.target.closest("[data-open-project-diff]");
  if (projectDiffButton) {
    closeHeaderMore();
    navigateProjectDiff(projectDiffButton);
    return;
  }

  const settingsSectionButton = event.target.closest("[data-scroll-settings-section]");
  if (settingsSectionButton) {
    closeHeaderMore();
    scrollSettingsSection(settingsSectionButton.dataset.scrollSettingsSection);
    return;
  }

  if (event.target.closest("[data-open-hidden-settings]")) {
    closeHeaderMore();
    navigate({ type: "hiddenSettings" });
    return;
  }

  if (event.target.closest("[data-refresh]")) {
    closeHeaderMore();
    refresh({ force: true });
    return;
  }

  if (event.target.closest("[data-restart-server]")) {
    closeHeaderMore();
    restartRemoteServer();
  }
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
  if (!event.target.closest("[data-agent-sort-menu]")) {
    closeAgentSortMenu();
  }

  const summaryButton = event.target.closest("[data-open-agent-summary]");
  if (summaryButton) {
    navigate({ type: "agentSummary", key: summaryButton.dataset.openAgentSummary });
    return;
  }

  const prDiffsButton = event.target.closest("[data-open-agent-pr-diffs]");
  if (prDiffsButton) {
    navigate({ type: "agentPullRequests", key: prDiffsButton.dataset.openAgentPrDiffs });
    return;
  }

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

  const agentSortButton = event.target.closest("[data-agent-sort-choice]");
  if (agentSortButton) {
    const nextSort = normalizeAgentSort(agentSortButton.dataset.agentSortChoice);
    state.agentSort = nextSort;
    setSessionStorageValue(AGENT_SORT_STORAGE_KEY, state.agentSort);
    renderAgents({ focusFilter: false });
    closeAgentSortMenu();
    els.view.querySelector(".agent-sort-trigger")?.focus({ preventScroll: true });
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

  const projectDiffButton = event.target.closest("[data-open-project-diff]");
  if (projectDiffButton) {
    navigateProjectDiff(projectDiffButton);
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

  const cancelProjectForm = event.target.closest("[data-cancel-project-form]");
  if (cancelProjectForm) {
    const route = parseRoute();
    const form = cancelProjectForm.closest("form");
    if (form) clearFormDraft(form);
    if (route.type === "projectForm") navigate({ type: "project", key: route.key });
    return;
  }

  const cancelScheduleForm = event.target.closest("[data-cancel-schedule-form]");
  if (cancelScheduleForm) {
    const form = cancelScheduleForm.closest("form");
    if (form) clearFormDraft(form);
    navigate({ type: "tab", tab: "now" });
    return;
  }

  const cancelScheduleMessageForm = event.target.closest("[data-cancel-schedule-message-form]");
  if (cancelScheduleMessageForm) {
    const form = cancelScheduleMessageForm.closest("form");
    if (form) clearFormDraft(form);
    navigate({ type: "tab", tab: "now" });
    return;
  }

  const guardButton = event.target.closest("[data-guard-action]");
  if (guardButton) {
    navigate({ type: "guard", key: guardButton.dataset.projectKey, action: guardButton.dataset.guardAction });
    return;
  }

  const newScheduleButton = event.target.closest("[data-new-schedule]");
  if (newScheduleButton) {
    navigate({ type: "scheduleForm", mode: "create" });
    return;
  }

  const editScheduleButton = event.target.closest("[data-edit-schedule]");
  if (editScheduleButton) {
    navigate({ type: "scheduleForm", mode: "edit", key: editScheduleButton.dataset.editSchedule });
    return;
  }

  const editScheduleMessageButton = event.target.closest("[data-edit-schedule-message]");
  if (editScheduleMessageButton) {
    navigate({ type: "scheduleMessage", key: editScheduleMessageButton.dataset.editScheduleMessage });
    return;
  }

  const deleteScheduleButton = event.target.closest("[data-delete-schedule]");
  if (deleteScheduleButton) {
    deleteSchedule(deleteScheduleButton.dataset.deleteSchedule);
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

  const refreshAgentPrsButton = event.target.closest("[data-refresh-agent-prs]");
  if (refreshAgentPrsButton) {
    refreshAgentPullRequests(refreshAgentPrsButton.dataset.refreshAgentPrs);
    return;
  }

  const refreshPrDiffButton = event.target.closest("[data-refresh-pr-diff]");
  if (refreshPrDiffButton) {
    refreshPullRequestDiff(refreshPrDiffButton.dataset.agentKey, refreshPrDiffButton.dataset.refreshPrDiff);
    return;
  }

  const refreshAllPrDiffsButton = event.target.closest("[data-refresh-all-pr-diffs]");
  if (refreshAllPrDiffsButton) {
    refreshAllPullRequestDiffs(refreshAllPrDiffsButton.dataset.refreshAllPrDiffs);
    return;
  }

  const deleteAttachmentButton = event.target.closest("[data-delete-attachment]");
  if (deleteAttachmentButton) {
    deleteAttachment(deleteAttachmentButton.dataset.deleteAttachment);
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
  handleDocumentCopyClick(event);
});

document.addEventListener("click", (event) => {
  if (eventPathIncludes(event, els.mark) || eventPathIncludes(event, els.unreadPanel)) return;
  closeUnreadPanel();
});

document.addEventListener("click", (event) => {
  if (eventPathIncludes(event, els.headerMore) || eventPathIncludes(event, els.headerMorePanel)) return;
  closeHeaderMore();
});

document.addEventListener("click", (event) => {
  if (!agentWorkspaceRoute(parseRoute())) return;

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

els.view.addEventListener("dragenter", handlePromptAttachmentDrag);
els.view.addEventListener("dragover", handlePromptAttachmentDrag);
els.view.addEventListener("dragleave", handlePromptAttachmentDragLeave);
els.view.addEventListener("drop", handlePromptAttachmentDrop);

document.addEventListener("dragend", clearComposerDropTargets);
document.addEventListener("drop", clearComposerDropTargets);

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

  const modelChoice = event.target.closest("[data-agent-model-select]");
  if (modelChoice) {
    applyAgentModelChoice(modelChoice);
    return;
  }

  const reasoningEffortChoice = event.target.closest("[data-agent-reasoning-effort-select]");
  if (reasoningEffortChoice) {
    applyAgentReasoningEffortChoice(reasoningEffortChoice);
    return;
  }

  const templateSelect = event.target.closest("[data-agent-template-select]");
  if (templateSelect) {
    applyAgentTemplateSelection(templateSelect);
    return;
  }

  const harnessSelect = event.target.closest("[data-agent-harness-select]");
  if (harnessSelect) applyAgentHarnessSelection(harnessSelect);

  const projectModelChoice = event.target.closest("[data-project-model-select]");
  if (projectModelChoice) {
    applyProjectModelChoice(projectModelChoice);
    return;
  }

  const projectReasoningEffortChoice = event.target.closest("[data-project-reasoning-effort-select]");
  if (projectReasoningEffortChoice) {
    applyProjectReasoningEffortChoice(projectReasoningEffortChoice);
    return;
  }

  const projectHarnessSelect = event.target.closest("[data-project-harness-select]");
  if (projectHarnessSelect) applyProjectHarnessSelection(projectHarnessSelect);

  const scheduleMessageSource = event.target.closest("[data-schedule-message-source]");
  if (scheduleMessageSource) {
    syncScheduleMessageFields(scheduleMessageSource.closest("form"));
  }
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

  if (event.target.id === "project-form") {
    const form = event.target;
    const projectKey = form.dataset.projectKey;
    if (!projectKey) return;
    const payload = projectFormPayload(form);

    mutate(async () => {
      const data = await apiPatch(`/projects/${encodeURIComponent(projectKey)}`, payload);
      if (data.project?.key) {
        upsertProject(data.project);
        clearFormDraft(form);
        navigate({ type: "project", key: data.project.key });
      }
    });
  }

  if (event.target.id === "schedule-form") {
    const form = event.target;
    const mode = form.dataset.mode;
    const scheduleKey = form.dataset.scheduleKey;
    const formData = new FormData(form);
    const payload = scheduleFormPayload(formData);

    mutate(async () => {
      const data = mode === "edit"
        ? await apiPatch(`/schedules/${encodeURIComponent(scheduleKey)}`, payload)
        : await apiPost("/schedules", payload);
      const nextSchedule = data.schedule;
      if (nextSchedule?.key) upsertSchedule(nextSchedule);
      clearFormDraft(form);
      navigate({ type: "tab", tab: "now" });
      await refresh({ force: true });
    });
  }

  if (event.target.id === "schedule-message-form") {
    const form = event.target;
    const scheduleKey = form.dataset.scheduleKey;
    const formData = new FormData(form);
    const payload = { content: String(formData.get("content") || "") };

    mutate(async () => {
      const data = await apiPatch(`/schedules/${encodeURIComponent(scheduleKey)}/message`, payload);
      if (data.message) state.scheduleMessages[scheduleKey] = data.message;
      clearFormDraft(form);
      navigate({ type: "tab", tab: "now" });
      await refresh({ force: true });
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

function deleteSchedule(key) {
  if (!key) return;
  if (!window.confirm(`Delete schedule ${key}?`)) return;

  mutate(async () => {
    await apiDelete(`/schedules/${encodeURIComponent(key)}`);
    state.schedules = (state.schedules || []).filter((schedule) => String(schedule.key || "") !== String(key));
    setConnection("Schedule deleted");
    render();
  });
}

function upsertSchedule(schedule) {
  if (!schedule?.key) return;
  const index = state.schedules.findIndex((item) => String(item.key || "") === String(schedule.key));
  if (index >= 0) state.schedules[index] = schedule;
  else state.schedules.unshift(schedule);
}

function syncScheduleMessageFields(form) {
  if (!form) return;
  const source = form.querySelector("[data-schedule-message-source]")?.value || "inline";
  form.querySelectorAll("[data-schedule-message-mode]").forEach((section) => {
    const active = section.dataset.scheduleMessageMode === source;
    section.classList.toggle("hidden", !active);
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

async function refreshAgentPullRequests(agentKey) {
  if (!agentKey) return;

  try {
    setConnection("Refreshing pull requests");
    await ensureAgentPullRequests(agentKey, true);
    state.renderedViewHtml = "";
    setConnection("Pull requests refreshed");
    render();
  } catch (error) {
    setConnection(error.message);
    render();
  }
}

async function refreshPullRequestDiff(agentKey, pullRequestId) {
  if (!agentKey || !pullRequestId) return;

  try {
    setConnection("Fetching PR diff");
    const data = await apiPost(`/agents/${encodeURIComponent(agentKey)}/pull-requests/${encodeURIComponent(pullRequestId)}/refresh`);
    state.pullRequestDiffs[pullRequestDiffKey(agentKey, pullRequestId)] = data.diff || { id: pullRequestId, files: [] };
    await ensureAgentPullRequests(agentKey, true);
    state.renderedViewHtml = "";
    setConnection("PR diff refreshed");
    render();
  } catch (error) {
    state.pullRequestDiffs[pullRequestDiffKey(agentKey, pullRequestId)] = { error: error.message, files: [] };
    setConnection(error.message);
    render();
  }
}

async function refreshAllPullRequestDiffs(agentKey) {
  if (!agentKey) return;

  try {
    setConnection("Fetching PR diffs");
    const data = await apiPost(`/agents/${encodeURIComponent(agentKey)}/pull-requests/refresh`);
    (data.refreshed || []).forEach((diff) => {
      if (!diff?.id) return;

      state.pullRequestDiffs[pullRequestDiffKey(agentKey, diff.id)] = diff;
    });
    await ensureAgentPullRequests(agentKey, true);
    state.renderedViewHtml = "";
    const failures = Array.isArray(data.failed) ? data.failed.length : 0;
    setConnection(failures ? `PR diffs refreshed with ${failures} failure${failures === 1 ? "" : "s"}` : "PR diffs refreshed");
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
  const modelSelect = form.querySelector("#agent-model");
  const reasoningEffortSelect = form.querySelector("#agent-reasoning-effort");
  const hint = form.querySelector(".field-hint");

  if (promptInput) promptInput.value = option.dataset.prompt || "";
  const harness = normalizeAgentHarness(option.dataset.agent);
  if (harnessSelect) harnessSelect.value = harness;
  if (modelSelect && modelSelect.dataset.dirty !== "true") modelSelect.value = option.dataset.model || "";
  updateAgentModelChoices(form, harness);
  if (reasoningEffortSelect && reasoningEffortSelect.dataset.dirty !== "true") {
    reasoningEffortSelect.value = option.dataset.reasoningEffort || defaultReasoningEffortForModel(harness, modelSelect?.value) || "";
    syncReasoningEffortForModel(form, { applyDefault: false });
  }
  if (sandboxInput) sandboxInput.value = option.dataset.sandboxMode || "danger-full-access";
  if (hint) hint.textContent = option.dataset.promptPreview || "Template defaults are loaded from the project configuration.";
  if (mode === "create" && nameInput) {
    const projectName = form.dataset.projectName || "Project";
    const templateName = String(option.dataset.templateName || "agent").toLowerCase();
    nameInput.value = `${projectName} ${templateName}`;
  }
  saveFormDraft(form);
}

function applyAgentHarnessSelection(select) {
  const form = select.closest("#agent-form");
  if (!form) return;

  updateAgentModelChoices(form, normalizeAgentHarness(select.value));
  saveFormDraft(form);
}

function applyAgentModelChoice(select) {
  const form = select.closest("#agent-form");
  if (!form) return;

  select.dataset.dirty = "true";
  syncReasoningEffortForModel(form, { applyDefault: true });
  saveFormDraft(form);
}

function applyAgentReasoningEffortChoice(select) {
  const form = select.closest("#agent-form");
  if (!form) return;

  select.dataset.dirty = "true";
  saveFormDraft(form);
}

function applyProjectHarnessSelection(select) {
  const form = select.closest("#project-form");
  if (!form) return;

  updateProjectModelChoices(form, normalizeAgentHarness(select.value));
  saveFormDraft(form);
}

function applyProjectModelChoice(select) {
  const form = select.closest("#project-form");
  if (!form) return;

  select.dataset.dirty = "true";
  syncProjectReasoningEffortForModel(form, { applyDefault: true });
  saveFormDraft(form);
}

function applyProjectReasoningEffortChoice(select) {
  const form = select.closest("#project-form");
  if (!form) return;

  select.dataset.dirty = "true";
  saveFormDraft(form);
}

function updateAgentModelChoices(form, harness) {
  const modelSelect = form.querySelector("#agent-model");
  const model = modelSelect?.value || "";
  if (modelSelect) modelSelect.innerHTML = modelChoiceOptions(harness, model);
  syncReasoningEffortForModel(form, { applyDefault: false });
}

function updateProjectModelChoices(form, harness) {
  const modelSelect = form.querySelector("#project-model");
  const model = modelSelect?.value || "";
  if (modelSelect) modelSelect.innerHTML = modelChoiceOptions(harness, model);
  syncProjectReasoningEffortForModel(form, { applyDefault: false });
}

function syncReasoningEffortForModel(form, options = {}) {
  const harness = normalizeAgentHarness(form.querySelector("#agent-harness")?.value);
  const model = form.querySelector("#agent-model")?.value || "";
  const effortSelect = form.querySelector("#agent-reasoning-effort");
  if (effortSelect) effortSelect.innerHTML = reasoningEffortChoiceOptions(harness, model, effortSelect.value || "");
  if (options.applyDefault && effortSelect && effortSelect.dataset.dirty !== "true") {
    const defaultEffort = defaultReasoningEffortForModel(harness, model);
    if (defaultEffort) {
      effortSelect.value = defaultEffort;
      effortSelect.innerHTML = reasoningEffortChoiceOptions(harness, model, effortSelect.value);
    }
  }
}

function syncProjectReasoningEffortForModel(form, options = {}) {
  const harness = normalizeAgentHarness(form.querySelector("#project-harness")?.value);
  const model = form.querySelector("#project-model")?.value || "";
  const effortSelect = form.querySelector("#project-reasoning-effort");
  if (effortSelect) effortSelect.innerHTML = reasoningEffortChoiceOptions(harness, model, effortSelect.value || "");
  if (options.applyDefault && effortSelect && effortSelect.dataset.dirty !== "true") {
    const defaultEffort = defaultReasoningEffortForModel(harness, model);
    if (defaultEffort) {
      effortSelect.value = defaultEffort;
      effortSelect.innerHTML = reasoningEffortChoiceOptions(harness, model, effortSelect.value);
    }
  }
}

function agentFormPayload(form) {
  const formData = new FormData(form);
  const payload = {
    name: String(formData.get("name") || "").trim(),
    template_key: String(formData.get("template_key") || "").trim(),
    agent: normalizeAgentHarness(formData.get("agent")),
    model: String(formData.get("model") || "").trim(),
    reasoning_effort: String(formData.get("reasoning_effort") || "").trim().toLowerCase(),
    prompt: String(formData.get("prompt") || "").trim(),
    sandbox_mode: String(formData.get("sandbox_mode") || "").trim(),
  };
  return payload;
}

function projectFormPayload(form) {
  const formData = new FormData(form);
  return {
    name: String(formData.get("name") || "").trim(),
    group: String(formData.get("group") || "").trim(),
    agent: normalizeAgentHarness(formData.get("agent")),
    model: String(formData.get("model") || "").trim(),
    reasoning_effort: String(formData.get("reasoning_effort") || "").trim().toLowerCase(),
  };
}

function scheduleFormPayload(form) {
  const formData = form instanceof FormData ? form : new FormData(form);
  const messageSource = String(formData.get("message_source") || "inline").trim();
  return {
    key: String(formData.get("key") || "").trim(),
    name: String(formData.get("name") || "").trim(),
    enabled: formData.has("enabled"),
    cron: String(formData.get("cron") || "").trim(),
    timezone: String(formData.get("timezone") || "local").trim(),
    project_key: String(formData.get("project_key") || "").trim(),
    agent_name: String(formData.get("agent_name") || "").trim(),
    message_source: messageSource,
    message: String(formData.get("message") || "").trim(),
    message_file: String(formData.get("message_file") || "").trim(),
    policy: {
      overlap: String(formData.get("overlap") || "skip").trim(),
      missed: String(formData.get("missed") || "run_once_on_start").trim(),
      archive_previous_agent: formData.has("archive_previous_agent"),
    },
  };
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

function closeAgentSortMenu() {
  document.querySelector("[data-agent-sort-menu]")?.removeAttribute("open");
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

function scrollConversationToRecent() {
  if (!document.querySelector("[data-conversation-recent]")) return;

  const root = conversationScrollRoot();
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

  const root = conversationScrollRoot();
  root.scrollTo({ top: root.scrollHeight, behavior: "auto" });
  if (root === document.scrollingElement || root === document.documentElement) {
    state.lastScrollY = Math.max(0, window.scrollY);
  }
  window.requestAnimationFrame(() => {
    if (root === document.scrollingElement || root === document.documentElement) {
      state.lastScrollY = Math.max(0, window.scrollY);
    }
    window.requestAnimationFrame(() => {
      if (root === document.scrollingElement || root === document.documentElement) {
        state.lastScrollY = Math.max(0, window.scrollY);
      }
      window.setTimeout(() => {
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
  if (agentWorkspaceRoute(parseRoute()) &&
      !document.activeElement?.closest?.("[data-attachment-flyout]") &&
      !document.activeElement?.closest?.("[data-toggle-attachments]")) {
    closeAttachmentFlyout();
  }
  if (agentWorkspaceRoute(parseRoute()) &&
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
