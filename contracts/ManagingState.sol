pragma solidity 0.4.18;

import './ManagingAccess.sol';

contract ManagingState is ManagingAccess {
    // Contract state management
    enum ContractState { Fundraising, Finalized, Paused }
    ContractState public state;         // Current state of the contract
    ContractState internal savedState;   // State of the contract before being paused
    uint256 public finalizedBlock;

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

    // finalize the funding round and save the block height for future reference
    function stateFinalize()
        internal
    {
        state = ContractState.Finalized;
        savedState = ContractState.Finalized;
        finalizedBlock = block.number;
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
}
