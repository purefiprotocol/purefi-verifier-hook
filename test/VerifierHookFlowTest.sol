// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import '../script/TestnetDeployment.s.sol';
import './utils/WorkaroundFunctions.sol';
import '@purefi-sdk-solidity-v5/PureFiIssuerRegistry.sol';
import {Test} from 'forge-std/Test.sol';

contract VerifierHookFlowTest is Test, TestnetDeployment {
    PoolManager private manager;
    MockCoin private token0 = MockCoin(0x4444444444444444444444444444444444444444);
    MockCoin private token1 = MockCoin(0x5555555555555555555555555555555555555555);
    PureFiModifyLiquidityRouter private modifyLiquidityRouter;
    PureFiSwapRouter private swapRouter;
    VerifierHook private verifierHook;

    uint24 private constant SWAP_FEE = 4000;
    int24 private constant TICK_SPACING = 10;
    uint256 private constant SWAP_TOKEN0_AMOUNT = 7000;
    uint256 private constant SWAP_TOKEN1_AMOUNT = 30_000;
    uint256 private constant LIQ_TOKEN0_AMOUNT = 100_000;
    uint256 private constant LIQ_TOKEN1_AMOUNT = 500_000;
    uint256 private constant REMOVE_LIQ_TOKEN0_AMOUNT = 30_119_201_882_931_882;
    uint256 private constant REMOVE_LIQ_TOKEN1_AMOUNT = 30_119_201_882_931_882;
    uint256 private constant RULE = 631;
    uint256 private constant MINT_AMOUNT = 1e24;
    uint256 private issuerPk;
    address private issuer;
    uint256 private issuerRegistryPk;
    address private issuerRegistry;
    uint256 private currentSession = 0;

    function setUp() public {
        vm.startBroadcast();
        (issuerRegistry, issuerRegistryPk) = makeAddrAndKey('issuerRegistry');
        (issuer, issuerPk) = makeAddrAndKey('issuer');

        PureFiIssuerRegistry registry = new PureFiIssuerRegistry();
        registry.initialize(msg.sender);
        PureFiVerifier verifier = new PureFiVerifier();
        verifier.initialize(address(registry));

        console.log('registry ', address(registry));
        console.log('verifier ', address(verifier));

        registry.setVerifier(address(verifier));
        //PureFi Stage Issuer
        registry.register(0x592157ab4c6FADc849fA23dFB5e2615459D1E4e5);
        registry.register(issuer);

        console.log('MESSAGE SENDER', msg.sender);
        (address issuer, uint256 issuerPk) = makeAddrAndKey('issuer');
        manager = new PoolManager(msg.sender);
        MockCoin token = new MockCoin();

        vm.etch(address(token0), address(token).code);
        vm.etch(address(token1), address(token).code);

        token0.initialize('ZERO', 'Zero test');
        token1.initialize('FRST', 'First test');

        token0.mint(msg.sender, MINT_AMOUNT);
        token1.mint(msg.sender, MINT_AMOUNT);

        (
            address pureFiModifyLiquidityRouterAddress,
            address pureFiSwapRouterAddress,
            address verifierHookAddress,
            address verifierHookWhitelist
        ) = deployPureFiRouterAndHook(manager, verifier);

        modifyLiquidityRouter = PureFiModifyLiquidityRouter(pureFiModifyLiquidityRouterAddress);
        swapRouter = PureFiSwapRouter(pureFiSwapRouterAddress);
        verifierHook = VerifierHook(verifierHookAddress);

        // make approve to lp router
        token0.approve(address(modifyLiquidityRouter), UINT256_MAX);
        token1.approve(address(modifyLiquidityRouter), UINT256_MAX);

        // make approve to swap router
        token0.approve(address(swapRouter), UINT256_MAX);
        token1.approve(address(swapRouter), UINT256_MAX);

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        manager.initialize(pool, startingPrice);

        vm.stopBroadcast();
    }

    function getTestModifyLiquidityPayload(uint8 decimals0, uint256 amount0, uint8 decimals1, uint256 amount1)
        internal
        returns (bytes memory _payload)
    {
        WorkaroundFunctions workaround = new WorkaroundFunctions();
        WorkaroundFunctions.WorkaroundPackageType48 memory packedStruct = WorkaroundFunctions.WorkaroundPackageType48(
            48,
            currentSession++,
            RULE,
            msg.sender,
            address(modifyLiquidityRouter),
            workaround.workaround_encodeTokenData(address(token0), decimals0, amount0),
            workaround.workaround_encodeTokenData(address(token1), decimals1, amount1)
        );

        uint64 time = uint64(block.timestamp);
        bytes memory package = abi.encode(packedStruct);
        bytes32 digest = keccak256(abi.encodePacked(time, package));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory encodedPackage = abi.encode(time, signature, package);

        return encodedPackage;
    }

    function getTestRemoveLiquidityPayload() internal returns (bytes memory _payload) {
        WorkaroundFunctions workaround = new WorkaroundFunctions();
        WorkaroundFunctions.WorkaroundPackageType48 memory packedStruct = WorkaroundFunctions.WorkaroundPackageType48(
            48,
            currentSession++,
            RULE,
            msg.sender,
            address(modifyLiquidityRouter),
            workaround.workaround_encodeTokenData(address(token0), 0, REMOVE_LIQ_TOKEN0_AMOUNT),
            workaround.workaround_encodeTokenData(address(token1), 0, REMOVE_LIQ_TOKEN1_AMOUNT)
        );

        uint64 time = uint64(block.timestamp);
        bytes memory package = abi.encode(packedStruct);
        bytes32 digest = keccak256(abi.encodePacked(time, package));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory encodedPackage = abi.encode(time, signature, package);

        return encodedPackage;
    }

    function getTestSwapPayloadToken(address token, uint8 decimals, uint256 amount)
        internal
        returns (bytes memory _payload)
    {
        WorkaroundFunctions workaround = new WorkaroundFunctions();
        WorkaroundFunctions.WorkaroundPackageType32 memory packedStruct = WorkaroundFunctions.WorkaroundPackageType32(
            32,
            currentSession++,
            RULE,
            msg.sender,
            address(swapRouter),
            workaround.workaround_encodeTokenData(token, decimals, amount)
        );

        uint64 time = uint64(block.timestamp);
        bytes memory package = abi.encode(packedStruct);
        bytes32 digest = keccak256(abi.encodePacked(time, package));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        bytes memory encodedPackage = abi.encode(time, signature, package);

        return encodedPackage;
    }

    // Happy Flow
    function test_AddLiqAndSwapFlow() public {
        vm.startBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory modifyLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 10 ether,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(
            pool,
            modifyLiquidityParams,
            getTestModifyLiquidityPayload(token0.decimals(), LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT)
        );

        PureFiSwapRouter.TestSettings memory testSettings =
            PureFiSwapRouter.TestSettings({takeClaims: true, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            //use library for conversion
            amountSpecified: -1 * int256(SWAP_TOKEN1_AMOUNT * 1e18),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PureFiSwapRouter(swapRouter).swap(
            pool,
            swapParams,
            testSettings,
            getTestSwapPayloadToken(address(token1), token1.decimals(), SWAP_TOKEN1_AMOUNT)
        );

        modifyLiquidityParams.liquidityDelta = -5 ether;
        modifyLiquidityRouter.modifyLiquidity(pool, modifyLiquidityParams, getTestRemoveLiquidityPayload());

        vm.stopBroadcast();
    }

    function test_ShouldRevertAddLiquidityAmount0ExceedsPackage() public {
        vm.startBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory modifyLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -2600,
            tickUpper: 2600,
            liquidityDelta: 5_000_000 ether,
            salt: bytes32(0)
        });

        bytes memory hookData =
            getTestModifyLiquidityPayload(token0.decimals(), LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT);

        //trying to add more token0 than allowed in the package
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(pool, modifyLiquidityParams, hookData);
        vm.stopBroadcast();
    }

    function test_ShouldRevertAddLiquidityAmount1ExceedsPackage() public {
        vm.startBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory modifyLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -2600,
            tickUpper: 2600,
            liquidityDelta: 5_000_000 ether,
            salt: bytes32(0)
        });

        bytes memory hookData = getTestModifyLiquidityPayload(
            token0.decimals(), 9 * LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT
        );
        //trying to add more token1 than allowed in the package
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(pool, modifyLiquidityParams, hookData);
        vm.stopBroadcast();
    }

    function test_ShouldRevertRemoveLiquidityAmount0ExceedsPackage() public {
        vm.startBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory addLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -2600,
            tickUpper: 2600,
            liquidityDelta: 1000 ether,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(
            pool,
            addLiquidityParams,
            getTestModifyLiquidityPayload(
                token0.decimals(), 9 * LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT
            )
        );

        PureFiSwapRouter.TestSettings memory testSettings =
            PureFiSwapRouter.TestSettings({takeClaims: true, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: int256(SWAP_TOKEN1_AMOUNT * 1e18),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PureFiSwapRouter(swapRouter).swap(
            pool,
            swapParams,
            testSettings,
            getTestSwapPayloadToken(address(token1), token1.decimals(), SWAP_TOKEN1_AMOUNT * 2)
        );

        addLiquidityParams.liquidityDelta = -5 ether;
        bytes memory removeLiquidityData = getTestRemoveLiquidityPayload();
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(pool, addLiquidityParams, removeLiquidityData);
        vm.stopBroadcast();
    }

    function test_ShouldRevertSwapTokenExceedsPackagExactOutput() public {
        vm.startBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory modifyLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 10 ether,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(
            pool,
            modifyLiquidityParams,
            getTestModifyLiquidityPayload(token0.decimals(), LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT)
        );

        PureFiSwapRouter.TestSettings memory testSettings =
            PureFiSwapRouter.TestSettings({takeClaims: true, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            //use library for conversion
            amountSpecified: int256(SWAP_TOKEN1_AMOUNT * 1e18),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory swapPayload = getTestSwapPayloadToken(address(token1), 0, SWAP_TOKEN1_AMOUNT);

        vm.expectRevert();
        PureFiSwapRouter(swapRouter).swap(pool, swapParams, testSettings, swapPayload);
        vm.stopBroadcast();
    }

    function test_ShouldRevertSwapTokenExceedsPackageExactInput() public {
        vm.startBroadcast();

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory modifyLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 10 ether,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(
            pool,
            modifyLiquidityParams,
            getTestModifyLiquidityPayload(token0.decimals(), LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT)
        );

        PureFiSwapRouter.TestSettings memory testSettings =
            PureFiSwapRouter.TestSettings({takeClaims: true, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false,
            //use library for conversion
            amountSpecified: -1 * int256(SWAP_TOKEN1_AMOUNT * 1e18),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory swapPayload = getTestSwapPayloadToken(address(token1), 0, SWAP_TOKEN1_AMOUNT);

        vm.expectRevert();
        PureFiSwapRouter(swapRouter).swap(pool, swapParams, testSettings, swapPayload);
        vm.stopBroadcast();
    }

    function test_ShouldExactInputSwapCorrect() external {
        vm.startBroadcast();
        vm.deal(msg.sender, 1e26);

        PoolKey memory pool = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: SWAP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: verifierHook
        });

        IPoolManager.ModifyLiquidityParams memory modifyLiquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: 1000 ether,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity{value: 1000 ether}(
            pool,
            modifyLiquidityParams,
            getTestModifyLiquidityPayload(token0.decimals(), LIQ_TOKEN0_AMOUNT, token1.decimals(), LIQ_TOKEN1_AMOUNT)
        );

        PureFiSwapRouter.TestSettings memory testSettings =
            PureFiSwapRouter.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -14_000_000_000_000,
            sqrtPriceLimitX96: 78_435_687_908_761_292_820_266_210_677
        });

        PureFiSwapRouter(swapRouter).swap(
            pool, swapParams, testSettings, getTestSwapPayloadToken(address(token0), 0, 14_000_000_000_000)
        );

        modifyLiquidityParams.liquidityDelta = -5 ether;
        modifyLiquidityRouter.modifyLiquidity(pool, modifyLiquidityParams, getTestRemoveLiquidityPayload());

        vm.stopBroadcast();
    }
}
