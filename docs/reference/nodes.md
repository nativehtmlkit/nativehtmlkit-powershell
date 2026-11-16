# Reference: nodes (elements without ids)

Id-based commands cover most apps. Node references address elements that have no `id`, for
example the rows of a generated table, the target of an event (`$evt.node`) or the results of a
selector query. A node reference is a string such as `node:1:18:1`, bound to one document
**generation**: after the element is removed or replaced, the old reference no longer resolves
(`NativeHTMLKit.RpcException` code -32004, `Stale node reference: ...`), and every node of a
retired document throws `NativeHTMLKit.StaleObjectException` in the SDK.

A `NativeHTMLKit.Node` has read-only properties `Id` (the reference string) and `Document`.
Commands that accept `-Node` (`Get-NativeHTMLKitComputedStyle`, `Set-NativeHTMLKitFocus`, the
selection and edit commands, form commands via `-FormNode`) refuse a node of another document.
Raw reference strings (for example in `$evt.node` or `Get-NativeHTMLKitNodes` results) can be passed
to `Invoke-NativeHTMLKitDocumentCommand` as `node = '<ref>'`, or wrapped with
`Get-NativeHTMLKitNode -Reference`.

### Get-NativeHTMLKitNode

Alias: `Get-NHKNode`

Resolves an element id to a node (`node_of`), returns the document root's node when neither
parameter is given, or wraps an existing reference string without a host round trip.

```text
Get-NativeHTMLKitNode [-Document] <Object> [[-Element] <string>] [[-Reference] <string>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Element` | `string` | no | - | Element id to resolve. Use `-Element` or `-Reference`, not both. |
| `-Reference` | `string` | no | - | An existing node reference string, for example `$evt.node`. |

**Returns** `NativeHTMLKit.Node`.

### Get-NativeHTMLKitNodes

Alias: `Get-NHKNodes`

Runs a CSS selector query and returns node references for matches, including elements without
ids (`query_nodes`).

```text
Get-NativeHTMLKitNodes [-Document] <Object> [-Selector] <string> [[-Offset] <int>] [[-Limit] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Selector` | `string` | yes | - | CSS selector. |
| `-Offset` | `int` | no | `0` | Index of the first match to return. Range 0 to 2147483647. |
| `-Limit` | `int` | no | `1024` | Maximum number of matches to return. Range 1 to 4096. |

**Returns** `@{ nodes = @(@{ node; element }); total; offset }` where `element` is the match's id
or `$null`.

```powershell
$third = (Get-NativeHTMLKitNodes -Document $doc -Selector '#log li' -Offset 2 -Limit 1).nodes[0].node
$html = (Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ node = $third }).html
```

### Get-NativeHTMLKitNodeInfo

Alias: `Get-NHKNodeInfo`

Describes a node (`get_node`).

```text
Get-NativeHTMLKitNodeInfo [-Node] <Object> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Node` | `NativeHTMLKit.Node` | yes | - | The node. |

**Returns** `@{ node; type; child_count; parent; ... }`. For an element also `name` (tag name),
`id`, `attributes` and the `previous`/`next` sibling references, for example `type = 'element'`,
`name = 'ul'`, `attributes = @{ id = 'list' }`. The root node has `type = 'document'`.

### Get-NativeHTMLKitNodeChildren

Alias: `Get-NHKNodeChildren`

Lists a node's children (`node_children`), paginated.

```text
Get-NativeHTMLKitNodeChildren [-Node] <Object> [[-Offset] <int>] [[-Limit] <int>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Node` | `NativeHTMLKit.Node` | yes | - | The node. |
| `-Offset` | `int` | no | `0` | Index of the first child. Range 0 to 2147483647. |
| `-Limit` | `int` | no | `256` | Maximum number of children. Range 1 to 4096. |

**Returns** `@{ children = @(@{ node; type; name; id }); total }`.

### Invoke-NativeHTMLKitNodeOperation

Alias: `Invoke-NHKNodeOperation`

Applies one node-addressed operation (sent as a one-element `node_batch`). Operations and their
extra parameters: `set_text`/`append_text` (`text`), `set_attribute` (`name`, `value`),
`remove_attribute`/`add_class`/`remove_class` (`name`), `insert_html` (`position`, `html`),
`replace_children_html` (`html`), `trim_children` (`keep`, optional `from`), `move_element`
(`target_node`, `position`), `remove_element`. A `NativeHTMLKit.Node` given as a parameter value
(for example `target_node`) is converted to its reference; nodes of another document are refused.

```text
Invoke-NativeHTMLKitNodeOperation [-Node] <Object> [-Operation] <string> [[-Parameters] <IDictionary>] [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Node` | `NativeHTMLKit.Node` | yes | - | The node to operate on. |
| `-Operation` | `string` | yes | - | Operation name. |
| `-Parameters` | `System.Collections.IDictionary` | no | `@{}` | Operation fields; `op` and `node` are reserved. |

```powershell
$list = Get-NativeHTMLKitNode -Document $doc -Element log
Invoke-NativeHTMLKitNodeOperation -Node $list -Operation trim_children -Parameters @{ keep = 200 }
```

### Invoke-NativeHTMLKitNodeBatch

Alias: `Invoke-NHKNodeBatch`

Applies several node-addressed operations as one atomic transaction (`node_batch`). Each operation
is a hashtable with `op`, `node` (a reference string) and the fields listed for
`Invoke-NativeHTMLKitNodeOperation`.

```text
Invoke-NativeHTMLKitNodeBatch [-Document] <Object> [-Operations] <Object[]> [<CommonParameters>]
```

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-Document` | `NativeHTMLKit.Document` | yes | - | The document. |
| `-Operations` | `object[]` | yes | - | Array of operation hashtables. |

```powershell
$rows = (Get-NativeHTMLKitNodes -Document $doc -Selector '#rows tr').nodes
Invoke-NativeHTMLKitNodeBatch -Document $doc -Operations @($rows | ForEach-Object { @{ op = 'add_class'; node = $_.node; name = 'stale' } })
```
