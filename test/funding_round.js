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

async function goToFundraisingStage(contract, stage) {
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
  goToBlock = goToBlock.toNumber();
  console.log(`moving to stage ${stage} at block #${goToBlock}`);
  await fastForward(goToBlock, contract);
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

});  
