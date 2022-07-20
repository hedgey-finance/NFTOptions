import { expect } from 'chai';
import { Contract, Signer } from 'ethers';
import { ethers } from 'hardhat';
import moment from 'moment';

//const baseURI = 'https://nft.hedgey.finance/hardhat/';
const one = ethers.utils.parseEther('1');
const initialSupply = ethers.utils.parseEther('1000');
const tomorrow = moment().add(1, 'day').unix().toString();
const yesterday = moment().subtract(1, 'day').unix().toString();


describe('NFTOptions transfering options', () => {
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

  it('should transfer option', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    await token.approve(contributorOptions.address, one);
    await token.transfer(holderAddress, one);

    const amount = one;
    const expiry = tomorrow;
    const vestDate = yesterday;
    const swappable = false;
    const paymentCurrency = token.address;
    const strike = one;

    const createOptionTransaction = await contributorOptions.createOption(
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

    const transferedOption = await contributorOptions
      .connect(holder)
      .transferFrom(holderAddress, adminAddress, optionId);
    const transferReceipt = await transferedOption.wait();
    const transferEvent = transferReceipt.events.find((event: any) => event.event === 'Transfer');
    const from = transferEvent.args['from'];
    const to = transferEvent.args['to'];
    const tokenId = transferEvent.args['tokenId'];
    await expect(transferedOption).to.emit(contributorOptions, 'Transfer').withArgs(from, to, tokenId);
  });

  it('unvested options cannot be transferred', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    await token.approve(nftOptions.address, one);
    await token.transfer(holderAddress, one);

    const amount = one;
    const expiry = tomorrow;
    const vestDate = tomorrow;
    const swappable = false;
    const paymentCurrency = token.address;
    const strike = one;

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

    await expect(
      nftOptions.connect(holder).transferFrom(holderAddress, adminAddress, optionId)
    ).to.be.revertedWith('OPT03');
  });
  it('expired options cannot be transferred', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    await token.approve(nftOptions.address, one);
    await token.transfer(holderAddress, one);

    const amount = one;
    const expiry = (Math.round(Date.now()/1000)+40).toString();
    const vestDate = yesterday;
    const swappable = false;
    const paymentCurrency = token.address;
    const strike = one;

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
    await new Promise((resolve) => setTimeout(resolve, 2000));
    await expect(
      nftOptions.connect(holder).transferFrom(holderAddress, adminAddress, optionId)
    ).to.be.revertedWith('OPT03');
  });
});
