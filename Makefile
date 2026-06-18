# matador-miner convenience targets (repo sanity checks + packaging + local status).
# The miner itself is the standalone `matador-miner` binary — see the README.

.DEFAULT_GOAL := help
.PHONY: help check test shell-check matador-config-check matador-bundle matador-status

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

check: shell-check matador-config-check ## Repo sanity checks — no GPU needed

shell-check: ## Syntax-check shell scripts
	@bash scripts/check-shell-syntax.sh

matador-config-check: ## Validate standalone matador-miner config fixtures/source (skips private source when absent)
	@bash scripts/check-matador-config.sh

matador-bundle: ## Package dist/matador-miner plus optional sidecars into a release tarball
	@bash private/matador-miner/package-bundle.sh

matador-status: ## Read local matador-miner API summary (MATADOR_API_URL overrides)
	@bash scripts/matador-status.sh

test: check ## Alias for `make check`
