# Deployments

This file records where the LI.FI Virtual Machine contracts are deployed, how their addresses are
derived, and how to check a deployment against its expected bytecode.

All core contracts are deployed through [CreateX](https://github.com/pcaversaccio/createx)
(`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`) with CREATE3, so each contract has the same
address on every chain.

**Deployer:** `0xC0dEbABe740e30ca00F648625e8734BB7372c9D3`

## Current release (v1.1)

v1.1 adds the EXPLODE opcode. It is live on all 31 mainnets in the [chain table](#mainnets) and
on the 5 [testnets](#testnets).

| Contract | Address | Salt |
|---|---|---|
| VirtualMachine | `0x0f8a1ED606A7e10Ce5bF593d0306D98eC6F91b5C` | `0xc0deb` |
| ProxyFactory | `0x91157645e4e9AD252f5902C96e62036420076E96` | `0xc0dec` |
| InvariantChecker | `0xe17006F4DfE8Aa2bf80589E497ad98D470f66fef` | `0xc0de7` (unchanged from v1.0) |
| ArithmeticProcessor | `0x25407266A1229c83d03ececfff8eD7d92754b285` | `0xc0dea` (unchanged from v1.0) |

The VirtualMachine links the `BlueprintEncoder` library. Forge deploys the library during the
deploy script instead of through CreateX, so its address differs between the mainnet and testnet
deployments. The VirtualMachine bytecode embeds the library address.

| Network group | BlueprintEncoder address |
|---|---|
| Mainnets | `0x67f22204B65054d65852FE9160124dC8a7Bc931b` |
| Testnets | `0x5378d744E3a57368177ec3A3fF46FdE90B773782` |

Users interact with the VM through a personal `MinimalProxy` created by the ProxyFactory. Use
`predictProxyAddress(user)` on the factory to find a user's proxy address.

## Previous release (v1.0)

v1.0 is the pre-EXPLODE release. It remains live on all 31 mainnets in the chain table, and its
proxies keep working (see [Migrating from v1.0](#migrating-from-v10-to-v11)).

| Contract | Address | Salt |
|---|---|---|
| VirtualMachine | `0xb57Ce43Be47DF611C98EB0943e5D36EBDb36cc6D` | `0xc0de5` |
| ProxyFactory | `0xe174D02351656a883f6626497C86684e849efB35` | `0xc0de6` |
| InvariantChecker | `0xe17006F4DfE8Aa2bf80589E497ad98D470f66fef` | `0xc0de7` |
| ArithmeticProcessor | `0x25407266A1229c83d03ececfff8eD7d92754b285` | `0xc0dea` |

v1.0 and v1.1 share the InvariantChecker and ArithmeticProcessor contracts.

## Chain coverage

Coverage was last checked on 2026-09-25 with `eth_getCode` against public RPC endpoints. Each
address was hashed and compared with the reference codehashes below. On every mainnet, the v1.1
ProxyFactory's `vmContract()` returns the v1.1 VirtualMachine, and the v1.0 ProxyFactory's
`vmContract()` returns the v1.0 VirtualMachine.

### Mainnets

The build columns name the codehash variant each chain runs; see
[Reference codehashes](#reference-codehashes).

| Chain ID | Name | v1.1 VM, factory, library | v1.0 VM, factory | InvariantChecker | ArithmeticProcessor |
|---|---|---|---|---|---|
| 1 | Ethereum | live | A | A | A |
| 10 | Optimism | live | A | A | A |
| 56 | BNB Chain | live | A | A | A |
| 100 | Gnosis | live | A | A | A |
| 130 | Unichain | live | A | A | A |
| 137 | Polygon | live | A | A | A |
| 143 | Monad | live | A | A | A |
| 146 | Sonic | live | A | A | A |
| 252 | Fraxtal | live | A | A | A |
| 324 | zkSync Era | live | A | A | B |
| 480 | World Chain | live | A | A | A |
| 999 | HyperEVM | live | A | A | A |
| 1088 | Metis | live | A | A | B |
| 1135 | Lisk | live | A | A | A |
| 1672 | Pharos | live | C | C | A |
| 1868 | Soneium | live | A | A | A |
| 4217 | Tempo | live | B | B | B |
| 4326 | MegaETH | live | A | A | A |
| 4663 | Robinhood | live | B | B | C |
| 5000 | Mantle | live | A | A | A |
| 5042 | Arc | live | B | B | B |
| 8453 | Base | live | A | A | A |
| 9745 | Plasma | live | B | B | A |
| 42161 | Arbitrum One | live | A | A | A |
| 42220 | Celo | live | A | A | A |
| 43114 | Avalanche | live | A | A | A |
| 59144 | Linea | live | A | A | A |
| 80094 | Berachain | live | A | A | A |
| 98866 | Plume | live | A | A | A |
| 534352 | Scroll | live | A | A | A |
| 747474 | Katana | live | A | A | A |

### Testnets

The testnets run the v1.1 contracts only, built from the commit pinned in
[`deployments/v1.1.json`](deployments/v1.1.json). Every contract and the linked library match the
manifest codehashes. `chains.json` lists these networks for `deploy-chains.sh`.

| Network | Chain ID | v1.1 contracts and library |
|---|---|---|
| Sepolia | 11155111 | match manifest |
| Base Sepolia | 84532 | match manifest |
| Arbitrum Sepolia | 421614 | match manifest |
| OP Sepolia | 11155420 | match manifest |
| Arc Testnet | 5042002 | match manifest |

## Reference codehashes

A codehash is `keccak256` of a contract's runtime bytecode. Mainnet and testnet builds differ, so
this section lists them separately.

### Mainnets

| Contract | Build | Codehash | Chains |
|---|---|---|---|
| VirtualMachine v1.1 | — | `0xefa7f3d768ebb3db407853371e03e6975c78b5fa9b10bcab7a1f30d53ae93212` | all 31 |
| ProxyFactory v1.1 | — | `0x90baad934c86740f6dc4a907836542c352b14f3e0058fef6f8c6dcf89c0c9eb4` | all 31 |
| BlueprintEncoder (v1.1) | — | `0xe2195cd6fc4ab3cf8cd99b4416625c660ff1a97a17fb63bf28c0b94a880c0b15` | all 31 |
| VirtualMachine v1.0 | A | `0x9953c7ed8fb4b213be3be1e47624abfd3b2808f6fec80dde987bc50d8c6ba141` | the other 26 |
| VirtualMachine v1.0 | B | `0x72a9e14d30ae86e14179864bf885f1735b8427ab2f283fd40b87646a58594076` | 4217, 4663, 5042, 9745 |
| VirtualMachine v1.0 | C | `0x04857c9c4b43e883285d55cfb4761203775baa72c6a42fdaae1c66a7fa128519` | 1672 |
| ProxyFactory v1.0 | A | `0x074edb41687367c0829a397f46c76c59f9e46367e91fc60da33bf447d764bc83` | the other 26 |
| ProxyFactory v1.0 | B | `0xab7b3d16c383dfd0f2260930069b414102d1cb2a22c478b64282cf01c1e0262b` | 4217, 4663, 5042, 9745 |
| ProxyFactory v1.0 | C | `0xddb28ab68133e0f4b442eb333e045bf302f9269d38a9962a188d40a9ca76ac3e` | 1672 |
| InvariantChecker | A | `0xd33478194c57ccb0cc3a36510e5ef890e524d7864bc8b2ef66c1f7020b1e8c96` | the other 26 |
| InvariantChecker | B | `0xbad0f3770ee906ea9bba260e934f9b138912ff204bc72a5e4abf45afb772ee74` | 4217, 4663, 5042, 9745 |
| InvariantChecker | C | `0x2da36591101545ef40334f3fa112c68785136d8c7772cc1fdb436f1a3509f1ac` | 1672 |
| ArithmeticProcessor | A | `0xbaab0832d81edf5ae0786943947af1b5a27bdbfe9eacfa088df2a1e4871a61a5` | the other 26 |
| ArithmeticProcessor | B | `0xc5bd04b825c2dd96662dfca79924ec9e5b8e80f279f8bf4b57e0f49ec35d2518` | 324, 1088, 4217, 5042 |
| ArithmeticProcessor | C | `0x9e8c6440fc324e83cb9512d962f40b536ba8830ef5d3d827ba3e0559a775a41e` | 4663 |

Builds B and C of a contract run the same code as build A. They were compiled separately, so they
differ only in the Solidity metadata hash that the compiler appends to the bytecode:

- InvariantChecker and ArithmeticProcessor: the variants differ only in the 32-byte metadata hash.
- ProxyFactory v1.0: the variants differ only in the metadata hashes of the factory and of the
  `MinimalProxy` creation code embedded in it.
- VirtualMachine v1.0: the variants also embed a different `BlueprintEncoder` library address,
  because each build linked its own library deployment.

### Testnets

[`deployments/v1.1.json`](deployments/v1.1.json) pins the testnet build: the source commit
(`7cec1004315247968841eb837302021fa9ccb2b5`), the deployer, and the address and codehash of each
contract and library.

| Contract | Codehash |
|---|---|
| VirtualMachine | `0x5ea5e24413a3cfe880b5ce4a9cc2dfe61e2e6165c083dee8c377f1db2e67e9db` |
| ProxyFactory | `0x8d0b9e768f967ab7b355170fe3041c94c94a9e783ac43c9b9f2da16ee55b36eb` |
| InvariantChecker | `0xb7dfd52619ae63c19bbd57ea565ef56e3ecd6ec98084a525c3d673091f64680a` |
| ArithmeticProcessor | `0xbaab0832d81edf5ae0786943947af1b5a27bdbfe9eacfa088df2a1e4871a61a5` |
| BlueprintEncoder | `0x3dc08a3d1237522e52becbe6ef9003c22e89dc82002cbd4c80ae4bf34562699c` |

The mainnet v1.1 contracts were built separately from the manifest build. Compared with the
testnet bytecode, the mainnet VirtualMachine differs in the linked library address and the metadata
hash, and the mainnet ProxyFactory and InvariantChecker differ only in metadata hashes. The
ArithmeticProcessor bytecode is identical. The manifest therefore describes the testnets, not the
mainnets.

## How addresses are derived

Each deploy script (`script/VirtualMachine.s.sol`, `script/ProxyFactory.s.sol`,
`script/InvariantCheckerScript.s.sol`, `script/RPNArithmeticScript.s.sol`) turns a salt number
into a CreateX permissioned salt:

| Bytes | Content |
|---|---|
| 0–19 (20 bytes) | deployer address (`tx.origin`) |
| 20 (1 byte) | `0x00`: no cross-chain redeploy protection, so the address is the same on every chain |
| 21–31 (11 bytes) | low 11 bytes of the salt number |

CreateX rejects a permissioned salt from any sender other than the address in its first 20
bytes, so only the deployer can occupy these addresses. CreateX then guards the salt as
`keccak256(bytes32(deployer) ++ salt)` (mirrored in `script/Create3Helpers.sol`) and deploys
through CREATE3. The resulting address depends only on the deployer and the salt, not on the
bytecode.

`script/DeployAll.s.sol` sets the default salt numbers: `0xc0deb` (VirtualMachine), `0xc0dec`
(ProxyFactory), `0xc0de7` (InvariantChecker) and `0xc0dea` (ArithmeticProcessor).

To derive an address yourself, ask CreateX on any chain:

```bash
DEPLOYER=0xC0dEbABe740e30ca00F648625e8734BB7372c9D3
CREATEX=0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed
SALT_NUMBER=0xc0deb   # VirtualMachine v1.1

SALT=0x${DEPLOYER#0x}00$(printf '%022x' "$SALT_NUMBER")
GUARDED=$(cast keccak "0x000000000000000000000000${DEPLOYER#0x}${SALT#0x}")
cast call "$CREATEX" 'computeCreate3Address(bytes32,address)(address)' "$GUARDED" "$CREATEX" \
  --rpc-url https://ethereum-rpc.publicnode.com
# 0x0f8a1ED606A7e10Ce5bF593d0306D98eC6F91b5C
```

User proxies follow the same scheme with the ProxyFactory as the deployer: the factory builds the
salt from its own address and `keccak256(user)`. A proxy address therefore depends on both the
user and the factory address.

## Checking a deployment

An address match proves nothing about the code at that address. Compare the codehash with the
[reference codehashes](#reference-codehashes):

```bash
RPC=https://ethereum-rpc.publicnode.com
cast keccak "$(cast code 0x0f8a1ED606A7e10Ce5bF593d0306D98eC6F91b5C --rpc-url "$RPC")"
# 0xefa7f3d768ebb3db407853371e03e6975c78b5fa9b10bcab7a1f30d53ae93212
```

This hashes the result of `eth_getCode`. `cast codehash` gives the same value but calls
`eth_getProof`, which some RPCs (for example Arc Testnet) do not serve.

Then check that the factory is bound to the expected VM:

```bash
cast call 0x91157645e4e9AD252f5902C96e62036420076E96 'vmContract()(address)' --rpc-url "$RPC"
# 0x0f8a1ED606A7e10Ce5bF593d0306D98eC6F91b5C
```

`deploy-chains.sh` runs these checks for every chain in `chains.json` and compares the results with
a reference build of the manifest commit on a local anvil node.

## Redeploying

### Versioned redeploys

Each deploy helper is idempotent. When the address predicted from `(deployer, salt)` already
holds code, the helper deploys nothing and returns that address. Because the address depends only
on the salt, changing a contract without changing its salt does **not** redeploy it.

`ProxyFactory` stores the VM address in an immutable, and every `MinimalProxy` stores its owner,
the VM and the factory in immutables. None of them can be re-pointed. A VM change therefore needs
a new VM salt **and** a new factory salt, and every user needs a new proxy from the new factory.

Adopting whatever code sits at an address is unsafe: a contract left at the salt by an aborted
run would be adopted silently and then baked into the factory's and every proxy's immutables. Two
helpers therefore check the incumbent before adopting it:

| Helper | Check | Revert message on failure |
|---|---|---|
| `deployVM` | incumbent codehash equals `keccak256(type(VirtualMachine).runtimeCode)` | `VM: existing VM at salt has different bytecode` |
| `deployProxyFactory` | incumbent answers `vmContract()` with the VM just resolved | `ProxyFactory: existing factory bound to a different VM` |
| `deployProxyFactory` | incumbent answers `create3Factory()` with the CreateX address | `ProxyFactory: existing factory bound to a different CreateX` |

`deployProxyFactory` reverts with `ProxyFactory: address occupied by a non-factory contract` when
the incumbent does not answer these getters. The InvariantChecker and ArithmeticProcessor helpers
check only that the address holds code.

A salt names a specific build. Any change to `src/` that reaches `VirtualMachine`, including
internal libraries inlined into it, produces a different codehash at the same salt. Freeze `src/`
before broadcasting, and record the codehashes with the salts, as
[`deployments/v1.1.json`](deployments/v1.1.json) does.

### Toolchain-specific builds (Tempo, chain 4217)

The VM check compares the full runtime code, including the Solidity metadata hash and the linked
library address. A chain whose VM came from a different build fails the check on a re-run even
when the logic is identical. Tempo (4217) is one such chain: its v1.0 contracts are a separate
build (build B in [Reference codehashes](#reference-codehashes)), shared with chains 4663, 5042
and 9745. The same applies to the mainnet v1.1 VM, which was built separately from the manifest
commit. Treat a failed check as a stop to investigate by confirming which build is live, never as
a check to relax.

Paying Tempo gas in a TIP-20 token (`./deploy.sh --tempo-fee-token <address>`) requires
tempo-foundry; `deploy.sh` refuses the flag with standard forge.

### Simulate before broadcasting

`DeployAll.deploy` broadcasts the VM (step 1) before `deployProxyFactory` (step 2) can reject an
incompatible incumbent. Discovering the factory check during a live run leaves the chain with a
new VM and no matching factory. Simulate every chain first:

```bash
./deploy.sh --simulate --sender 0xC0dEbABe740e30ca00F648625e8734BB7372c9D3 --rpc-url <rpc-url>
```

The simulation prints each predicted address and whether it already holds code. The VM deploy is
idempotent, so re-running after fixing the cause is safe. `deploy-chains.sh` always simulates each
chain and broadcasts only when the simulation prints the manifest addresses.

### Chain-specific flags

Some chains need non-default `forge` flags or extra funding. `deploy.sh` passes these flags
through to `forge script`.

| Chain | Flags or action | Reason |
|---|---|---|
| 1088 Metis | `--legacy` | The RPC does not implement `eth_feeHistory`, which EIP-1559 fee estimation needs. Forge may also warn that Metis lacks `PUSH0` (EIP-3855); the contracts deployed on Metis contain `PUSH0` and are live. |
| 4326 MegaETH | `--legacy --with-gas-price 5000000 --gas-estimate-multiplier 10000` | The node requires far more gas than forge estimates, so without the multiplier the inner CREATE runs out of gas. |
| 534352 Scroll | fund the deployer above forge's estimate | Scroll charges an L1 data fee on top of L2 execution gas, which the estimate omits. |

## Migrating from v1.0 to v1.1

- **Existing proxies stay on the v1.0 VM.** A proxy's `vmAddress` is immutable. To use v1.1, a
  user needs a new proxy from the v1.1 factory. Because the factory address is part of the proxy
  salt, the new proxy has a new address. Token approvals granted to the old proxy do not carry
  over and must be granted again to the new one.
- **EXPLODE requires a v1.1 proxy.** EXPLODE is opcode `2`. The v1.0 VM reverts any program that
  contains it with `Disallowed()`; the whole call reverts, so nothing executes and no funds move.
  Programs that use EXPLODE must run through a proxy created by the v1.1 factory.
- **v1.0 keeps working.** The v1.0 VM and factory still serve programs that do not use EXPLODE.
  There is no on-chain shutdown; retiring v1.0 is a routing decision for integrators.

## Salt history

Production salts, oldest first. Every salt listed is permissioned to the deployer above.

| Salt | Contract | Address | Status |
|---|---|---|---|
| `0xc0de5` | VirtualMachine v1.0 | `0xb57Ce43Be47DF611C98EB0943e5D36EBDb36cc6D` | live |
| `0xc0de6` | ProxyFactory v1.0 | `0xe174D02351656a883f6626497C86684e849efB35` | live |
| `0xc0de7` | InvariantChecker | `0xe17006F4DfE8Aa2bf80589E497ad98D470f66fef` | live, used by v1.0 and v1.1 |
| `0xc0de8` | ArithmeticProcessor | `0x46C2c852E6FEfaF173dFe49457f0Fe61Dc3F587a` | superseded by a later ArithmeticProcessor build; do not use |
| `0xc0de9` | ArithmeticProcessor | `0x9eCe54047685003A8bf1aa0E2C60477b1a479013` | abandoned; do not use (see below) |
| `0xc0dea` | ArithmeticProcessor | `0x25407266A1229c83d03ececfff8eD7d92754b285` | live, used by v1.0 and v1.1 |
| `0xc0deb` | VirtualMachine v1.1 | `0x0f8a1ED606A7e10Ce5bF593d0306D98eC6F91b5C` | live |
| `0xc0dec` | ProxyFactory v1.1 | `0x91157645e4e9AD252f5902C96e62036420076E96` | live |

Salt `0xc0de9` shows why the deploy helpers check an incumbent's identity instead of trusting an
address. Its address holds the ArithmeticProcessor on 19 mainnets. On Base (8453) it holds an
unrelated 444-byte contract exposing `getHealthFactor(address,address)`. Because the salt is
permissioned, the deployer itself placed that contract there; it is not a third-party collision.
An address-only check would have adopted it on Base. Comparing the runtime codehash exposed it, and
the ArithmeticProcessor moved to salt `0xc0dea`.
