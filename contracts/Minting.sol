pragma solidity 0.4.18;

import './ManagingState.sol';
import './StandardToken.sol';


contract Minting is StandardToken, ManagingState {
    // Minting
    //
    // The company might decide at a later time to announce and conduct a new round
    // of public token sale. This will require the minting of new tokens.
    // In order to protect the current token holders from unpredictable outcomes,
    // minting for new rounds of token sales will adhere to a three-stage process 
    // that can only happen after the first ICO is finalized.
    //
    // 1. The admins broadcast a mintPrepare() transaction that signals their intention
    // to mint and allocate a specified fresh token supply to a new ICO contract.
    // The current token holders have the opportunity to review this decision and take
    // appropriate action for a period of 31 days.
    //
    // 2. After 31 days have passed since mintPrepare(), the admins will broadcast
    // a mintCommit() transaction that effectively creates the defined token supply and
    // assigns it to the specified ICO contract. At this time, all the token transfers 
    // are locked except the transfers that originate from the ICO contract address
    // (these are needed in order to distribute the tokens during the next ICOs).
    // 
    // 3. Once the ICO is concluded, the tokens that have been minted but are left
    // unassigned are burnt and all the transfers are unlocked.

    enum MintingState { NotStarted, Prepared, Committed }
    MintingState public currentMintingState;
    
    // Minimum delay required before announcing a new minting round
    uint256 public mintingPrepareDelay;
    
    // Minimum delay required between announcing the minting and generating the tokens
    uint256 public mintingCommitDelay;
    
    // Address of the new ICO contract that the minting tokens are allocated to
    address public mintAddress;
    
    // Amount of new tokens to be minted (should include 10**18 decimals)
    uint256 public mintValue;
    uint256 public mintPreparedBlock;
    uint256 public mintFinalizedBlock;

    function mintPrepare(address _to, uint256 _value)
        external
        isFinalized  // Minting can only work after the first ICO is finalized
        onlyOwner
        returns (bool success)
    {
        require(currentMintingState == MintingState.NotStarted);
        require(_to != address(0));
        require(_value > 0);
        
        // if no previous minting took place, use the funding round finalization
        // time as reference
        if (mintFinalizedBlock == 0) {
            mintFinalizedBlock = finalizedBlock;
        }
        require(mintFinalizedBlock + mintingPrepareDelay < block.number);
        
        mintAddress = _to;
        mintValue = _value;
        mintPreparedBlock = block.number;
        currentMintingState = MintingState.Prepared;
        return true;
    }

    function mintCancel()
        external
        isFinalized  // Minting can only work after the first ICO is finalized
        onlyOwner
        returns (bool success)
    {
        require(currentMintingState == MintingState.Prepared);
        mintAddress = address(0);
        mintValue = 0;
        mintPreparedBlock = 0;
        currentMintingState = MintingState.NotStarted;
        return true;
    }

    function mintCommit()
        external
        isFinalized  // Minting can only work after the first ICO is finalized
        onlyOwner
        returns (bool success)
    {
        // Check if a previous mintPrepare() is active
        require(currentMintingState == MintingState.Prepared);

        // Check for sane block number values
        require(0 < mintPreparedBlock && mintPreparedBlock < block.number);
        
        // The commit delay must have passed since the last mintPrepare()
        require(mintPreparedBlock + mintingCommitDelay < block.number);

        // If all these conditions are met, mint new MINE tokens to the address
        // specified previously in the mintPrepare() call
        balances[mintAddress] = SafeMath.add(balances[mintAddress], mintValue);
        totalSupply = SafeMath.add(totalSupply, mintValue);

        // Prevent replay attacks
        mintValue = 0;
        currentMintingState = MintingState.Committed;
        return true;
    }

    function mintFinalize()
        external
        isFinalized  // Minting can only work after the first ICO is finalized
        onlyOwner
        returns (bool success)
    {
        require(currentMintingState == MintingState.Committed);
        totalSupply = SafeMath.sub(totalSupply, balances[mintAddress]);
        balances[mintAddress] = 0;
        mintFinalizedBlock = block.number;
        mintAddress = address(0);
        currentMintingState = MintingState.NotStarted;
        return true;
    }
}