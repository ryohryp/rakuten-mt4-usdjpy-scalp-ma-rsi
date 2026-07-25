# Phase 2 Outcome design notes

- The outcome unit is one logged signal candidate, not one executed trade.
- Virtual entry, SL and TP are fixed from `signal_candidates` at registration time.
- BUY outcomes use Bid; SELL outcomes use Ask.
- The tracker runs on every tick before trade-result tracking.
- The initial horizon is fixed at 48 M5 bars to match `tp15_sl10_h48_v1`.
- Pending outcomes are held in memory and removed immediately after successful append.
- Unresolved candidates are written as `TRUNCATED` before logger handles close.
- Restart recovery and a pending snapshot remain out of scope for this increment.
- AI remains OFF and the outcome tracker cannot permit, reject or modify orders.
