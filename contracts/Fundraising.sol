pragma solidity 0.4.18;

import './ManagingState.sol';
import './StandardToken.sol';
import './TrackingHolders.sol';
import './usingOraclize.sol';


contract Fundraising is StandardToken, ManagingState, TrackingHolders, usingOraclize {
    uint8 public constant decimals = 18;

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

    // For checking if user has already undergone KYC or not, to lock up his tokens until then
    mapping (address => bool) public kycVerified;

    // For tracking if team members already got their tokens
    bool public teamTokensDelivered;

    // Events used for logging
    event LogRefund(address indexed _to, uint256 _value);
    event LogCreateMINE(address indexed _to, uint256 _value);
    event LogKycRejected(address indexed _user, uint256 _value);
    event LogTeamTokensDelivered(address indexed distributor, uint256 _value);

    modifier minimumReached() {
        require(totalSupply >= TOKEN_CREATED_MIN);
        _;
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
        stateFinalize();

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
}