import { expect } from 'chai';
import { BigNumber, Contract, Signer } from 'ethers';
import { ethers } from 'hardhat';
import moment from 'moment';

//const baseURI = 'https://nft.hedgey.finance/hardhat/';
const one = ethers.utils.parseEther('1');
const initialSupply = ethers.utils.parseEther('1000');
const tomorrow = moment().add(1, 'day').unix().toString();
const yesterday = moment().subtract(1, 'day').unix().toString();

describe('NFTOptions create option', () => {
  let accounts: Signer[];
  let admin: Signer;
  let adminAddress: string;
  let weth: Contract;
  let nftOptions: Contract;
  let token: Contract;

  before(async () => {
    accounts = await ethers.getSigners();
    admin = accounts[0];
    adminAddress = await admin.getAddress();

    const Weth = await ethers.getContractFactory('WETH9');
    weth = await Weth.deploy();

    const Token = await ethers.getContractFactory('Token');
    token = await Token.deploy(initialSupply, 'Token', 'TKN');

    const NFTOptions = await ethers.getContractFactory('NFTOptions');
    nftOptions = await NFTOptions.deploy('Hedgey Options', 'HGOPT', weth.address, adminAddress);
  });

  it('should create an option with a token', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    await token.approve(nftOptions.address, one);

    const amount = one;
    const expiry = tomorrow;
    const vestDate = yesterday;
    const swappable = false;
    const paymentCurrency = token.address;
    const strike = one;
    const balanceBefore = await nftOptions.balanceOf(holderAddress);

    const createOptionTransaction = await nftOptions.createOption(
      holderAddress,
      amount,
      token.address,
      expiry,
      vestDate,
      strike,
      paymentCurrency,
      swappable
    );
    const receipt = await createOptionTransaction.wait();
    const event = receipt.events.find((event: any) => event.event === 'OptionCreated');
    const optionId = event.args['id'];

    await expect(createOptionTransaction)
      .to.emit(nftOptions, 'OptionCreated')
      .withArgs(
        optionId,
        holderAddress,
        one,
        token.address,
        expiry,
        vestDate,
        strike,
        paymentCurrency,
        adminAddress,
        swappable
      );
    const balance = await nftOptions.balanceOf(holderAddress);
    expect(balance).to.be.eq(balanceBefore.add(1));
  });

  it('should create an option with weth', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();
    await weth.deposit({ value: one });
    const amount = one;
    const expiry = tomorrow;
    const vestDate = yesterday;
    const swappable = false;
    const paymentCurrency = weth.address;
    const strike = one;
    const balanceBefore = await nftOptions.balanceOf(holderAddress);
    const createOptionTransaction = await nftOptions.createOption(
      holderAddress,
      amount,
      weth.address,
      expiry,
      vestDate,
      strike,
      paymentCurrency,
      swappable
    );
    const receipt = await createOptionTransaction.wait();
    const event = receipt.events.find((event: any) => event.event === 'OptionCreated');
    const optionId = event.args['id'];

    await expect(createOptionTransaction)
      .to.emit(nftOptions, 'OptionCreated')
      .withArgs(
        optionId,
        holderAddress,
        one,
        weth.address,
        expiry,
        vestDate,
        strike,
        paymentCurrency,
        adminAddress,
        swappable
      );
    const balance = await nftOptions.balanceOf(holderAddress);
    expect(balance).to.be.eq(balanceBefore.add(1));
  });
});
