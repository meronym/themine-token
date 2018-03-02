const TheMineToken = artifacts.require("TheMineToken");

const promisify = (inner) =>
    new Promise((resolve, reject) =>
        inner((err, res) => {
            if (err) {
                console.log(err);
                reject(err);
            }
            resolve(res);
        })
    );

module.exports = async function(deployer) {
    const accounts = await promisify(cb => web3.eth.getAccounts(cb));
    const lastBlock = await promisify(cb => web3.eth.getBlockNumber(cb));
    const days = 24 * 60 * 4;

    const admin1 = accounts[1];
    const admin2 = accounts[2];
    const admin3 = accounts[3];
    const kycValidator = accounts[4];
    const presaleAccount = accounts[5];
    const fundingStartBlock = lastBlock + 2 * days;
    const fundingRoundDuration = 10 * days;
    const mintingPrepareDelay = 31 * days;
    const mintingCommitDelay = 31 * days;
    const maxContribution = web3.toWei(20);

    deployer.deploy(
        TheMineToken,
        admin1, admin2, admin3, kycValidator, presaleAccount,
        fundingStartBlock, fundingRoundDuration, mintingPrepareDelay, mintingCommitDelay,
        maxContribution
    );
};
