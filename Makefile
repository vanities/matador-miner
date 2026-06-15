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
.PHONY: help up down restart logs stats status balance address gpu bench pool matador solo deploy stop-miner start-miner pool-logs matador-logs shell cli backup restore reset clean

# Payout address for pool mode — pulled from address.txt (gitignored) so it
# never lands in a committed file. The first btx1... line wins.
POOL_ADDR = $(shell grep -m1 '^btx1' address.txt 2>/dev/null)

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

status: ## Sync + mining status (height, difficulty trend, live solve rate)
	@$(CLI) getblockchaininfo | grep -E '"(blocks|headers|verificationprogress|initialblockdownload)"'
	@$(CLI) getmininginfo   | grep -E 'difficulty|networkhashps|should_pause_mining|"reason"|near_tip'
	@printf 'live rate : '; \
	 N1=$$($(CLI) getmatmulchallengeprofile 2>/dev/null | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0'); \
	 sleep 3; \
	 N2=$$($(CLI) getmatmulchallengeprofile 2>/dev/null | jq -r '.service_profile.runtime_observability.solve_pipeline.batched_nonce_attempts // 0'); \
	 if [ "$$N2" -gt "$$N1" ] 2>/dev/null; then echo "$$(( (N2-N1)/3 )) nonce-attempts/s (live, vs bench which runs several x faster)"; else echo "(warming up)"; fi

balance: ## Wallet balance / immature / tx count
	@$(WCLI) getwalletinfo | grep -E '"balance"|immature|txcount'

address: ## Show the mining payout address
	@cat ./btx-data/miner-address.txt 2>/dev/null || $(WCLI) getnewaddress

gpu: ## GPU utilization / power / temp (host nvidia-smi)
	@nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu --format=csv,noheader

bench: ## A/B the solver across images in v2 (live-representative) mode; pauses miner
	@bash bench/ab.sh

pool: ## Switch to POOL mining (minebtx) — stops solo. Pool's solver is SLOWER than solo; trades speed for steady payouts
	@test -n "$(POOL_ADDR)" || { echo "No btx1... payout address in address.txt — add one first."; exit 1; }
	@echo "Payouts will go to: $(POOL_ADDR)"
	@echo "Stopping SOLO miner (solo and pool can't share the GPU)..."
	@$(COMPOSE) stop $(SVC) 2>/dev/null || true
	@echo "Building + starting POOL miner..."
	@BTX_PAYOUT_ADDRESS=$(POOL_ADDR) $(COMPOSE) --profile pool up -d --build btx-pool
	@echo "Pool mining. Logs: make pool-logs   ·   Back to solo: make solo"

matador: ## Switch to MATADOR — our fast custom pool miner (saturates the 5090), stops solo + official pool
	@test -n "$(POOL_ADDR)" || { echo "No btx1... payout address in address.txt — add one first."; exit 1; }
	@echo "Payouts will go to: $(POOL_ADDR)"
	@echo "Stopping solo + official pool (one miner owns the GPU)..."
	@$(COMPOSE) stop $(SVC) btx-pool 2>/dev/null || true
	@echo "Building + starting MATADOR..."
	@BTX_PAYOUT_ADDRESS=$(POOL_ADDR) $(COMPOSE) --profile matador up -d --build matador
	@echo "MATADOR mining (olé). Logs: make matador-logs   ·   Back to solo: make solo"

solo: ## Switch back to SOLO mining (our patched node) — stops pool
	@echo "Stopping POOL miners..."
	@$(COMPOSE) --profile pool stop btx-pool 2>/dev/null || true
	@$(COMPOSE) --profile matador stop matador 2>/dev/null || true
	@echo "Starting SOLO miner..."
	@$(COMPOSE) up -d $(SVC)
	@echo "Solo mining (our optimized solver)."

stop-miner: ## Pause GPU mining (idle gate) - keeps btxd + node synced + keeper alive, NO warmup
	@$(COMPOSE) exec -T $(SVC) touch $(DATADIR)/.pause-mining && echo "Miner paused; node stays up. Resume: make start-miner"

start-miner: ## Resume GPU mining after stop-miner (instant, no warmup)
	@$(COMPOSE) exec -T $(SVC) rm -f $(DATADIR)/.pause-mining && echo "Miner resumed."

deploy: ## Minimal-downtime version bump: build new image WHILE mining continues, then swap + time the warmup gap
	@echo "[deploy] building $(SVC) (the running miner keeps mining during the build)..."
	@$(COMPOSE) build $(SVC)
	@echo "[deploy] build OK. Stopping any pool-side miner, then swapping solo to the new image..."
	@$(COMPOSE) --profile pool stop btx-pool 2>/dev/null || true
	@$(COMPOSE) --profile matador stop matador 2>/dev/null || true
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
	  echo "[deploy] if this gap recurs on every bump (not just the one-time 0.32.11 rebuild), see docs/minimal-downtime-deploy.md"

node: ## Run the node ONLY (wallet + RPC, no mining, no GPU compute) — start alongside the pool so balance/stats/status work while pooling
	@echo "Starting NODE-ONLY btxd: wallet + RPC, no mining, no GPU compute."
	@echo "It shares the card harmlessly with the pool (holds a context, runs no solver kernels)."
	@BTX_MINING_ENABLED=0 $(COMPOSE) up -d --build $(SVC)
	@echo "Booting (one shielded-state warmup; faster on 0.32.10). Once RPC is up:"
	@echo "  make balance   |   make stats   |   make status   |   make address"
	@echo "Stop just the node (keep pooling): $(COMPOSE) stop $(SVC)   |   Back to mining: make solo"

pool-logs: ## Follow the pool miner logs
	@$(COMPOSE) logs -f btx-pool

matador-logs: ## Follow the MATADOR miner logs
	@$(COMPOSE) logs -f matador

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
