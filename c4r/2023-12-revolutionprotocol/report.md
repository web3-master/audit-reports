| Severity | Title | 
|:--:|:---|
| [M-01](#m-01-erc20tokenemittersolbuytoken-lack-of-slippage-control) | ERC20TokenEmitter.sol#buyToken: Lack of slippage control. |
| [M-02](#m-02-maxheapsol-already-extracted-tokenid-may-be-extracted-again) | MaxHeap.sol: Already extracted tokenId may be extracted again. |
| [M-03](#m-03-erc20tokenemittersolbuytoken-more-governance-tokens-than-the-calculation-of-vrgda-formula-will-be-minted) | ERC20TokenEmitter.sol#buyToken: More governance tokens than the calculation of VRGDA formula will be minted. |


# [M-01] ERC20TokenEmitter.sol#buyToken: Lack of slippage control.
## Impact
The price is governance token is volatile and varies according to the VRGDA formula.
Thus when the large amount of governance tokens are minted in a short time, the price will be increased.
ERC20TokenEmitter.sol#buyToken function has no slippage control.
Therefore while a user's call to buyToken function stays in mempool, if other users mint large amount of governance tokens, the user will receive small amount of tokens than expectation.

## Proof of Concept
ERC20TokenEmitter.sol#buyToken function is following.
```solidity
File: ERC20TokenEmitter.sol
152:     function buyToken(
153:         address[] calldata addresses,
154:         uint[] calldata basisPointSplits,
155:         ProtocolRewardAddresses calldata protocolRewardsRecipients
156:     ) public payable nonReentrant whenNotPaused returns (uint256 tokensSoldWad) {
157:         //prevent treasury from paying itself
158:         require(msg.sender != treasury && msg.sender != creatorsAddress, "Funds recipient cannot buy tokens");
159: 
160:         require(msg.value > 0, "Must send ether");
161:         // ensure the same number of addresses and bps
162:         require(addresses.length == basisPointSplits.length, "Parallel arrays required");
163: 
164:         // Get value left after protocol rewards
165:         uint256 msgValueRemaining = _handleRewardsAndGetValueToSend(
166:             msg.value,
167:             protocolRewardsRecipients.builder,
168:             protocolRewardsRecipients.purchaseReferral,
169:             protocolRewardsRecipients.deployer
170:         );
171: 
172:         //Share of purchase amount to send to treasury
173:         uint256 toPayTreasury = (msgValueRemaining * (10_000 - creatorRateBps)) / 10_000;
174: 
175:         //Share of purchase amount to reserve for creators
176:         //Ether directly sent to creators
177:         uint256 creatorDirectPayment = ((msgValueRemaining - toPayTreasury) * entropyRateBps) / 10_000;
178:         //Tokens to emit to creators
179:         int totalTokensForCreators = ((msgValueRemaining - toPayTreasury) - creatorDirectPayment) > 0
180:             ? getTokenQuoteForEther((msgValueRemaining - toPayTreasury) - creatorDirectPayment)
181:             : int(0);
182: 
183:         // Tokens to emit to buyers
184:         int totalTokensForBuyers = toPayTreasury > 0 ? getTokenQuoteForEther(toPayTreasury) : int(0);
185: 
186:         //Transfer ETH to treasury and update emitted
187:         emittedTokenWad += totalTokensForBuyers;
188:         if (totalTokensForCreators > 0) emittedTokenWad += totalTokensForCreators;
189: 
190:         //Deposit funds to treasury
191:         (bool success, ) = treasury.call{ value: toPayTreasury }(new bytes(0));
192:         require(success, "Transfer failed.");
193: 
194:         //Transfer ETH to creators
195:         if (creatorDirectPayment > 0) {
196:             (success, ) = creatorsAddress.call{ value: creatorDirectPayment }(new bytes(0));
197:             require(success, "Transfer failed.");
198:         }
199: 
200:         //Mint tokens for creators
201:         if (totalTokensForCreators > 0 && creatorsAddress != address(0)) {
202:             _mint(creatorsAddress, uint256(totalTokensForCreators));
203:         }
204: 
205:         uint256 bpsSum = 0;
206: 
207:         //Mint tokens to buyers
208: 
209:         for (uint256 i = 0; i < addresses.length; i++) {
210:             if (totalTokensForBuyers > 0) {
211:                 // transfer tokens to address
212:                 _mint(addresses[i], uint256((totalTokensForBuyers * int(basisPointSplits[i])) / 10_000));
213:             }
214:             bpsSum += basisPointSplits[i];
215:         }
216: 
217:         require(bpsSum == 10_000, "bps must add up to 10_000");
218: 
219:         emit PurchaseFinalized(
220:             msg.sender,
221:             msg.value,
222:             toPayTreasury,
223:             msg.value - msgValueRemaining,
224:             uint256(totalTokensForBuyers),
225:             uint256(totalTokensForCreators),
226:             creatorDirectPayment
227:         );
228: 
229:         return uint256(totalTokensForBuyers);
230:     }
```
As can be seen, the function has no parameter to protect the slippage.

## Lines of code
https://github.com/code-423n4/2023-12-revolutionprotocol/blob/main/packages/revolution/src/ERC20TokenEmitter.sol#L152

## Tool used
Manual Review

## Recommended Mitigation Steps
Any user can predict the amount of tokens to receive through the call to getTokenQuoteForPayment function before the calling to the buyToken function.
Therefore, the user can add the smallest amount limit of tokens as a parameter to buyToken function.

# [M-02] MaxHeap.sol: Already extracted tokenId may be extracted again.
## Impact
MaxHeap.sol#extractMax function only decreases the size variable without initializing the heap state variable.
On the other hand, MaxHeap.sol#maxHeapify function involves the heap variable for the out-of-bound index which will contain dirty non-zero value.
As a result, uncleared dirty value of heap state variable will be used in the process and already extracted tokenId will be extracted again.

## Proof of Concept
MaxHeap.sol#extractMax function is following.
```solidity
File: MaxHeap.sol
156:     function extractMax() external onlyAdmin returns (uint256, uint256) {
157:         require(size > 0, "Heap is empty");
158: 
159:         uint256 popped = heap[0];
160:         heap[0] = heap[--size];
161:         maxHeapify(0);
162: 
163:         return (popped, valueMapping[popped]);
164:     }
```
As can be seen, the above funcion decreases size state variable by one, but does not initialize the heap[size] value to zero.
In the meantime,MaxHeap.sol#maxHeapify function is following.
```solidity
File: MaxHeap.sol
094:     function maxHeapify(uint256 pos) internal {
095:         uint256 left = 2 * pos + 1;
096:         uint256 right = 2 * pos + 2;
097: 
098:         uint256 posValue = valueMapping[heap[pos]];
099:         uint256 leftValue = valueMapping[heap[left]];
100:         uint256 rightValue = valueMapping[heap[right]];
101: 
102:         if (pos >= (size / 2) && pos <= size) return;
103: 
104:         if (posValue < leftValue || posValue < rightValue) {
105:             if (leftValue > rightValue) {
106:                 swap(pos, left);
107:                 maxHeapify(left);
108:             } else {
109:                 swap(pos, right);
110:                 maxHeapify(right);
111:             }
112:         }
113:     }
```
For example, if size=2 and pos=0, right = 2 = size holds true.
So the heap[right]=heap[size] indicates the value of out-of-bound index which may be not initialized in extractMax function ahead.
But in L102 since pos = 0 < (size / 2) = 1 holds true, the function does not return and continue to proceed the below section of function.
Thus, abnormal phenomena occurs due to the value that should not be used.

We can verify the above issue by adding and running the following test code to test/max-heap/Updates.t.sol.
```solidity
    function testExtractUpdateError() public {
        // Insert 3 items with value 20 and remove them all
        maxHeapTester.insert(1, 20);
        maxHeapTester.insert(2, 20);
        maxHeapTester.insert(3, 20);

        maxHeapTester.extractMax();
        maxHeapTester.extractMax();
        maxHeapTester.extractMax(); // Because all of 3 items are removed, itemId=1,2,3 should never be extracted after.

        // Insert 2 items with value 10 which is small than 20
        maxHeapTester.insert(4, 10);
        maxHeapTester.insert(5, 10);
        // Update value to cause maxHeapify
        maxHeapTester.updateValue(4, 5);

        // Now the item should be itemId=5, value=10
        // But in fact the max item is itemId=3, value=20 now.
        (uint256 itemId, uint256 value) = maxHeapTester.extractMax(); // itemId=3 will be extracted again

        require(itemId == 5, "Item ID should be 5 but 3 now");
        require(value == 10, "value should be 10 but 20 now");
    }
```
As a result of test code, the return value of the last extractMax call is not (itemId, value) = (5, 10) but (itemId, value) = (3, 20) which is error.
According to READM.md#L313, the above result must not be forbidden.

## Lines of code
https://github.com/code-423n4/2023-12-revolutionprotocol/blob/main/packages/revolution/src/MaxHeap.sol#L102
https://github.com/code-423n4/2023-12-revolutionprotocol/blob/main/packages/revolution/src/MaxHeap.sol#L156

## Tool used
Manual Review

## Recommended Mitigation Steps
Modify the MaxHeap.sol#extractMax function as follows.
```solidity
    function extractMax() external onlyAdmin returns (uint256, uint256) {
        require(size > 0, "Heap is empty");

        uint256 popped = heap[0];
        heap[0] = heap[--size];
 ++     heap[size] = 0;
        maxHeapify(0);

        return (popped, valueMapping[popped]);
    }
```
Since the value of heap[size] is initialized to zero, no errors will occur even though the value of out-of-bound index is used in maxHeapify function.

# [M-03] ERC20TokenEmitter.sol#buyToken: More governance tokens than the calculation of VRGDA formula will be minted.
## Impact
ERC20TokenEmitter.sol#buyToken function calculates the amount of governance tokens to be minted to the creators and the treasury by two times respectively.

The VRGDAC.sol#yToX function involved in the calculation is a concave function.
That is yToX(t, s, x1) + yToX(t, s, x2) > yToX(t, s, x1 + x2) holds for 0 < x1, 0 < x2.

Therefore, the amount of minted tokens will be greater than the case of calculating the amount of tokens minted to the treasury and creators at a time.
Thus, the VRGDA formula is misapplied.

## Proof of Concept
ERC20TokenEmitter.sol#buyToken function is following.
```solidity
File: ERC20TokenEmitter.sol
152:     function buyToken(
153:         address[] calldata addresses,
154:         uint[] calldata basisPointSplits,
155:         ProtocolRewardAddresses calldata protocolRewardsRecipients
156:     ) public payable nonReentrant whenNotPaused returns (uint256 tokensSoldWad) {
157:         //prevent treasury from paying itself
158:         require(msg.sender != treasury && msg.sender != creatorsAddress, "Funds recipient cannot buy tokens");
159: 
160:         require(msg.value > 0, "Must send ether");
161:         // ensure the same number of addresses and bps
162:         require(addresses.length == basisPointSplits.length, "Parallel arrays required");
163: 
164:         // Get value left after protocol rewards
165:         uint256 msgValueRemaining = _handleRewardsAndGetValueToSend(
166:             msg.value,
167:             protocolRewardsRecipients.builder,
168:             protocolRewardsRecipients.purchaseReferral,
169:             protocolRewardsRecipients.deployer
170:         );
171: 
172:         //Share of purchase amount to send to treasury
173:         uint256 toPayTreasury = (msgValueRemaining * (10_000 - creatorRateBps)) / 10_000;
174: 
175:         //Share of purchase amount to reserve for creators
176:         //Ether directly sent to creators
177:         uint256 creatorDirectPayment = ((msgValueRemaining - toPayTreasury) * entropyRateBps) / 10_000;
178:         //Tokens to emit to creators
179:         int totalTokensForCreators = ((msgValueRemaining - toPayTreasury) - creatorDirectPayment) > 0
180:             ? getTokenQuoteForEther((msgValueRemaining - toPayTreasury) - creatorDirectPayment)
181:             : int(0);
182: 
183:         // Tokens to emit to buyers
184:         int totalTokensForBuyers = toPayTreasury > 0 ? getTokenQuoteForEther(toPayTreasury) : int(0);
185: 
186:         //Transfer ETH to treasury and update emitted
187:         emittedTokenWad += totalTokensForBuyers;
188:         if (totalTokensForCreators > 0) emittedTokenWad += totalTokensForCreators;
189: 
190:         //Deposit funds to treasury
191:         (bool success, ) = treasury.call{ value: toPayTreasury }(new bytes(0));
192:         require(success, "Transfer failed.");
193: 
194:         //Transfer ETH to creators
195:         if (creatorDirectPayment > 0) {
196:             (success, ) = creatorsAddress.call{ value: creatorDirectPayment }(new bytes(0));
197:             require(success, "Transfer failed.");
198:         }
199: 
200:         //Mint tokens for creators
201:         if (totalTokensForCreators > 0 && creatorsAddress != address(0)) {
202:             _mint(creatorsAddress, uint256(totalTokensForCreators));
203:         }
204: 
205:         uint256 bpsSum = 0;
206: 
207:         //Mint tokens to buyers
208: 
209:         for (uint256 i = 0; i < addresses.length; i++) {
210:             if (totalTokensForBuyers > 0) {
211:                 // transfer tokens to address
212:                 _mint(addresses[i], uint256((totalTokensForBuyers * int(basisPointSplits[i])) / 10_000));
213:             }
214:             bpsSum += basisPointSplits[i];
215:         }
216: 
217:         require(bpsSum == 10_000, "bps must add up to 10_000");
218: 
219:         emit PurchaseFinalized(
220:             msg.sender,
221:             msg.value,
222:             toPayTreasury,
223:             msg.value - msgValueRemaining,
224:             uint256(totalTokensForBuyers),
225:             uint256(totalTokensForCreators),
226:             creatorDirectPayment
227:         );
228: 
229:         return uint256(totalTokensForBuyers);
230:     }
```
As can be seen, L180 and L184 calcualates the amount of token minted to the creators and treasury by two times respectively.
There the getTokenQuoteForEther function calls the VRGDAC.sol#yToX internaly with the same emittedTokenWad.

The yToX function is a concave function as stated in README.md.
That is yToX(t, s, x1) + yToX(t, s, x2) > yToX(t, s, x1 + x2) holds for 0 < x1, 0 < x2.

On the other hand L187-L188 add the sum of token amount minted to creators and treasury to the emittedTokenWad state variable.
Thus the more tokens than the VRGDA formula will be minted to treasury and creators.

## Lines of code
https://github.com/code-423n4/2023-12-revolutionprotocol/blob/main/packages/revolution/src/ERC20TokenEmitter.sol#L179-L188

## Tool used
Manual Review

## Recommended Mitigation Steps
There are two methods to fix the error.

After the calculation of the amount of tokens minted to creators, at first increase the emittedTokenWad with the calculated amount and then calculate the amount of tokens minted to treasury.
That is, move the code of L188 of ERC20TokenEmitter.sol#buyToken to the line above L184 as follows.
```solidity
        ...
        int totalTokensForCreators = ((msgValueRemaining - toPayTreasury) - creatorDirectPayment) > 0
180:        ? getTokenQuoteForEther((msgValueRemaining - toPayTreasury) - creatorDirectPayment)
            : int(0);
++      if (totalTokensForCreators > 0) emittedTokenWad += totalTokensForCreators;

        // Tokens to emit to buyers
184:    int totalTokensForBuyers = toPayTreasury > 0 ? getTokenQuoteForEther(toPayTreasury) : int(0);

        //Transfer ETH to treasury and update emitted
        emittedTokenWad += totalTokensForBuyers;
--      if (totalTokensForCreators > 0) emittedTokenWad += totalTokensForCreators;
        ...
```
Calculate the sum amount of tokens minted to creators and treasury at a time and distribute them to the creators and treasury due to the respective ratios.
