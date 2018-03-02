# Setting up the testing environment

The test suite needs access to an Ethereum blockchain that:

- has 10 accounts generated deterministically from the seed phrase "fun prepare manage hat cereal job enforce nominee desk manage group super"
- the accounts are credited with at least 1000 test ethers each (in order to test the large contribution limits of the fundraise)

A simple way to setup a stable environment with these parameters is to install and run `ganache-cli` through Docker:

```bash
$ docker run -d -p 8545:8545 trufflesuite/ganache-cli:latest -e 10000 -s "fun prepare manage hat cereal job enforce nominee desk manage group super"
```

At this point the entire test suite can be run with
```bash
$ truffle test
```
