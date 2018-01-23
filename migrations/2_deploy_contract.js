var TheMineToken = artifacts.require("TheMineToken");

module.exports = function(deployer) {
   deployToken(deployer);
};

function deployToken(deployer) {
    const accounts = web3.eth.accounts;
    const admin1 = accounts[1];
    const admin2 = accounts[2];
    const admin3 = accounts[3];
    const kycValidator = accounts[4];
    const presaleAccount = accounts[5];
    const fundingStartBlock = web3.eth.getBlock('latest').number + 1000;

    deployer.deploy(
        TheMineToken,
        admin1, admin2, admin3, kycValidator, fundingStartBlock, presaleAccount
    );
}
