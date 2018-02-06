var TheMineToken = artifacts.require("TheMineToken");

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
    let accounts = await promisify(cb => web3.eth.getAccounts(cb));
    let lastBlock = await promisify(cb => web3.eth.getBlockNumber(cb));

    const admin1 = accounts[1];
    const admin2 = accounts[2];
    const admin3 = accounts[3];
    const kycValidator = accounts[4];
    const presaleAccount = accounts[5];
    const fundingStartBlock = lastBlock + 1000;
    const fundingRoundDuration = 10 * (24 * 60 * 4);
    const mintingAnnounceDelay = 31 * (24 * 60 * 4);

    deployer.deploy(
        TheMineToken,
        admin1, admin2, admin3, kycValidator, presaleAccount,
        fundingStartBlock, fundingRoundDuration, mintingAnnounceDelay
    );
};
