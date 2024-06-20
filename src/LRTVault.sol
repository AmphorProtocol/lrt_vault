//SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {IERC7540, IERC165, IERC7540Redeem, IERC7540Deposit} from "./interfaces/IERC7540.sol";
import {ERC7540Receiver} from "./interfaces/ERC7540Receiver.sol";
import {IERC20, SafeERC20, Math, PermitParams} from "./SyncVault.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20Upgradeable, IERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

uint16 constant MAX_FEES = 3000; // 30%
uint256 constant YEAR = 24 * 3600 * 360;

/**
 * Asynchronous Vault inspired by ERC-7540
 */

/**
 * @dev This constant is used to divide the fees by 10_000 to get the percentage
 * of the fees.
 */
uint256 constant BPS_DIVIDER = 10_000;

uint256 constant RATE_DIVIDER = 10_000_000;

/*
 * ########
 * # LIBS #
 * ########
 */
using Math for uint256; // only used for `mulDiv` operations.
using SafeERC20 for IERC20; // `safeTransfer` and `safeTransferFrom`

/**
 * @title AsyncVault
 * @dev This structure contains all the informations needed to let user claim
 * their request after we processed those. To avoid rounding errors we store the
 * totalSupply and totalAssets at the time of the deposit/redeem for the deposit
 * and the redeem. We also store the amount of assets and shares given by the
 * user.
 */
struct EpochData {
    uint256 redeemRatio;
    uint256 totalSupplySnapshot;
    mapping(address => uint256) redeemRequestBalance;
}

/**
 * @title SettleValues
 * @dev Hold the required values to settle the vault deposit and
 * redeem requests.
 */
struct SettleValues {
    uint256 fees;
    uint256 pendingRedeem;
    uint256 assetsToWithdraw;
    uint256 totalSupplySnapshot;
}

/**
 * @title Silo
 * @dev This contract is used to hold the assets/shares of the users that
 * requested a deposit/redeem. It is used to simplify the logic of the vault.
 */
contract Silo {
    constructor(IERC20 underlying) {
        underlying.forceApprove(msg.sender, type(uint256).max);
    }
}

contract LRTVault is
    IERC7540Redeem,
    Ownable2StepUpgradeable,
    ERC20PermitUpgradeable,
    ERC20PausableUpgradeable
{
    event Deposit(
        address indexed sender,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    /*
     * ####################################
     * #  SYNTHETIC RELATED STORAGE #
     * ####################################
     */
    uint256 internal _min_rate; // guardrail
    uint256 internal current_rate;

    /**
     * @notice The epochId is used to keep track of the deposit and redeem
     * requests. It is incremented every time the owner calls the `settle`
     * function.
     */
    uint256 public epochId;

    /**
     * @notice The epochStart is used to compute the annualized fee rate.
     */
    uint256 public epochStart;

    bool public vaultIsOpen; // vault is open or closed
    uint256 public lastSavedBalance; // last saved balance
    IERC20 internal _asset; // underlying asset
    uint8 private _underlyingDecimals;

    error VaultIsClosed();
    error VaultIsOpen();
    error FeesTooHigh();
    error VaultIsEmpty(); // We cannot start an epoch with an empty vault
    error ERC4626ExceededMaxDeposit(
        address receiver,
        uint256 assets,
        uint256 max
    );
    error ERC4626ExceededMaxMint(address receiver, uint256 shares, uint256 max);
    error ERC4626ExceededMaxWithdraw(
        address owner,
        uint256 assets,
        uint256 max
    );
    error ERC4626ExceededMaxRedeem(address owner, uint256 shares, uint256 max);

    /**
     * @notice The treasury1 is used to store the address of the treasury1.
     * The treasury1 is used to store the fees taken from the vault.
     * The treasury1 can be the owner of the contract or a specific address.
     * The treasury1 can be changed by the owner of the contract.
     * The treasury1 can be used to store the fees taken from the vault.
     * The treasury1 can be the owner of the contract or a specific address.
     */
    address public treasury;
    uint16 public feesInBips;

    /**
     * @notice The lastSavedBalance is used to keep track of the assets in the
     * vault at the time of the last `settle` call.
     */
    Silo public pendingSilo;
    /**
     * @notice The claimableSilo is used to hold the assets/shares of the users
     * that requested a deposit/redeem.
     */
    Silo public claimableSilo;
    /**
     * @notice The epochs mapping is used to store the informations needed to
     * let user claim their request after we processed those. To avoid rounding
     * errors we store the totalSupply and totalAssets at the time of the
     * deposit/redeem for the deposit and the redeem. We also store the amount
     * of assets and shares given by the user.
     */
    mapping(uint256 epochId => EpochData epoch) public epochs;
    /**
     * @notice The lastRedeemRequestId is used to keep track of the last redeem
     * request made by the user. It is used to let the user claim their request
     * after we processed those.
     */
    mapping(address user => uint256 epochId) public lastRedeemRequestId;

    /*
     * ##########
     * # EVENTS #
     * ##########
     */
    event EpochStart(
        uint256 indexed timestamp,
        uint256 lastSavedBalance,
        uint256 totalShares
    );

    event EpochEnd(
        uint256 indexed timestamp,
        uint256 lastSavedBalance,
        uint256 returnedAssets,
        uint256 fees,
        uint256 totalShares
    );

    event FeesChanged(uint16 oldFees, uint16 newFees);

    /**
     * @notice This event is emitted when a user request a redeem.
     * @param requestId The id of the request.
     * @param owner The address of the user that requested the redeem.
     * @param previousRequestedShares The amount of shares requested by the user
     * before the new request.
     * @param newRequestedShares The amount of shares requested by the user.
     */
    event DecreaseRedeemRequest(
        uint256 indexed requestId,
        address indexed owner,
        uint256 indexed previousRequestedShares,
        uint256 newRequestedShares
    );

    /**
     * @notice This event is emitted when a user request a redeem.
     * @param requestId The id of the request.
     * @param owner The address of the user that requested the redeem.
     * @param receiver The amount of shares requested by the user
     * before the new request.
     * @param assets The amount of shares requested by the user.
     * @param shares The amount of shares requested by the user.
     */
    event ClaimRedeem(
        uint256 indexed requestId,
        address indexed owner,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );

    /*
     * ##########
     * # ERRORS #
     * ##########
     */

    /**
     * @notice This error is emitted when the user request more shares than the
     * maximum allowed.
     * @param receiver The address of the user that requested the redeem.
     * @param shares The amount of shares requested by the user.
     */
    error ExceededMaxRedeemRequest(
        address receiver,
        uint256 shares,
        uint256 maxShares
    );

    error MinRateReached();
    /**
     * @notice This error is emitted when the user try to make a new request
     * with an incorrect data.
     */
    error ReceiverFailed();
    /**
     * @notice This error is emitted when the user try to make a new request
     * on behalf of someone else.
     */
    error ERC7540CantRequestDepositOnBehalfOf();
    /**
     * @notice This error is emitted when the user try to make a request
     * when there is no claimable request available.
     */
    error NoClaimAvailable(address owner);
    /**
     * @notice This error is emitted when the user try to set an invalid address as treasury
     */
    error InvalidTreasury();

    /**
     * @notice This error is emitted when a method is not available
     */
    error UnavailableMethod();

    /*
     * ##############################
     * #  SYNTHETIC FUNCTIONS #
     * ##############################
     */

    modifier whenClosed() {
        if (vaultIsOpen) revert VaultIsOpen();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
         _disableInitializers();
    }

    function initialize(
        uint16 _fees,
        address _owner,
        address _treasury,
        IERC20 _underlying,
        uint256 bootstrapAmount,
        string memory name,
        string memory symbol,
		bool withBootstrap
    ) public initializer {
        epochId = 1;
        vaultIsOpen = true;
        _asset = _underlying;
        pendingSilo = new Silo(_underlying);
        claimableSilo = new Silo(_underlying);
        __ERC20_init(name, symbol);
        __Ownable_init(_owner);
        __ERC20Permit_init(name);
        __ERC20Pausable_init();
		if (withBootstrap ) {
			deposit(bootstrapAmount, _owner);
		}
        setTreasury(_treasury);
        setFees(_fees);
        _min_rate = 9_000_000; //90%
        current_rate = 10_000_000; // 100 %
    }

    function setMinRate(uint256 _rate) public onlyOwner {
        _min_rate = _rate;
    }

    /**
     * @dev The `_deposit` function is used to deposit the specified underlying
     * assets amount in exchange of a proportionnal amount of shares.
     * @param caller The address of the caller.
     * @param receiver The address of the shares receiver.
     * @param assets The underlying assets amount to be converted into shares.
     * @param shares The shares amount to be converted into underlying assets.
     */
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal {
        // If _asset is ERC777, transferFrom can trigger a reentrancy BEFORE the
        // transfer happens through the tokensToSend hook. On the other hand,
        // the tokenReceived hook, that is triggered after the transfer,calls
        // the vault, which is assumed not malicious.
        //
        // Conclusion: we need to do the transfer before we mint so that any
        // reentrancy would happen before the assets are transferred and before
        // the shares are minted, which is a valid state.
        // slither-disable-next-line reentrancy-no-eth
        _asset.safeTransferFrom(caller, owner(), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev The function `_withdraw` is used to withdraw the specified
     * underlying assets amount in exchange of a proportionnal amount of shares
     * by
     * specifying all the params.
     * @notice The `withdraw` function is used to withdraw the specified
     * underlying assets amount in exchange of a proportionnal amount of shares.
     * @param receiver The address of the shares receiver.
     * @param owner The address of the owner.
     * @param assets The underlying assets amount to be converted into shares.
     * @param shares The shares amount to be converted into underlying assets.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal {
        if (caller != owner) _spendAllowance(owner, caller, shares);

        _burn(owner, shares);
        _asset.safeTransfer(receiver, assets);

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override(ERC20Upgradeable, ERC20PausableUpgradeable) {
        ERC20PausableUpgradeable._update(from, to, value);
    }

    /**
     * SIMPLE VAULT VERSION : 1/1 conversion rate at deposit
     * @dev See {IERC4626-deposit}
     * @notice The `deposit` function is used to deposit underlying assets into
     * the vault.
     * @param assets The underlying assets amount to be converted into shares.
     * @param receiver The address of the shares receiver.
     * @return Amount of shares received in exchange of the
     * specified underlying assets amount.
     */
    function deposit(
        uint256 assets,
        address receiver
    ) public whenNotPaused returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }

        _deposit(_msgSender(), receiver, assets, assets);
        return assets;
    }

    // @return address of the underlying asset.
    function asset() public view returns (address) {
        return address(_asset);
    }

    /*
     * @dev The `maxDeposit` function is used to calculate the maximum deposit.
     * @notice If the vault is paused, users are not allowed to
     * deposit,
     * the maxDeposit is 0.
     * @return Amount of the maximum underlying assets deposit amount.
     */
    function maxDeposit(address) public view returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    /**
     * @dev The `mint` function is used to mint the specified amount of shares
     * in
     * exchange of the corresponding assets amount from owner.
     * @param shares The shares amount to be converted into underlying assets.
     * @param receiver The address of the shares receiver.
     * @return Amount of underlying assets deposited in exchange of the
     * specified
     * amount of shares.
     */
    function mint(
        uint256 shares,
        address receiver
    ) public whenNotPaused returns (uint256) {
        return deposit(shares, receiver);
    }

    /**
     * @dev See {IERC4626-maxRedeem}.
     * @notice If the function is called during the lock period the maxRedeem is
     * `0`;
     * @param owner The address of the owner.
     * @return Amount of the maximum number of redeemable shares.
     */
    function maxRedeem(address owner) public view returns (uint256) {
        return vaultIsOpen && !paused() ? balanceOf(owner) : 0;
    }

    /**
     * 1/1 redeem engine
     * @dev The `redeem` function is used to redeem the specified amount of
     * shares in exchange of the corresponding underlying assets amount from
     * owner.
     * @param shares The shares amount to be converted into underlying assets.
     * @param receiver The address of the shares receiver.
     * @param owner The address of the owner.
     * @return Amount of underlying assets received in exchange of the specified
     * amount of shares.
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public whenNotPaused returns (uint256) {
        uint256 maxShares = maxRedeem(owner);
        if (shares > maxShares) {
            revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        }
        uint256 assets = shares.mulDiv(
            current_rate,
            RATE_DIVIDER,
            Math.Rounding.Floor
        );
        _withdraw(_msgSender(), receiver, owner, assets, shares);
        return shares;
    }

    /**
     * @dev This function is used to decrease the amount of shares requested to
     * redeem by the user. It can only be called by the user who made the
     * request.
     * @param shares The amount of shares requested by the user.
     */
    function decreaseRedeemRequest(
        uint256 shares
    ) external whenClosed whenNotPaused {
        address owner = _msgSender();
        uint256 oldBalance = epochs[epochId].redeemRequestBalance[owner];
        epochs[epochId].redeemRequestBalance[owner] -= shares;
        _update(address(pendingSilo), owner, shares);

        emit DecreaseRedeemRequest(
            epochId,
            owner,
            oldBalance,
            epochs[epochId].redeemRequestBalance[owner]
        );
    }

    /*
     * ######################################
     * #  SYNTHETIC RELATED FUNCTIONS #
     * ######################################
     */

    /**
     * @dev The `setTreasury` function is used to set the treasury address.
     * It can only be called by the owner of the contract (`onlyOwner`
     * modifier).
     * @param _treasury The address of the treasury.
     */
    function setTreasury(address _treasury) public onlyOwner {
        if (_treasury == address(0)) revert InvalidTreasury();
        treasury = _treasury;
    }

    function setFees(uint16 _fees) public onlyOwner {
        if (_fees > MAX_FEES) revert FeesTooHigh();
        feesInBips = _fees;
    }

    function totalAssets() public view returns (uint256) {
        if (vaultIsOpen) return _asset.balanceOf(address(this));
        else return _asset.balanceOf(address(this)) + lastSavedBalance;
    }

    /**
     * @dev The `close` function is used to close the vault.
     * It can only be called by the owner of the contract (`onlyOwner`
     * modifier).
     */
    function close() external onlyOwner {
        if (!vaultIsOpen) revert VaultIsClosed();
        if (totalSupply() == 0) revert VaultIsEmpty();
        lastSavedBalance = totalSupply();
        vaultIsOpen = false;
        epochStart = block.timestamp;
        emit EpochStart(block.timestamp, totalSupply(), totalSupply());
    }

    /**
     * @dev The `open` function is used to open the vault.
     * @notice The `open` function is used to end the lock period of the vault.
     * It can only be called by the owner of the contract (`onlyOwner` modifier)
     * and only when the vault is locked.
     * If there are profits, the performance fees are taken and sent to the
     * owner of the contract.
     * @param assetReturned The underlying assets amount to be deposited into
     * the vault.
     */
    function open(
        uint256 assetReturned
    ) external onlyOwner whenNotPaused whenClosed {
        uint256 newBalance = _settle(assetReturned);
        vaultIsOpen = true;
        _asset.safeTransferFrom(owner(), address(this), newBalance);
    }

    /*
     * #################################
     * #   Permit RELATED FUNCTIONS    #
     * #################################
     */

    /**
     * @dev The `settle` function is used to settle the vault.
     * @notice The `settle` function is used to settle the vault. It can only be
     * called by the owner of the contract (`onlyOwner` modifier).
     * If there are profits, the performance fees are taken and sent to the
     * owner of the contract.
     * Since  strategies can be time sensitive, we must be able to switch
     * epoch without needing to put all the funds back.
     * Using _settle we can virtually put back the funds, check how much we owe
     * to users that want to redeem and maybe take the extra funds from the
     * deposit requests.
     * @param epochRate The underlying assets amount to be deposited into
     * the vault.
     */
    function settle(
        uint256 epochRate
    ) external onlyOwner whenNotPaused whenClosed {
        uint256 totalSupply = _settle(epochRate);

        epochStart = block.timestamp;
        emit EpochStart(block.timestamp, totalSupply, totalSupply);
    }

    /**
     * @dev pendingRedeemRequest is used to know how many shares are currently
     * waiting to be redeemed for the user.
     * @param owner The address of the user that requested the redeem.
     */
    function pendingRedeemRequest(
        address owner
    ) external view returns (uint256) {
        return epochs[epochId].redeemRequestBalance[owner];
    }

    /**
     * @dev How many shares are  virtually waiting for the user to be redeemed
     * via the `claimRedeem` function.
     * @param owner The address of the user that requested the redeem.
     */
    function claimableRedeemRequest(
        address owner
    ) external view returns (uint256) {
        uint256 lastRequestId = lastRedeemRequestId[owner];
        return
            isCurrentEpoch(lastRequestId)
                ? 0
                : epochs[lastRequestId].redeemRequestBalance[owner];
    }

    /**
     * @dev How many shares are  waiting to be redeemed for all users.
     * @return The amount of shares waiting to be redeemed.
     */
    function totalPendingRedeems() external view returns (uint256) {
        return vaultIsOpen ? 0 : balanceOf(address(pendingSilo));
    }

    /**
     * @dev How many assets are virtually waiting for the user to be deposit
     * via the `claimDeposit` function.
     * @return The amount of assets waiting to be deposited.
     */
    function totalClaimableAssets() external view returns (uint256) {
        return _asset.balanceOf(address(claimableSilo));
    }

    /**
     * @dev when the vault is closed, users can only request to redeem.
     * By doing this shares will be sent and wait in the pendingSilo.
     * When the owner will call the `open` or `settle` function, the shares will
     * be redeemed and the assets will be sent to the claimableSilo. Waiting for
     * the users to claim them.
     * @param shares The amount of shares requested by the user.
     * @param receiver The address of the user that requested the redeem.
     * @param owner The address of the user that requested the redeem.
     * @param data The data to be sent to the receiver.
     */
    function requestRedeem(
        uint256 shares,
        address receiver,
        address owner,
        bytes memory data
    ) public whenNotPaused whenClosed {
        if (_msgSender() != owner) {
            _spendAllowance(owner, _msgSender(), shares);
        }

        if (previewClaimRedeem(receiver) > 0) {
            _claimRedeem(receiver, receiver);
        }

        if (shares > maxRedeemRequest(owner)) {
            revert ExceededMaxRedeemRequest(
                receiver,
                shares,
                maxRedeemRequest(owner)
            );
        }

        _update(owner, address(pendingSilo), shares);
        // Create a new request
        _createRedeemRequest(shares, receiver, owner, data);
    }

    /**
     * @dev This function let users claim the assets we owe them after we
     * processed their redeem request, in the _settle function.
     * @param receiver The address of the user that requested the redeem.
     */
    function claimRedeem(
        address receiver
    ) public whenNotPaused returns (uint256 assets) {
        return _claimRedeem(_msgSender(), receiver);
    }

    /**
     * @dev users can request redeem only when the vault is closed and not
     * paused.
     * @param owner The address of the user that requested the redeem.
     * @return The maximum amount of shares the user can request.
     */
    function maxRedeemRequest(address owner) public view returns (uint256) {
        return vaultIsOpen || paused() ? 0 : balanceOf(owner);
    }

    /**
     * @dev This function let users preview how many assets they will get if
     * they claim their redeem request.
     * @param owner The address of the user that requested the redeem.
     * @return The amount of assets the user will get if they claim their
     * redeem request.
     */
    function previewClaimRedeem(address owner) public view returns (uint256) {
        uint256 lastRequestId = lastRedeemRequestId[owner];
        uint256 shares = epochs[lastRequestId].redeemRequestBalance[owner];
        uint256 rate = epochs[lastRequestId].redeemRatio;
        return shares.mulDiv(rate, RATE_DIVIDER, Math.Rounding.Floor);
    }

    /**
     * @dev This function claimableRedeemBalanceInAsset is used to know if the
     * owner will have to send money to the claimableSilo (for users who want to
     * leave the vault) or if he will receive money from it.
     * @param epochRate The underlying assets amount to be deposited into
     * the vault.
     * @return assetsToVault The amount of assets the user will get if
     * they claim their redeem request.
     * @return expectedAssetFromOwner The amount of assets that will be taken
     * from the owner.
     * @return redeemRatio the expected redeem redeemRatio post fees
     * from the owner.
     * @return settleValues The settle values.
     */
    function previewSettle(
        uint256 epochRate
    )
        public
        view
        returns (
            uint256 assetsToVault,
            uint256 expectedAssetFromOwner,
            uint256 redeemRatio,
            SettleValues memory settleValues
        )
    {
        if (epochRate < _min_rate) {
            revert MinRateReached();
        }

        uint256 supply = totalSupply();
        uint256 duration = block.timestamp - epochStart;
        // calculate the fees between lastSavedBalance and newSavedBalance
        uint256 _fees = _computeFees(supply, duration, feesInBips);

		redeemRatio =  _computeRealRate(epochRate, _fees, supply);

        address pendingSiloAddr = address(pendingSilo);
        uint256 pendingRedeem = balanceOf(pendingSiloAddr);

        uint256 assetsToWithdraw = pendingRedeem.mulDiv(
            epochRate,
            RATE_DIVIDER,
            Math.Rounding.Floor
        );

        settleValues = SettleValues({
            fees: _fees,
            pendingRedeem: pendingRedeem,
            assetsToWithdraw: assetsToWithdraw,
            totalSupplySnapshot: supply
        });

        assetsToVault = assetsToWithdraw;
        expectedAssetFromOwner = _fees + assetsToVault;
    }

    /**
     * @dev _createRedeemRequest is used to update the balance of the user in
     * order to create the redeem request.
     * @param shares The amount of shares requested by the user.
     * @param receiver The address of the user that requested the redeem.
     * @param owner The address of the user that requested the redeem.
     * @param data The data to be sent to the receiver.
     * @notice This function is used to update the balance of the user.
     */
    function _createRedeemRequest(
        uint256 shares,
        address receiver,
        address owner,
        bytes memory data
    ) internal {
        epochs[epochId].redeemRequestBalance[receiver] += shares;
        if (lastRedeemRequestId[receiver] != epochId) {
            lastRedeemRequestId[receiver] = epochId;
        }

        if (
            data.length > 0 &&
            ERC7540Receiver(receiver).onERC7540RedeemReceived(
                _msgSender(),
                owner,
                epochId,
                shares,
                data
            ) !=
            ERC7540Receiver.onERC7540RedeemReceived.selector
        ) revert ReceiverFailed();

        emit RedeemRequest(receiver, owner, epochId, _msgSender(), shares);
    }

    /**
     * @dev _claimRedeem is used to claim the pending redeem and request a new
     * one in one transaction.
     * @param owner The address of the user that requested the redeem.
     * @param receiver The address of the user that requested the redeem.
     * @return assets The amount of assets requested by the user.
     */
    function _claimRedeem(
        address owner,
        address receiver
    ) internal whenNotPaused returns (uint256 assets) {
        uint256 lastRequestId = lastRedeemRequestId[owner];
        if (lastRequestId == epochId) revert NoClaimAvailable(owner);

        assets = previewClaimRedeem(owner);

        uint256 shares = epochs[lastRequestId].redeemRequestBalance[owner];
        epochs[lastRequestId].redeemRequestBalance[owner] = 0;
        _asset.safeTransferFrom(address(claimableSilo), receiver, assets);
        emit ClaimRedeem(lastRequestId, owner, receiver, assets, shares);
    }

    /**
     * @dev _settle is used to settle the vault.
     * @param epochRate The underlying assets amount to be deposited into
     * the vault.
     * @return totalSupply The total supply.
     */
    function _settle(uint256 epochRate) internal returns (uint256) {
        (
            uint256 assetsToVault,
            ,
            uint256 redeemRatio,
            SettleValues memory settleValues
        ) = previewSettle(epochRate);

        emit EpochEnd(
            block.timestamp,
            totalSupply(),
            assetsToVault,
            settleValues.fees,
            totalSupply()
        );

        // transfer fees
        if (settleValues.fees > 0) {
            _asset.safeTransferFrom(owner(), treasury, settleValues.fees);
        }

        // Settle the shares balance
        _burn(address(pendingSilo), settleValues.pendingRedeem);

        _asset.safeTransferFrom(owner(), address(claimableSilo), assetsToVault);

        emit Withdraw(
            address(pendingSilo),
            address(claimableSilo),
            address(pendingSilo),
            settleValues.assetsToWithdraw,
            settleValues.pendingRedeem
        );

        epochs[epochId].totalSupplySnapshot = settleValues.totalSupplySnapshot;
        epochs[epochId].redeemRatio = redeemRatio;
        current_rate = redeemRatio;

        epochId++;

        return (totalSupply());
    }

    /**
     * @dev isCurrentEpoch is used to check if the request is the current epoch.
     * @param requestId The id of the request.
     */
    function isCurrentEpoch(uint256 requestId) internal view returns (bool) {
        return requestId == epochId;
    }

    // compute fees
    // the tvl is averaged during the period
    function _computeFees(
        uint256 supply,
        uint256 duration,
        uint256 annualBips
    ) public pure returns (uint256 fees) {
        if (annualBips == 0) {
            return 0;
        }
        uint256 annualized = (supply).mulDiv(
            duration,
            YEAR,
            Math.Rounding.Floor
        );
        fees = (annualized).mulDiv(
            annualBips,
            BPS_DIVIDER,
            Math.Rounding.Floor
        );
    }

    // computeRatio
    function _computeRealRate(
        uint256 _epochRate,
        uint256 _fees,
        uint256 _supply
    ) public pure returns (uint256) {
        uint256 numerator = (_supply).mulDiv(_epochRate,
            RATE_DIVIDER,
            Math.Rounding.Floor
        );
		numerator = (numerator - _fees)*RATE_DIVIDER;
		return numerator/(_supply);
    }

    /**
     * @dev see EIP
     * @param interfaceId The interface id to check for.
     * @return True if the contract implements the interface.
     */
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IERC7540Redeem).interfaceId;
    }
}
