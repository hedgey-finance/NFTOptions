import { expect } from 'chai';
import { Contract, Signer } from 'ethers';
import { ethers } from 'hardhat';
import moment from 'moment';

//const baseURI = 'https://nft.hedgey.finance/hardhat/';
const one = ethers.utils.parseEther('1');
const initialSupply = ethers.utils.parseEther('1000');
const tomorrow = moment().add(1, 'day').unix().toString();
const yesterday = moment().subtract(1, 'day').unix().toString();
const inseconds = moment().add(5, 'seconds').unix().toString();

describe('ContributorOptions exercise option', () => {
  let accounts: Signer[];
  let admin: Signer;
  let adminAddress: string;
  let weth: Contract;
  let contributorOptions: Contract;
  let token: Contract;

  before(async () => {
    accounts = await ethers.getSigners();
    admin = accounts[0];
    adminAddress = await admin.getAddress();

    const Weth = await ethers.getContractFactory('WETH9');
    weth = await Weth.deploy();

    const Token = await ethers.getContractFactory('Token');
    token = await Token.deploy(initialSupply, 'Token', 'TKN');

    const ContributorOptions = await ethers.getContractFactory('ContributorOptions');
    contributorOptions = await ContributorOptions.deploy('Hedgey Options', 'HGOPT', weth.address, adminAddress);
  });

  it('should excercise an option', async () => {
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

    await token.connect(holder).approve(contributorOptions.address, one);
    const exerciseOptionTransaction = await contributorOptions.connect(holder).exerciseOption(optionId);
    const exerciseOptionReceipt = await exerciseOptionTransaction.wait();
    const exerciseOptionEvent = exerciseOptionReceipt.events.find((event: any) => event.event === 'OptionExercised');
    const exerciseOptionId = exerciseOptionEvent.args['id'];
    await expect(exerciseOptionTransaction).to.emit(contributorOptions, 'OptionExercised').withArgs(exerciseOptionId);
  });

  it('only the owner of the option can exercise it', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    const notTheHolder = accounts[2];

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

    const exerciseOptionTransaction = contributorOptions.connect(notTheHolder).exerciseOption(optionId);
    await expect(exerciseOptionTransaction).to.be.revertedWith("OPT02");
  });

  it('should not allow exercise if the vest date has not been reached', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    await token.approve(contributorOptions.address, one);
    await token.transfer(holderAddress, one);

    const amount = one;
    const expiry = tomorrow;
    const vestDate = tomorrow;
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

    await token.connect(holder).approve(contributorOptions.address, one);
    const exerciseOptionTransaction = contributorOptions.connect(holder).exerciseOption(optionId);
    await expect(exerciseOptionTransaction).to.be.revertedWith("OPT03");
  });

  it('should not allow exercise if the option has expired', async () => {
    const holder = accounts[1];
    const holderAddress = await holder.getAddress();

    await token.approve(contributorOptions.address, one);
    await token.transfer(holderAddress, one);

    const amount = one;
    const expiry = inseconds;
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
    await new Promise((resolve) => setTimeout(resolve, 60000));
    await token.connect(holder).approve(contributorOptions.address, one);
    const exerciseOptionTransaction = contributorOptions.connect(holder).exerciseOption(optionId);
    await expect(exerciseOptionTransaction).to.be.revertedWith("OPT03");
  });
});
