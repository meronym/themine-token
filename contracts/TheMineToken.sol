pragma solidity ^0.4.17;

import 'zeppelin-solidity/contracts/token/StandardToken.sol';

contract TheMineToken is StandardToken {
    // Token metadata
    string public constant name = 'TheMineToken';
    string public constant symbol = 'MINE';
    uint8 public constant decimals = 18;
    string public constant version = '0.1';

    // Fundraising goals: minimums and maximums
    uint256 public constant dec_multiplier = uint(10) ** decimals;
    uint256 public constant TOKEN_CREATION_CAP = 5 * (10**6) * dec_multiplier; // 5 million tokens
    uint256 public constant TOKEN_CREATED_MIN = 5 * (10**5) * dec_multiplier;  // 500 000 tokens
    uint256 public constant TOKEN_MIN = 1 * dec_multiplier;                    // 1 MINE token
    uint256 public constant TOKENS_PRESALE = 2 * (10**5) * dec_multiplier;     // 200 000 tokens

    // Bonus multipliers
    uint256 public constant TOKEN_FIRST_BONUS_MULTIPLIER  = 110;    // 10% bonus
    uint256 public constant TOKEN_SECOND_BONUS_MULTIPLIER = 105;    // 5% bonus
    uint256 public constant TOKEN_THIRD_BONUS_MULTIPLIER  = 100;    // 0% bonus

    // Round duration expressed in blocks (each round should last approx 10 days)
    uint256 public constant FUNDING_ROUND_DURATION_BLOCKS = 10 * (24 * 60 * 4);  // 10 days with 15s block time

    // Fundraising parameters provided when creating the contract
    uint256 public fundingStartBlock; // block number that triggers the fundraising start
    uint256 public fundingEndBlock;   // block number that guards for the time constraint
    uint256 public roundTwoBlock;     // block number that triggers the second exchange rate change
    uint256 public roundThreeBlock;   // block number that triggers the third exchange rate change

    // Current ETH/USD exchange rate
    uint256 public ETH_USD_EXCHANGE_RATE_IN_CENTS; // to be set by oraclize

    // ETH balance per user
    // Since we have different exchange rates at different stages, we need to keep track
    // of how much ether each contributed in case that we need to issue a refund
    mapping (address => uint256) private ethBalances;
    mapping (address => uint256) private noKycEthBalances;

    // Total received ETH balances
    uint256 public allReceivedEth;
    uint256 public allUnKycedEth; // total amount of ETH we have no KYC for yet

    // Access management
    address public admin1;       // First administrator for multi-sig mechanism
    address public admin2;       // Second administrator for multi-sig mechanism
    address public admin3;       // Third (backup) administrator for multi-sig mechanism
    address public kycValidator; // Can approve or reject KYC checks

    // For storing the hashes of admins' msg.data
    mapping (address => bytes32) private multiSigHashes;

    // For checking if user has already undergone KYC or not, to lock up his tokens until then
    mapping (address => bool) public kycVerified;

    // For tracking if team members already got their tokens
    bool public teamTokensDelivered;

    // Events used for logging
    event LogRefund(address indexed _to, uint256 _value);
    event LogCreateMINE(address indexed _to, uint256 _value);
    event LogKycRejected(address indexed _user, uint256 _value);
    event LogTeamTokensDelivered(address indexed distributor, uint256 _value);

    // Implements a 2-of-3 multisig check so that the execution is carried on if
    // and only if at least 2 admins have independently broadcasted the same query
    modifier onlyOwner() {
        // Check if transaction sender is admin.
        require(msg.sender == admin1 || msg.sender == admin2 || msg.sender == admin3);
        
        // If yes, store the msg.data
        multiSigHashes[msg.sender] = keccak256(msg.data);

        // Check if the stored msg.data hash equals to the one of the other admins
        if (((multiSigHashes[admin1]) == (multiSigHashes[admin2])) ||
            ((multiSigHashes[admin2]) == (multiSigHashes[admin3])) ||
            ((multiSigHashes[admin1]) == (multiSigHashes[admin3]))) {
            // If yes, at least two admins agreed - continue
            _;

            // Reset hashes after successful execution
            multiSigHashes[admin1] = 0x0;
            multiSigHashes[admin2] = 0x0;
            multiSigHashes[admin3] = 0x0;
        } else {
            // If not (yet), return.
            return;
        }
    }

    modifier onlyKycValidator() {
        require(msg.sender == kycValidator);
        _;
    }

    function updateKycValidator(address _newKycValidator)
    external
    onlyOwner
    returns (bool success)
    {
        kycValidator = _newKycValidator;
        return true;
    }

    // Contract state management
    enum ContractState { Fundraising, Finalized, Paused }
    ContractState public state;         // Current state of the contract
    ContractState private savedState;   // State of the contract before being paused

    // Contract state-related modifiers
    modifier isFundraising() {
        require(state == ContractState.Fundraising);
        _;
    }

    modifier isFinalized() {
        require(state == ContractState.Finalized);
        _;
    }

    modifier isPaused() {
        require(state == ContractState.Paused);
        _;
    }

    modifier notPaused() {
        require(state != ContractState.Paused);
        _;
    }

    modifier isFundraisingIgnorePaused() {
        require(state == ContractState.Fundraising || (state == ContractState.Paused && savedState == ContractState.Fundraising));
        _;
    }

    modifier minimumReached() {
        require(totalSupply >= TOKEN_CREATED_MIN);
        _;
    }

    /// @dev Pauses the contract
    function pause()
    external
    notPaused   // Prevent the contract getting stuck in the Paused state
    onlyOwner   // Only both admins calling this method can pause the contract
    {
        // Move the contract to Paused state
        savedState = state;
        state = ContractState.Paused;
    }

    /// @dev Proceeds with the contract
    function proceed()
    external
    isPaused
    onlyOwner   // Only both admins calling this method can proceed with the contract
    {
        // Move the contract to the state it was before we paused it
        state = savedState;
    }

    // Minting
    //
    // The company might decide at a later time to announce and conduct a new round
    // of public token sale. This will require the minting of new tokens.
    // In order to protect the current token holders from unpredictable outcomes,
    // minting for new rounds of token sales will adhere to a three-stage process 
    // that can only happen after the first ICO is finalized.
    //
    // 1. The admins broadcast a MintPrepare() transaction that signals their intention
    // to mint and allocate a specified fresh token supply to a new ICO contract.
    // The current token holders have the opportunity to review this decision and take
    // appropriate action for a period of 7 days.
    //
    // 2. After 7 days have passed since MintPrepare(), the admins will broadcast
    // a MintCommit() transaction that effectively creates the defined token supply and
    // assigns it to the specified ICO contract. At this time, all the token transfers 
    // are locked except the transfers that originate from the ICO contract address
    // (these are needed in order to distribute the tokens during the next ICOs).
    // 
    // 3. Once the ICO is concluded, the tokens that have been minted but are left
    // unassigned are burnt and all the transfers are unlocked.

    enum MintingState { NotStarted, Prepared, Committed }
    MintingState public currentMintingState;
    
    address public mintAddress;
    uint256 public mintValue;
    uint256 public mintPrepareBlock;

    // The minimum delay between Prepare() and Commit() is set to 7 days at 15 sec per block
    uint256 public constant MINT_COMMIT_BLOCK_DELAY = (60 / 15) * 60 * 24 * 7;

    function MintPrepare(address _to, uint256 _value)
    external
    isFinalized  // Minting can only work after the first ICO is finalized
    onlyOwner
    returns (bool success)
    {
        require(currentMintingState == MintingState.NotStarted);
        require(_to != address(0));
        require(_value > 0);
        
        mintAddress = _to;
        mintValue = _value;
        mintPrepareBlock = block.number;
        currentMintingState = MintingState.Prepared;
        return true;
    }

    function MintCancel()
    external
    isFinalized  // Minting can only work after the first ICO is finalized
    onlyOwner
    returns (bool success)
    {
        require(currentMintingState == MintingState.Prepared);
        mintAddress = address(0);
        mintValue = 0;
        mintPrepareBlock = 0;
        currentMintingState = MintingState.NotStarted;
        return true;
    }

    function MintCommit()
    external
    isFinalized  // Minting can only work after the first ICO is finalized
    onlyOwner
    returns (bool success)
    {
        // Check if a previous MintPrepare() is active
        require(currentMintingState == MintingState.Prepared);

        // Check for sane block number values
        require(block.number > mintPrepareBlock && mintPrepareBlock > 0);
        
        // Minimum 7 days (at 4 blocks per minute) must have passed since
        // the last MintPrepare()
        require(block.number - mintPrepareBlock > MINT_COMMIT_BLOCK_DELAY);

        // If all these conditions are met, mint new MINE tokens to the address
        // specified previously in the MintPrepare() call
        balances[mintAddress] = SafeMath.add(balances[mintAddress], mintValue);
        totalSupply = SafeMath.add(totalSupply, mintValue);

        // Prevent replay attacks
        mintValue = 0;
        currentMintingState = MintingState.Committed;
        return true;
    }

    function MintFinalize()
    external
    isFinalized  // Minting can only work after the first ICO is finalized
    onlyOwner
    returns (bool success)
    {
        require(currentMintingState == MintingState.Committed);
        totalSupply = SafeMath.sub(totalSupply, balances[mintAddress]);
        balances[mintAddress] = 0;
        mintAddress = address(0);
        currentMintingState = MintingState.NotStarted;
        return true;
    }

    modifier transfersAllowed(address _from) {
        require(
            // Do not allow transfers during the first ICO
            (block.number < fundingStartBlock || state == ContractState.Finalized) &&
            // Only allow transfers during the next token sales if they originate from the
            // specified contract address (in order to distribute the minted tokens)
            (currentMintingState != MintingState.Committed || _from == mintAddress));
        _;
    }

    // Overridden method to check for state conditions before allowing transfer of tokens
    function transfer(address _to, uint256 _value)
    public
    transfersAllowed(msg.sender)
    returns (bool success)
    {
        return super.transfer(_to, _value);
    }

    // Overridden method to check for state conditions before allowing transfer of tokens
    function transferFrom(address _from, address _to, uint256 _value)
    public
    transfersAllowed(msg.sender)
    returns (bool success)
    {
        return super.transferFrom(_from, _to, _value);
    }

    // Token contract constructor
    function TheMineToken(
        address _admin1,
        address _admin2,
        address _admin3,
        address _kycValidator,
        uint256 _fundingStartBlock,
        address _presaleAccount)
    public
    payable 
    {
        // The start of the fundraising should happen in the future
        require(block.number < _fundingStartBlock);

        // Admin addresses must be set and must be different
        require(_admin1 != address(0));
        require(_admin2 != address(0));
        require(_admin3 != address(0));
        require((_admin1 != _admin2) && (_admin1 != _admin3) && (_admin2 != _admin3));
        
        // Presale account must be properly defined
        require(_presaleAccount != address(0));

        // kycValidator must be set and be different from the admins
        require(_kycValidator != address(0));
        require(_kycValidator != _admin1);
        require(_kycValidator != _admin2);
        require(_kycValidator != _admin3);

        // Set the addresses
        admin1 = _admin1;
        admin2 = _admin2;
        admin2 = _admin3;
        kycValidator = _kycValidator;

        // Init contract state
        state = ContractState.Fundraising;
        savedState = ContractState.Fundraising;
        fundingStartBlock = _fundingStartBlock;
        roundTwoBlock = _fundingStartBlock + FUNDING_ROUND_DURATION_BLOCKS;
        roundThreeBlock = _fundingStartBlock + 2 * FUNDING_ROUND_DURATION_BLOCKS;
        fundingEndBlock = _fundingStartBlock + 3 * FUNDING_ROUND_DURATION_BLOCKS;

        currentMintingState = MintingState.NotStarted;

        // Allocate the presale tokens
        totalSupply = TOKENS_PRESALE;
        balances[_presaleAccount] = TOKENS_PRESALE;

        // TODO to be set by oraclize
        ETH_USD_EXCHANGE_RATE_IN_CENTS = 1000 * 100;    // 1000 USD in cents
    }

    // Update the fundraising start date
    function updateFundingStart(uint256 _fundingStartBlock)
    external
    isFundraisingIgnorePaused  
    onlyOwner
    {
        // Can only change the funding start block if the funding had not started yet
        require(fundingStartBlock > block.number);
        // The new date needs to be set in the future
        require(_fundingStartBlock > block.number);
        
        fundingStartBlock = _fundingStartBlock;
        roundTwoBlock = _fundingStartBlock + FUNDING_ROUND_DURATION_BLOCKS;
        roundThreeBlock = _fundingStartBlock + 2*FUNDING_ROUND_DURATION_BLOCKS;
        fundingEndBlock = _fundingStartBlock + 3*FUNDING_ROUND_DURATION_BLOCKS;
    }

    // Returns the current token price
    function getCurrentBonusRate()
    private
    constant
    returns (uint256 currentDiscountRate)
    {
        // determine which bonus to apply
        if (block.number < roundTwoBlock) {
            // first round
            return TOKEN_FIRST_BONUS_MULTIPLIER;
        } else if (block.number < roundThreeBlock){
            // second round
            return TOKEN_SECOND_BONUS_MULTIPLIER;
        } else {
            // third round
            return TOKEN_THIRD_BONUS_MULTIPLIER;
        }
    }

    // Accepts ether and creates new MINE tokens
    function createTokens()
    payable
    external
    isFundraising
    {
        require(block.number >= fundingStartBlock);
        require(block.number <= fundingEndBlock);
        require(msg.value > 0);

        // Calculate how many tokens need to be allocated
        uint256 valueUsd = SafeMath.mul(msg.value, ETH_USD_EXCHANGE_RATE_IN_CENTS) / 100;
        uint256 tokens = SafeMath.mul(valueUsd, getCurrentBonusRate()) / 100;
        uint256 checkedSupply = SafeMath.add(totalSupply, tokens);

        // Check the minimum amount of tokens and the token cap
        require(tokens >= TOKEN_MIN);
        require(checkedSupply <= TOKEN_CREATION_CAP);

        // Only when all the checks have passed, we check if the address is already KYCEd and then 
        // update the state (noKycEthBalances, allReceivedEth, totalSupply, and balances) of the contract
        if (kycVerified[msg.sender] == false) {
            // @dev The unKYCed eth balances are moved to main ethBalances after approveKyc()
            noKycEthBalances[msg.sender] = SafeMath.add(noKycEthBalances[msg.sender], msg.value);
            // add the contributed eth to the total unKYCed eth amount
            allUnKycedEth = SafeMath.add(allUnKycedEth, msg.value);
        } else {
            // if buyer is already KYC approved, assign the Eth to the main pool
            ethBalances[msg.sender] = SafeMath.add(ethBalances[msg.sender], msg.value);
            allReceivedEth = SafeMath.add(allReceivedEth, msg.value);
        }

        totalSupply = checkedSupply;
        balances[msg.sender] += tokens;  // safeAdd not needed

        // Log the creation of these tokens
        LogCreateMINE(msg.sender, tokens);
    }

    // Approve KYC of a user and track his contributions
    function approveKyc(address _owner)
    external
    onlyKycValidator
    {
        require(kycVerified[_owner] == false);

        // unlock the owner to allow transfer of tokens
        kycVerified[_owner] = true;

        // check if the user was an Eth buyer
        if (noKycEthBalances[_owner] > 0) {
            // now move the unKYCed Eth balance to the regular ethBalance. 
            ethBalances[_owner] = noKycEthBalances[_owner];

            // add the now KYCed Eth to the total received Eth
            allReceivedEth = SafeMath.add(allReceivedEth, noKycEthBalances[_owner]);

            // subtract the now KYCed Eth from total amount of unKYCed Eth
            allUnKycedEth = SafeMath.sub(allUnKycedEth, noKycEthBalances[_owner]);

            // and set the user's unKYCed Eth balance to 0
            noKycEthBalances[_owner] = 0; // preventing replay attacks
        }
    }

    // Reject KYC of a user and refund his contributions
    function rejectKyc(address _user)
    external
    onlyKycValidator
    {
        // once a user is verified, we can't kick him out
        require(kycVerified[_user] == false);

        // stop if a user has no contribution
        uint256 ethVal = noKycEthBalances[_user];
        require(ethVal > 0);

        // stop if a user has no tokens
        uint256 tokenVal = balances[_user];
        require(tokenVal > 0);

        // update the total unKYCed Eth balance
        allUnKycedEth = SafeMath.sub(allUnKycedEth, noKycEthBalances[_user]);

        // remove the tokens from user's balances
        balances[_user] = 0; 
        noKycEthBalances[_user] = 0;

        // update the total supply of generated tokens so far
        totalSupply = SafeMath.sub(totalSupply, tokenVal);

        // Log this refund
        LogKycRejected(_user, ethVal);

        // Send the contributions only after we have updated all the balances
        // If you're using a contract, make sure it works with .transfer() gas limits
        _user.transfer(ethVal);
    }

    // Allows contributors to recover their ether in case the minimum funding goal is not reached
    function refund()
    external
    {
        // Allow refunds only a week after end of funding to give KYC-team time to verify contributors
        require(block.number > (fundingEndBlock + 42000));

        // No refunds if the minimum token cap has been reached
        require(totalSupply < TOKEN_CREATED_MIN);

        // Make sure we need to refund anything
        require(ethBalances[msg.sender] > 0 || noKycEthBalances[msg.sender] > 0);

        // Only refund if the sender owns MINE tokens
        uint256 tokenVal = balances[msg.sender];
        require(tokenVal > 0);

        // Refund either KYCed eth or un-KYCd eth
        uint256 ethVal = SafeMath.add(ethBalances[msg.sender], noKycEthBalances[msg.sender]);
        require(ethVal > 0);

        allReceivedEth = SafeMath.sub(allReceivedEth, ethBalances[msg.sender]);    // subtract only the KYCed ETH from allReceivedEth, because the latter is what admins will only be able to withdraw
        allUnKycedEth = SafeMath.sub(allUnKycedEth, noKycEthBalances[msg.sender]); // or if there was any unKYCed Eth, subtract it from the total unKYCed eth balance.

        // Update the state only after all the checks have passed.
        // reset everything to zero, no replay attacks.
        balances[msg.sender] = 0;
        ethBalances[msg.sender] = 0;
        noKycEthBalances[msg.sender] = 0;
        totalSupply = SafeMath.sub(totalSupply, tokenVal); // Extra safe

        // Log this refund
        LogRefund(msg.sender, ethVal);

        // Send the contributions only after we have updated all the balances
        // If you're using a contract, make sure it works with .transfer() gas limits
        msg.sender.transfer(ethVal);
    }

    /// Allows to transfer ether from the contract as soon as the minimum is reached
    function retrieveEth(uint256 _value, address _safe)
    external
    minimumReached
    onlyOwner
    {
        // make sure unKYCed eth cannot be withdrawn
        require(SafeMath.sub(this.balance, _value) >= allUnKycedEth);
        
        // make sure a recipient was defined
        require(_safe != address(0));

        // send the eth to where admins agree upon
        _safe.transfer(_value);
    }

    /// Ends the fundraising period and sends the ETH to wherever the admins agree upon
    function finalize(address _safe)
    external
    isFundraising
    minimumReached
    onlyOwner  // Only the admins calling this method exactly the same way can finalize the sale.
    {
        // Only allow to finalize the contract before the ending block if we already reached any of the two caps
        require(block.number > fundingEndBlock || totalSupply >= TOKEN_CREATED_MIN);
        
        // make sure a recipient was defined
        require (_safe != address(0));

        // Move the contract to Finalized state
        state = ContractState.Finalized;
        savedState = ContractState.Finalized;

        // Send the KYCed ETH to where admins agree upon.
        _safe.transfer(allReceivedEth);
    }

    // Deliver tokens to be distributed to team members
    function deliverTeamTokens(address _to)
    external
    isFinalized
    onlyOwner
    {
        require(teamTokensDelivered == false);
        require(_to != address(0));

        // Company, advisors and supporters get 12% of a whole final pie
        // thus we need to add ~13.6% to the current totalSupply now
        // e.g. (100 - 12) * x = 100, where x amounts to roughly about 1.13636 and 12 is the be the team's final allocation
        uint256 newTotalSupply = SafeMath.mul(totalSupply, 113636) / 100000;

        // give company and supporters their 12% 
        uint256 tokens = SafeMath.sub(newTotalSupply, totalSupply);
        balances[_to] = tokens;

        //update state
        teamTokensDelivered = true;
        totalSupply = newTotalSupply;

        // Log the creation of these tokens
        LogTeamTokensDelivered(_to, tokens);
    }

}
