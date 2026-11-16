# INHERITFI V1 Core

Smart contracts of INHERITFI V1: ERC-20 wrappers that add inheritance and recovery to the assets they hold.

A holder wraps an asset (for example ETH into iETH, or DAI into iDAI), names heirs and recovery contacts, and keeps proving activity simply by using the wallet. If the wallet stays inactive for the configured periods, heirs can start and execute the inheritance, or recovery contacts can recover the funds, following the waiting times written in the contract.

- Website and documentation: https://inheritfi.com
- App: https://app.inheritfi.com
- ENS: inheritfi.eth

## Deployment (Ethereum mainnet)

All contracts are verified on Etherscan. The owner of the 29 wrappers is the Safe `0xD01288D704B7116BAcb49585680eC422e53409Ba`. The 2 libraries have no owner.

| Contract | Address | Underlying asset |
|---|---|---|
| InheritfiV1GovernanceLib | `0x0601a3fd01B747EdEA0D493913B1242BC521935c` | library |
| InheritfiV1InheritanceLib | `0xC94E2F80fb08b0736972fe7EA224FAdEA2d21386` | library |
| InheritfiV1ETH (iETH) | `0xAfc5991a78B1137c3e6fFB3CDF03452880bAefa4` | native ETH |
| InheritfiV1AAVE (iAAVE) | `0x04387AEe5cBAF9763E332C9586f24e24eb63993F` | `0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9` |
| InheritfiV1AXS (iAXS) | `0x5c03977830675B657a8b06be6F11e09319086F19` | `0xBB0E17EF65F82Ab018d8EDd776e8DD940327B28b` |
| InheritfiV1COMP (iCOMP) | `0x2c5d1E668Fba493615e877eBA8348BF93A295fd1` | `0xc00e94Cb662C3520282E6f5717214004A7f26888` |
| InheritfiV1CRV (iCRV) | `0xeBF86441d4c088938fD3F9a1E01C1ef65e4641C5` | `0xD533a949740bb3306d119CC777fa900bA034cd52` |
| InheritfiV1crvUSD (icrvUSD) | `0xf47f91e2731667F03B7d28C1e3C90dE4Cfcd8d3c` | `0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E` |
| InheritfiV1CVX (iCVX) | `0x81b54C2efde41096132Dd776eA0bd6154698cC8C` | `0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B` |
| InheritfiV1DAI (iDAI) | `0xF891601608E4F297107450b24E4dE6B6638a9eb1` | `0x6B175474E89094C44Da98b954EedeAC495271d0F` |
| InheritfiV1ENS (iENS) | `0xC9C97495404eCb822A3dd56F9615119f92D6B6bc` | `0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72` |
| InheritfiV1ETHFI (iETHFI) | `0x2baF5EBA11F4584FEF4bc099aB082a6a9428d13A` | `0xFe0c30065B384F05761f15d0CC899D4F9F9Cc0eB` |
| InheritfiV1FET (iFET) | `0x3AA60d63f68445147c5B6D9205DE8904a7927549` | `0xaea46A60368A7bD060eec7DF8CBa43b7EF41Ad85` |
| InheritfiV1GHO (iGHO) | `0xF6738797bCdA9D3F5469dAeDb4786F32d4868D33` | `0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f` |
| InheritfiV1GRT (iGRT) | `0xfAaBBbD1628962C579B3C4E8e2Ee5359874380A2` | `0xc944E90C64B2c07662A292be6244BDf05Cda44a7` |
| InheritfiV1IMX (iIMX) | `0x4051A3BDd4633535645342FD39E762B87Ca9b6Da` | `0xF57e7e7C23978C3cAEC3C3548E3D615c346e79fF` |
| InheritfiV1INJ (iINJ) | `0xC7AaBf1Bc6daE558b6c6418144Bf8Dd4c85F4EfB` | `0xe28b3B32B6c345A34Ff64674606124Dd5Aceca30` |
| InheritfiV1JASMY (iJASMY) | `0x1082C7d79821fC0d1c9734B29475528C714B0177` | `0x7420B4b9a0110cdC71fB720908340C03F9Bc03EC` |
| InheritfiV1LDO (iLDO) | `0x3cDF99dD5786e636AF29735733E7aB2357b6583f` | `0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32` |
| InheritfiV1LINK (iLINK) | `0xa10E8d825DeDA3B7531C51711D1901cAB08be460` | `0x514910771AF9Ca656af840dff83E8264EcF986CA` |
| InheritfiV1PENDLE (iPENDLE) | `0xe45D4691D32D7314De33a745D4C9f96d634f61B8` | `0x808507121B80c02388fAd14726482e061B8da827` |
| InheritfiV1PEPE (iPEPE) | `0x249f512BaA2677B2C00661268729cA9e5B8b4284` | `0x6982508145454Ce325dDbE47a25d4ec3d2311933` |
| InheritfiV1POL (iPOL) | `0x2C38D8D6C0c3cCC9B3277B226f21172e7804CA89` | `0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6` |
| InheritfiV1SHIB (iSHIB) | `0xBd0BeBB7342200C3fDc4b6ee0284645e868f9866` | `0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE` |
| InheritfiV1SKY (iSKY) | `0x549793b17a06708406DB8aAd89D2B285C13476EE` | `0x56072C95FAA701256059aa122697B133aDEd9279` |
| InheritfiV1STRK (iSTRK) | `0x9B84D56807561063d699b2886509952c49317D73` | `0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766` |
| InheritfiV1UNI (iUNI) | `0x5C05e3c1B9e1d5A3320C527856435765A0214216` | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| InheritfiV1WBTC (iWBTC) | `0x834358EC4cfC379ea4bD7Cc4CB2be5182d66F70d` | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` |
| InheritfiV1WETH (iWETH) | `0xA967DDD3A9FF2566C8d1f70e99D1350533cAD2Ed` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| InheritfiV1WLD (iWLD) | `0x8D8171f464fA83249995FAF4aa9414e8585d9BaF` | `0x163f8C2467924be0ae7B5347228CABF260318753` |
| InheritfiV1wstETH (iwstETH) | `0x8AD934dc5C6A7d3E45C5148eFfDcE0a682b7ce9c` | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |

## Repository layout

- `src/`: the contracts, exactly as deployed and verified (2 external libraries, the shared base, the shared types and 29 wrappers).
- `test/`: Foundry tests (unit, fuzz and invariant tests).
- `lib/`: dependencies as git submodules: OpenZeppelin Contracts v5.7.0 and forge-std v1.16.2.

## Build and test

Requires Foundry 1.8.6 or later. The compiler is solc 0.8.38 with `via_ir`, optimizer 200 runs and EVM version `osaka` (see `foundry.toml`).

```sh
git clone --recurse-submodules https://github.com/inheritfi/v1-core.git
cd v1-core
forge build
forge test
```

Test identifiers such as `AUD2-03`, `AUD3-01`, `M-06` or `I-01`, also present in two source comments, refer to findings of internal security reviews and to the tests that cover them.

## Security

No external security audit has been published for INHERITFI V1. Use it at your own risk and read the disclaimer at https://inheritfi.com/disclaimer/.

## License

Business Source License 1.1 (`BUSL-1.1`), see `LICENSE.txt`. Change Date: The earlier of 2030-11-10 or a date specified at v1-core-license-date.inheritfi.eth. Change License: GNU General Public License v3.0 or later. Additional Use Grant: Any uses listed and defined at v1-core-license-grants.inheritfi.eth.
