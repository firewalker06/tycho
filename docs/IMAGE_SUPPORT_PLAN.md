---
name: IMAGE_SUPPORT_PLAN
description: Implementation plan for image support in HQ TUI and Remote UI
type: project-plan
---

# Image Support Implementation Plan

## Goal

Add first-class image support to HQ managed-agent workflows across both interfaces:

- TUI: attach local images to a managed-agent prompt, inspect image attachments from agent results, and open or preview them from the agent chat experience.
- Remote UI: upload images from desktop or mobile browsers, send them with chat messages, display image attachments in conversations, and inspect them through a thumbnail/gallery flow.

Image support should build on HQ's existing managed-agent attachment and memory model instead of introducing a separate artifact system.

## Current Implementation

HQ already has a partial attachment foundation:

- `~/.tycho/config/schemas/agent_result.json` accepts structured attachments with `kind: image`.
- `HQ::Domain::ManagedAgent#capture_run_memory!` persists structured result attachments into agent memory and attachment sidecars.
- Agent artifacts live under `~/.tycho/logs/agents/`, including `.memory.jsonl` and `.attachments.json` files.
- The TUI can surface attachment counts and open selected attachment targets through the OS.
- The TUI currently does not attach images to outgoing prompts.
- The TUI currently does not render inline image previews.
- The Remote UI currently renders text conversation content, but does not expose agent attachment metadata or image blobs to the browser.
- Codex CLI supports image input through `codex exec --image` and resume-mode image input through `codex exec resume --image`.
- Claude-compatible image-input behavior still needs a compatibility spike before HQ should rely on it.

## Product Scope

### In Scope

- Import local image files into a durable HQ-managed asset store.
- Store normalized image metadata in agent memory and attachment sidecars.
- Send image attachments with new user messages.
- Pass images to Codex agents using native `--image` flags.
- Provide a compatibility fallback for agent harnesses that cannot consume binary image input.
- Show pending image attachments before send.
- Show persisted image attachments after send and from agent results.
- Add Remote API upload, thumbnail, and blob access.
- Add Remote UI image upload, preview, gallery, and lightbox behavior.
- Add automated coverage for attachment normalization, command construction, TUI rendering, and Remote API auth behavior.

### Out of Scope for the First Version

- Full OCR, image annotation, or canvas editing.
- Cross-agent shared image libraries.
- Cloud object storage.
- Public unauthenticated image URLs.
- Lossless image transformation workflows beyond thumbnail generation.
- Native inline terminal rendering as the only viewing path.

## Design Principles

- Treat images as attachments on conversation events, not as a separate conversation type.
- Store binary files once under HQ-managed logs/assets paths, then reference metadata from memory.
- Keep `memory.jsonl` portable and small by storing metadata and local paths, not base64 payloads.
- Keep existing `kind`, `title`, `url`, and `description` fields compatible with structured result output.
- Prefer reliable open/view behavior first, then layer terminal inline preview where supported.
- Use the same `AgentStore` and `ManagedAgent` behavior from both TUI and Remote UI.
- Authenticate all Remote API blob and thumbnail reads the same way as other Remote API operations.
- Keep browser uploads local-first and bounded by explicit file size/count limits.

## Attachment Data Model

Extend image attachment metadata without breaking the current schema:

```json
{
  "id": "att_20260512_120000_abcd1234",
  "kind": "image",
  "title": "screenshot.png",
  "description": "Uploaded with user message",
  "path": "~/.tycho/logs/agents/assets/my-agent/att_20260512_120000_abcd1234/original.png",
  "url": null,
  "mime_type": "image/png",
  "size_bytes": 348221,
  "width": 1440,
  "height": 900,
  "sha256": "...",
  "thumbnail_path": "~/.tycho/logs/agents/assets/my-agent/att_20260512_120000_abcd1234/thumb.png",
  "source": "user_upload",
  "created_at": "2026-05-12T05:00:00Z"
}
```

Recommended fields:

| Field | Purpose |
|-------|---------|
| `id` | Stable attachment identifier for UI selection, blob routes, and memory references. |
| `kind` | Existing attachment kind. Use `image` for image assets. |
| `title` | Display name, usually the original basename. |
| `description` | Optional user or agent-provided context. |
| `path` | Local HQ-managed original file path. |
| `url` | Existing compatibility field for external links. Usually `null` for local images. |
| `mime_type` | Validated image MIME type. |
| `size_bytes` | Original file size. |
| `width` | Pixel width when known. |
| `height` | Pixel height when known. |
| `sha256` | Content hash for dedupe and integrity checks. |
| `thumbnail_path` | Local HQ-managed thumbnail path. |
| `source` | `user_upload`, `agent_result`, or `remote_upload`. |
| `created_at` | ISO 8601 creation timestamp. |

## Storage Layout

Add an image asset area beneath the existing agent logs root:

```text
~/.tycho/logs/agents/assets/{agent_key}/{attachment_id}/
  original.{ext}
  thumb.{ext}
  metadata.json
```

Persist references in existing sidecars:

```text
~/.tycho/logs/agents/{agent_key}.attachments.json
~/.tycho/logs/agents/{agent_key}.memory.jsonl
```

Do not store uploaded image bytes directly inside `memory.jsonl`.

## Domain Layer

Add `HQ::Domain::AgentAttachmentStore`.

Responsibilities:

- Import local files into the HQ-managed asset store.
- Decode Remote UI base64 upload payloads into temporary files before import.
- Validate file extension and MIME type.
- Reject unsupported or oversized files.
- Compute `sha256`.
- Read image dimensions.
- Generate thumbnails.
- Return normalized attachment metadata.
- Find attachments by `agent_key` and `attachment_id`.
- Resolve original and thumbnail paths for authorized Remote API routes.
- Optionally dedupe identical image content per agent by hash.

Suggested constraints for the first version:

- Supported MIME types: `image/png`, `image/jpeg`, `image/webp`, `image/gif`.
- Maximum image size: start with 10 MB per image.
- Maximum attached images per message: start with 4.
- Thumbnail max edge: 512 px.

Dimension and thumbnail implementation can start with a small dependency if needed. Prefer a simple, well-maintained Ruby image library over shelling out to platform-specific tools unless the repo already has a reliable local dependency.

## Memory Events

Extend user and assistant memory events with attachments:

```json
{
  "type": "message",
  "role": "user",
  "content": "What is wrong with this screenshot?",
  "attachments": [
    {
      "id": "att_20260512_120000_abcd1234",
      "kind": "image",
      "title": "screenshot.png",
      "path": "~/.tycho/logs/agents/assets/my-agent/att_20260512_120000_abcd1234/original.png",
      "thumbnail_path": "~/.tycho/logs/agents/assets/my-agent/att_20260512_120000_abcd1234/thumb.png",
      "mime_type": "image/png",
      "size_bytes": 348221,
      "width": 1440,
      "height": 900
    }
  ]
}
```

Keep assistant structured result attachments compatible with the current result schema, then normalize image-specific metadata when persisting them.

## Managed Agent Execution

Change the managed-agent send path to accept text plus attachments:

```ruby
agent.add_user_message!(
  content,
  attachments: normalized_attachments
)
```

Internally, command construction should use a structured execution input:

```ruby
ExecutionInput = Struct.new(
  :text,
  :image_paths,
  keyword_init: true
)
```

### Codex

For Codex agents:

- First run: pass every attached image as `--image <path>` to `codex exec`.
- Resume run: pass every attached image as `--image <path>` to `codex exec resume`.
- Keep the textual prompt unchanged except for any short attachment labels that help the transcript remain understandable.

Example command shape:

```text
codex exec --json --image ~/.tycho/logs/agents/assets/my-agent/att_.../original.png "Prompt text"
```

### Claude-Compatible Harnesses

Run a compatibility spike before enabling native image input:

- Verify whether the configured Claude CLI accepts image paths in non-interactive stream-json mode.
- Verify whether custom Claude-compatible wrappers preserve image input through their execution path.
- Capture exact supported flags and output shapes in `docs/research/claude-json-schema-research.md` or a focused image-input research note.

Until verified, use a safe fallback:

- Persist images normally.
- Include local image paths and metadata in the text prompt.
- Mark the execution path as `image_mode: "path_reference"` in logs or run metadata if useful.

The fallback is not equivalent to native vision input, so the UI should avoid implying that all harnesses can inspect pixels.

## TUI Plan

### Composer Attachments

Add pending attachment state to the agent chat form:

- `pending_attachments`
- selected pending attachment index
- last attachment validation error

Add image attach actions:

- Attach local image path from a focused input prompt.
- Detect pasted local image paths in the composer and offer/import them as images.
- Remove a pending attachment before send.
- Clear pending attachments after successful send.

Suggested controls:

| Control | Behavior |
|---------|----------|
| `ctrl+i` | Open attach-image prompt. |
| `ctrl+x` | Remove selected pending image chip when the pending image row is focused. |
| `enter` | Send text plus pending images. |

Keep paste handling compatible with `lib/hq/bubbletea_input.rb` and `lib/hq/ui/components/text_paste.rb`. Pasted paths must be inserted or imported as whole text, not interpreted one rune at a time by global shortcuts.

### Composer Rendering

Render pending image chips above the composer:

```text
Images: [screenshot.png 1440x900 340 KB] [mobile.webp 390x844 82 KB]
```

Show compact validation errors near the composer:

```text
Image rejected: file is larger than 10 MB
```

### Conversation Rendering

For user and assistant message blocks:

- Show image attachment chips or a compact gallery row under the message text.
- Include title, dimensions, and size when available.
- Ensure block wrapping and selection offsets continue to match rendered rows.

Example:

```text
You: What changed in this screenshot?
  [image] screenshot.png 1440x900 340 KB
```

### Attachment Overlay

Keep the existing attachment overlay, but make image-specific details richer:

- preview title
- dimensions
- size
- MIME type
- local path
- source
- created timestamp
- open original action
- copy path action if the app already has a copy abstraction

### Image Preview

First version:

- Always support opening the original with macOS `open`.
- Always support opening the thumbnail or original from the attachment detail action.

Optional terminal inline preview:

- Detect support for a terminal image protocol before rendering pixels.
- Prefer Kitty graphics protocol or iTerm2 inline images only when support is explicit.
- Fall back to metadata-only display when unsupported.

Inline preview should be opportunistic, not required for image support.

## Remote API Plan

Extend the Remote Sessions API served by `bin/tycho serve`.

### Agent Payload

Include attachment metadata in `RemoteService#agent_payload`, or add a focused endpoint if payload size becomes too large:

```http
GET /agents/:key/attachments
```

Return metadata only, not base64 image data.

### Message Send

Extend message creation:

```http
POST /agents/:key/messages
```

Request shape:

```json
{
  "content": "Use this screenshot as context.",
  "attachments": [
    {
      "filename": "screenshot.png",
      "mime_type": "image/png",
      "data_base64": "..."
    }
  ]
}
```

The server should:

- enforce bearer-token auth
- validate request size before decoding where possible
- import images through `AgentAttachmentStore`
- persist normalized attachments on the user message
- pass normalized attachment paths to the managed-agent execution path

For large images or future drag-and-drop flows, consider a two-step upload API:

```http
POST /agents/:key/attachments
POST /agents/:key/messages
```

The first implementation can use inline base64 JSON because the expected file count and size are small.

### Blob and Thumbnail Routes

Add authenticated image routes:

```http
GET /agents/:key/attachments/:attachment_id/blob
GET /agents/:key/attachments/:attachment_id/thumbnail
```

These routes should:

- require the same bearer token as JSON API routes
- only serve files resolved through `AgentAttachmentStore`
- set accurate `Content-Type`
- set conservative `Cache-Control`
- reject path traversal
- return `404` for unknown attachments

Because `<img src>` cannot easily attach a bearer token without cookies, the Remote UI should fetch blobs with `fetch`, pass the token header, create object URLs, and revoke them when no longer needed.

## Remote UI Plan

### Composer Upload

Add image upload controls to the Remote UI composer:

- hidden file input with `accept="image/*"`
- attach button near the text composer
- drag-and-drop support on desktop if it does not complicate mobile behavior
- paste-image support from clipboard where available
- mobile browser camera/photo picker support through normal file input behavior

Pending images should show before send:

- thumbnail
- filename
- dimensions when known
- file size
- remove button
- upload/validation error state

Preserve typed message text and pending images across polling refreshes.

### Conversation Attachments

Render image attachments in conversation blocks:

- thumbnail grid under the related message
- title and dimensions in compact metadata text
- click/tap opens lightbox
- keyboard-accessible open/close behavior

### Lightbox

Add an image lightbox for inspection:

- larger image preview
- filename
- dimensions
- size
- open/download action if supported by the browser flow
- close button and Escape behavior
- mobile-safe layout

### Attachment Gallery

In the agent detail area, add an attachments section:

- recent image thumbnails
- filter by image attachments if future attachment kinds grow
- open selected image in lightbox

This should reuse the same metadata and authenticated blob fetch path as conversation rendering.

## Security and Safety

Image support introduces file and browser blob handling. Keep the implementation constrained:

- Validate MIME type server-side.
- Validate extension as a secondary check only.
- Enforce per-file and per-message size limits.
- Use generated attachment IDs, never user filenames, in stored paths.
- Preserve original filename only as display metadata.
- Reject path traversal and symlinks when importing local files.
- Serve only files registered in attachment metadata.
- Keep Remote API image routes authenticated.
- Revoke browser object URLs after use.
- Do not log base64 payloads or full bearer tokens.
- Treat uploaded images as potentially sensitive local data.

## Tests

### Domain Tests

Add focused tests for `AgentAttachmentStore`:

- imports supported image types
- rejects unsupported MIME types
- rejects oversized files
- computes hash and dimensions
- generates thumbnails
- normalizes metadata shape
- prevents path traversal

### Managed Agent Tests

Add tests for:

- user memory events with image attachments
- assistant structured result image attachment normalization
- Codex first-run command includes `--image`
- Codex resume command includes `--image`
- Claude-compatible fallback prompt includes local image references when native image support is disabled

### TUI Rendering Tests

Extend `test/rendering_test.rb` for:

- pending image chip rendering
- message image attachment rendering
- attachment overlay image metadata
- raw and bracketed paste path behavior still inserts/imports correctly
- long filenames do not break viewport offsets

### Remote Server Tests

Extend `test/remote_server_test.rb` for:

- message creation with base64 image attachment
- attachment metadata appears in agent payload or attachment endpoint
- thumbnail route requires auth
- blob route requires auth
- unknown attachment IDs return 404
- oversized payloads are rejected

### Browser Verification

For Remote UI changes, verify in an actual browser engine:

- upload from file input
- pending thumbnails render before send
- typed composer text survives polling refresh
- pending images survive polling refresh
- send clears pending images
- conversation thumbnails render after send
- lightbox opens and closes
- mobile viewport layout remains usable
- authenticated blob fetch works without leaking token into plain image URLs

Use the existing safe Remote UI verification pattern:

```text
TYCHO_CONFIG_PATH=<temp config>
TYCHO_SYSTEM_PROMPTS_PATH=<temp prompts>
TYCHO_LOGS_ROOT=<temp logs>
bundle exec ruby bin/tycho serve --host 127.0.0.1 --port <spare port>
```

Then drive `http://127.0.0.1:<port>/` with Browser plugin or Playwright + local Chrome fallback.

## Implementation Phases

### Phase 1: Durable Image Attachment Foundation

- Add `AgentAttachmentStore`.
- Add image metadata normalization.
- Add local image import and thumbnail generation.
- Persist image attachments in existing agent memory and attachment sidecars.
- Add domain tests.

### Phase 2: Codex Image Send Path

- Extend managed-agent user message APIs to accept attachments.
- Build structured execution input from text plus image paths.
- Add Codex `--image` command construction for first-run and resume flows.
- Add fallback prompt behavior for non-verified harnesses.
- Add command construction tests.

### Phase 3: TUI Attach and Inspect

- Add pending image state to agent chat forms.
- Add attach/remove/send controls.
- Render pending image chips.
- Render message attachment chips.
- Enrich image attachment overlay details.
- Preserve paste behavior.
- Add rendering and paste regression tests.

### Phase 4: Remote API

- Add image upload support to message creation.
- Add attachment metadata endpoint or payload expansion.
- Add authenticated blob and thumbnail routes.
- Add Remote server tests.

### Phase 5: Remote UI

- Add composer file input and pending image previews.
- Add conversation thumbnails.
- Add image lightbox.
- Add agent attachment gallery.
- Verify polling preservation and mobile layout in a browser.

### Phase 6: Harness Compatibility and Polish

- Research Claude-compatible native image input.
- Enable native image input per harness only when verified.
- Add optional terminal inline preview when terminal support is explicit.
- Update `docs/AGENT_MEMORY.md`, `docs/REMOTE_SERVER.md`, and `docs/PROJECT_STATUS.md` if image support becomes a committed roadmap item.

## Open Questions

- Which image library should HQ use for dimension extraction and thumbnails?
- Should image dedupe be per agent, per project, or global under `~/.tycho/logs/agents/assets/`?
- Should Remote UI use inline base64 message uploads for the MVP, or start with a two-step upload API?
- What exact image input flags are supported by Claude-compatible stream-json execution paths?
- Should the TUI attach-image action accept directories and import every image inside, or only single files?
- Should HQ expose image attachments to future agent tools as paths, URLs, or both?

## Recommended First Slice

Start with the smallest end-to-end path:

1. Implement `AgentAttachmentStore` for local PNG/JPEG import.
2. Add attachments to `ManagedAgent#add_user_message!`.
3. Pass Codex image paths through `--image`.
4. Add a TUI attach-by-path action and pending chip renderer.
5. Add tests for import, memory persistence, and Codex command construction.

This slice proves the core model before adding Remote UI upload complexity or optional inline terminal previews.
