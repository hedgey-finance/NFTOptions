# NFT Options (Call options)

This smart contract is a basic primative for creating call options that are stored with an NFT.  
They may be used to reward employees or contributors, or even community members with token options. The NFT Options can also be sold via an OTC Pool offering similar to the hedgey NFT-OTC-Core architecture that supports both distributing token-vesting NFTs to contributors in batches, as well as selling locked token positions to the public or whitelisted investors / buyers.   
The code is flexible so that there is no predefined pricing or specifications, it can be used however the DAO / company sees best fit. 
The NFTs are enumerable so that they can be adopted into other integrations, and can be traded on NFT marketplaces. 

## Testing
Clone repository

``` bash
npm install
npx hardhat compile
npx hardhat test
```
