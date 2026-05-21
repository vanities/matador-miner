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
.PHONY: help up down restart logs status balance address gpu shell cli backup restore clean

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

status: ## Sync + mining status (height, difficulty, chain_guard)
	@$(CLI) getblockchaininfo | grep -E '"(blocks|headers|verificationprogress|initialblockdownload)"'
	@$(CLI) getmininginfo   | grep -E 'difficulty|networkhashps|should_pause_mining|"reason"|near_tip'

balance: ## Wallet balance / immature / tx count
	@$(WCLI) getwalletinfo | grep -E '"balance"|immature|txcount'

address: ## Show the mining payout address
	@cat ./btx-data/miner-address.txt 2>/dev/null || $(WCLI) getnewaddress

gpu: ## GPU utilization / power / temp (host nvidia-smi)
	@nvidia-smi --query-gpu=utilization.gpu,power.draw,temperature.gpu --format=csv,noheader

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

clean: ## Stop and DELETE all chain data + wallet (irreversible — run 'make backup' first)
	$(COMPOSE) down
	@echo "Removing ./btx-data (chain + wallet) in 3s — Ctrl-C to abort..."; sleep 3
	rm -rf ./btx-data
