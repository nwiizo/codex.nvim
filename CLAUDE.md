# CLAUDE.md - codex.nvim

## 目的

Codex CLI を Neovim から操作し、現在のファイル・選択範囲・explorer の
選択・画像・review target を Codex へ安全に渡す依存なし Lua プラグイン。

## 設計境界

- Neovim 0.12+、macOS/Linux、Codex CLI を対象とする。
- `backend = "terminal"` を安定した既定値とし、完全な Codex TUI を使う。
- `backend = "app_server"` は stdio JSONL の実験的 native UI として分離する。
- `lua/codex/terminal.lua` だけが terminal job/channel を所有する。
- `lua/codex/app_server/client.lua` だけが app-server process と JSONL RPC を所有する。
- 外部 command は shell 文字列ではなく argv 配列で起動する。
- window を閉じても process は維持し、`:CodexStop` だけが明示停止する。
- panel を内側から隠した時は、直前に使っていた editor window へ戻す。
- cwd は session 開始元 buffer から一度だけ解決し、実行中に暗黙変更しない。Codex TUI 内で `/cd` されても context の参照先が変わらないよう、terminal backend への `@path` は絶対パスで送る。
- editor context は行数・byte 数の上限を超えたら切り詰めず拒否する。
- 直近の context は path・行範囲・cwd・insert/submit の metadata だけを session 中に保持する。
- explorer 連携は optional adapter とし、runtime dependency を追加しない。
- 複数同時 session、独自 transcript 永続化、Windows 対応は範囲外。

## 検証

```sh
make check
make integration # installed Codex CLI を使う任意の実機確認
lua-language-server --check=. --checklevel=Warning --configpath=.luarc.json --check_format=pretty
```

個別には `make test`、`make fmt-check`、`make lint` を使用する。

## Commit gate

- commit 前に、CI と同じ StyLua、Luacheck、headless test を含む `make check` を成功させる。
- Lua の型や public annotation を変更した時は、`.luarc.json` を使う LuaLS 型診断もローカルで確認する。
- `.github/workflows/` を変更した時は `actionlint` を実行する。
- app-server process、JSONL、thread lifecycle を変更した時は、Codex CLI を使う `make integration` も実行する。
- 検証を省略したまま「CIで通る」と判断しない。実行できない項目があれば、commit前に理由を明示する。
