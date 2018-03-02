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
  // console.log(`address: ${contract.address} fundingStartBlock: ${fundingStartBlock}`);
  return contract;
}


async function getCurrentBlock () {
  return await promisify(cb => web3.eth.getBlockNumber(cb));
}

async function fastForward(untilBlock, contract) {
  let currentBlock = await getCurrentBlock();

  for(let i=0; i < untilBlock - currentBlock; i++) {
    await contract.ping();
  }
  
  let newCurrentBlock = await getCurrentBlock();
}

async function goToFundraisingStage(contract, stage, offset=0) {
  let goToBlock = 0;
  if (stage == 1) {
    goToBlock = await contract.fundingStartBlock.call();
  } else if (stage == 2) {
    goToBlock = await contract.roundTwoBlock.call();
  } else if (stage == 3) {
    goToBlock = await contract.roundThreeBlock.call();
  } else if (stage == 4) {
    goToBlock = await contract.fundingEndBlock.call();
  } else {
    throw new Error('invalid stage specified');
  }
  goToBlock = goToBlock.toNumber() + offset;
  // console.log(`moving to stage ${stage} at block #${goToBlock}`);
  await fastForward(goToBlock, contract);

  let currentBlock = await getCurrentBlock();
  assert.isAtLeast(currentBlock, goToBlock, `couldn't skip to block ${goToBlock}`);
}

async function finalizeSale(contract, acct) {
  // simulate a crowdfunding that exceeds minimum cap
  await goToFundraisingStage(contract, 1, 1);
  await contract.createTokens({from: acct.user1, value: web3.toWei(100)})
  await contract.createTokens({from: acct.user2, value: web3.toWei(100)})
  await contract.createTokens({from: acct.user3, value: web3.toWei(100)})

  let totalSupply = await contract.totalSupply();
  let minimumCap = await contract.TOKEN_CREATED_MIN();
  assert.isAtLeast(totalSupply.toNumber(), minimumCap.toNumber(), "couldn't create enough tokens to exceed minimum cap");

  // finalize the crowdfunding round
  await goToFundraisingStage(contract, 4, 10);
  await contract.finalize(acct.owner, {from: acct.admin1});  
  await contract.finalize(acct.owner, {from: acct.admin2});

  let state = await contract.state();
  assert.equal(state.toNumber(), 1, "couldn't finalize the funding round");
}

contract('TheMineToken', async function (accounts) {
  const acct = allocateAccounts(accounts);

  it("shouldn't allow minting before the funding round is finalized", async function() {
    let contract = await deployContract(acct);
    
    await goToFundraisingStage(contract, 4, 1);

    try {
      await contract.mintPrepare(acct.owner, web3.toWei(100), {from: acct.admin1});
      await contract.mintPrepare(acct.owner, web3.toWei(100), {from: acct.admin3});
    } catch(e) {
      return true;
    }
    throw new Error("allowed token minting before the funding round is finalized");
  });

  it("should allow minting after the funding round is finalized", async function() {
    let contract = await deployContract(acct);
    
    await finalizeSale(contract, acct);
      
    let balanceBefore = await contract.balanceOf(acct.owner);
    let supplyBefore = await contract.totalSupply();
    let mintedValue = web3.toWei(100);

    let currentBlock = await getCurrentBlock();
    let mintingPrepareDelay = await contract.mintingPrepareDelay();
    await fastForward(currentBlock + mintingPrepareDelay.toNumber() + 1, contract);

    await contract.mintPrepare(acct.owner, mintedValue, {from: acct.admin1});
    await contract.mintPrepare(acct.owner, mintedValue, {from: acct.admin2});

    currentBlock = await getCurrentBlock();
    let mintingCommitDelay = await contract.mintingCommitDelay();
    await fastForward(currentBlock + mintingCommitDelay.toNumber() + 1, contract);

    await contract.mintCommit({from: acct.admin2});
    await contract.mintCommit({from: acct.admin3});

    let balanceAfter = await contract.balanceOf(acct.owner);
    let supplyAfter = await contract.totalSupply();

    // FIXME should actually match correctly, but it spits an error due to JS big number math issues
    assert.equal(
      balanceAfter.minus(balanceBefore).toNumber(),
      mintedValue,
      "minting didn't increase token the balance of mintAddress"
    );
    assert.equal(
      supplyAfter.minus(supplyBefore).toNumber(),
      mintedValue,
      "minting didn't increase the total token supply"
    );
  });

})
