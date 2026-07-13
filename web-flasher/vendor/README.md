# Vendored ESP Web Tools

`esp-web-tools` is vendored at exact version **10.2.1** under
`vendor/esp-web-tools/` so the firmware installer never executes floating CDN
code with Web Serial access.

- npm package integrity: `sha512-BMIAANw06yGx4rgTPshV8OdMcnFpPuwv6AWPaKJZS2UiwdkW3TV5AgLGpa6rw+8dPuGnoKtSshyFCz02FRGsUQ==`
- `install-button.js` SHA-256: `2a3b0f39a31049879c1bc47615ad2edfddd06ddc67d9aff45b8c13d3a4467cf9`
- Upstream license: `esp-web-tools/LICENSE`

To update, fetch an exact npm version, verify its registry integrity, replace
the complete `dist/web/` directory and license, then rerun the local browser
test before accepting the new code.
