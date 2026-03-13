# AirAccount Onboarding Page

Minimal single-page onboarding demo for AirAccount (M4.4). Four-step flow:

1. **Create Passkey** — WebAuthn P-256 credential + browser wallet connection
2. **Configure Account** — Choose template from `../configs/`, adjust limits
3. **Create Account** — Deploy via factory (CREATE2), show predicted address
4. **Test Transaction** — Send 0.001 ETH from the new smart wallet

## Quick Start

```bash
cd pages/
pnpm install
pnpm dev
```

Then open `http://localhost:5173` in your browser.

## Requirements

- Browser with WebAuthn support (Chrome, Safari, Firefox)
- MetaMask or compatible browser wallet connected to **Sepolia**
- Sepolia ETH for gas (use a faucet: https://sepoliafaucet.com)

## Notes

- This is a **developer demo**, not a production UI
- The factory address points to the M3 deployment on Sepolia
- Config templates are loaded from `../configs/*.json`
- Uses [viem](https://viem.sh) for all chain interactions (no ethers.js)
- Vite serves as the dev server and handles TypeScript compilation
