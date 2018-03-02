pragma solidity 0.4.18;

contract ManagingAccess {
    // Access management
    address public admin1;       // First administrator for multi-sig mechanism
    address public admin2;       // Second administrator for multi-sig mechanism
    address public admin3;       // Third (backup) administrator for multi-sig mechanism
    address public kycValidator; // Can approve or reject KYC checks

    // For storing the hashes of admins' msg.data
    mapping (address => bytes32) private multiSigHashes;

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
}