// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {e, ebool, euint256} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";

/// @title CipherMines
/// @notice Single-player onchain Mines. The 5x5 grid is generated fully encrypted with
///         Inco Lightning (`ebool` per tile) — nobody, including the contract deployer,
///         can read where the mines are. Each tile only becomes decryptable the instant
///         it's revealed, and the game only trusts the result once it's backed by a
///         signed decryption attestation — never a bare claimed value.
///
/// @dev CORRECTED VERSION: the real inco-lightning package has no euint8 type at all —
///      only euint256, ebool, eaddress, and elist. Randomness is `e.randBounded(upperBound)`,
///      not `e.randEuint8()`. Revealing a value is `e.reveal(handle)`, which makes it
///      publicly decryptable off-chain; the contract only trusts a decrypted result once
///      it's handed a `DecryptionAttestation` + covalidator signatures via
///      `e.requireEqual()`. All of this was verified directly against the published
///      inco-lightning npm package source, not guessed.
///
///      What's still a manual step for you: getting the attestation + signatures for a
///      revealed tile is a client-side call via inco-lightning-js (their JS SDK talks to
///      Inco's decryption/covalidator nodes) — see docs.inco.org/js-sdk. `resolveTile()`
///      below is the onchain half; the frontend needs to fetch the attestation after
///      calling `revealTile()` and then submit it via `resolveTile()`.
contract CipherMines {
    using e for *;

    uint8 public constant GRID_SIZE = 25; // 5x5 board

    struct Round {
        address player;
        uint256 stake;
        uint8 mineCount;
        uint8 safeRevealed;
        uint256 multiplierBps; // 10000 = 1.00x
        bool active;
        mapping(uint8 => ebool) cell; // true = mine, encrypted
        mapping(uint8 => bool) revealRequested;
        mapping(uint8 => bool) resolved;
    }

    uint256 public nextRoundId;
    mapping(uint256 => Round) private rounds;

    /// @notice Where losses and a cut of wins go. Point this at the Megapot
    ///         jackpot contract/vault for the Megapot prize track. Note: Megapot
    ///         takes USDC via ticket purchases, not raw ETH — a real integration
    ///         needs a swap or USDC stake step before this hop, see project README.
    address public megapotVault;
    uint256 public megapotFeeBps = 500; // 5% of every cash-out win

    event RoundStarted(uint256 indexed roundId, address indexed player, uint256 stake, uint8 mineCount);
    event TileRevealRequested(uint256 indexed roundId, uint8 index);
    event TileSafe(uint256 indexed roundId, uint8 index, uint256 newMultiplierBps);
    event TileMine(uint256 indexed roundId, uint8 index);
    event RoundLost(uint256 indexed roundId, uint256 stakeToMegapot);
    event CashedOut(uint256 indexed roundId, uint256 payout, uint256 megapotFee);

    modifier onlyRoundPlayer(uint256 roundId) {
        require(rounds[roundId].player == msg.sender, "not your round");
        _;
    }

    constructor(address _megapotVault) {
        megapotVault = _megapotVault;
    }

    /// @notice Start a round: stake ETH, choose a mine count (risk level),
    ///         get a fully encrypted 5x5 grid back.
    function startRound(uint8 mineCount) external payable returns (uint256 roundId) {
        require(msg.value > 0, "stake required");
        require(mineCount >= 1 && mineCount <= 10, "mineCount 1-10");

        roundId = nextRoundId++;
        Round storage r = rounds[roundId];
        r.player = msg.sender;
        r.stake = msg.value;
        r.mineCount = mineCount;
        r.multiplierBps = 10000;
        r.active = true;

        // Per-cell probabilistic placement: draw a random value in [0, 99] per
        // cell and mark it a mine if it falls under (mineCount * 4). Simple and
        // fully encrypted, but probabilistic, not an exact-count shuffle — see
        // README for swapping in Inco's ConfidentialDeck/EList shuffle instead.
        for (uint8 i = 0; i < GRID_SIZE; i++) {
            euint256 draw = e.randBounded(100);
            ebool isMine = draw.lt(uint256(mineCount) * 4);
            r.cell[i] = isMine;
            isMine.allowThis();
        }

        emit RoundStarted(roundId, msg.sender, msg.value, mineCount);
    }

    /// @notice Step 1 of revealing a tile: makes that tile's encrypted value
    ///         publicly decryptable via Inco's network. The frontend should
    ///         call this, then use inco-lightning-js to fetch the resulting
    ///         DecryptionAttestation + signatures, then call resolveTile().
    function revealTile(uint256 roundId, uint8 index) external onlyRoundPlayer(roundId) {
        Round storage r = rounds[roundId];
        require(r.active, "round not active");
        require(index < GRID_SIZE, "bad index");
        require(!r.revealRequested[index], "already requested");

        r.revealRequested[index] = true;
        e.reveal(r.cell[index]);

        emit TileRevealRequested(roundId, index);
    }

    /// @notice Step 2: submit the signed proof of what the tile decrypted to.
    ///         Reverts if the attestation doesn't match this exact tile's
    ///         encrypted handle or isn't validly signed — so the game can
    ///         never be told "it was safe" without cryptographic proof.
    function resolveTile(
        uint256 roundId,
        uint8 index,
        bool isMine,
        DecryptionAttestation calldata attestation,
        bytes[] calldata signatures
    ) external onlyRoundPlayer(roundId) {
        Round storage r = rounds[roundId];
        require(r.active, "round not active");
        require(r.revealRequested[index], "call revealTile first");
        require(!r.resolved[index], "already resolved");

        e.requireEqual(r.cell[index], isMine, attestation, signatures);
        r.resolved[index] = true;

        if (isMine) {
            r.active = false;
            emit TileMine(roundId, index);
            _sendToMegapot(r.stake);
            emit RoundLost(roundId, r.stake);
            return;
        }

        r.safeRevealed += 1;
        // Simple growth curve: bigger mine count -> bigger multiplier bump
        // per safe tile. Not a rigorously fair-odds model, tune before
        // wiring real money.
        r.multiplierBps = (r.multiplierBps * (10000 + uint256(r.mineCount) * 350)) / 10000;
        emit TileSafe(roundId, index, r.multiplierBps);
    }

    /// @notice Cash out at the current multiplier. A cut of every win feeds
    ///         the Megapot jackpot — this is the "meaningful part of core
    ///         gameplay" hook for the Megapot prize track, not just a link.
    function cashOut(uint256 roundId) external onlyRoundPlayer(roundId) {
        Round storage r = rounds[roundId];
        require(r.active, "round not active");
        require(r.safeRevealed > 0, "reveal at least one tile first");

        r.active = false;
        uint256 payout = (r.stake * r.multiplierBps) / 10000;
        uint256 fee = (payout * megapotFeeBps) / 10000;
        uint256 toPlayer = payout - fee;

        _sendToMegapot(fee);
        (bool ok, ) = msg.sender.call{value: toPlayer}("");
        require(ok, "payout failed");

        emit CashedOut(roundId, toPlayer, fee);
    }

    function _sendToMegapot(uint256 amount) internal {
        if (megapotVault == address(0) || amount == 0) return;
        (bool ok, ) = megapotVault.call{value: amount}("");
        require(ok, "megapot transfer failed");
    }

    /// @notice Returns the raw encrypted handle for a tile, so the frontend can
    ///         pass it to Inco's attestedReveal() after calling revealTile().
    function getCellHandle(uint256 roundId, uint8 index) external view returns (bytes32) {
        return ebool.unwrap(rounds[roundId].cell[index]);
    }

    function getMultiplierBps(uint256 roundId) external view returns (uint256) {
        return rounds[roundId].multiplierBps;
    }

    function isRoundActive(uint256 roundId) external view returns (bool) {
        return rounds[roundId].active;
    }

    receive() external payable {}
}
