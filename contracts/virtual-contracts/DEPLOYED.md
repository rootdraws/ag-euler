# VIRTUAL — Deployed Addresses (Base 8453)

Deployed to the VVV cluster via `contracts/virtual-contracts/` scripts 01-07.

## Infrastructure

| Contract | Address |
|----------|---------|
| EulerRouter (shared, VVV cluster) | `0x0293B19af06dF6CB00323e1e924AA8995bC1718B` |
| VIRTUAL/USD Chainlink Adapter | `0xFd73B3A1b55d0E95d25308Dc34360003a8f1Ba28` |
| VIRTUAL KinkIRM | `0x6D429C42038E9270039bf16B97406912CeAAc28E` |
| Fee Receiver | `0x4f894Bfc9481110278C356adE1473eBe2127Fd3C` |

## Vaults

| Contract | Address |
|----------|---------|
| VIRTUAL Borrow Vault | `0x3Bd428B28C52f3534CC78075799CA798e4BcE5a8` |
| VIRTUAL Collateral Vault | `0xced5E60B38B3cfE5cF945762c4f015fB4727bD64` |

## Configuration

| Parameter | Value |
|-----------|-------|
| IRM | Base=0%, Kink(80%)=15%, Max=100% |
| Caps | 3,300,000 VIRTUAL supply & borrow |
| LTV / LLTV | 85% / 87% |
| Liquidation Discount | 5% |
| Interest Fee | 10% |

## Cluster Membership

VIRTUAL is cross-collateralized with the VVV cluster vaults:

| Vault | Address |
|-------|---------|
| VVV Borrow Vault | `0x4B6509B06f664eb8c8a4e9072655A4C6cafc1D9C` |
| USDC Borrow Vault | `0x21c8c8A56790A2b10370373fAcb94e925fD6a06E` |
| ETH Borrow Vault | `0x68AAD2c78065E2D28d2B46f6A80c5a813461FFf4` |
| ZRO Borrow Vault | `0xCB935d7916B20748e7f14C3B95931b8dcdA2472D` |
| AERO Borrow Vault | `0xAf5F576396730C212A8C6056A00eaA58123d78B6` |
| USDC Collateral Vault | `0x70abc7848ce268017728aD8E45F979F6F1071403` |
| VVV Collateral Vault | `0xDA8f11258CAC545F2A6f28b13aAca364E08F8599` |
| WETH Collateral Vault | `0xeC0c00e9b0894553c9D63C1Dd930c27a303F953c` |
| ZRO Collateral Vault | `0xaA73062F331873581991eDdD6848e0e57575E14f` |
| AERO Collateral Vault | `0x2172Df80c6ba09F2a314318C4c1D385F67582a1c` |
