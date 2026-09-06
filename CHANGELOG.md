# Changelog

## Unreleased

- Automatic use of a fresh official `rundot` CLI session for Studio authentication
- 5-minute expiry safety window before attempting the CLI token
- Fallback to existing authentication mechanisms when the CLI token is rejected, expired, or near expiry
- Documentation updates (authentication precedence, prerequisites, troubleshooting, development note)
