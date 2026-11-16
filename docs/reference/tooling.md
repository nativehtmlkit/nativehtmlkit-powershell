# Reference: project scaffolding and agent skills

How-to: [Project scaffolding](../guides/project-scaffolding.md).

### New-NativeHTMLKitProject

Alias: `New-NHKProject`

Generates a runnable app folder: `app.ps1` (UTF-8 with BOM, so Windows PowerShell 5.1 reads it
correctly), `index.html`, `style.css` and an optional `app.toml` manifest. Refuses to overwrite any
of these files without `-Force`. Run the app with `pwsh -File ./app.ps1` (or
`powershell.exe -File .\app.ps1`); `app.toml` is for launchers that start the host explicitly with
`Start-NativeHTMLKitHost` and names `pwsh`, or `powershell.exe` with `-WindowsPowerShell`.

```text
New-NativeHTMLKitProject [-Path] <string> [[-Name] <string>] [[-AppId] <string>] [-WindowsPowerShell] [-Force] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Path` | `string` | yes | - | Destination folder; created when missing. Must not be a file. |
| `-Name` | `string` | no | `'NativeHTMLKit PowerShell App'` | App name (1-128 characters, no quotes, backslashes or control characters). |
| `-AppId` | `string` | no | `'org.example.PowerShellApp'` | Reverse-DNS identity written to `app.ps1` and `app.toml`. |
| `-WindowsPowerShell` | `switch` | no | off | Make `app.toml` start `powershell.exe` instead of `pwsh`. Alias: `-WindowsPowerShell51`. |
| `-Force` | `switch` | no | off | Overwrite existing generated files. |

**Returns** the folder's `System.IO.DirectoryInfo`.

```powershell
New-NativeHTMLKitProject -Path ./InventoryTool -Name 'Inventory tool' -AppId 'org.example.InventoryTool'
pwsh -File ./InventoryTool/app.ps1
```

### Install-NativeHTMLKitSkill

Alias: `Install-NHKSkill`

Installs, inspects or removes the `nativehtmlkit-powershell` coding-agent skill (bundled in the
module under `skills/`) for Claude Code, Codex, OpenCode, GitHub Copilot, Cursor and Gemini CLI.
User scope writes below your home folder; project scope below `-ProjectPath`:

| Agent | User scope | Project scope |
|---|---|---|
| `claude` | `~/.claude/skills` | `.claude/skills` |
| `codex` | `~/.agents/skills` | `.agents/skills` |
| `opencode` | `~/.config/opencode/skills` | `.opencode/skills` |
| `copilot` | `~/.copilot/skills` | `.github/skills` |
| `cursor` | `~/.cursor/skills` | `.cursor/skills` |
| `gemini` | `~/.gemini/skills` | `.gemini/skills` |

An installed folder carries a `.nativehtmlkit-managed.json` record of its file hashes. Folders not
installed by this command (`unmanaged`) or edited since (`modified`) are never replaced or removed
without `-Force`; links and junctions in the destination path are refused.

```text
Install-NativeHTMLKitSkill [[-Action] <string>] [[-Agents] <string[]>] [[-Scope] <string>] [[-ProjectPath] <string>] [-Force] [-DryRun] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Action` | `string` | no | `'install'` | `install`, `status` or `uninstall`. One of: `install`, `status`, `uninstall`. |
| `-Agents` | `string[]` | no | `@('all')` | Agent names (also comma-separated) or `all`. |
| `-Scope` | `string` | no | `'user'` | `user` or `project`. One of: `user`, `project`. |
| `-ProjectPath` | `string` | no | - | Existing project folder; required with `-Scope project`, not allowed with `user`. |
| `-Force` | `switch` | no | off | Replace or remove unmanaged or modified skill folders. |
| `-DryRun` | `switch` | no | off | Report what would happen without changing anything. |

**Returns** one object per agent: `Agent`, `Scope`, `State` (`missing`, `installed`, `modified`,
`unmanaged`), `Path`, `Action` (`installed`, `removed`, `none`, `status`, `would-<action>`).

```powershell
Install-NativeHTMLKitSkill -Action status -Agents claude,codex -Scope project -ProjectPath .
```
