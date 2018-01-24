const promisify = (inner) =>
  new Promise((resolve, reject) =>
    inner((err, res) => {
      if (err) { reject(err) }
      resolve(res);
    })
  );


module.exports = async function(callback) {
    // console.log(web3.eth.accounts);
    // web3.eth.getAccounts(function(error, result) {console.log(result);});
    
    const accounts = await promisify(cb => web3.eth.getAccounts(cb));
    
    console.log(accounts);

    let lastBlock = await promisify(cb => web3.eth.getBlockNumber(cb));

    console.log('Last Block:', lastBlock);

}
