// Specifically request an abstraction for MetaCoin
var TheMineToken = artifacts.require("TheMineToken");

// function getSettings(accounts) {
//   return {
//     admin1: accounts[1],
//     admin2: accounts[2],
//     admin3: accounts[3],
//     kycValidator: accounts[4],
//     presaleAccount: accounts[5],
//     fundingStartBlock: web3.eth.getBlock('latest').number + 1000
//   };
// }

contract('TheMineToken', function(accounts) {
  // settings = getSettings(accounts);

  it("should allocate the presale tokens correctly", function() {
    return TheMineToken.deployed().then(function(instance) {
      return instance.balanceOf.call(accounts[5]);
    }).then(function(balance) {
      assert.equal(balance.valueOf(), 2 * 10**23, "the presale account didn't receive its tokens");
    });
  });

});
