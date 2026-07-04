# Omnisearch Plan

## Goal

Add an Omnisearch overlay opened with `<space>` while the Agent/Projects sidebar is focused. It fuzzy-searches active managed agents and active projects by name, then selects the matched Agent or Project with Enter. The overlay should feel like a Neovim-style floating finder: centered above the existing UI, transient, keyboard-first, and scoped to normal sidebar navigation.

## User Experience

- Press `<space>` only while focus is on the Agent or Projects sidebar.
- Render a floating panel above all existing panels with:
  - a single-line query input
  - live fuzzy results below the input
  - the current selection highlighted
- When Omnisearch first opens with an empty query, list all unread active agents by default so the user can quickly jump to the next unread agent.
- Type to filter by active agent names, agent project names, and active project app names.
- Use up/down arrows to move through visible results.
- Press Enter to navigate:
  - Agent result: switch to the Agents screen and select the agent row
  - Project result: switch to the Projects screen and select the project row
- Press Escape to close the overlay and restore the previous screen state.
- Do not open Omnisearch from detail panels, chat composers, inquiry forms, agent editor fields, project forms, or any sidebar overlay.
- Do not include archived projects or archived agents.

## Implementation Steps

1. Add Omnisearch state to `HQ::App`
   - Track whether the overlay is open.
   - Track query text, selected result index, and the previously focused screen/context.
   - Keep state small and reset it when the overlay closes.

2. Build a small domain/search helper
   - Collect project records from the registry-backed project list.
   - Collect managed-agent records from `AgentStore`.
   - Normalize names for case-insensitive matching.
   - Return unread active agents as the default result set when the query is empty.
   - Sort default unread-agent results by the same ordering used in the Agents sidebar unless a clearer unread recency signal already exists.
   - Implement fuzzy scoring locally first; avoid adding a dependency unless the matching quality is poor.

3. Wire global key handling
   - In the main update flow, open Omnisearch on `<space>` only when the list sidebar owns focus on the Agents or Projects screen.
   - When Omnisearch is open, route keys to the overlay first:
     - text input updates query
     - up/down moves selection
     - Enter performs navigation
     - Escape closes
   - Ensure arrow keys do not leak to the underlying screen while the overlay is active.

4. Add rendering module
   - Create a focused renderer under `lib/hq/ui/rendering/` and compose it through `lib/hq/ui/rendering.rb`.
   - Implement the floating panel with the same Lipgloss placement approach already used by the app's confirm/detail overlays:
     - render the normal main screen first
     - render the Omnisearch card as a bordered Lipgloss block
     - center the card with `Lipgloss.place(@window_width, @window_height, :center, :center, dialog)`
     - later, if we need a true overlay that preserves visible background rows behind the panel, introduce a small line-composition helper that replaces only the centered rectangle rows in the rendered base screen
   - Use existing style helpers from `lib/hq/ui/rendering/styles.rb`.
   - Keep dimensions responsive to terminal width/height, with a reasonable max width and result count.
   - Use `Lipgloss.join_vertical` for title/input/results/hint and `Bubbles::ANSI.cut_string` or existing text helpers to clamp long names.
   - Source check: the Ruby Lipgloss docs expose `Lipgloss.place(width, height, horizontal_position, vertical_position, string)` for placing rendered content in whitespace, and the current HQ code already uses that method for centered modal overlays.

5. Implement navigation behavior
   - For projects, reuse the existing project selection/index mechanics.
   - For agents, reuse the existing agent selection/index mechanics.
   - Enter only selects the matching row on the relevant screen; it does not open detail or chat.

6. Add regression coverage
   - Unit-test fuzzy matching and result ordering if the helper is separate.
   - Add rendering tests for:
     - empty-query default unread-agent results
     - overlay shown above a base screen
     - agent and project results by name
     - selected result styling
   - Add interaction/update tests for:
     - `<space>` opens from Agents/Projects sidebar focus
     - `<space>` is ignored outside sidebar focus
     - arrows move selection
     - Escape closes
     - Enter selects the matched Agent or Project without opening detail/chat

7. Manual verification
   - Run `bundle exec ruby -c bin/tycho`.
   - Run `bundle exec ruby test/registry_test.rb`.
   - Run `bundle exec ruby test/rendering_test.rb`.
   - Run `bin/tycho` and verify Omnisearch across Projects, Agents, detail views, chat, forms, and sidebar overlays.

## Decisions

- Open trigger: `<space>` only from Agent/Projects sidebar focus.
- Enter behavior: only select the matched row on the Agents/Projects screen.
- Project search/display: app names only for now.
- Agent search/display: agent names plus project names for disambiguation.
- Scope: active projects and active agents only; archived records are excluded.
- Default results: empty query lists unread active agents first, optimized for jumping to the next unread agent quickly.

## Data Gathering

Omnisearch should not read config files or logs directly while the user types. It should build a lightweight index from the current app state when the overlay opens, then reuse that index until the overlay closes.

Sources:

- Projects: use `@projects`, which is populated from `Registry#projects` and wrapped as `Project` objects in `load_registry!`.
- Project searchable/display text: `Project#name` only. Do not search `key`, `path`, `group`, host, or repo metadata for the first version.
- Project target: keep the project object or its `key`, plus its current index in `@projects`.
- Agents: use `@agents`, which is loaded from `AgentStore#load` and sorted by `sort_agents`.
- Agent searchable/display text: `ManagedAgent#name` plus the project name shown beside it. Do not search harness/provider, workspace path, prompt, template, or logs for the first version.
- Agent unread default filter: `ManagedAgent#unread?`.
- Agent target: keep the agent object or its `key`, plus its current index in `@agents`.

Active-only behavior falls out of current app state: archived projects are removed from `@projects`, and agents for archived projects are removed from `@agents` during archive. Still, the index builder should defensively reject agents whose `project_key` no longer maps to an active project.

Index row shape:

```ruby
OmnisearchItem = Struct.new(
  :type,          # :agent or :project
  :label,         # rendered name
  :search_text,   # normalized label
  :target_key,    # agent.key or project.key
  :source_index,  # index in @agents or @projects at index build time
  :unread,        # true only for unread agents
  keyword_init: true
)
```

## Fuzzy Finding

Use a small local matcher so Omnisearch has no new runtime dependency and stays predictable in tests.

Normalization:

- Convert query and candidate names to lowercase.
- Strip leading/trailing whitespace.
- Collapse repeated whitespace to a single space.
- Keep punctuation, but let the matcher skip across it.

Matching rules:

- Empty query: return unread active agents only.
- Non-empty query: search all active agents and active projects.
- A candidate matches when every query character appears in order inside the candidate name.
- Exact substring matches should rank above scattered character matches.
- Prefix matches should rank above non-prefix substring matches.
- Compact contiguous matches should rank above wide-gap matches.
- Earlier matches should rank above later matches.
- Tie-break by type priority and source order:
  - agents before projects when scores are equal
  - then `source_index`, preserving the sidebar's current order

Suggested score shape:

```ruby
score =
  1_000                                  # base match
  + exact_prefix_bonus                   # candidate starts with query
  + exact_substring_bonus                # candidate includes query
  + contiguous_bonus                     # matched positions are adjacent
  - gap_penalty                          # distance between matched chars
  - start_penalty                        # later first match is worse
```

Implementation sketch:

```ruby
def fuzzy_score(query, candidate)
  query = normalize_search_text(query)
  candidate = normalize_search_text(candidate)
  return nil if query.empty? || candidate.empty?

  positions = []
  cursor = 0
  query.each_char do |char|
    found = candidate.index(char, cursor)
    return nil unless found

    positions << found
    cursor = found + 1
  end

  gaps = positions.each_cons(2).sum { |left, right| right - left - 1 }
  score = 1_000
  score += 500 if candidate.start_with?(query)
  score += 300 if candidate.include?(query)
  score += 100 if gaps.zero?
  score -= gaps * 10
  score -= positions.first * 3
  score
end
```

Result building:

- On open, build the index once from `@agents` and `@projects`.
- On each query change, compute scores against the index.
- Drop items with `nil` scores.
- Sort by `[-score, type_priority, source_index]`.
- Clamp visible results to the panel height; selection index should reset or clamp when results change.

## Rendering Notes

I should look at Lipgloss placement directly during implementation, and the repo already gives us the right starting point. `delete_confirm_view`, `project_archive_confirm_view`, `clone_confirm_view`, and `detail_full_view` render a dialog and pass it to `Lipgloss.place(...)`. Omnisearch should reuse that proven pattern first because it is simple and consistent with HQ's existing modal behavior.

The only subtlety: `Lipgloss.place` places the panel in whitespace, so returning only that output replaces the underlying screen rather than compositing on top of it. If the visual requirement is that the current panels remain visible behind Omnisearch, implement a small overlay compositor that:

1. renders `main_screen_view`
2. renders the Omnisearch card
3. splits both into lines
4. computes the centered top/left offset
5. replaces the corresponding rectangle in the base lines with the card lines

That keeps the "floating above all panels" behavior literal while still using Lipgloss for sizing, borders, and placement math.
