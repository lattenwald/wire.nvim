.DEFAULT_GOAL := help

NVIM_BIN ?= nvim
MINI_TEST_URL ?= https://github.com/nvim-mini/mini.test
TEST_HOME := $(CURDIR)/.test-home
FILE ?=

.PHONY: help
help:
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

deps/mini.test:
	git clone --filter=blob:none $(MINI_TEST_URL) $@

.PHONY: test
test: deps/mini.test ## Run the tests headless (one file: FILE=tests/test_x.lua)
	rm -rf $(TEST_HOME) && mkdir -p $(TEST_HOME)/state/nvim
	XDG_CONFIG_HOME=$(TEST_HOME)/config XDG_DATA_HOME=$(TEST_HOME)/data \
	XDG_STATE_HOME=$(TEST_HOME)/state XDG_CACHE_HOME=$(TEST_HOME)/cache \
	$(NVIM_BIN) --headless --noplugin -u tests/minimal_init.lua -c "lua wire_test_run('$(FILE)')"

.PHONY: lint
lint: ## Check formatting, lint and the help file
	stylua --check lua plugin tests
	selene lua plugin tests
	$(NVIM_BIN) --headless --clean --cmd "set rtp^=." -l tests/doccheck.lua

.PHONY: doc
doc: ## Regenerate doc/tags
	$(NVIM_BIN) --headless --clean -c "helptags doc" -c q

.PHONY: format
format: ## Format the Lua sources
	stylua lua plugin tests
