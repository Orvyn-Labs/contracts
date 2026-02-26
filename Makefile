# ============================================================
#  DChain Research Crowdfunding — Foundry Makefile
#  Usage: make <target>
# ============================================================

# Load .env automatically if it exists
-include .env
export

RPC_BASE_SEPOLIA  ?= https://base-sepolia.drpc.org
RPC_BASE          ?= https://base.drpc.org
VERIFIER_URL      := https://api.etherscan.io/v2/api?chainid=84532

# ── Build & Test ─────────────────────────────────────────────

build:
	forge build

test:
	forge test -vvv

test-gas:
	forge test --gas-report

snapshot:
	forge snapshot

clean:
	forge clean

# ── Local Anvil ──────────────────────────────────────────────

anvil:
	anvil --chain-id 31337 --block-time 2

deploy-local:
	forge script script/Deploy.s.sol \
		--rpc-url http://localhost:8545 \
		--broadcast \
		-vvv

# ── Base Sepolia Deployment ───────────────────────────────────

deploy-sepolia:
	forge script script/Deploy.s.sol \
		--rpc-url $(RPC_BASE_SEPOLIA) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		-vvv

# ── Base Sepolia: Deploy + Verify in one command ──────────────
# Requires BASESCAN_API_KEY in .env

deploy-sepolia-verify:
	forge script script/Deploy.s.sol \
		--rpc-url $(RPC_BASE_SEPOLIA) \
		--private-key $(PRIVATE_KEY) \
		--broadcast \
		--verify \
		--verifier-url $(VERIFIER_URL) \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		-vvv

# ── Verify already-deployed contracts ────────────────────────
# Usage: make verify-contract CONTRACT=DiktiToken ADDRESS=0x...

verify-contract:
	forge verify-contract $(ADDRESS) src/tokens/$(CONTRACT).sol:$(CONTRACT) \
		--rpc-url $(RPC_BASE_SEPOLIA) \
		--verifier-url $(VERIFIER_URL) \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--watch

# Verify a UUPS proxy (the proxy itself via ERC1967Proxy)
verify-proxy:
	forge verify-contract $(ADDRESS) lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
		--rpc-url $(RPC_BASE_SEPOLIA) \
		--verifier-url $(VERIFIER_URL) \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--watch

# ── Utilities ────────────────────────────────────────────────

format:
	forge fmt

lint:
	forge fmt --check

size:
	forge build --sizes

.PHONY: build test test-gas snapshot clean anvil \
        deploy-local deploy-sepolia deploy-sepolia-verify \
        verify-contract verify-proxy format lint size
