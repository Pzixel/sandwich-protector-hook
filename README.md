# SandwitchProtectorHook

This project aims to create a hook that is transparent for regular users but prevents third parties from sandwiching their transactions. The hook achieves this by imposing increasing fees on the rebalancing buyout (the closing part of the sandwich), making the entire sandwich attack unprofitable. While simultaneous swaps in opposite directions on the same pool are rare, the hook still imposes a minimal fee—almost zero for regular users, and only slightly more in rare cases. However, actual sandwich attackers face significantly higher fees, preventing them from profiting off regular users. This keeps the profits with the swapper, who will prefer this pool over others.

The hook is fully compatible with existing aggregation protocols, making it easily composable and enabling multi-hop trades.

The tests folder includes tests that check all the invariants and also features a few property tests that validate the essential properties of the hook.
