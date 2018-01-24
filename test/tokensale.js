// Specifically request an abstraction for MetaCoin
var TheMineToken = artifacts.require("TheMineToken");

function allocateAccounts(accounts) {
  return {
    admin1: accounts[1],
    admin2: accounts[2],
    admin3: accounts[3],
    kycValidator: accounts[4],
    presaleAccount: accounts[5],
  };
}

contract('TheMineToken', async function(accounts) {
  acct = allocateAccounts(accounts);

  it("should allocate the presale tokens correctly", async function() {
    let contract = await TheMineToken.deployed();
    let presaleBalance = await contract.balanceOf.call(acct.presaleAccount);
    
    assert.equal(presaleBalance.valueOf(), 2 * 10**23, "the presale account didn't receive its tokens");
  });

  // it("shouldn't change the funding start if only one admin signs", async function() {
  //   let contract = await TheMineToken.deployed();
  //   let fundingStartBlock = await contract.fundingStartBlock.call().valueOf();

  //   let a1changetx = await contract.updateFundingStart(fundingStartBlock + 1000);
    
  //   let newfundingStartBlock = await contract.fundingStartBlock.call();

  //   assert.equal(newfundingStartBlock, fundingStartBlock, "a single admin triggered a change of the funding start block");  
  // });

});
