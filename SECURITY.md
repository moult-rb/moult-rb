# Security Policy

Moult reads source code and (optionally) coverage and provider data, so we take
security seriously. Thank you for helping keep Moult and its users safe.

## Supported versions

Moult is pre-1.0; only the latest released `0.x` version receives security
fixes. Pin a version and upgrade promptly.

## Reporting a vulnerability

**Please do not open a public issue for security reports.**

Report privately via GitHub's [private vulnerability reporting](https://github.com/moult-rb/moult-rb/security/advisories/new)
(Security → Report a vulnerability), or email **contact@moult.dev** with:

- a description of the issue and its impact,
- steps to reproduce (a minimal repository or snippet helps),
- any known mitigations.

We aim to acknowledge reports within 5 business days and to keep you updated as
we investigate and fix. Please give us a reasonable window to release a fix
before any public disclosure.

## Scope notes

- Moult runs **locally / in your CI**; the gem itself does not transmit your
  source anywhere. The optional `moult-action` uploads only the **sanitised,
  source-free** gate result (see `Moult::CloudUpload`) to a URL you configure.
- Findings are confidence-graded signals, never assertions of fact — but a bug
  that causes Moult to read files outside the analysis root, leak source in any
  output, or mis-handle credentials is in scope and worth reporting.
