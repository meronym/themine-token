pragma solidity 0.4.18;

contract TrackingHolders {
    // For keeping track of holders (important for payouts later)
    mapping (address => bool) public isHolder;
    address[] public holders;

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
        internal
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
}
