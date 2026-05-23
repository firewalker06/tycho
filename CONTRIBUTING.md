# Contributing

Thanks for working on HQ.

## Setup

```bash
bundle install
cp config/hq.yml.example config/hq.yml
cp config/system_prompts.yml.example config/system_prompts.yml
bin/tycho
```

Use synthetic projects and temp logs when testing Remote UI or agent behavior.
Do not commit real `.env`, `config/hq.yml`, `config/system_prompts.yml`, logs,
agent transcripts, private paths, or provider account IDs.

## Development

Follow the existing Ruby style:

- Two-space indentation.
- Double-quoted strings.
- `snake_case` methods and variables.
- `SCREAMING_SNAKE_CASE` constants.
- Small domain objects and focused rendering modules.

Keep registry/config parsing out of the TUI layer. Keep managed-agent and Kamal
behavior in domain objects. Keep rendering split between
`lib/hq/ui/rendering.rb` and focused modules under `lib/hq/ui/rendering/`.

## Tests

Run the suite before opening a PR:

```bash
bin/test
```

At minimum, changes should pass:

```bash
bundle exec ruby -c bin/tycho
bundle exec ruby test/registry_test.rb
bundle exec ruby test/rendering_test.rb
bundle exec ruby test/parser_test.rb
bundle exec ruby test/managed_agent_test.rb
bundle exec ruby test/remote_server_test.rb
bundle exec ruby test/tailscale_test.rb
bundle exec ruby test/terminal_qr_test.rb
```

Remote UI changes should include browser verification against a throwaway
`bin/tycho serve` instance with temporary config and logs.

## Pull Requests

PRs should include:

- A brief summary.
- Verification steps.
- Screenshots or terminal captures for visible UI changes.
- Any config, schema, hook, agent, Remote UI, or external-tool implications.

Call out changes to Bubbletea input handling, bracketed paste behavior, Bubbles
text components, Remote UI auth, or agent harness execution.
