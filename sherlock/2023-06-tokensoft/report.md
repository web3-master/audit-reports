| Severity | Title | 
|:--:|:---|
| [H-01](#h-01-malicious-beneficiary-will-get-more-voting-power-than-normal) | Malicious beneficiary will get more voting power than normal. |


# [H-01] Malicious beneficiary will get more voting power than normal.
## Summary
Malicious beneficiary will get more voting power than normal.

## Vulnerability Detail
AdvancedDistributor._initializeDistributionRecord() function mints NEW voting power token to beneficiary.
The code is as follows:
```solidity
File: AdvancedDistributor.sol
77:   function _initializeDistributionRecord(
78:     address beneficiary,
79:     uint256 totalAmount
80:   ) internal virtual override {
81:     super._initializeDistributionRecord(beneficiary, totalAmount);
82: 
83:     // add voting power through ERC20Votes extension
84:     _mint(beneficiary, tokensToVotes(totalAmount));
85:   }
```
This function CAN be called multiple times for the same beneficiary.
```solidity
File: ContinuousVestingMerkle.sol
43:   function initializeDistributionRecord(
44:     uint256 index, // the beneficiary's index in the merkle root
45:     address beneficiary, // the address that will receive tokens
46:     uint256 amount, // the total claimable by this beneficiary
47:     bytes32[] calldata merkleProof
48:   )
49:     external
50:     validMerkleProof(keccak256(abi.encodePacked(index, beneficiary, amount)), merkleProof)
51:   {
52:     _initializeDistributionRecord(beneficiary, amount);
53:   }
```
From the above code, ContinuousVestingMerkle.initializeDistributionRecord() is external function, so it can be called many times for the same beneficiary.
And L52 will call AdvancedDistributor._initializeDistributionRecord(), which mints NEW voting power token each time.

As a result, beneficiary will get many times more vote token than normal.

PriceTierVestingSale_2_0.initializeDistributionRecord() also produces such problem.

## Impact
If TokenSoft sets up a ContinuousVestingMerkle to vest a token, each beneficiary must get fixed amount of vote token according to this formula: totalAmount * voteFactor / fractionDenominator.
But a malicious beneficiary can mint much more vote token just by calling ContinuousVestingMerkle.initializeDistributionRecord() function multiple times.

## Code Snippet
https://github.com/sherlock-audit/2023-06-tokensoft/blob/main/contracts/contracts/claim/abstract/AdvancedDistributor.sol#L84

## Tool used
Manual Review

## Recommendation
```solidity
File: AdvancedDistributor.sol
77:   function _initializeDistributionRecord(
78:     address beneficiary,
79:     uint256 totalAmount
80:   ) internal virtual override {
81: -    super._initializeDistributionRecord(beneficiary, totalAmount);
82: -
83: -    // add voting power through ERC20Votes extension
84: -    _mint(beneficiary, tokensToVotes(totalAmount));
85: -  }

81: +    if (!records[beneficiary].initialized) {
82: +      super._initializeDistributionRecord(beneficiary, totalAmount);
83: +
84: +      // add voting power through ERC20Votes extension
85: +      _mint(beneficiary, tokensToVotes(totalAmount));
86: +    } else {
87: +      uint256 prevTotal = records[beneficiary].totalAmount;
88: +      super._initializeDistributionRecord(totalAmount);
89: +      if (prevTotal <= totalAmount){
90: +        _mint(beneficiary, tokensToVotes(totalAmount) - tokensToVotes(prevTotal));
91: +      } else {
92: +        _burn(beneficiary, tokensToVotes(prevTotal) - tokensToVotes(totalAmount));
93: +      }
94: +    }
95: +  }
```