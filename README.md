# Cipher Mines — Encrypted Mines on Inco

Single-player onchain Mines. The 5x5 grid is generated fully encrypted with
Inco Lightning (`euint8` per tile) — nobody, including the contract deployer,
can read where the mines are. Each tile decrypts only the instant it's
clicked. A cut of every win, and all of every loss, feeds a Megapot jackpot
pool — that's the "meaningful part of core gameplay" hook for the Megapot
prize track, not just a link tacked on.

Much simpler than a multiplayer game: no lobby, no turn sync between
players, one active round per wallet at a time.

## What's in here

- `contracts/CipherMines.sol` — the game contract: stake, encrypted grid,
  reveal-one-tile-at-a-time, cash out with a growing multiplier, Megapot
  payout hooks on both win and loss.
- `frontend/index.html` — playable demo of the full loop. Open it directly
  in a browser, no build step, no wallet needed.
- `scripts/deploy.js`, `hardhat.config.js`, `.env.example` — deploy to Base
  Sepolia.

## Honest status — read before you deploy

Same as before: I can't deploy contracts or hold a wallet key from this
sandbox, so nothing here has run against a live Inco node yet.

- **Contract**: written against Inco's documented conventions confirmed
  from their docs (`using e for *`, `euint8`, `.select()`, `.lt()`,
  `.allow()`). Two spots are flagged in comments and genuinely need you to
  check them against `docs.inco.org/quickstart/lib-reference`:
  1. The randomness call, used as `e.randEuint8(100)`.
  2. The decrypt-callback pattern in `revealTile()` / `onTileDecrypted()`.
     Solidity can't branch on an encrypted value directly, so revealing a
     tile has to be an async request → callback, not a plain if-statement.
     The contract has the shape of this (a request function and a callback
     function) but the actual "register this callback with Inco" call is a
     placeholder comment, not a real SDK call — this is the one piece of
     real engineering work left, look at Inco's confidential-token tutorial
     for their reveal/decrypt pattern and mirror it here.
- **Mine placement is probabilistic, not exact-count**: each tile is placed
  independently with roughly `mineCount/25` odds, so a "3 mines" round
  might occasionally land with 2 or 4. Fine for a hackathon demo, flagged
  in the contract if you want to swap in an exact-count shuffle later
  (Inco's ConfidentialDeck template does this properly).
- **Payout multiplier curve is simplified**, not a rigorously fair-odds
  model. Tune the formula in `onTileDecrypted()` before this ever touches
  real money.
- **Frontend demo** runs on local JS state. Every action (start round,
  reveal tile, cash out) has a `LIVE WIRING POINT` comment marking exactly
  where the real `ethers.js` contract call goes.

## Deploying for real

```bash
npm install
cp .env.example .env
# fill in PRIVATE_KEY (funded with Base Sepolia ETH) and MEGAPOT_VAULT_ADDRESS
npm run compile
npm run deploy:baseSepolia
```

## Suggested next moves

1. Open `frontend/index.html`, play a few rounds, sanity-check the vibe.
2. Nail down the decrypt-callback pattern (the one real gap) using Inco's
   confidential token tutorial as a reference.
3. Deploy to Base Sepolia, swap the frontend's mock functions for real
   contract calls.
4. Get a real Megapot vault/contract address for `MEGAPOT_VAULT_ADDRESS` —
   check Megapot's "Start Here" and "Contract Overview" docs for the actual
   integration point on Base.
