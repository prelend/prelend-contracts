// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {IAaveIncentivesController} from "src/interfaces/IAaveIncentivesController.sol";

import {PoolAddressesProviderRegistry} from "src/protocol/configuration/PoolAddressesProviderRegistry.sol";
import {PoolAddressesProvider} from "src/protocol/configuration/PoolAddressesProvider.sol";
import {AaveProtocolDataProvider} from "src/misc/AaveProtocolDataProvider.sol";
import {AaveOracle} from "src/misc/AaveOracle.sol";

import {L2Pool} from "src/protocol/pool/L2Pool.sol";
import {PoolConfigurator} from "src/protocol/pool/PoolConfigurator.sol";
import {DefaultReserveInterestRateStrategy} from "src/protocol/pool/DefaultReserveInterestRateStrategy.sol";

import {ACLManager} from "src/protocol/configuration/ACLManager.sol";
import {L2Encoder} from "src/misc/L2Encoder.sol";

import {EmissionManager} from "src/rewards/EmissionManager.sol";
import {RewardsController} from "src/rewards/RewardsController.sol";
import {PullRewardsTransferStrategy} from "src/rewards/transfer-strategies/PullRewardsTransferStrategy.sol";

import {AToken} from "src/protocol/tokenization/AToken.sol";
import {DelegationAwareAToken} from "src/protocol/tokenization/DelegationAwareAToken.sol";
import {StableDebtToken} from "src/protocol/tokenization/StableDebtToken.sol";
import {VariableDebtToken} from "src/protocol/tokenization/VariableDebtToken.sol";

import {ConfiguratorInputTypes} from "src/protocol/libraries/types/ConfiguratorInputTypes.sol";

import {WrappedTokenGatewayV3} from "src/periphery/WrappedTokenGatewayV3.sol";
import {WalletBalanceProvider} from "src/periphery/WalletBalanceProvider.sol";
import {UiPoolDataProviderV3} from "src/periphery/UiPoolDataProviderV3.sol";
import {UiIncentiveDataProviderV3} from "src/periphery/UiIncentiveDataProviderV3.sol";
import {IEACAggregatorProxy} from "src/misc/interfaces/IEACAggregatorProxy.sol";
import {RewardsDataTypes} from "src/rewards/libraries/RewardsDataTypes.sol";

import {EarlyPRE} from "src/EarlyPRE.sol";
import {IERC20Rebasing} from "src/blast/IERC20Rebasing.sol";
import {IRebaseTracker} from "src/interfaces/IRebaseTracker.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

contract MockFeed is IEACAggregatorProxy {
    int256 public immutable latestAnswer;
    uint256 public constant latestRound = 1;
    uint8 public decimals;

    constructor(int256 a, uint8 d) {
        latestAnswer = a;
        decimals = d;
    }

    function latestTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    function getAnswer(uint256 roundId) external view returns (int256) {
        return latestAnswer;
    }

    function getTimestamp(uint256 roundId) external view returns (uint256) {
        return block.timestamp;
    }
}

contract MockRebaseTracker is IRebaseTracker {
    mapping(address => uint256) lastPrice;
    uint256 immutable c;

    constructor() {
        c = block.timestamp;
    }

    function catchUp() external returns (uint256, uint256) {
        uint256 price = block.timestamp - c + 1;
        uint256 last = lastPrice[msg.sender];
        if (last == 0) {
            lastPrice[msg.sender] = price;
            return (1, 1);
        }

        if (last != price) {
            lastPrice[msg.sender] = price;
        }
        return (last, price);
    }

    function peek() external view returns (uint256, uint256) {
        uint256 price = block.timestamp - c + 1;
        uint256 last = lastPrice[msg.sender];
        if (last == 0) {
            return (1, 1);
        }

        return (last, price);
    }
}

contract RebaseTracker is IRebaseTracker {
    IERC20Rebasing public immutable token;
    mapping(address => uint256) lastPrice;

    constructor(address _token) {
        token = IERC20Rebasing(_token);
    }

    function catchUp() external returns (uint256, uint256) {
        uint256 price = token.price();
        uint256 last = lastPrice[msg.sender];
        if (last == 0) {
            lastPrice[msg.sender] = price;
            return (price, price);
        }

        if (last != price) {
            lastPrice[msg.sender] = price;
        }
        return (last, last);
    }

    function peek() external view returns (uint256, uint256) {
        uint256 price = token.price();
        uint256 last = lastPrice[msg.sender];
        if (last == 0) {
            return (price, price);
        }

        return (last, price);
    }
}
contract RebaseTracker2 is IRebaseTracker {
    IERC20Rebasing public immutable token;
    mapping(address => uint256) lastPrice;

    constructor(address _token) {
        token = IERC20Rebasing(_token);
    }

    function catchUp() external returns (uint256, uint256) {
        uint256 price = token.sharePrice();
        uint256 last = lastPrice[msg.sender];
        if (last == 0) {
            lastPrice[msg.sender] = price;
            return (price, price);
        }

        if (last != price) {
            lastPrice[msg.sender] = price;
        }
        return (last, last);
    }

    function peek() external view returns (uint256, uint256) {
        uint256 price = token.sharePrice();
        uint256 last = lastPrice[msg.sender];
        if (last == 0) {
            return (price, price);
        }

        return (last, price);
    }
}

contract WETH9 {
    string public name     = "Wrapped Ether";
    string public symbol   = "WETH";
    uint8  public decimals = 18;

    event  Approval(address indexed src, address indexed guy, uint wad);
    event  Transfer(address indexed src, address indexed dst, uint wad);
    event  Deposit(address indexed dst, uint wad);
    event  Withdrawal(address indexed src, uint wad);

    mapping (address => uint)                       public  balanceOf;
    mapping (address => mapping (address => uint))  public  allowance;

    receive() external payable {
        deposit();
    }
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        emit Deposit(msg.sender, msg.value);
    }
    function withdraw(uint wad) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        msg.sender.call{value: wad}("");
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad)
        public
        returns (bool)
    {
        require(balanceOf[src] >= wad);

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }
}
contract Main is Script {
    address admin;
    address treasury;
    address fallbackOracle = address(0);
    address weth;
    address usdc;
    address virtualBLAST =
        address(uint160(uint256(keccak256("preBLAST_underlying_virtual"))));

    PoolConfigurator poolConfig;
    L2Pool pool;
    PoolAddressesProviderRegistry registry;
    PoolAddressesProvider addressesProvider;
    AaveProtocolDataProvider protocolDataProvider;
    ACLManager aclManager;
    AaveOracle oracle;
    L2Encoder l2Encoder;
    EmissionManager emissionManager;
    RewardsController rewardsController;
    AToken aToken;
    DelegationAwareAToken delegationAwareAToken;
    StableDebtToken stableDebtToken;
    VariableDebtToken variableDebtToken;
    DefaultReserveInterestRateStrategy volatileInterestRateStrategy;
    DefaultReserveInterestRateStrategy zeroInterestRateStrategy;

    WrappedTokenGatewayV3 gateway;
    WalletBalanceProvider walletBalanceProvider;
    UiPoolDataProviderV3 uiPoolDataProvider;
    UiIncentiveDataProviderV3 uiIncentiveDataProvider;

    EarlyPRE earlyPRE;

    function setUp() public {}

    function run() public {
        admin = tx.origin;
        treasury = tx.origin;
        vm.rpc("anvil_setBalance", string(abi.encodePacked("[\"", vm.toString(tx.origin), "\", \"", vm.toString(uint256(10000 ether)), "\"]")));
        vm.startBroadcast();
        usdc = address(new ERC20("Rebasing USD", "USDB"));

        weth = address(new WETH9());

        registry = new PoolAddressesProviderRegistry(admin);

        addressesProvider = new PoolAddressesProvider("PreLend", admin);
        registry.registerAddressesProvider(address(addressesProvider), 1);

        protocolDataProvider = new AaveProtocolDataProvider(addressesProvider);
        addressesProvider.setPoolDataProvider(address(protocolDataProvider));

        pool = new L2Pool(addressesProvider);
        pool.initialize(addressesProvider);

        poolConfig = new PoolConfigurator();
        poolConfig.initialize(addressesProvider);

        addressesProvider.setACLAdmin(admin);
        aclManager = new ACLManager(addressesProvider);
        addressesProvider.setACLManager(address(aclManager));
        aclManager.addPoolAdmin(admin);
        aclManager.addEmergencyAdmin(admin);

        oracle = new AaveOracle(
            addressesProvider,
            new address[](0),
            new address[](0),
            fallbackOracle,
            address(0),
            1e8
        );
        addressesProvider.setPriceOracle(address(oracle));

        addressesProvider.setPoolImpl(address(pool));
        pool = L2Pool(addressesProvider.getPool());

        addressesProvider.setPoolConfiguratorImpl(address(poolConfig));
        poolConfig = PoolConfigurator(addressesProvider.getPoolConfigurator());

        l2Encoder = new L2Encoder(pool);

        poolConfig.updateFlashloanPremiumTotal(0);
        poolConfig.updateFlashloanPremiumToProtocol(0);

        emissionManager = new EmissionManager(tx.origin);

        rewardsController = new RewardsController(address(emissionManager));
        rewardsController.initialize(address(0));
        addressesProvider.setAddressAsProxy(
            keccak256("INCENTIVES_CONTROLLER"),
            address(rewardsController)
        );
        rewardsController = RewardsController(
            addressesProvider.getAddress(keccak256("INCENTIVES_CONTROLLER"))
        );
        emissionManager.setRewardsController(address(rewardsController));

        aToken = new AToken(pool);
        aToken.initialize(
            pool,
            address(0),
            address(0),
            IAaveIncentivesController(address(0)),
            0,
            "ATOKEN_IMPL",
            "ATOKEN_IMPL",
            hex""
        );

        delegationAwareAToken = new DelegationAwareAToken(pool);
        delegationAwareAToken.initialize(
            pool,
            address(0),
            address(0),
            IAaveIncentivesController(address(0)),
            0,
            "DELEGATION_AWARE_ATOKEN_IMPL",
            "DELEGATION_AWARE_ATOKEN_IMPL",
            hex""
        );

        stableDebtToken = new StableDebtToken(pool);
        stableDebtToken.initialize(
            pool,
            address(0),
            IAaveIncentivesController(address(0)),
            0,
            "STABLE_DEBT_TOKEN_IMPL",
            "STABLE_DEBT_TOKEN_IMPL",
            hex""
        );

        variableDebtToken = new VariableDebtToken(pool);
        variableDebtToken.initialize(
            pool,
            address(0),
            IAaveIncentivesController(address(0)),
            0,
            "VARIABLE_DEBT_TOKEN_IMPL",
            "VARIABLE_DEBT_TOKEN_IMPL",
            hex""
        );

        volatileInterestRateStrategy = new DefaultReserveInterestRateStrategy(
            addressesProvider,
            0.45e27,
            0,
            0.0e27,
            3e27,
            0.07e27,
            3e27,
            0.02e27,
            0.05e27,
            0.2e27
        );

        zeroInterestRateStrategy = new DefaultReserveInterestRateStrategy(
            addressesProvider,
            0.45e27,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
        );

        ConfiguratorInputTypes.InitReserveInput[]
            memory reserves = new ConfiguratorInputTypes.InitReserveInput[](1);
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);

        reserves[0] = ConfiguratorInputTypes.InitReserveInput({
            aTokenImpl: address(aToken),
            stableDebtTokenImpl: address(stableDebtToken),
            variableDebtTokenImpl: address(variableDebtToken),
            underlyingAssetDecimals: 6,
            interestRateStrategyAddress: address(volatileInterestRateStrategy),
            underlyingAsset: usdc,
            virtual_: false,
            treasury: treasury,
            incentivesController: address(rewardsController),
            aTokenName: "preUSDB",
            aTokenSymbol: "preUSDB",
            variableDebtTokenName: "preUSDB debt",
            variableDebtTokenSymbol: "preUSDB debt",
            stableDebtTokenName: "preUSDB stable debt",
            stableDebtTokenSymbol: "preUSDB stable debt",
            rebaseTracker: address(0),
            params: hex""
        });
        poolConfig.initReserves(reserves);
        poolConfig.configureReserveAsCollateral(usdc, 8000, 8500, 10500);
        poolConfig.setReserveBorrowing(usdc, true);
        //configurator.setBorrowCap();
        //configurator.setReserveStableRateBorrowing();
        //poolConfig.setReserveFlashLoaning(usdc, true);
        //configurator.setSupplyCap;
        poolConfig.setReserveFactor(usdc, 1000);
        poolConfig.setLiquidationProtocolFee(usdc, 1000);
        assets[0] = usdc;
        sources[0] = address(new MockFeed(1e8, 8));
        oracle.setAssetSources(assets, sources);

        reserves[0] = ConfiguratorInputTypes.InitReserveInput({
            aTokenImpl: address(aToken),
            stableDebtTokenImpl: address(stableDebtToken),
            variableDebtTokenImpl: address(variableDebtToken),
            underlyingAssetDecimals: 18,
            interestRateStrategyAddress: address(volatileInterestRateStrategy),
            underlyingAsset: weth,
            virtual_: false,
            treasury: treasury,
            incentivesController: address(rewardsController),
            aTokenName: "preETH",
            aTokenSymbol: "preETH",
            variableDebtTokenName: "preETH debt",
            variableDebtTokenSymbol: "preETH debt",
            stableDebtTokenName: "preETH stable debt",
            stableDebtTokenSymbol: "preETH stable debt",
            rebaseTracker: address(0),
            params: hex""
        });
        poolConfig.initReserves(reserves);
        poolConfig.configureReserveAsCollateral(weth, 7500, 8000, 10500);
        poolConfig.setReserveBorrowing(weth, true);
        //configurator.setBorrowCap();
        //configurator.setReserveStableRateBorrowing();
        //poolConfig.setReserveFlashLoaning(weth, true);
        //configurator.setSupplyCap;
        poolConfig.setReserveFactor(weth, 1000);
        poolConfig.setLiquidationProtocolFee(weth, 1000);
        assets[0] = weth;
        sources[0] = address(new MockFeed(2500e8, 8));
        oracle.setAssetSources(assets, sources);

        reserves[0] = ConfiguratorInputTypes.InitReserveInput({
            aTokenImpl: address(aToken),
            stableDebtTokenImpl: address(stableDebtToken),
            variableDebtTokenImpl: address(variableDebtToken),
            underlyingAssetDecimals: 18,
            interestRateStrategyAddress: address(zeroInterestRateStrategy),
            underlyingAsset: virtualBLAST,
            virtual_: true,
            treasury: treasury,
            incentivesController: address(rewardsController),
            aTokenName: "preBLAST",
            aTokenSymbol: "preBLAST",
            variableDebtTokenName: "preBLAST debt",
            variableDebtTokenSymbol: "preBLAST debt",
            stableDebtTokenName: "preBLAST stable debt",
            stableDebtTokenSymbol: "preBLAST stable debt",
            rebaseTracker: address(0),
            params: ""
        });
        poolConfig.initReserves(reserves);
        //poolConfig.configureReserveAsCollateral(virtualBLAST, 7500, 8000, 10500);
        poolConfig.setReserveBorrowing(virtualBLAST, true);
        //configurator.setBorrowCap();
        //configurator.setReserveStableRateBorrowing();
        //poolConfig.setReserveFlashLoaning(weth, true);
        //configurator.setSupplyCap;
        poolConfig.setReserveFactor(virtualBLAST, 8000);
        //poolConfig.setLiquidationProtocolFee(weth, 1000);
        assets[0] = virtualBLAST;
        sources[0] = address(new MockFeed(10e8, 8));
        oracle.setAssetSources(assets, sources);

        gateway = new WrappedTokenGatewayV3(weth, admin, pool);
        walletBalanceProvider = new WalletBalanceProvider();
        uiPoolDataProvider = new UiPoolDataProviderV3(
            new MockFeed(2000e8, 8),
            new MockFeed(1e8, 8)
        );
        uiIncentiveDataProvider = new UiIncentiveDataProviderV3();
        uiPoolDataProvider.setTokenName(virtualBLAST, "BLAST", "BLAST");

        /*
        earlyPRE = new EarlyPRE();
        emissionManager.setEmissionAdmin(address(earlyPRE), admin);

        {
            PullRewardsTransferStrategy st = new PullRewardsTransferStrategy(
                address(rewardsController),
                admin,
                admin
            );
            earlyPRE.approve(address(st), type(uint256).max);
            RewardsDataTypes.RewardsConfigInput[]
                memory rewardsConfigInput = new RewardsDataTypes.RewardsConfigInput[](
                    1
                );
            rewardsConfigInput[0].emissionPerSecond = 1e18;
            rewardsConfigInput[0].distributionEnd = uint32(
                block.timestamp + 365 days
            );
            rewardsConfigInput[0].reward = address(earlyPRE);
            rewardsConfigInput[0].transferStrategy = st;
            rewardsConfigInput[0].rewardOracle = new MockFeed(0.01e18, 18);

            rewardsConfigInput[0].asset = pool
                .getReserveData(usdc)
                .aTokenAddress;
            emissionManager.configureAssets(rewardsConfigInput);

            rewardsConfigInput[0].asset = pool
                .getReserveData(weth)
                .aTokenAddress;
            emissionManager.configureAssets(rewardsConfigInput);

            rewardsConfigInput[0].asset = pool
                .getReserveData(virtualBLAST)
                .aTokenAddress;
            emissionManager.configureAssets(rewardsConfigInput);

            rewardsConfigInput[0].asset = pool
                .getReserveData(usdc)
                .variableDebtTokenAddress;
            emissionManager.configureAssets(rewardsConfigInput);

            rewardsConfigInput[0].asset = pool
                .getReserveData(weth)
                .variableDebtTokenAddress;
            emissionManager.configureAssets(rewardsConfigInput);

            rewardsConfigInput[0].asset = pool
                .getReserveData(virtualBLAST)
                .variableDebtTokenAddress;
            emissionManager.configureAssets(rewardsConfigInput);
        }
        */
        vm.stopBroadcast();

        //StdChains.Chain memory chain = getChain(block.chainid);
        vm.serializeAddress(
            "addresses",
            "POOL_ADDRESSES_PROVIDER",
            address(addressesProvider)
        );
        vm.serializeAddress("addresses", "POOL", address(pool));
        vm.serializeAddress("addresses", "WETH_GATEWAY", address(gateway));
        vm.serializeAddress(
            "addresses",
            "WALLET_BALANCE_PROVIDER",
            address(walletBalanceProvider)
        );
        vm.serializeAddress(
            "addresses",
            "UI_POOL_DATA_PROVIDER",
            address(uiPoolDataProvider)
        );
        vm.serializeAddress(
            "addresses",
            "UI_INCENTIVE_DATA_PROVIDER",
            address(uiIncentiveDataProvider)
        );
        vm.serializeAddress("addresses", "L2_ENCODER", address(l2Encoder));
        vm.serializeAddress("addresses", "L2_ENCODER", address(l2Encoder));
        vm.writeJson(
            vm.serializeUint("addresses", "chainId", block.chainid),
            string(abi.encodePacked("./deployed/deployment.json"))
        );
    }
}
