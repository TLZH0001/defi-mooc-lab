//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    address target_address = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
    address me = address(this);
    address AavePool = 0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9;
    address USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; 
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;  
    address UniswapFactory = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here *** 
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    receive() external payable {}
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***
        ILendingPool lending_pool = ILendingPool(0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9);
        uint256 total_collatera_ETH = 0;
        uint256 total_debt_ETH = 0;
        uint256 avail_borrows_ETH = 0;
        uint256  cur_liq_thre = 0;
        uint256 ltv = 0;
        uint256 health_factor = 0;

        IUniswapV2Factory factory = IUniswapV2Factory(UniswapFactory);
        // order : WBTC, WETH, USDT
        address WETH_USDT_pair_address = factory.getPair(WETH, USDT);
        IUniswapV2Pair WETH_USDT_pair = IUniswapV2Pair(WETH_USDT_pair_address);
        uint256 amt = 100000000000;

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        (total_collatera_ETH, total_debt_ETH, avail_borrows_ETH, cur_liq_thre, ltv, health_factor) = lending_pool.getUserAccountData(target_address);
        require(health_factor < (10 ** health_factor_decimals), "sercurity check fails");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***
        WETH_USDT_pair.swap(0, amt, me, abi.encode("flash loan"));

        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***
        uint256 my_eth = IERC20(WETH).balanceOf(address(this));
        IWETH(WETH).withdraw(my_eth);
        msg.sender.call{value: my_eth}("");
        // END TODO
    }

    // required by the swap
    function uniswapV2Call(
        address,
        uint256,
        uint256 amount1,
        bytes calldata
    ) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        ILendingPool lending_pool = ILendingPool(0x7d2768de32b0b80b7a3454c06bdac94a69ddc7a9);
        IERC20 usdt_tokken = IERC20(USDT);
        IERC20 wbtc_tokken = IERC20(WBTC);
        IERC20 weth_tokken = IERC20(WETH);
        // order : WBTC, WETH, USDT

        // 2.1 liquidate the target user
        //    *** Your code here ***
        usdt_tokken.approve(lending_pool, amount1);
        lending_pool.liquidationCall(WBTC, USDT, target_address, amount1, false);
       

        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        IUniswapV2Factory factory = IUniswapV2Factory(UniswapFactory);
        // order : WBTC, WETH, USDT
        address WBTC_WETH_pair_address = factory.getPair(WBTC, WETH);
        IUniswapV2Pair WBTC_WETH_pair = IUniswapV2Pair(WBTC_WETH_pair_address);

        uint256 my_wbtc = wbtc_tokken.balanceOf(me);
        wbtc_tokken.approve(WBTC_WETH_pair_address, my_wbtc);
        wbtc_tokken.transfer(WBTC_WETH_pair_address, my_wbtc);

        uint256 wbtc_reserved = 0;
        uint256 weth_reserved = 0;
        uint256 tblock = 0;
        (wbtc_resrved, weth_reserved, tblock)= WBTC_WETH_pair.getReserves();
        uint256 amt = getAmountOut(my_wbtc, wbtc_reserved, weth_reserved);
        WBTC_WETH_pair.swap(0, amt, me, "");

        // 2.3 repay
        //    *** Your code here ***
        // order : WBTC, WETH, USDT
        address WETH_USDT_pair_address = factory.getPair(WETH, USDT);
        IUniswapV2Pair WETH_USDT_pair = IUniswapV2Pair(WETH_USDT_pair_address);
        uint256 weth_reserved2 = 0;
        uint256 usdt_reserved = 0;
        uint256 tblock2 = 0;
        (weth_reserved2, usdt_reserved, tblock2) = WETH_USDT_pair.getReserves();
        uint256 weth_amt = getAmountIn(amount1, weth_reserved2, usdt_reserved);
        weth_tokken.approve(WETH_USDT_pair_address, weth_amt);
        weth_tokken.transfer(WETH_USDT_pair_address, weth_amt);
        // END TODO
    }
}
