---@meta

---@alias CodexNvimSplitSide "left"|"right"
---@alias CodexNvimTerminalLayout "split"|"float"
---@alias CodexNvimFloatBorder "none"|"single"|"double"|"rounded"|"solid"|"shadow"
---@alias CodexNvimBackend "terminal"|"app_server"
---@alias CodexNvimCwdPolicy "root"|"file"|"nvim"|string|fun(ctx: CodexNvimCwdContext): string?

---@class (exact) CodexNvimCwdContext
---@field bufnr integer
---@field file? string
---@field file_dir? string
---@field nvim_cwd string

---@class (exact) CodexNvimWindowNavigation
---@field left? string
---@field down? string
---@field up? string
---@field right? string

---@class (exact) CodexNvimTerminalFloatOptions
---@field width_percentage? number
---@field height_percentage? number
---@field border? CodexNvimFloatBorder

---@class (exact) CodexNvimTerminalOptions
---@field layout? CodexNvimTerminalLayout
---@field split_side? CodexNvimSplitSide
---@field split_width_percentage? number
---@field float? CodexNvimTerminalFloatOptions
---@field auto_insert? boolean
---@field auto_close? boolean
---@field hide_keys? string[]
---@field normal_mode_keys? string[]
---@field window_navigation? false|CodexNvimWindowNavigation

---@class (exact) CodexNvimContextOptions
---@field max_lines? integer
---@field max_bytes? integer

---@class (exact) CodexNvimSetupOptions
---@field cmd? string[]
---@field backend? CodexNvimBackend
---@field env? table<string, string>
---@field cwd? CodexNvimCwdPolicy
---@field root_markers? string[]
---@field focus_after_send? boolean
---@field terminal? CodexNvimTerminalOptions
---@field context? CodexNvimContextOptions
---@field app_server? { cmd?: string[] }

---@class (exact) CodexNvimTerminalFloatConfig
---@field width_percentage number
---@field height_percentage number
---@field border CodexNvimFloatBorder

---@class (exact) CodexNvimTerminalConfig
---@field layout CodexNvimTerminalLayout
---@field split_side CodexNvimSplitSide
---@field split_width_percentage number
---@field float CodexNvimTerminalFloatConfig
---@field auto_insert boolean
---@field auto_close boolean
---@field hide_keys string[]
---@field normal_mode_keys string[]
---@field window_navigation false|CodexNvimWindowNavigation

---@class (exact) CodexNvimContextConfig
---@field max_lines integer
---@field max_bytes integer

---@class (exact) CodexNvimConfig
---@field cmd string[]
---@field backend CodexNvimBackend
---@field env table<string, string>
---@field cwd CodexNvimCwdPolicy
---@field root_markers string[]
---@field focus_after_send boolean
---@field terminal CodexNvimTerminalConfig
---@field context CodexNvimContextConfig
---@field app_server { cmd: string[] }

---@class (exact) CodexNvimOpenOptions
---@field focus? boolean
---@field argv? string[]
---@field subcommand? string
---@field args? string[]
---@field cwd? string
---@field keep_open_on_exit? boolean

---@class (exact) CodexNvimShowOptions
---@field focus? boolean

---@class (exact) CodexNvimSendOptions
---@field submit? boolean
---@field on_complete? fun(ok: boolean)

---@class (exact) CodexNvimStatus
---@field backend CodexNvimBackend
---@field running boolean
---@field visible boolean
---@field bufnr? integer
---@field winid? integer
---@field jobid? integer
---@field cwd? string
---@field resolved_cwd? string
---@field argv? string[]
---@field exit_code? integer
---@field initialized? boolean
---@field thread_id? string
---@field turn_id? string
---@field active? boolean
---@field last_context? CodexNvimContextReceipt

---@class (exact) CodexNvimContextMetadata
---@field kind? "file"|"range"|"visual"
---@field file_path string
---@field start_line? integer
---@field end_line? integer
---@field cwd? string
---@field source? string
---@field submitted? boolean

---@alias CodexNvimContextReceipt CodexNvimSingleContextReceipt|CodexNvimFilesContextReceipt

---@class (exact) CodexNvimSingleContextReceipt
---@field kind "file"|"range"|"visual"
---@field file_path string
---@field start_line? integer
---@field end_line? integer
---@field cwd string
---@field source string
---@field submitted boolean

---@class (exact) CodexNvimFilesContextReceipt
---@field kind "files"
---@field paths string[]
---@field cwd string
---@field source string
---@field submitted boolean

---@class (exact) CodexNvimPathsSent
---@field paths string[]
---@field source string
---@field cwd string
---@field submitted boolean
