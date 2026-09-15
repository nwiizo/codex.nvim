<p align="center">

  <img src="assets/codex-nvim.png" alt="codex.nvim icon" width="180">
</p>
# codex.nvim

[![CI](https://github.com/nwiizo/codex.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/nwiizo/codex.nvim/actions/workflows/ci.yml)

`codex.nvim` is an unofficial, dependency-free Neovim integration for the [OpenAI Codex CLI](https://developers.openai.com/codex/cli/). It keeps Codex beside the file you are editing and can send files, selections, explorer entries, images, and review targets without leaving Neovim.

The command surface and side-panel workflow are inspired by [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim). The implementation uses Codex's public CLI and app-server interfaces.

> [!NOTE] This is a community project. It is not maintained or endorsed by OpenAI.

<p align="center">
  <img src="assets/codex-nvim-demo.png" alt="codex.nvim running OpenAI Codex beside an active Neovim buffer">
</p>

## Features

- Pure Lua with no runtime plugin dependencies
- Neovim 0.12-native APIs and shell-free argv execution
- Interactive Codex terminal that survives window hiding
- Smart focus: reveal a hidden session, jump to a visible session, or hide it and return to the most recent editor window when already focused
- Configurable terminal-to-window navigation, defaulting to `Alt-h/j/k/l`
- Working directory policies centered on the active file or project root
- Resume, continue, fork, review, image, and interrupt workflows
- Exact line, characterwise, linewise, and blockwise selection context
- Configurable Ask/Edit hints below selections and editable request drafts
- Request actions for explanation, fixes, tests, and refactoring, with optional source diagnostics and file references
- File/directory references from nvim-tree, neo-tree, Oil, mini.files, netrw, and Snacks picker lists
- Status receipts for the last file or selection handed to the active session
- Optional app-server backend with streamed Markdown, approval prompts, plans, and native diff buffers
- `:checkhealth codex` diagnostics and `User` autocmd lifecycle events

## Requirements

- Neovim 0.12+
- [Codex CLI](https://developers.openai.com/codex/cli/) on `PATH`
- macOS or Linux

## Installation

With lazy.nvim:

```lua
{
  "nwiizo/codex.nvim",
  event = "VeryLazy", -- load before selecting text to show Ask/Edit hints
  cmd = {
    "Codex",
    "CodexOpen",
    "CodexFocus",
    "CodexResume",
    "CodexContinue",
    "CodexFork",
    "CodexReview",
    "CodexImage",
    "CodexPrompt",
    "CodexAsk",
    "CodexAskVisual",
    "CodexFollowUp",
    "CodexEdit",
    "CodexSend",
    "CodexSendVisual",
    "CodexAddVisual",
    "CodexAdd",
    "CodexTreeAdd",
    "CodexDiff",
    "CodexInterrupt",
    "CodexStatus",
    "CodexStop",
    "CodexHealth",
  },
  opts = {},
}
```

For local development, replace the repository string with `dir = "/path/to/codex.nvim"` and add `name = "codex.nvim"`.

## Quick start

Open or toggle Codex:

```vim
:Codex
```

Add the current file to the composer without submitting:

```vim
:CodexAdd
```

Insert an exact visual selection without submitting, then finish the prompt inside Codex:

```vim
:'<,'>CodexAddVisual
```

Send an exact visual selection:

```vim
:'<,'>CodexSendVisual
```

Selections and line ranges also work in unnamed buffers, such as stdin mail
readers. Their text is included directly without an `@path` reference or a
temporary file. `CodexAdd` still requires a file path.

Add marked or selected explorer entries:

```vim
:CodexTreeAdd
```

A compact keymap setup:

```lua
keys = {
  { "<leader>ax", "<cmd>CodexFocus<cr>", desc = "Focus or hide Codex" },
  { "<leader>ab", "<cmd>CodexAdd<cr>", desc = "Add current buffer to Codex" },
  {
    "<leader>aa",
    "<cmd>CodexAsk<cr>",
    desc = "Ask Codex with file context",
  },
  {
    "<leader>as",
    ":<C-U>CodexSendVisual<CR>",
    mode = "v",
    desc = "Send selection to Codex",
  },
}
```

`CodexFocus` behaves according to where the Codex window is:

| State                     | Result                               |
| ------------------------- | ------------------------------------ |
| Running but hidden        | Reopen and focus it                  |
| Visible in another window | Move focus to it                     |
| Already focused           | Hide it without stopping the process |
| Not running               | Start and focus a new session        |

Prompt and context commands also start the selected backend when it is not running. Terminal input stays queued until Codex exposes its composer, so an upgrade or onboarding screen cannot consume it. Cold starts honor `focus_after_send` while the session starts.

Hiding the panel from inside it restores the most recent non-Codex window when that window still exists.

Inside the terminal, `Alt-h`, `Alt-j`, `Alt-k`, and `Alt-l` leave terminal mode and move to the neighboring Neovim window. If your terminal emulator does not send Option/Alt as Meta, configure different keys with `terminal.window_navigation`.

Neovim sends keys typed in terminal mode to Codex, including `Esc`. Use `Ctrl-\` followed by `Ctrl-n` to enter Neovim's terminal Normal mode, then use `v`, `V`, or `Ctrl-v` to select terminal text and `i` to return to Codex. Set `terminal.normal_mode_keys` for a shorter buffer-local mapping. Avoid mapping `Esc`, because Codex uses it to cancel UI states and interrupt or backtrack.

## Select, ask, and edit

Select code with `v`, `V`, or `Ctrl-v`. A virtual line below the selection shows `[Codex <leader>aa: Ask, <leader>aE: Edit]`. Ask opens an editable Markdown request containing the exact selection. Edit also adds a change-request prompt. Write the instruction before sending; opening either action does not start Codex.

The request window shows **“Type your request. Ctrl-S to send. Enter for a new line.”** while you type, and **“Press i to start typing. Ctrl-S to send.”** in Normal mode. **“Ctrl-S Send”** also appears above the text, before attachment shortcuts, and stays visible when the header is shortened to fit a narrow window. These instructions are outside the editable message and are never sent to Codex. The same guidance appears for `:CodexFollowUp`.

| Request key | Action |
| ----------- | ------ |
| `Ctrl-s` or `:write` | Submit the edited request |
| `Enter` (Insert mode) | Add a new line to the request |
| `Ctrl-p` | Add an Explain, Fix, Add tests, or Refactor instruction |
| `Ctrl-d` | Attach diagnostics from the source selection or file |
| `Ctrl-f` | Attach a file or directory reference |
| `q` (Normal mode) / `Ctrl-c` | Hide and keep the draft |

Use `:CodexAsk` to reopen a hidden draft and `:bdelete!` in the request buffer to discard it. Attachments are plain editable text: remove them by deleting their lines. Delivery failures keep the draft for retry; a queued request stays locked until delivery completes. Edit asks Codex to change code through the selected backend; it does not provide an inline accept/reject patch UI.

Submission hides the request so the Codex panel can show startup, approvals, and the response. A delivery failure reopens the editable draft. Once Codex answers, type directly in its terminal or use `:CodexFollowUp` for another multiline request in the running conversation. Follow-up works from the panel or a diff view and does not attach that buffer's text. It refuses submission if the process stops or is replaced, or the app-server thread changes, while the draft is open. Terminal-side conversation switches remain managed by the Codex TUI.

The terminal panel displays **“Type a message. Enter to send.”** while accepting keyboard input. In terminal Normal mode it says **“Press i to start typing.”**; while selecting text it tells you to press Esc first. If a request is waiting for startup, the panel asks you to check any Codex setup prompts and sends the queued request once the composer is ready. Existing custom winbar actions remain after these instructions. Whole-bar `%!` formatters keep control of their winbar and do not receive the built-in hint.

Use `:CodexClose` to return to editing while keeping the process, then `:CodexOpen` to read or continue the conversation. Review saved changes with your Git diff integration; the terminal backend applies edits through Codex and does not stage or revert them automatically. `:CodexDiff` is the app-server backend's latest-turn diff.

Without a selection, `:CodexAsk` adds the saved file's absolute `@path`, or a snapshot of a named buffer with unsaved changes. Drafts retain their original working directory even after changing files. Both context limits apply to the entire edited request, and oversized requests are rejected without truncation.

Configure the visual mappings and hint together, for example when Avante also uses `<leader>aa` and `<leader>aE`:

```lua
selection = {
  enabled = true,
  hint = true,
  keymaps = { ask = "<leader>oa", edit = "<leader>oe" },
}
```

Existing mappings are preserved and conflicting actions are omitted from the hint. Set `hint = false` to keep mappings without the hint, `enabled = false` to disable both, or an individual keymap to `false` to disable that action's mapping. The hint uses the `CodexSelectionHint` highlight group (linked to `Comment`).

## Commands

| Command | Description |
| --- | --- |
| `:Codex [args...]` | Toggle the selected backend; start `codex [args...]` when absent |
| `:CodexOpen [args...]` | Show the selected backend; start Codex when absent |
| `:CodexClose` | Hide the window without stopping Codex |
| `:CodexFocus` | Focus a visible/hidden session, or hide it when already focused |
| `:CodexStop` | Stop the Codex process |
| `:CodexResume [--all\|session]` | Pick or resume a prior session |
| `:CodexContinue` | Resume the most recent session |
| `:CodexFork [--all\|session]` | Pick or fork a prior session |
| `:CodexReview [--uncommitted\|--base BRANCH\|--commit SHA\|instructions]` | Review a change target |
| `:CodexImage {path...}` | Start a Codex session/turn with local images |
| `:CodexPrompt [text]` | Prompt Codex, using `vim.ui.input` when text is omitted |
| `:[range]CodexAsk [text]` | Compose a request with file or line context |
| `:'<,'>CodexAskVisual [text]` | Compose a request with the exact selection |
| `:CodexFollowUp [text]` | Compose a follow-up without attaching the current buffer |
| `:'<,'>CodexEdit [text]` | Compose a change request with the exact selection |
| `:[range]CodexSend` | Send complete lines with file and range context |
| `:'<,'>CodexSendVisual` | Send the exact visual selection |
| `:'<,'>CodexAddVisual` | Insert the exact visual selection without submitting |
| `:CodexAdd [path]` | Insert an `@path` reference without submitting |
| `:[range]CodexTreeAdd` | Insert selected explorer paths without submitting |
| `:CodexSendText[!] {text}` | Send and submit text; bang only inserts it |
| `:CodexDiff` | Show the latest app-server diff in a native diff buffer |
| `:CodexInterrupt` | Interrupt the active app-server turn |
| `:CodexStatus` | Show backend, process, cwd, and the last context receipt |
| `:CodexHealth` | Run `:checkhealth codex` |

Starting a separate terminal review, image, resume, or fork command does not replace an active terminal process. Stop or exit the current session first. When no session ID is supplied, `CodexResume` and `CodexFork` briefly use app-server `thread/list` to provide `vim.ui.select` pickers even with the terminal backend. Supply a session ID to use the terminal CLI directly.

## Configuration

```lua
require("codex").setup({
  backend = "terminal", -- "terminal" or "app_server"
  cmd = { "codex" },
  env = {}, -- passed to terminal and app-server processes

  -- "root", "file", "nvim", a directory path, or function(ctx)
  cwd = "root",
  root_markers = { ".git" },
  focus_after_send = false, -- applies to both backends

  terminal = {
    layout = "split", -- "split" or "float"
    split_side = "right",
    split_width_percentage = 0.35,
    float = {
      width_percentage = 0.85,
      height_percentage = 0.85,
      border = "rounded",
    },
    auto_insert = true,
    auto_close = true,
    hide_keys = {}, -- terminal-local keys that hide Codex
    normal_mode_keys = {}, -- terminal-local keys that enter Neovim Normal mode
    window_navigation = {
      left = "<M-h>",
      down = "<M-j>",
      up = "<M-k>",
      right = "<M-l>",
    },
  },

  context = {
    max_lines = 500,
    max_bytes = 65536,
  },

  selection = {
    enabled = true,
    hint = true,
    keymaps = { ask = "<leader>aa", edit = "<leader>aE" },
  },

  app_server = {
    cmd = { "codex", "app-server" },
  },
})
```

For a named Codex profile:

```lua
cmd = { "codex", "--profile", "work" },
app_server = {
  cmd = { "codex", "--profile", "work", "app-server" },
},
```

Configure both commands so the native backend and terminal resume/fork pickers list sessions from the same profile.

Set `terminal.window_navigation = false` to disable all four terminal-local mappings.

For example, use `Alt-n` to enter Neovim's terminal Normal mode without taking `Esc` away from Codex:

```lua
terminal = {
  normal_mode_keys = { "<M-n>" },
}
```

The mappings are local to the Codex terminal buffer. Once in Normal mode, use `v`, `V`, or `Ctrl-v` for Visual mode and `i` or `a` to return to terminal mode.

For a centered floating Codex TUI with terminal-local hide keys:

```lua
terminal = {
  layout = "float",
  float = {
    width_percentage = 0.85,
    height_percentage = 0.85,
    border = "rounded",
  },
  hide_keys = { "<C-/>", "<C-_>" },
}
```

The hide mappings are buffer-local, so the same keys keep their existing behavior in editor and other terminal buffers. `<C-/>` and `<C-_>` cover the two encodings commonly produced for Ctrl-/ by terminals and multiplexers.

### Working directory policy

The default `cwd = "root"` starts Codex from the nearest directory containing a root marker for the file that was active when the session started. When no root is found, it falls back to the file's directory, then Neovim's cwd. For example, opening `github.com/nwiizo/codex.nvim/lua/codex/init.lua` in the standalone repository starts Codex from `github.com/nwiizo/codex.nvim`. Use `cwd = "file"` when the file's own `lua/codex` directory should always win.

| Value           | Resolution                                          |
| --------------- | --------------------------------------------------- |
| `"root"`        | Nearest configured root marker from the active file |
| `"file"`        | Active file's directory                             |
| `"nvim"`        | Neovim's current working directory                  |
| `"/fixed/path"` | Explicit directory                                  |
| `function(ctx)` | Custom directory chosen from buffer context         |

The callback receives `bufnr`, `file`, `file_dir`, and `nvim_cwd`:

```lua
cwd = function(ctx)
  return vim.fs.root(ctx.file or ctx.nvim_cwd, { "Makefile", ".git" })
    or ctx.file_dir
    or ctx.nvim_cwd
end
```

The resolved startup cwd is fixed for the lifetime of a running session. Stop it before restarting from a different file or root. If you change the Codex TUI cwd with `/cd`, terminal context commands use absolute `@path` references so files and selections still point to the intended source. `:CodexStatus` keeps showing the startup cwd managed by codex.nvim.

## Backends

### Terminal (default)

The terminal backend runs the complete interactive Codex TUI. It is the recommended default because Codex owns the conversation UI and approval flow. Closing its split or float only hides the buffer; `:CodexStop` stops the process. The split side and width under `terminal` are also reused by the app-server panel. Argument-free resume/fork pickers depend on app-server; pass a session ID to run those terminal commands without the picker protocol.

### App-server (experimental)

```lua
opts = { backend = "app_server" }
```

The app-server backend starts `codex app-server` over stdio JSONL and provides a native Markdown transcript, streamed agent messages, thread pickers, plan and command output, approval and permission prompts through `vim.ui.select`, user input requests, and diff buffers. MCP elicitation can be declined or cancelled; client-defined dynamic tools and external token/attestation providers are not advertised or implemented. The upstream app-server API is experimental and may change. The terminal TUI can still be used if a Codex CLI update changes the protocol; pass explicit session IDs instead of using its app-server-backed resume/fork pickers.

## Explorer integration

Run `:CodexTreeAdd` from a supported explorer buffer. No explorer is installed or required by codex.nvim.

| Explorer      | Selection behavior                                |
| ------------- | ------------------------------------------------- |
| nvim-tree     | Marks, then the node under the cursor             |
| neo-tree      | Visual range/selection, then the current node     |
| Oil           | Visual range or cursor entry                      |
| mini.files    | Visual range or cursor entry                      |
| netrw         | Marked files or cursor entry                      |
| Snacks picker | Selected items, with the current item as fallback |

Paths are canonicalized, deduplicated, checked for existence, and sent relative to the running Codex cwd when possible.

## Events

The plugin emits these `User` autocmds. Payloads are available in `event.data`.

| Pattern                | When                                          |
| ---------------------- | --------------------------------------------- |
| `CodexStarted`         | A terminal process starts                     |
| `CodexExited`          | A terminal process exits                      |
| `CodexOpened`          | A hidden terminal becomes visible             |
| `CodexClosed`          | A terminal window is hidden                   |
| `CodexContextSent`     | A file, range, or visual selection is sent    |
| `CodexPathsSent`       | One or more explorer/command paths are sent   |
| `CodexAppServerReady`  | The app-server initialize handshake completes |
| `CodexAppServerExited` | The app-server process exits                  |
| `CodexThreadStarted`   | A new app-server thread starts                |
| `CodexTurnStarted`     | An app-server turn starts                     |
| `CodexTurnCompleted`   | An app-server turn finishes                   |
| `CodexDiffUpdated`     | The latest app-server turn diff changes       |

Terminal payloads include process/window metadata. Context payloads include kind, file path, line numbers when applicable, cwd, and whether the context was inserted into the composer or submitted. `:CodexStatus` retains only this metadata for the active session, not the selected source text. The `source` field identifies the buffer, explorer, range, or visual-selection origin. Paths in context events and status remain relative to the startup cwd when possible, even though the terminal composer receives absolute references. App-server payloads include thread/turn identifiers and event-specific data.

## Design boundaries

- One Codex process/thread is managed per Neovim instance.
- Context over `context.max_lines` or `context.max_bytes` is rejected instead of silently truncated.
- The plugin does not persist a second transcript; Codex remains the source of truth for session history.
- Windows is not currently supported.

## Development

```sh
make test          # headless unit/behavior suite
make integration   # initialize the installed Codex app-server and list threads
make fmt-check
make lint
make check
```

LuaLS reads `.luarc.json`; CI runs formatting, type diagnostics, and the test suite against Neovim 0.12, stable, and nightly.

## License

Friend License (MIT-equivalent).
