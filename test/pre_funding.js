var TheMineToken = artifacts.require("TheMineToken");

function allocateAccounts(accounts) {
  return {
    owner: accounts[0],
    admin1: accounts[1],
    admin2: accounts[2],
    admin3: accounts[3],
    kycValidator: accounts[4],
    presaleAccount: accounts[5],
    teamAccount: accounts[6],
    user1: accounts[7],
    user2: accounts[8],
    user3: accounts[9]
  };
}

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

async function deployContract(acct) {
  let lastBlock = await promisify(cb => web3.eth.getBlockNumber(cb));
  
  let fundingStartBlock = lastBlock + 10;
  let fundingRoundDuration = 10;
  let mintingPrepareDelay = 10;
  let mintingCommitDelay = 10;
  let maxContribution = web3.toWei(200);

  let contract = await TheMineToken.new(
    acct.admin1, acct.admin2, acct.admin3, acct.kycValidator, acct.presaleAccount,
    fundingStartBlock, fundingRoundDuration, mintingPrepareDelay, mintingCommitDelay,
    maxContribution
  );
  return contract;
}

contract('TheMineToken', async function(accounts) {
  const acct = allocateAccounts(accounts);
  
  it("should correctly register the admin and kycValidator addresses", async function() {
    let contract = await deployContract(acct);
    
    let admin1 = await contract.admin1.call();
    assert.equal(admin1, acct.admin1, "admin1 incorrectly set");
    
    let admin2 = await contract.admin2.call()
    assert.equal(admin2, acct.admin2, "admin2 incorrectly set");
    
    let admin3 = await contract.admin3.call()
    assert.equal(admin3, acct.admin3, "admin3 incorrectly set");
  });

  it("should correctly allocate the presale tokens", async function() {
    let contract = await deployContract(acct);
    let presaleTokens = await contract.TOKENS_PRESALE.call();    
    let presaleBalance = await contract.balanceOf.call(acct.presaleAccount);
    
    assert.equal(presaleBalance.toNumber(), presaleTokens, "the presale account didn't receive its tokens");
  });

  it("shouldn't change the funding start if only one admin requests it", async function() {
    let contract = await deployContract(acct);
    let fundingStartBlock = await contract.fundingStartBlock.call();

    // test for each individual admin
    for(let [index, admin] of [acct.admin1, acct.admin2, acct.admin3].entries()) {
      let reqFundingStartBlock = fundingStartBlock.toNumber() + 10 + index;
      let changetx = await contract.updateFundingStart(reqFundingStartBlock, {from: admin});
      
      let newFundingStartBlock = await contract.fundingStartBlock.call();
      assert.equal(newFundingStartBlock.toNumber(), fundingStartBlock.toNumber(), "a single admin triggered a change of the funding start block");
    }
  });

  it("should change the funding start if two admins request it", async function() {
    let contract = await deployContract(acct);
    let fundingStartBlock = await contract.fundingStartBlock.call();

    // test for each individual admin pair
    const adminPairs = [[acct.admin1, acct.admin2], [acct.admin1, acct.admin3], [acct.admin2, acct.admin3]];

    for(let [index, [adminA, adminB]] of adminPairs.entries()) {
      let reqFundingStartBlock = fundingStartBlock.toNumber() + 10 + index * 10;
      let changetxA = await contract.updateFundingStart(reqFundingStartBlock, {from: adminA});
      let changetxB = await contract.updateFundingStart(reqFundingStartBlock, {from: adminB});

      let newFundingStartBlock = await contract.fundingStartBlock.call();
      assert.equal(reqFundingStartBlock, newFundingStartBlock.toNumber(), "two admins couldn't trigger a change of the funding start block");
    }
  });

});
