# Security: untrusted text, HTML, files and secrets

NativeHTMLKit has no JavaScript engine and no network server, so classic browser attacks such as
script injection or cross-site requests do not apply. Markup injection still does: untrusted text
inserted as HTML can change your UI, add misleading controls or load local resources. These rules
keep an app safe.

## 1. Show text as text

`Set-NativeHTMLKitDocumentText` never parses its input. Use it for anything that did not come from
your own source code: user input, file content, log lines, process names, error messages, data
from web services.

```powershell
Set-NativeHTMLKitDocumentText -Document $doc -Element preview -Text (Get-Content -LiteralPath $path -Raw)
```

## 2. Encode every value you put into HTML

When you build HTML (tables, lists), encode each untrusted value with
`[System.Net.WebUtility]::HtmlEncode()`; it is available in both PowerShell editions and encodes
`<`, `>`, `&`, `"` and `'`, so it is also correct inside double- or single-quoted attribute values.

```powershell
$row = '<tr data-name="' + [Net.WebUtility]::HtmlEncode($file.Name) + '"><td>' +
       [Net.WebUtility]::HtmlEncode($file.Name) + '</td></tr>'
```

Never put untrusted values into tag names, attribute names, `style` attributes, CSS text or URLs
without validating them against a strict pattern (for example `^[A-Za-z0-9_-]+$` for an id, a
`^#[0-9a-fA-F]{6}$` colour). Generate element ids from your own counters, not from data.

## 3. Treat event data as input

`$evt.value`, `$evt.element` and form entries come from the document, which the user controls.
Validate them before using them in file paths, command lines or queries. Parse ids you generated
with an anchored regular expression (`'^todo-(\d+)-delete$'`) instead of trusting their content.

## 4. Files and paths

- Use `-LiteralPath` with paths from dialogs or users, so `[` and `*` are not wildcards.
- Check that a path chosen in a dialog is what you expect (extension, folder) before writing.
- `Open-NativeHTMLKitExternal` refuses executables, scripts and shortcuts, and only accepts
  `http`, `https`, `mailto`, `file` and absolute paths; still validate URLs you build from data.

## 5. Background tasks get data, not objects

`Start-NativeHTMLKitTask` refuses SDK objects in `-ArgumentList`. Pass the minimum data the worker
needs; do not pass credentials unless the work needs them, and prefer `PSCredential` objects over
plain-text passwords.

## 6. Secrets and logs

- The host's launch token (`UI4ME_TOKEN`) is removed from the process environment when the
  backend connects, so programs your app starts do not inherit it. Do not log it.
- SDK diagnostics and support bundles are redacted (no values, text, paths or tokens). Your own
  `Write-Host` output is not: avoid printing passwords, tokens or personal data.
- The launcher's temporary manifest folder is private to your user (mode 0700 on Linux, per-user
  `%TEMP%` on Windows) and removed after the run.

## 7. Integrity of the host

The module verifies the bundled host binary against the SHA-256 in `HOST-MANIFEST.json` before
running it, and refuses to run a mismatching file. `NATIVEHTMLKIT_HOST_BINARY` bypasses this check
by design: set it only to binaries you trust.
