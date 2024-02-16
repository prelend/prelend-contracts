// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {VersionedInitializable} from "../libraries/aave-upgradeability/VersionedInitializable.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {ReserveConfiguration} from "../libraries/configuration/ReserveConfiguration.sol";
import {PoolLogic} from "../libraries/logic/PoolLogic.sol";
import {ReserveLogic} from "../libraries/logic/ReserveLogic.sol";
import {EModeLogic} from "../libraries/logic/EModeLogic.sol";
import {SupplyLogic} from "../libraries/logic/SupplyLogic.sol";
import {FlashLoanLogic} from "../libraries/logic/FlashLoanLogic.sol";
import {BorrowLogic} from "../libraries/logic/BorrowLogic.sol";
import {LiquidationLogic} from "../libraries/logic/LiquidationLogic.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {BridgeLogic} from "../libraries/logic/BridgeLogic.sol";
import {IERC20WithPermit} from "../../interfaces/IERC20WithPermit.sol";
import {IPoolAddressesProvider} from "../../interfaces/IPoolAddressesProvider.sol";
import {IPool} from "../../interfaces/IPool.sol";
import {IACLManager} from "../../interfaces/IACLManager.sol";
import {PoolStorage} from "./PoolStorage.sol";
import {IERC20Detailed} from "../../interfaces/IERC20Detailed.sol";
import {IAToken} from "../../interfaces/IAToken.sol";
import {IVariableDebtToken} from "../../interfaces/IVariableDebtToken.sol";
import {IStableDebtToken} from "../../interfaces/IStableDebtToken.sol";
import {SafeCast} from '../../dependencies/openzeppelin/contracts/SafeCast.sol';

/**
 * @title Pool contract
 * @author Aave
 * @notice Main point of interaction with an Aave protocol's market
 * - Users can:
 *   # Supply
 *   # Withdraw
 *   # Borrow
 *   # Repay
 *   # Swap their loans between variable and stable rate
 *   # Enable/disable their supplied assets as collateral rebalance stable rate borrow positions
 *   # Liquidate positions
 *   # Execute Flash Loans
 * @dev To be covered by a proxy contract, owned by the PoolAddressesProvider of the specific market
 * @dev All admin functions are callable by the PoolConfigurator contract defined also in the
 *   PoolAddressesProvider
 */
contract Pool is VersionedInitializable, PoolStorage, IPool {
    using ReserveLogic for DataTypes.ReserveData;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    uint256 public constant POOL_REVISION = 0x1;
    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /**
     * @dev Only pool configurator can call functions marked by this modifier.
     */
    modifier onlyPoolConfigurator() {
        _onlyPoolConfigurator();
        _;
    }

    /**
     * @dev Only pool admin can call functions marked by this modifier.
     */
    modifier onlyPoolAdmin() {
        _onlyPoolAdmin();
        _;
    }

    /**
     * @dev Only bridge can call functions marked by this modifier.
     */
    modifier onlyBridge() {
        _onlyBridge();
        _;
    }

    function _onlyPoolConfigurator() internal view virtual {
        require(
            ADDRESSES_PROVIDER.getPoolConfigurator() == msg.sender,
            Errors.CALLER_NOT_POOL_CONFIGURATOR
        );
    }

    function _onlyPoolAdmin() internal view virtual {
        require(
            IACLManager(ADDRESSES_PROVIDER.getACLManager()).isPoolAdmin(
                msg.sender
            ),
            Errors.CALLER_NOT_POOL_ADMIN
        );
    }

    function _onlyBridge() internal view virtual {
        require(
            IACLManager(ADDRESSES_PROVIDER.getACLManager()).isBridge(
                msg.sender
            ),
            Errors.CALLER_NOT_BRIDGE
        );
    }

    function getRevision() internal pure virtual override returns (uint256) {
        return POOL_REVISION;
    }

    /**
     * @dev Constructor.
     * @param provider The address of the PoolAddressesProvider contract
     */
    constructor(IPoolAddressesProvider provider) {
        ADDRESSES_PROVIDER = provider;
    }

    /**
     * @notice Initializes the Pool.
     * @dev Function is invoked by the proxy contract when the Pool contract is added to the
     * PoolAddressesProvider of the market.
     * @dev Caching the address of the PoolAddressesProvider in order to reduce gas consumption on subsequent operations
     * @param provider The address of the PoolAddressesProvider
     */
    function initialize(
        IPoolAddressesProvider provider
    ) external virtual initializer {
        require(
            provider == ADDRESSES_PROVIDER,
            Errors.INVALID_ADDRESSES_PROVIDER
        );
        _maxStableRateBorrowSizePercent = 0.25e4;
    }

    /// @inheritdoc IPool
    function mintUnbacked(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external virtual override onlyBridge {
        asset = _toVirtualAsset[asset];
        BridgeLogic.executeMintUnbacked(
            _reserves,
            _reservesList,
            _usersConfig[onBehalfOf],
            asset,
            amount,
            onBehalfOf,
            referralCode
        );
    }

    /// @inheritdoc IPool
    function backUnbacked(
        address asset,
        uint256 amount,
        uint256 fee
    ) external virtual override onlyBridge returns (uint256) {
        asset = _toVirtualAsset[asset];
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        return
            BridgeLogic.executeBackUnbacked(
                _reserves[asset],
                _toActualAsset,
                asset,
                amount,
                fee,
                _bridgeProtocolFee
            );
    }

    /// @inheritdoc IPool
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) public virtual override {
        asset = _toVirtualAsset[asset];
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        SupplyLogic.executeSupply(
            _reserves,
            _reservesList,
            _toActualAsset,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteSupplyParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf,
                referralCode: referralCode,
                transferAsset: true
            })
        );
    }

    /// @inheritdoc IPool
    function supplyWithPermit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) public virtual override {
        asset = _toVirtualAsset[asset];
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        IERC20WithPermit(_toActualAsset[asset]).permit(
            msg.sender,
            address(this),
            amount,
            deadline,
            permitV,
            permitR,
            permitS
        );
        SupplyLogic.executeSupply(
            _reserves,
            _reservesList,
            _toActualAsset,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteSupplyParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf,
                referralCode: referralCode,
                transferAsset: true
            })
        );
    }

    /// @inheritdoc IPool
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) public virtual override returns (uint256) {
        asset = _toVirtualAsset[asset];
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        return
            SupplyLogic.executeWithdraw(
                _reserves,
                _reservesList,
                _eModeCategories,
                _usersConfig[msg.sender],
                DataTypes.ExecuteWithdrawParams({
                    asset: asset,
                    amount: amount,
                    to: to,
                    reservesCount: _reservesCount,
                    oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                    userEModeCategory: _usersEModeCategory[msg.sender]
                })
            );
    }

    function borrowAToken(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) public virtual {
        asset = _toVirtualAsset[asset];
        SupplyLogic.executeSupply(
            _reserves,
            _reservesList,
            _toActualAsset,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteSupplyParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf,
                referralCode: referralCode,
                transferAsset: false
            })
        );
        BorrowLogic.executeBorrow(
            _reserves,
            _reservesList,
            _toActualAsset,
            _eModeCategories,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteBorrowParams({
                asset: asset,
                user: msg.sender,
                onBehalfOf: onBehalfOf,
                amount: amount,
                interestRateMode: DataTypes.InterestRateMode(interestRateMode),
                referralCode: referralCode,
                releaseUnderlying: false,
                maxStableRateBorrowSizePercent: _maxStableRateBorrowSizePercent,
                reservesCount: _reservesCount,
                oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                userEModeCategory: _usersEModeCategory[onBehalfOf],
                priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel()
            })
        );
    }

    /// @inheritdoc IPool
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) public virtual override {
        if (_aTokenToVirtualAsset[asset] != address(0)) {
            borrowAToken(_aTokenToVirtualAsset[asset], amount, interestRateMode, referralCode, onBehalfOf);
            return;
        }
        asset = _toVirtualAsset[asset];
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        BorrowLogic.executeBorrow(
            _reserves,
            _reservesList,
            _toActualAsset,
            _eModeCategories,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteBorrowParams({
                asset: asset,
                user: msg.sender,
                onBehalfOf: onBehalfOf,
                amount: amount,
                interestRateMode: DataTypes.InterestRateMode(interestRateMode),
                referralCode: referralCode,
                releaseUnderlying: true,
                maxStableRateBorrowSizePercent: _maxStableRateBorrowSizePercent,
                reservesCount: _reservesCount,
                oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                userEModeCategory: _usersEModeCategory[onBehalfOf],
                priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel()
            })
        );
    }

    /// @inheritdoc IPool
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) public virtual override returns (uint256) {
        asset = _toVirtualAsset[asset];
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        return
            BorrowLogic.executeRepay(
                _reserves,
                _reservesList,
                _toActualAsset,
                _usersConfig[onBehalfOf],
                DataTypes.ExecuteRepayParams({
                    asset: asset,
                    amount: amount,
                    interestRateMode: DataTypes.InterestRateMode(
                        interestRateMode
                    ),
                    onBehalfOf: onBehalfOf,
                    useATokens: false
                })
            );
    }

    /// @inheritdoc IPool
    function repayWithPermit(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) public virtual override returns (uint256) {
        require (!_reserves[asset].configuration.getVirtual(), "virtual asset");
        {
            IERC20WithPermit(_toActualAsset[asset]).permit(
                msg.sender,
                address(this),
                amount,
                deadline,
                permitV,
                permitR,
                permitS
            );
        }
        {
            DataTypes.ExecuteRepayParams memory params = DataTypes
                .ExecuteRepayParams({
                    asset: asset,
                    amount: amount,
                    interestRateMode: DataTypes.InterestRateMode(
                        interestRateMode
                    ),
                    onBehalfOf: onBehalfOf,
                    useATokens: false
                });
            return
                BorrowLogic.executeRepay(
                    _reserves,
                    _reservesList,
                    _toActualAsset,
                    _usersConfig[onBehalfOf],
                    params
                );
        }
    }

    /// @inheritdoc IPool
    function repayWithATokens(
        address asset,
        uint256 amount,
        uint256 interestRateMode
    ) public virtual override returns (uint256) {
        asset = _toVirtualAsset[asset];
        return
            BorrowLogic.executeRepay(
                _reserves,
                _reservesList,
                _toActualAsset,
                _usersConfig[msg.sender],
                DataTypes.ExecuteRepayParams({
                    asset: asset,
                    amount: amount,
                    interestRateMode: DataTypes.InterestRateMode(
                        interestRateMode
                    ),
                    onBehalfOf: msg.sender,
                    useATokens: true
                })
            );
    }

    /// @inheritdoc IPool
    function swapBorrowRateMode(
        address asset,
        uint256 interestRateMode
    ) public virtual override {
        asset = _toVirtualAsset[asset];
        BorrowLogic.executeSwapBorrowRateMode(
            _reserves[asset],
            _usersConfig[msg.sender],
            asset,
            DataTypes.InterestRateMode(interestRateMode)
        );
    }

    /// @inheritdoc IPool
    function rebalanceStableBorrowRate(
        address asset,
        address user
    ) public virtual override {
        asset = _toVirtualAsset[asset];
        BorrowLogic.executeRebalanceStableBorrowRate(
            _reserves[asset],
            asset,
            user
        );
    }

    /// @inheritdoc IPool
    function setUserUseReserveAsCollateral(
        address asset,
        bool useAsCollateral
    ) public virtual override {
        asset = _toVirtualAsset[asset];
        SupplyLogic.executeUseReserveAsCollateral(
            _reserves,
            _reservesList,
            _eModeCategories,
            _usersConfig[msg.sender],
            asset,
            useAsCollateral,
            _reservesCount,
            ADDRESSES_PROVIDER.getPriceOracle(),
            _usersEModeCategory[msg.sender]
        );
    }

    /// @inheritdoc IPool
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) public virtual override {
        collateralAsset = _toVirtualAsset[collateralAsset];
        debtAsset = _toVirtualAsset[debtAsset];
        LiquidationLogic.executeLiquidationCall(
            _reserves,
            _reservesList,
            _toActualAsset,
            _usersConfig,
            _eModeCategories,
            DataTypes.ExecuteLiquidationCallParams({
                reservesCount: _reservesCount,
                debtToCover: debtToCover,
                collateralAsset: collateralAsset,
                debtAsset: debtAsset,
                user: user,
                receiveAToken: receiveAToken,
                priceOracle: ADDRESSES_PROVIDER.getPriceOracle(),
                userEModeCategory: _usersEModeCategory[user],
                priceOracleSentinel: ADDRESSES_PROVIDER.getPriceOracleSentinel()
            })
        );
    }

    /// @inheritdoc IPool
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata interestRateModes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) public virtual override {
        revert("");
        DataTypes.FlashloanParams memory flashParams = DataTypes
            .FlashloanParams({
                receiverAddress: receiverAddress,
                assets: assets,
                amounts: amounts,
                interestRateModes: interestRateModes,
                onBehalfOf: onBehalfOf,
                params: params,
                referralCode: referralCode,
                flashLoanPremiumToProtocol: _flashLoanPremiumToProtocol,
                flashLoanPremiumTotal: _flashLoanPremiumTotal,
                maxStableRateBorrowSizePercent: _maxStableRateBorrowSizePercent,
                reservesCount: _reservesCount,
                addressesProvider: address(ADDRESSES_PROVIDER),
                userEModeCategory: _usersEModeCategory[onBehalfOf],
                isAuthorizedFlashBorrower: IACLManager(
                    ADDRESSES_PROVIDER.getACLManager()
                ).isFlashBorrower(msg.sender)
            });

        FlashLoanLogic.executeFlashLoan(
            _reserves,
            _reservesList,
            _toActualAsset,
            _eModeCategories,
            _usersConfig[onBehalfOf],
            flashParams
        );
    }

    /// @inheritdoc IPool
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) public virtual override {
        revert("");
        DataTypes.FlashloanSimpleParams memory flashParams = DataTypes
            .FlashloanSimpleParams({
                receiverAddress: receiverAddress,
                asset: asset,
                amount: amount,
                params: params,
                referralCode: referralCode,
                flashLoanPremiumToProtocol: _flashLoanPremiumToProtocol,
                flashLoanPremiumTotal: _flashLoanPremiumTotal
            });
        FlashLoanLogic.executeFlashLoanSimple(_reserves[asset], flashParams);
    }

    /// @inheritdoc IPool
    function mintToTreasury(
        address[] calldata assets
    ) external virtual override {
        address[] memory virtualAssets = new address[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            virtualAssets[i] = _toVirtualAsset[assets[i]];
        }
        PoolLogic.executeMintToTreasury(_reserves, virtualAssets);
    }

    /// @inheritdoc IPool
    function getReserveData(
        address asset
    ) external view virtual override returns (DataTypes.ReserveData memory) {
        asset = _toVirtualAsset[asset];
        return _reserves[asset];
    }

    /// @inheritdoc IPool
    function getUserAccountData(
        address user
    )
        external
        view
        virtual
        override
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return
            PoolLogic.executeGetUserAccountData(
                _reserves,
                _reservesList,
                _eModeCategories,
                DataTypes.CalculateUserAccountDataParams({
                    userConfig: _usersConfig[user],
                    reservesCount: _reservesCount,
                    user: user,
                    oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                    userEModeCategory: _usersEModeCategory[user]
                })
            );
    }

    /// @inheritdoc IPool
    function getConfiguration(
        address asset
    )
        external
        view
        virtual
        override
        returns (DataTypes.ReserveConfigurationMap memory)
    {
        asset = _toVirtualAsset[asset];
        return _reserves[asset].configuration;
    }

    /// @inheritdoc IPool
    function getUserConfiguration(
        address user
    )
        external
        view
        virtual
        override
        returns (DataTypes.UserConfigurationMap memory)
    {
        return _usersConfig[user];
    }

    /// @inheritdoc IPool
    function getReserveNormalizedIncome(
        address asset
    ) external view virtual override returns (uint256) {
        asset = _toVirtualAsset[asset];
        return _reserves[asset].getNormalizedIncome();
    }

    /// @inheritdoc IPool
    function getReserveNormalizedVariableDebt(
        address asset
    ) external view virtual override returns (uint256) {
        asset = _toVirtualAsset[asset];
        return _reserves[asset].getNormalizedDebt();
    }

    /// @inheritdoc IPool
    function getReservesList()
        external
        view
        virtual
        override
        returns (address[] memory)
    {
        uint256 reservesListCount = _reservesCount;
        uint256 droppedReservesCount = 0;
        address[] memory reservesList = new address[](reservesListCount);

        for (uint256 i = 0; i < reservesListCount; i++) {
            if (_reservesList[i] != address(0)) {
                address r = _reservesList[i];
                if (_toActualAsset[r] != address(0)) {
                    r = _toActualAsset[r];
                }
                reservesList[i - droppedReservesCount] = r;
            } else {
                droppedReservesCount++;
            }
        }

        // Reduces the length of the reserves array by `droppedReservesCount`
        assembly {
            mstore(reservesList, sub(reservesListCount, droppedReservesCount))
        }
        return reservesList;
    }

    /// @inheritdoc IPool
    function getReserveAddressById(uint16 id) external view returns (address) {
        address r = _reservesList[id];
        if (_toActualAsset[r] != address(0)) {
            r = _toActualAsset[r];
        }
        return r;
    }

    /// @inheritdoc IPool
    function MAX_STABLE_RATE_BORROW_SIZE_PERCENT()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _maxStableRateBorrowSizePercent;
    }

    /// @inheritdoc IPool
    function BRIDGE_PROTOCOL_FEE()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _bridgeProtocolFee;
    }

    /// @inheritdoc IPool
    function FLASHLOAN_PREMIUM_TOTAL()
        public
        view
        virtual
        override
        returns (uint128)
    {
        return _flashLoanPremiumTotal;
    }

    /// @inheritdoc IPool
    function FLASHLOAN_PREMIUM_TO_PROTOCOL()
        public
        view
        virtual
        override
        returns (uint128)
    {
        return _flashLoanPremiumToProtocol;
    }

    /// @inheritdoc IPool
    function MAX_NUMBER_RESERVES()
        public
        view
        virtual
        override
        returns (uint16)
    {
        return ReserveConfiguration.MAX_RESERVES_COUNT;
    }

    /// @inheritdoc IPool
    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 balanceFromBefore,
        uint256 balanceToBefore
    ) external virtual override {
        require(
            msg.sender == _reserves[asset].aTokenAddress,
            Errors.CALLER_NOT_ATOKEN
        );
        asset = _toVirtualAsset[asset];
        SupplyLogic.executeFinalizeTransfer(
            _reserves,
            _reservesList,
            _eModeCategories,
            _usersConfig,
            DataTypes.FinalizeTransferParams({
                asset: asset,
                from: from,
                to: to,
                amount: amount,
                balanceFromBefore: balanceFromBefore,
                balanceToBefore: balanceToBefore,
                reservesCount: _reservesCount,
                oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                fromEModeCategory: _usersEModeCategory[from]
            })
        );
    }

    /// @inheritdoc IPool
    function initReserve(
        address asset,
        address aTokenAddress,
        address stableDebtAddress,
        address variableDebtAddress,
        address interestRateStrategyAddress,
        address rebaseTracker,
        bool virtual_
    ) external virtual override onlyPoolConfigurator {
        if (
            PoolLogic.executeInitReserve(
                _reserves,
                _reservesList,
                _toVirtualAsset,
                _toActualAsset,
                DataTypes.InitReserveParams({
                    asset: asset,
                    actualAsset: virtual_ ? address(0) : asset,
                    aTokenAddress: aTokenAddress,
                    stableDebtAddress: stableDebtAddress,
                    variableDebtAddress: variableDebtAddress,
                    interestRateStrategyAddress: interestRateStrategyAddress,
                    rebaseTracker: rebaseTracker,
                    reservesCount: _reservesCount,
                    maxNumberReserves: MAX_NUMBER_RESERVES()
                })
            )
        ) {
            _reservesCount++;
            _aTokenToVirtualAsset[aTokenAddress] = asset;
        }
    }

    /// @inheritdoc IPool
    function dropReserve(
        address asset
    ) external virtual override onlyPoolConfigurator {
        asset = _toVirtualAsset[asset];
        PoolLogic.executeDropReserve(_reserves, _reservesList, asset);
    }

    function actualizeReserve(
        address virtualAsset,
        address actualAsset
    ) external virtual onlyPoolConfigurator {
        DataTypes.ReserveData storage reserve = _reserves[virtualAsset];
        require(reserve.configuration.getVirtual(), "not virtual");

        IAToken(reserve.aTokenAddress).actualize(actualAsset);
        IStableDebtToken(reserve.stableDebtTokenAddress).actualize(actualAsset);
        IVariableDebtToken(reserve.variableDebtTokenAddress).actualize(
            actualAsset
        );

        uint8 newDecimals = IERC20Detailed(actualAsset).decimals();
        uint256 decimalsFactor = 10 **
            (18 + newDecimals - reserve.configuration.getDecimals());
        reserve.configuration.setDecimals(newDecimals);
        reserve.liquidityIndex =
            SafeCast.toUint128((reserve.liquidityIndex * decimalsFactor) /
            1e18);
        reserve.variableBorrowIndex =
            SafeCast.toUint128((reserve.variableBorrowIndex * decimalsFactor) /
            1e18);

        _toActualAsset[virtualAsset] = actualAsset;
        _toVirtualAsset[actualAsset] = virtualAsset;

        reserve.configuration.setVirtual(false);
    }

    /// @inheritdoc IPool
    function setReserveInterestRateStrategyAddress(
        address asset,
        address rateStrategyAddress
    ) external virtual override onlyPoolConfigurator {
        asset = _toVirtualAsset[asset];
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(
            _reserves[asset].id != 0 || _reservesList[0] == asset,
            Errors.ASSET_NOT_LISTED
        );
        _reserves[asset].interestRateStrategyAddress = rateStrategyAddress;
    }

    function setReserveRebaseTrackerAddress(
        address asset,
        address rebaseTrackerAddress
    ) external virtual onlyPoolConfigurator {
        asset = _toVirtualAsset[asset];
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(
            _reserves[asset].id != 0 || _reservesList[0] == asset,
            Errors.ASSET_NOT_LISTED
        );
        _reserves[asset].rebaseTracker = rebaseTrackerAddress;
    }

    /// @inheritdoc IPool
    function setConfiguration(
        address asset,
        DataTypes.ReserveConfigurationMap calldata configuration
    ) external virtual override onlyPoolConfigurator {
        asset = _toVirtualAsset[asset];
        require(asset != address(0), Errors.ZERO_ADDRESS_NOT_VALID);
        require(
            _reserves[asset].id != 0 || _reservesList[0] == asset,
            Errors.ASSET_NOT_LISTED
        );
        _reserves[asset].configuration = configuration;
    }

    /// @inheritdoc IPool
    function updateBridgeProtocolFee(
        uint256 protocolFee
    ) external virtual override onlyPoolConfigurator {
        _bridgeProtocolFee = protocolFee;
    }

    /// @inheritdoc IPool
    function updateFlashloanPremiums(
        uint128 flashLoanPremiumTotal,
        uint128 flashLoanPremiumToProtocol
    ) external virtual override onlyPoolConfigurator {
        _flashLoanPremiumTotal = flashLoanPremiumTotal;
        _flashLoanPremiumToProtocol = flashLoanPremiumToProtocol;
    }

    /// @inheritdoc IPool
    function configureEModeCategory(
        uint8 id,
        DataTypes.EModeCategory memory category
    ) external virtual override onlyPoolConfigurator {
        // category 0 is reserved for volatile heterogeneous assets and it's always disabled
        require(id != 0, Errors.EMODE_CATEGORY_RESERVED);
        _eModeCategories[id] = category;
    }

    /// @inheritdoc IPool
    function getEModeCategoryData(
        uint8 id
    ) external view virtual override returns (DataTypes.EModeCategory memory) {
        return _eModeCategories[id];
    }

    /// @inheritdoc IPool
    function setUserEMode(uint8 categoryId) external virtual override {
        EModeLogic.executeSetUserEMode(
            _reserves,
            _reservesList,
            _eModeCategories,
            _usersEModeCategory,
            _usersConfig[msg.sender],
            DataTypes.ExecuteSetUserEModeParams({
                reservesCount: _reservesCount,
                oracle: ADDRESSES_PROVIDER.getPriceOracle(),
                categoryId: categoryId
            })
        );
    }

    /// @inheritdoc IPool
    function getUserEMode(
        address user
    ) external view virtual override returns (uint256) {
        return _usersEModeCategory[user];
    }

    /// @inheritdoc IPool
    function resetIsolationModeTotalDebt(
        address asset
    ) external virtual override onlyPoolConfigurator {
        asset = _toVirtualAsset[asset];
        PoolLogic.executeResetIsolationModeTotalDebt(_reserves, asset);
    }

    /// @inheritdoc IPool
    function rescueTokens(
        address token,
        address to,
        uint256 amount
    ) external virtual override onlyPoolAdmin {
        revert("");
        PoolLogic.executeRescueTokens(token, to, amount);
    }

    /// @inheritdoc IPool
    /// @dev Deprecated: maintained for compatibility purposes
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external virtual override {
        asset = _toVirtualAsset[asset];
        SupplyLogic.executeSupply(
            _reserves,
            _reservesList,
            _toActualAsset,
            _usersConfig[onBehalfOf],
            DataTypes.ExecuteSupplyParams({
                asset: asset,
                amount: amount,
                onBehalfOf: onBehalfOf,
                referralCode: referralCode,
                transferAsset: true
            })
        );
    }
}
