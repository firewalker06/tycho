# File Browser Visibility Policy

The Project Workspace browser is a remote, project-scoped view of repository files. It intentionally does not behave like a local file manager: exclusion protects credentials, host metadata, and generated trees from remote discovery.

| Class | Decision | Rationale |
| --- | --- | --- |
| Version-control metadata: `.git`, `.hg`, `.svn` | Hide | Repository internals can expose history, hooks, local configuration, and credentials; they are not useful source browsing targets. |
| Dependency, build, cache, and runtime trees: `.bundle`, `.cache`, `*.cache`, `.terraform`, `.yardoc`, `build`, `coverage`, `dist`, `log`, `logs`, `node_modules`, `pkg`, `tmp`, `vendor` | Hide | These are generated, high-volume, or dependency-managed. `vendor/` remains hidden under this convention. |
| Explicit credential names: `.aws`, `.env`, `.envrc`, `.gnupg`, `.netrc`, `.npmrc`, `.pypirc`, `.ssh`, `credentials`, `credentials.json`, private-key and SSH names | Hide | Names have a high credential probability. Safe example files remain visible. |
| Credential-like names: `.env.*`, names containing `credential`, `private-key`, or `private_key`, and conventional `password`, `secret`, and `token` config files | Hide | Defense in depth against ordinary secret-file naming conventions. |
| Key/certificate suffixes: `.key`, `.p12`, `.pfx`, `.pem` | Hide | These formats commonly contain private or client authentication material. |
| Dotfiles not matched above, such as `.rubocop.yml`, `.editorconfig`, `.github`, and `.agents` | Show | They are normal repository configuration and can be needed to understand a project. A file is still blocked if its path or content trips another rule. |
| Internal symlinks | Show and read only after canonical containment succeeds; do not edit | Read-only use preserves useful repository links. The editor rejects a symlink in any path component, including a symlinked directory. |
| External/broken/looping symlinks and non-file/non-directory special entries | Hide | They cannot meet canonical containment or a safe regular-file/directory contract. |
| Files whose content looks like a private key or secret | Hide from preview and editing | Name checks are not sufficient; content scanning prevents accidental remote disclosure. |

No new visibility exception is needed now. Any future request to browse `vendor/` is a separate explicit product change that would revise the generated/dependency-tree convention.
