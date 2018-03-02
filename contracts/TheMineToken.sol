pragma solidity 0.4.18;

import './StandardToken.sol';
import './usingOraclize.sol';

// Token contract code heavily inspired by FirstBlood, BAT and Envion

contract TheMineToken is StandardToken, usingOraclize {
    // Token metadata
    string public constant name = 'TheMineToken';
    string public constant symbol = 'MINE';
    uint8 public constant decimals = 18;
    string public constant version = '0.2';

    // Fundraising goals: minimums and maximums
    uint256 public constant dec_multiplier = uint(10) ** decimals;
    uint256 public constant TOKEN_CREATION_CAP = 53 * (10**5) * dec_multiplier; // 5.3 million tokens
    uint256 public constant TOKEN_CREATED_MIN = 5 * (10**5) * dec_multiplier;   // 500 000 tokens
    uint256 public constant TOKEN_MIN = 1 * dec_multiplier;                     // 1 MINE token
    uint256 public constant TOKENS_PRESALE = 2 * (10**5) * dec_multiplier;      // 200 000 tokens

    // Bonus multipliers
    uint256 public constant TOKEN_FIRST_BONUS_MULTIPLIER  = 110;    // 10% bonus
    uint256 public constant TOKEN_SECOND_BONUS_MULTIPLIER = 105;    // 5% bonus
    uint256 public constant TOKEN_THIRD_BONUS_MULTIPLIER  = 100;    // 0% bonus

    // Fundraising parameters provided when creating the contract
    uint256 public fundingStartBlock; // block number that triggers the fundraising start
    uint256 public fundingRoundDuration; // round duration expressed in blocks (determines the timestamps below)
    uint256 public roundTwoBlock;     // block number that triggers the second exchange rate change
    uint256 public roundThreeBlock;   // block number that triggers the third exchange rate change
    uint256 public fundingEndBlock;   // block number that guards for the time constraint

    // Per account limits
    uint256 public minContribution = 2 * (uint(10) ** 17);   // 0.2 ETH
    uint256 public maxContribution;                          // provided at contract creation

    // Current ETH/USD exchange rate, to be updated by Oraclize every 6 hours
    uint256 public ETH_USD_EXCHANGE_RATE_IN_CENTS;

    // Everything oraclize related
    event updatedPrice(string price);
    event newOraclizeQuery(string description);
    uint public oraclizeQueryCost;

    // ETH balance per user
    // Since we have different exchange rates at different stages, we need to keep track
    // of how much ether each address contributed in case that we need to issue a refund
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

    // For keeping track of holders (important for payouts)
    mapping (address => bool) public isHolder;
    address[] public holders;

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
        if ((msg.sender != admin1 && multiSigHashes[msg.sender] == multiSigHashes[admin1]) ||
            (msg.sender != admin2 && multiSigHashes[msg.sender] == multiSigHashes[admin2]) ||
            (msg.sender != admin3 && multiSigHashes[msg.sender] == multiSigHashes[admin3])) {
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
        onlyOwner   // Only both admins calling this method can resume the contract
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
        require(mintFinalizedBlock + mintingPrepareDelay < block.number);
        require(_to != address(0));
        require(_value > 0);
        
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
        
        // Minimum 31 days (at 4 blocks per minute) must have passed since the last mintPrepare()
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

    modifier transfersAllowed(address _from) {
        require(
            // Do not allow transfers if the contract is Paused
            state != ContractState.Paused &&
            // Do not allow transfers during the first ICO
            (block.number < fundingStartBlock || state == ContractState.Finalized) &&
            // Only allow transfers during the next token sales if they originate from the
            // specified ICO contract address (in order to distribute the minted tokens)
            (currentMintingState != MintingState.Committed || _from == mintAddress));
        _;
    }

    // Allows to figure out the amount of known token holders
    function getHolderCount()
        public
        constant
        returns (uint256 _holderCount)
    {
        return holders.length;
    }

    // Allows for easier retrieval of holder by array index
    function getHolder(uint256 _index)
        public
        constant
        returns (address _holder)
    {
        return holders[_index];
    }

    function trackHolder(address _to)
        private
        returns (bool success)
    {
        // Check if the recipient is a known token holder
        if (isHolder[_to] == false) {
            // if not, add him to the holders array and mark him as a known holder
            holders.push(_to);
            isHolder[_to] = true;
        }
        return true;
    }

    // Overridden method to check for state conditions before allowing transfer of tokens
    function transfer(address _to, uint256 _value)
        public
        transfersAllowed(msg.sender)
        returns (bool success)
    {
        bool result = super.transfer(_to, _value);
        if (result) {
            trackHolder(_to); // track the owner for later payouts
        }
        return result;
    }

    // Overridden method to check for state conditions before allowing transfer of tokens
    function transferFrom(address _from, address _to, uint256 _value)
        public
        transfersAllowed(msg.sender)
        returns (bool success)
    {
        bool result = super.transferFrom(_from, _to, _value);
        if (result) {
            trackHolder(_to); // track the owner for later payouts
        }
        return result;
    }

    // Token contract constructor
    function TheMineToken(
        address _admin1,
        address _admin2,
        address _admin3,
        address _kycValidator,
        address _presaleAccount,
        uint256 _fundingStartBlock,
        uint256 _fundingRoundDuration,
        uint256 _mintingPrepareDelay,
        uint256 _mintingCommitDelay,
        uint256 _maxContribution
    )
        public
        payable 
    {
        // Make sure the production contract is initialized with the right values
        // require(_fundingRoundDuration == 10 * (24 * 60 * 4))     // 10 days with 15s block time
        // require(_mintingPrepareDelay == 31 * (24 * 60 * 4))      // 31 days with 15s block time
        // require(_mintingCommitDelay == 31 * (24 * 60 * 4))       // 31 days with 15s block time
        require(_fundingRoundDuration > 0);
        require(_mintingPrepareDelay > 0);
        require(_mintingCommitDelay > 0);
        require(_maxContribution > 0);

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
        admin3 = _admin3;
        kycValidator = _kycValidator;

        // Init contract state
        state = ContractState.Fundraising;
        savedState = ContractState.Fundraising;

        // Set contribution thresholds
        minContribution = 2 * (uint(10) ** 17); // 0.2 ETH
        // require(_maxContribution == 2 * (uint(10) ** 19));       // 20 ETH
        maxContribution = _maxContribution;

        // Round duration blocks
        fundingStartBlock = _fundingStartBlock;
        fundingRoundDuration = _fundingRoundDuration;
        roundTwoBlock = _fundingStartBlock + fundingRoundDuration;
        roundThreeBlock = _fundingStartBlock + 2 * fundingRoundDuration;
        fundingEndBlock = _fundingStartBlock + 3 * fundingRoundDuration;

        // Minting state
        mintingPrepareDelay = _mintingPrepareDelay;
        mintingCommitDelay = _mintingCommitDelay;
        currentMintingState = MintingState.NotStarted;

        // Allocate the presale tokens
        totalSupply = TOKENS_PRESALE;
        balances[_presaleAccount] = TOKENS_PRESALE;
        trackHolder(_presaleAccount);

        // TODO to be set by oraclize
        ETH_USD_EXCHANGE_RATE_IN_CENTS = 1000 * 100;    // 1000 USD in cents

        // Oraclize 
        // oraclize_setCustomGasPrice(100000000000 wei); // set the gas price a little bit higher, so the pricefeed definitely works
        // updatePrice();
        // oraclizeQueryCost = oraclize_getPrice("URL");
    }

    //// oraclize START
    // @dev oraclize is called recursively here - once a callback fetches the newest ETH price, the next callback is scheduled for the next hour again
    function __callback(bytes32 myid, string result)
        public
    {
        require(msg.sender == oraclize_cbAddress());

        // setting the token price here
        ETH_USD_EXCHANGE_RATE_IN_CENTS = SafeMath.parse(result);
        updatedPrice(result);

        // fetch the next price
        updatePrice();
    }

    function updatePrice()
        public  // can be left public as a way for replenishing contract's ETH balance, just in case
        payable 
    {
        if (msg.sender != oraclize_cbAddress()) {
            require(msg.value >= 200 finney);
        }
        if (oraclize_getPrice("URL") > this.balance) {
            newOraclizeQuery("Oraclize query was NOT sent, please add some ETH to cover for the query fee");
        } else {
            newOraclizeQuery("Oraclize sent, wait..");
            // Schedule query in 6 hours. Set the gas amount to 220000, as parsing in __callback takes around 70000 - we play it safe.
            oraclize_query(21600, "URL", "json(https://min-api.cryptocompare.com/data/price?fsym=ETH&tsyms=USD).USD", 220000);
        }
    }
    //// oraclize END

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
        roundTwoBlock = _fundingStartBlock + fundingRoundDuration;
        roundThreeBlock = _fundingStartBlock + 2*fundingRoundDuration;
        fundingEndBlock = _fundingStartBlock + 3*fundingRoundDuration;
    }

    // Returns the current token price
    function getCurrentBonusRate()
        private
        constant
        returns (uint256 currentBonusRate)
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
        external
        payable
        isFundraising
    {
        require(block.number >= fundingStartBlock);
        require(block.number <= fundingEndBlock);
        require(msg.value >= minContribution);

        // Calculate how many tokens need to be allocated
        uint256 valueUsd = SafeMath.mul(msg.value, ETH_USD_EXCHANGE_RATE_IN_CENTS) / 100;
        uint256 tokens = SafeMath.mul(valueUsd, getCurrentBonusRate()) / 100;
        uint256 checkedSupply = SafeMath.add(totalSupply, tokens);
        
        // Assign a variable to later compute the total contribution of this sender
        uint256 newBalance = 0;

        // Check the minimum amount of tokens and the token cap
        require(tokens >= TOKEN_MIN);
        require(checkedSupply <= TOKEN_CREATION_CAP);

        // Only when all the checks have passed, we check if the address is already KYCEd and then 
        // update the state (noKycEthBalances, allReceivedEth, totalSupply, and balances) of the contract
        if (kycVerified[msg.sender] == false) {
            // Check for a maximum contribution of 20 ETH
            newBalance = SafeMath.add(noKycEthBalances[msg.sender], msg.value);
            require(newBalance <= maxContribution);

            // @dev The unKYCed eth balances are moved to main ethBalances after approveKyc()
            noKycEthBalances[msg.sender] = newBalance;

            // Add the contributed eth to the total unKYCed eth amount
            allUnKycedEth = SafeMath.add(allUnKycedEth, msg.value);
        } else {
            // Check for a maximum contribution of 20 ETH
            newBalance = SafeMath.add(ethBalances[msg.sender], msg.value);
            require(newBalance <= maxContribution);

            // If buyer is already KYC approved, assign the Eth to the main pool
            ethBalances[msg.sender] = newBalance;
            allReceivedEth = SafeMath.add(allReceivedEth, msg.value);
        }

        totalSupply = checkedSupply;
        balances[msg.sender] += tokens;  // safeAdd not needed

        // Track token holder for future use cases (reward distribution)
        trackHolder(msg.sender);

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

        // check if the user has active unKYCed ethers
        if (noKycEthBalances[_owner] > 0) {
            // now move the unKYCed Eth balance to the regular ethBalance
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
        // require(block.number > (fundingEndBlock + 42000));
        require(block.number > fundingEndBlock);

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
        // Only allow to finalize the contract before the ending block if we already reached the minimum cap
        require(block.number > fundingEndBlock || totalSupply >= TOKEN_CREATED_MIN);
        
        // make sure a recipient was defined
        require(_safe != address(0));

        // Move the contract to Finalized state
        state = ContractState.Finalized;
        savedState = ContractState.Finalized;
        mintFinalizedBlock = block.number;

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

        // Company, team, advisors and supporters get 13% of a whole final pie
        // (100 - 13) * x = 100, where 13 is the team's final allocation and x amounts to roughly about 1.14942
        // thus we need to increase the current totalSupply with ~14.9%
        uint256 newTotalSupply = SafeMath.mul(totalSupply, 114942) / 100000;
        uint256 newTokens = SafeMath.sub(newTotalSupply, totalSupply);

        // Give bounty manager 2/13 of the allocation
        // FIXME Replace with the real bounty manager address
        address bountyManager = address(0x68dd77f8d88236cb47e0956467e053a3d21503cb);
        uint256 bountyTokens = SafeMath.mul(newTokens, 2) / 13;
        balances[bountyManager] = bountyTokens;
        
        // Give company, team and advisors the remaining 11/13 from the allocation
        uint256 teamTokens = SafeMath.sub(newTokens, bountyTokens);
        balances[_to] = teamTokens;

        // Update state
        teamTokensDelivered = true;
        totalSupply = newTotalSupply;

        // Track the recipient addresses
        trackHolder(bountyManager);
        trackHolder(_to);

        // Log the creation of these tokens
        LogTeamTokensDelivered(bountyManager, bountyTokens);
        LogTeamTokensDelivered(_to, teamTokens);
    }

    // @dev for test purposes only
    function ping()
        external
        returns (bool success)
    {
        return true;
    }
}
