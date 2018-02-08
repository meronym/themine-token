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
  let mintingAnnounceDelay = 10;

  let contract = await TheMineToken.new(
    acct.admin1, acct.admin2, acct.admin3, acct.kycValidator, acct.presaleAccount,
    fundingStartBlock, fundingRoundDuration, mintingAnnounceDelay
  );
  console.log(`address: ${contract.address} fundingStartBlock: ${fundingStartBlock}`);
  return contract;
}


async function getCurrentBlock() {
  return await promisify(cb => web3.eth.getBlockNumber(cb));
}

async function fastForward(untilBlock, contract) {
  let currentBlock = await getCurrentBlock();

  for(let i=0; i < untilBlock - currentBlock; i++) {
    await contract.ping();
  }
  
  let newCurrentBlock = await getCurrentBlock();
}


async function getExpectedTokenAmount(contract, sentValue) {
  // determine which bonus should be applied
  let currentBlock = await getCurrentBlock();
  let roundTwoBlock = await contract.roundTwoBlock();
  let roundThreeBlock = await contract.roundThreeBlock();
  let bonusMultiplier = 0;

  if (currentBlock < roundTwoBlock.toNumber()) {
    bonusMultiplier = await contract.TOKEN_FIRST_BONUS_MULTIPLIER();
  } else if (currentBlock < roundThreeBlock.toNumber()) {
    bonusMultiplier = await contract.TOKEN_SECOND_BONUS_MULTIPLIER();
  } else {
    bonusMultiplier = await contract.TOKEN_THIRD_BONUS_MULTIPLIER();
  }
  bonusMultiplier = bonusMultiplier.toNumber();

  let exchangeRate = await contract.ETH_USD_EXCHANGE_RATE_IN_CENTS();
  return exchangeRate.toNumber() * bonusMultiplier * parseInt(sentValue / 100 / 100);
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
  console.log(`moving to stage ${stage} at block #${goToBlock}`);
  await fastForward(goToBlock, contract);

  let currentBlock = await getCurrentBlock();
  assert.isAtLeast(currentBlock, goToBlock, `couldn't skip to block ${goToBlock}`);
}

contract('TheMineToken', async function(accounts) {
  const acct = allocateAccounts(accounts);

  it("shouldn't allocate user tokens before fundraising starts", async function() {
    let contract = await deployContract(acct);
    
    try {
      await contract.createTokens({from: acct.user1, value: web3.toWei(1)});
    } catch(e) {
      return true;
    }
    throw new Error("created tokens before fundingStartBlock");
  });

  it("should allocate user tokens after fundraising starts", async function() {
    let contract = await deployContract(acct);

    for(let [stage, user] of [[1, acct.user1], [2, acct.user2], [3, acct.user3]]) {
      await goToFundraisingStage(contract, stage);

      let sentValue = web3.toWei(1);
      let expectedBalance = await getExpectedTokenAmount(contract, sentValue);
      await contract.createTokens({from: user, value: sentValue});

      let actualBalance = await contract.balanceOf(user);
      assert.equal(actualBalance.toNumber(), expectedBalance);
    }
  });

  it("shouldn't allocate tokens after fundraising ends", async function() {
    let contract = await deployContract(acct);

    await goToFundraisingStage(contract, 4);

    try {
      await contract.createTokens({from: acct.user1, value: web3.toWei(1)});
    } catch(e) {
      return true;
    }
    throw new Error("created tokens after fundingEndBlock");   
  });

  it("shouldn't allocate tokens if the contract is paused during the funding round", async function() {
    let contract = await deployContract(acct);
    
    await goToFundraisingStage(contract, 1);
    await contract.pause({from: acct.admin1 });
    await contract.pause({from: acct.admin2 });

    let isPaused = await contract.state();
    assert.equal(isPaused.valueOf(), 2, "couldn't get contract to paused state");
    
    try {
      await contract.createTokens({from: acct.user1, value: web3.toWei(1)});
    } catch(e) {
      return true;
    }
    throw new Error("created tokens while the contract was paused");
  });

  it("shouldn't allow token transfers during the funding round", async function() {
    let contract = await deployContract(acct);

    await goToFundraisingStage(contract, 1);
    await contract.createTokens({from: acct.user1, value: web3.toWei(1)});

    let balance = await contract.balanceOf(acct.user1);
    assert.isAtLeast(balance.toNumber(), 1, "couldn't create tokens during fundraising");

    try {
      await contract.transfer(acct.user2, 1, {from: user1});
    } catch(e) {
      return true;
    }
    throw new Error("allowed token transfers during the funding round");
  });

  it("shouldn't allow token transfers before the funding is finalized", async function() {
    let contract = await deployContract(acct);

    await goToFundraisingStage(contract, 1);
    await contract.createTokens({from: acct.user1, value: web3.toWei(1)});

    let balance = await contract.balanceOf(acct.user1);
    assert.isAtLeast(balance.toNumber(), 1, "couldn't create tokens during fundraising");

    await goToFundraisingStage(contract, 4, 10);
    try {
      await contract.transfer(acct.user2, 1, {from: user1});
    } catch(e) {
      return true;
    }
    throw new Error("allowed token transfers before the contract is finalized");
  });

  it("shouldn't finalize the contract if minimum cap is not reached", async function() {
    let contract = await deployContract(acct);

    await goToFundraisingStage(contract, 1);
    await contract.createTokens({from: acct.user1, value: web3.toWei(1)})

    let balance = await contract.balanceOf(acct.user1);
    assert.isAtLeast(balance.toNumber(), 1, "couldn't create tokens during fundraising");

    await goToFundraisingStage(contract, 4, 10);

    try {
      await contract.finalize(acct.owner, {from: acct.admin1});  
      await contract.finalize(acct.owner, {from: acct.admin2});
    } catch(e) {
      return true;
    }
    throw new Error("contract finalized under minimum cap");
  });

  // it("should allow token transfers after the funding round is finalized", async function() {
  //   let state = await contract.state();
  //   assert.equal(state.toNumber(), 1, "couldn't finalize the funding round");

  //   await contract.transfer(acct.user2, 1, {from: acct.user1});
  //   balance = await contract.balanceOf(acct.user2);
  //   assert.equal(balance.toNumber(), 1, "tokens were not transferred");
  // });
});
