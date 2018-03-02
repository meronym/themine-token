pragma solidity 0.4.18;

import './Fundraising.sol';
import './Minting.sol';

// Token contract code heavily inspired by FirstBlood, BAT and Envion

contract TheMineToken is ManagingAccess, ManagingState, Fundraising, Minting {
    // Token metadata
    string public constant name = 'TheMineToken';
    string public constant symbol = 'MINE';
    uint8 public constant decimals = 18;
    string public constant version = '0.2';

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

    // Check conditions for allowing the transfer of tokens
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

    // @dev for test purposes only
    function ping()
        external
        returns (bool success)
    {
        return true;
    }
}
