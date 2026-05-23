# Remote UI Audit Checklist

> Audited: 2026-05-10 against `http://100.64.0.10:7373/`.

## Inventory

- Live endpoint was reachable and served `/`, `/ui.css`, `/ui.js`, and JSON API endpoints.
- Checked main routes: Now, Agents, Search, Projects, Setup, agent detail, project detail, and project action preflight.
- Observed live state: 20 managed agents, 14 active projects, 3 unread agents, no bearer token required, and Tailscale MagicDNS available.

## Fix Checklist

- [x] Fix top-level header layout so the hidden Back button does not make Refresh stretch across the header.
- [x] Replace transient "Agent not found" / "Project not found" deep-link flashes with loading states while initial data loads.
- [x] Align advertised Remote UI refresh intervals with actual client polling behavior.
- [x] Fix long path and summary wrapping in setup/detail rows.
- [x] Rename the Agents tab "New" action so it truthfully reflects the current project-selection flow.
- [x] Add visible feedback for copy-to-clipboard actions.
- [x] Preserve filter caret position across rerenders while typing.
- [x] Add favicon routing so browser favicon requests do not produce noisy 404s.
- [x] Polish placeholder navigation/header controls with icon-style labels and accessible names.
- [x] Strengthen agent start/stop/send affordances with clearer labels and confirmation on stopping a run.
- [x] Keep the footer nav fixed on top-level screens, hide it while scrolling down, and reveal it while scrolling up.

## Verification Notes

- Run `bundle exec ruby -c bin/tycho`.
- Run `bundle exec ruby test/remote_server_test.rb`.
- Run `bundle exec ruby test/registry_test.rb`.
- Run `bundle exec ruby test/rendering_test.rb`.
- Verify `/` and key hash routes in a browser at mobile and desktop widths.
