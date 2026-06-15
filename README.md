# Cross-chain Rebase Token

1. A protocol that allows user to deposit into a vault and in return receive rebase tokens
   that represents their underlying balance.
2. Rebase token -> balanceOf function is dynamic to show the changing balance with time.
   - Balance increase linearly with time
   - mint tokens to our users every time they perform an action (minting, burning, transferring ... or bridging)
3. Interest rate:
   - Individually set an interest rate or each user based on some global interest rate of the protocol at the time the user deposits into the vault.
   - This global interest rate can only decrease to incentivise/reward early adopters.
   - Increase token adoption!

The mechanism works as follows: When a user initiates one of these actions, the contract will first check the time elapsed since their last interaction. It then calculates the interest accrued to that user during this period, based on their specific interest rate. These newly calculated interest tokens are then minted to the user's recorded balance on -chain. only After this balance update does the contract proceed to execute the user's original requested action with their uptodate balance.
