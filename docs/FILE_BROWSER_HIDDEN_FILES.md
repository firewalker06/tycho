# File Browser Visibility Policy

The Project Workspace browser is a remote, project-scoped view of repository files. It intentionally does not behave like a local file manager: exclusion protects credentials, host metadata, and generated trees from remote discovery.

| Class | Decision | Rationale |
| --- | --- | --- |
| Version-control metadata: `.git`, `.hg`, `.svn` | Hide | Repository internals can expose history, hooks, local configuration, and credentials; they are not useful source browsing targets. |
| Dependency, build, cache, and runtime trees: `.bundle`, `.cache`, `*.cache`, `.terraform`, `.yardoc`, `build`, `coverage`, `dist`, `log`, `logs`, `node_modules`, `pkg`, `tmp`, `vendor` | Hide | These are generated, high-volume, or dependency-managed. The existing bounded browser is for project source and documentation. |
| Explicit credential names: `.aws`, `.env`, `.envrc`, `.gnupg`, `.netrc`, `.npmrc`, `.pypirc`, `.ssh`, `credentials`, `credentials.json`, private-key and SSH names | Hide | Names have a high credential probability. Safe example files remain visible. |
| Credential-like names: `.env.*`, names containing `credential`, `private-key`, or `private_key`, and conventional `password`, `secret`, and `token` config files | Hide | Defense in depth against ordinary secret-file naming conventions. |
| Key/certificate suffixes: `.key`, `.p12`, `.pfx`, `.pem` | Hide | These formats commonly contain private or client authentication material. |
| Dotfiles not matched above, such as `.rubocop.yml`, `.editorconfig`, `.github`, and `.agents` | Show | They are normal repository configuration and can be needed to understand a project. A file is still blocked if its path or content trips another rule. |
| Internal symlinks | Show and read only after canonical containment succeeds; do not edit | Read-only use preserves useful repository links. Editing a link has poorer race and target semantics, so the editor rejects every leaf symlink. |
| External/broken/looping symlinks and non-file/non-directory special entries | Hide | They cannot meet canonical containment or a safe regular-file/directory contract. |
| Files whose content looks like a private key or secret | Hide from preview and editing | Name checks are not sufficient; content scanning prevents accidental remote disclosure. |

No new visibility exception is needed now. The one product choice worth revisiting is whether `vendor/` should be browsable for repositories that commit first-party generated source; that would weaken the current generated/dependency-tree convention and needs operator approval.
