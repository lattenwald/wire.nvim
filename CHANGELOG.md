# Changelog

## [0.6.0](https://github.com/lattenwald/wire.nvim/compare/v0.5.0...v0.6.0) (2026-10-02)


### Features

* **lsp:** optional in-process language server: symbols, definition, hover, code actions ([652bbd5](https://github.com/lattenwald/wire.nvim/commit/652bbd52f32869bf5362c4cd613408e21376002a))

## [0.5.0](https://github.com/lattenwald/wire.nvim/compare/v0.4.0...v0.5.0) (2026-10-02)


### Features

* :Wire yank copies the request under the cursor as curl, without sending ([d89b266](https://github.com/lattenwald/wire.nvim/commit/d89b266c4e3c6c2f7ace47b0d276d2d21436d19b))
* **ui:** g? hint in the response window winbar, truncated after the tabs ([857e785](https://github.com/lattenwald/wire.nvim/commit/857e7857968e507e09f3970aead5f7bc2d7d9c5e))

## [0.4.0](https://github.com/lattenwald/wire.nvim/compare/v0.3.0...v0.4.0) (2026-10-02)


### Features

* request timing breakdown and Server-Timing in Verbose, response.timing for scripts ([9f0f197](https://github.com/lattenwald/wire.nvim/commit/9f0f197c885d32891f7bd9cb50919f6ac4c691ee))

## [0.3.0](https://github.com/lattenwald/wire.nvim/compare/v0.2.0...v0.3.0) (2026-10-01)


### Features

* env() in the response window returns the shown result's environment; statusline examples ([c7154ee](https://github.com/lattenwald/wire.nvim/commit/c7154ee198c7bd522aba7ef14000457a6dd8afc2))


### Bug Fixes

* **ui:** [ and ] no longer wait on ftplugin maps or redraw at the ends of history ([6038acc](https://github.com/lattenwald/wire.nvim/commit/6038accb240f69c2ef1c03a58922c1a2d62d3583))

## [0.2.0](https://github.com/lattenwald/wire.nvim/compare/v0.1.0...v0.2.0) (2026-10-01)


### Features

* mask option to relax or extend secret masking; validate trusted_dirs and mask in setup ([816628f](https://github.com/lattenwald/wire.nvim/commit/816628f584f54e27e13fe3727805497259247ffd))
* trusted_dirs option to skip :trust for project files under listed directories ([c3a615d](https://github.com/lattenwald/wire.nvim/commit/c3a615d906e7f112f9c7005e9bfe9b6c06f05a5b))

## 0.1.0 (2026-09-30)


### Features

* :Wire command, setup, highlighting, health and README ([240028a](https://github.com/lattenwald/wire.nvim/commit/240028a5d011aab50da5b3a7ced0dcc42546fe63))
* curl transport with config on stdin ([7f8ef5b](https://github.com/lattenwald/wire.nvim/commit/7f8ef5b61a9da9aa63b76053c6a6ab527148b0c3))
* g? lists response window keys; summary shows history position ([feb15c4](https://github.com/lattenwald/wire.nvim/commit/feb15c4cef7125046b59164ae83d26f3ea072f0d))
* helper layers with content cache ([ee75498](https://github.com/lattenwald/wire.nvim/commit/ee754987653a143b30849d6648227a3fb84864dc))
* highlight .http from wire's own parser ([bceaf21](https://github.com/lattenwald/wire.nvim/commit/bceaf213f6d4ef58a2f3fff8ae04fab47ce1ddc6))
* highlighter decides JSON bodies like a send, using remembered env defaults ([3ec5cba](https://github.com/lattenwald/wire.nvim/commit/3ec5cbae8306254aa65264051fff1a751ab8101a))
* project discovery, trust and environments ([f366a87](https://github.com/lattenwald/wire.nvim/commit/f366a87dceff0b9f5dbc58329aad2b68640b515b))
* Report as a markdown table with failure details below ([07f638c](https://github.com/lattenwald/wire.nvim/commit/07f638c53478e5f119ec28735e9a9f2729c83ea7))
* Report lists every test, passing ones too ([caf4746](https://github.com/lattenwald/wire.nvim/commit/caf4746675e419a165b5d54a0b1f7c4176a949ed))
* response window, report and icons ([a6e033b](https://github.com/lattenwald/wire.nvim/commit/a6e033b2d9422fd26fb90cf368bf5e241c598ceb))
* run pipeline, results and quickfix ([17cd126](https://github.com/lattenwald/wire.nvim/commit/17cd126b08ea543698c1ab1a7808b326ad9a22ed))
* script compilation and test harness ([c457325](https://github.com/lattenwald/wire.nvim/commit/c4573255b36322ebe31bbe202a880efc7b536c84))
* secret masking ([9bc0780](https://github.com/lattenwald/wire.nvim/commit/9bc0780b6bbbe57e640271434d4fbeb3df39b5c3))
* test harness and .http line parser ([36b5be0](https://github.com/lattenwald/wire.nvim/commit/36b5be04c5a26636fa188e90e0276aef5a47e624))
* variable chain, expressions and JSON-aware templates ([0cdd921](https://github.com/lattenwald/wire.nvim/commit/0cdd921c492e89596961fa9c54fb6ce62965d80d))
* warn about unknown $ keys in env files ([7ab51ce](https://github.com/lattenwald/wire.nvim/commit/7ab51ce7344f0273e6b6be06410a650fdb8aff54))


### Bug Fixes

* code review findings ([87ed4ae](https://github.com/lattenwald/wire.nvim/commit/87ed4aeec0f73678c51681e443e210c56ffa292e))
* keep the .http highlighter off the response buffer ([c9aeeba](https://github.com/lattenwald/wire.nvim/commit/c9aeeba501272ee48d5ed6510bab567e46256d3f))
* multi-line Report cells continue on extra rows instead of being cut ([f9413ae](https://github.com/lattenwald/wire.nvim/commit/f9413ae0b9ae60e42a61897b440ad5e96f9afdb5))


### Performance Improvements

* highlight through a decoration provider, re-parsing only edited sections ([f389a22](https://github.com/lattenwald/wire.nvim/commit/f389a221161702e2ee712bca5bfc78865f0b1824))
