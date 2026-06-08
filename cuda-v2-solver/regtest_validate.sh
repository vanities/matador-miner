#!/usr/bin/env bash
# End-to-end validation: mine real v2 (nonce-seed) blocks on regtest with the GPU matrix-gen path
# and confirm the node ACCEPTS its own GPU-mined blocks (= consensus-exact integration).
# v2 forced active from genesis via the regtest override args (mirrors mainnet >=125000 where
# binding+productdigest(61k) and nonceseed(125k) are all active).
set -u
cd /src
export BTX_MATMUL_BACKEND=cuda
RT=/tmp/rt
CLI="./build/bin/btx-cli -regtest -datadir=$RT"
rm -rf "$RT" && mkdir -p "$RT"
./build/bin/btxd -regtest -datadir="$RT" -server=1 -daemon -fallbackfee=0.0001 \
  -regtestmatmulnonceseedheight=0 -regtestmatmulproductdigestheight=0 -regtestmatmulbindingheight=0 \
  >/dev/null 2>&1
for i in $(seq 1 60); do $CLI getblockchaininfo >/dev/null 2>&1 && break; sleep 1; done
$CLI getblockchaininfo >/dev/null 2>&1 || { echo "RPC_DOWN"; tail -20 "$RT/regtest/debug.log"; exit 1; }
$CLI -named createwallet wallet_name=t >/dev/null 2>&1 || true
ADDR=$($CLI -rpcwallet=t getnewaddress 2>/dev/null)
echo "mining 20 v2 blocks (GPU matrix-gen) to $ADDR ..."
if $CLI -rpcwallet=t generatetoaddress 20 "$ADDR" >/tmp/gen.out 2>&1; then
  echo "GENERATE_OK"
else
  echo "GENERATE_FAIL"; tail -6 /tmp/gen.out
fi
echo "height=$($CLI getblockcount 2>&1)  besthash=$($CLI getbestblockhash 2>&1)"
# re-validate the whole chain from disk (independent consensus check of the GPU-mined blocks)
echo "verifychain(4,0)=$($CLI verifychain 4 0 2>&1)"
echo "--- GPU path log (expect: GPU base-matrix generation ACTIVE) ---"
grep -iE 'GPU base-matrix|MatMul v2' "$RT/regtest/debug.log" | head -3
echo "--- consensus/matmul errors (expect none) ---"
grep -iE 'ERROR|bad-txns|bad-matmul|invalid|reject|assertion' "$RT/regtest/debug.log" 2>/dev/null | grep -iE 'matmul|pow|seed|block' | tail -5
$CLI stop >/dev/null 2>&1 || true
