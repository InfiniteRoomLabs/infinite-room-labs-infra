<!-- CCSM:START -->
## Secret Handling Protocol

This project uses Claude Code Secrets Manager (CCSM). Follow these rules:

1. NEVER read, cat, echo, print, or log secret values.
2. Use placeholder syntax in shell commands: `${{SECRET:credName}}`
3. Use the `authenticated_request` MCP tool for API calls with secrets.
4. Run `ccsm secret list` to see available credentials.
<!-- CCSM:END -->
