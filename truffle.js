// Load deployment and account settings from the .settings file
var fs = require('fs');
var settings = JSON.parse(fs.readFileSync('.settings', 'utf8'));

var HDWalletProvider = require("truffle-hdwallet-provider");

module.exports = {
  // See http://truffleframework.com/docs/advanced/configuration
  networks: {
    development: {
      host: "127.0.0.1",
      port: 7545,
      network_id: "*", // Match any network id
      gas: 6700000,
      // gasPrice: 32000000000
    },
    rinkeby: {
      provider: function() {
        return new HDWalletProvider(settings.mnemonic, "https://rinkeby.infura.io/" + settings.infuraToken, 0, 10);
      },
      network_id: 4,
      gas: 6700000,
      // gasPrice: 32000000000
    }
  },
  solc: {
    optimizer: {
      enabled: true,
      runs: 200
    }
  }
};
