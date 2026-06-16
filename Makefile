# btx-miner convenience targets.
# Run these on the Linux box that has the GPU + Docker (the deploy host), from
# this directory. Override any var, e.g.  make backup BACKUP=/mnt/usb/wallet.dat

COMPOSE    ?= docker compose
SVC        ?= btx-miner
DATADIR    ?= /data
WALLET     ?= miner
BACKUP     ?= wallet-backup/miner-wallet-backup.dat
RESTORE_AS ?= miner-restored

CLI  = $(COMPOSE) exec -T $(SVC) btx-cli -datadir=$(DATADIR)
WCLI = $(CLI) -rpcwallet=$(WALLET)

.DEFAULT_GOAL := help
.PHONY: help up down restart logs stats status balance address gpu solo deploy stop-miner start-miner safe-stop safe-restart node shell cli backup restore reset clean

help: ## List available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n", $$1, $$2}'

up: ## Build if needed and start the miner (detached)
	$(COMPOSE) up -d --build

down: ## Stop the miner
	$(COMPOSE) down

restart: ## Stop then start the miner
	$(COMPOSE) down && $(COMPOSE) up -d --build

logs: ## Follow the miner logs
	$(COMPOSE) logs -f

stats: ## One-shot dashboard: balance + chain + mining + GPU
	@bash scripts/stats.sh

status: ## Sync + chain status (height, sync progress, difficulty, peer/guard health)
	@$(CLI) getblockchaininfo | grep -E '"(blocks|headers|verificationprogress|initialblockdownload)"'
	@$(CLI) getmininginfo   | grep -E 'difficulty|networkhashps|should_pause_mining|"reason"|near_tip'

balance: ## Wallet balance / immature / tx count
	@$(WCLI) getwalletinfo | grep -E '"balance"|immature|txcount'

address: ## Show the mining payout address
	@cat ./btx-data/miner-address.txt 2>/dev/null || $(WCLI) getnewaddress

gpu: ## GPU utilization / power / temp (host nvidia-smi)
	@nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu --format=csv,noheader

solo: ## Resume/start SOLO mining. NO node recreate if it's only idle-gated (no warmup)
	@# CRITICAL: do NOT `compose up -d` a running btx-miner — that can RECREATE it
	@# (config-hash drift across invocations) and trigger a full shielded rebuild
	@# warmup. If it's already up (e.g. resuming after stop-miner), JUST clear the
	@# idle-gate flag — no recreate, no warmup. Only `up -d` when it's genuinely down.
	@if docker ps --filter name=^/$(SVC)$$ --filter status=running -q | grep -q .; then \
	  echo "Solo node already up — clearing idle-gate flag (no recreate, no warmup)."; \
	  $(COMPOSE) exec -T $(SVC) rm -f $(DATADIR)/.pause-mining 2>/dev/null || true; \
	else \
	  echo "Solo node not running — starting it (this incurs a one-time warmup)."; \
	  $(COMPOSE) up -d $(SVC); sleep 5; \
	  $(COMPOSE) exec -T $(SVC) rm -f $(DATADIR)/.pause-mining 2>/dev/null || true; \
	fi
	@echo "Solo mining resumed."

stop-miner: ## Pause GPU mining (idle gate) - keeps btxd + node synced + keeper alive, NO warmup
	@$(COMPOSE) exec -T $(SVC) touch $(DATADIR)/.pause-mining && echo "Miner paused; node stays up. Resume: make start-miner"

start-miner: ## Resume GPU mining after stop-miner (instant, no warmup)
	@$(COMPOSE) exec -T $(SVC) rm -f $(DATADIR)/.pause-mining && echo "Miner resumed."

safe-stop: ## Wait for a caught-up + well-peered window, THEN stop btxd cleanly (so next boot fast-restores, not a 15min rebuild)
	@bash scripts/clean-stop.sh

safe-restart: ## Clean-stop at a safe window, then start again — same container, expect ~30s fast-restore (use this instead of `make restart`)
	@ACTION=restart bash scripts/clean-stop.sh

deploy: ## Minimal-downtime version bump: build new image WHILE mining continues, then swap + time the warmup gap
	@echo "[deploy] building $(SVC) (the running miner keeps mining during the build)..."
	@$(COMPOSE) build $(SVC)
	@echo "[deploy] build OK. Swapping solo to the new image..."
	@echo "[deploy] waiting for a caught-up + well-peered window before the swap (clean stop -> best chance of a fast restore)..."
	@ACTION=wait MAX_WAIT_MIN=$${DEPLOY_WAIT_MIN:-15} bash scripts/clean-stop.sh || echo "[deploy] no clean window in time — swapping anyway (may rebuild)"
	@t0=$$(date +%s); $(COMPOSE) up -d $(SVC); \
	  echo "[deploy] swapped; waiting for mining to resume (warmup = shielded state + sync catch-up)..."; \
	  for i in $$(seq 1 90); do \
	    sleep 10; \
	    N=$$($(CLI) getmatmulchallengeprofile 2>/dev/null | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0' 2>/dev/null | tr -dc 0-9); \
	    if [ -n "$$N" ] && [ "$$N" -gt 0 ] 2>/dev/null; then \
	      echo "[deploy] mining RESUMED after $$(($$(date +%s)-t0))s (solve counter=$$N) - that gap is the real downtime"; break; \
	    fi; \
	    echo "[deploy]   ...warming $$(($$(date +%s)-t0))s"; \
	  done; \
	  echo "[deploy] if this gap recurs on every bump (not just a one-time state rebuild), see docs/minimal-downtime-deploy.md"

node: ## Run the node ONLY (wallet + RPC, no mining, no GPU compute) — e.g. to run an external miner against it
	@echo "Starting NODE-ONLY btxd: wallet + RPC, no mining, no GPU compute."
	@BTX_MINING_ENABLED=0 $(COMPOSE) up -d --build $(SVC)
	@echo "Booting (one shielded-state warmup). Once RPC is up:"
	@echo "  make balance   |   make stats   |   make status   |   make address"
	@echo "Stop just the node: $(COMPOSE) stop $(SVC)   |   Back to solo mining: make solo"

shell: ## Open a shell inside the miner container
	$(COMPOSE) exec $(SVC) bash

cli: ## Run an arbitrary btx-cli command, e.g. make cli ARGS="getpeerinfo"
	@$(CLI) $(ARGS)

backup: ## Consistent wallet backup -> wallet-backup/ (gitignored)
	@mkdir -p wallet-backup
	@$(WCLI) backupwallet $(DATADIR)/miner-wallet-backup.dat
	@$(COMPOSE) cp $(SVC):$(DATADIR)/miner-wallet-backup.dat $(BACKUP)
	@chmod 600 $(BACKUP)
	@echo "Backed up -> $(BACKUP)  (private keys; never commit — already gitignored)"

restore: ## Restore wallet from wallet-backup/ as $(RESTORE_AS)
	@test -f $(BACKUP) || { echo "No backup at $(BACKUP)"; exit 1; }
	@$(COMPOSE) cp $(BACKUP) $(SVC):$(DATADIR)/restore-source.dat
	@$(CLI) restorewallet $(RESTORE_AS) $(DATADIR)/restore-source.dat
	@echo "Restored as '$(RESTORE_AS)'. Query it: $(COMPOSE) exec $(SVC) btx-cli -datadir=$(DATADIR) -rpcwallet=$(RESTORE_AS) getbalance"

reset: ## Recover a wedged node: wipe chain/shielded state + re-fast-start, keep wallet (stays pruned)
	bash scripts/reset-faststart.sh

clean: ## Stop and DELETE all chain data + wallet (irreversible — run 'make backup' first)
	$(COMPOSE) down
	@echo "Removing ./btx-data (chain + wallet) in 3s — Ctrl-C to abort..."; sleep 3
	rm -rf ./btx-data
