// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Token} from "./Token.sol";
import {Math} from "./Math.sol";

contract Pool {
    Token public immutable token0;
    Token public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalShares;
    mapping(address => uint256) public shares;

    uint256 private constant MINIMUM_LIQUIDITY = 100;

    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    error ZeroInput();
    error NoLiquidity();
    error InvalidToken();
    error SlippageExceeded(uint256 got, uint256 min);
    error ZeroOutput();
    error ZeroShares();
    error InsufficientShares(uint256 have, uint256 want);

    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    event AddLiquidity(address indexed provider, uint256 amount0, uint256 amount1, uint256 sharesMinted);

    event RemoveLiquidity(address indexed provider, uint256 sharesBurned, uint256 amount0, uint256 amount1);

    constructor(Token _token0, Token _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /// @dev Adds liquidity and mints non-transferable LP shares.
    function addLiquidity(uint256 amount0, uint256 amount1, uint256 minShares) external returns (uint256 sharesMinted) {
        if (amount0 == 0 || amount1 == 0) {
            revert ZeroShares();
        }

        bool firstDeposit = totalShares == 0;

        if (firstDeposit) {
            // First deposit: geometric mean, minus locked shares.
            uint256 initialShares = Math.sqrt(amount0 * amount1);

            if (initialShares <= MINIMUM_LIQUIDITY) {
                revert ZeroShares();
            }

            sharesMinted = initialShares - MINIMUM_LIQUIDITY;
        } else {
            // Later deposits mint shares based on the smaller ratio.
            uint256 shares0 = (amount0 * totalShares) / reserve0;
            uint256 shares1 = (amount1 * totalShares) / reserve1;

            sharesMinted = shares0 < shares1 ? shares0 : shares1;

            if (sharesMinted == 0) {
                revert ZeroShares();
            }
        }

        // Slippage protection: check before changing state or moving tokens.
        if (sharesMinted < minShares) {
            revert SlippageExceeded(sharesMinted, minShares);
        }

        // Effects: record shares and reserves.
        shares[msg.sender] += sharesMinted;

        if (firstDeposit) {
            totalShares = sharesMinted + MINIMUM_LIQUIDITY;
        } else {
            totalShares += sharesMinted;
        }

        reserve0 += amount0;
        reserve1 += amount1;

        // Interactions: pull in both tokens.
        token0.transferFrom(msg.sender, address(this), amount0);
        token1.transferFrom(msg.sender, address(this), amount1);

        emit AddLiquidity(msg.sender, amount0, amount1, sharesMinted);
    }

    function removeLiquidity(uint256 sharesToBurn) external returns (uint256 amount0, uint256 amount1) {
        // Checks: the provider must own enough shares.
        uint256 providerShares = shares[msg.sender];

        if (providerShares < sharesToBurn) {
            revert InsufficientShares(providerShares, sharesToBurn);
        }

        if (sharesToBurn == 0) {
            revert ZeroOutput();
        }

        // Calculate the provider's proportional share of each reserve.
        // Integer division rounds down, in favour of the pool.
        amount0 = (sharesToBurn * reserve0) / totalShares;
        amount1 = (sharesToBurn * reserve1) / totalShares;

        if (amount0 == 0 || amount1 == 0) {
            revert ZeroOutput();
        }

        // Effects: burn shares and update accounting before token calls.
        shares[msg.sender] = providerShares - sharesToBurn;
        totalShares -= sharesToBurn;
        reserve0 -= amount0;
        reserve1 -= amount1;

        // Interactions: return the withdrawn tokens.
        token0.transfer(msg.sender, amount0);
        token1.transfer(msg.sender, amount1);

        emit RemoveLiquidity(msg.sender, sharesToBurn, amount0, amount1);
    }

    function swap(Token tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        // Checks: accept only the two tokens in this pool.
        if (address(tokenIn) != address(token0) && address(tokenIn) != address(token1)) {
            revert InvalidToken();
        }

        // Determine direction once.
        bool zeroForOne = address(tokenIn) == address(token0);

        Token tokenOut;
        uint256 reserveIn;
        uint256 reserveOut;

        if (zeroForOne) {
            tokenOut = token1;
            reserveIn = reserve0;
            reserveOut = reserve1;
        } else {
            tokenOut = token0;
            reserveIn = reserve1;
            reserveOut = reserve0;
        }

        // Checks: calculate output and enforce the slippage limit.
        amountOut = getAmountOut(amountIn, reserveIn, reserveOut);

        if (amountOut == 0) {
            revert ZeroOutput();
        }

        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        // Effects: update state before interacting with token contracts.
        if (zeroForOne) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // Interactions: move the tokens.
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, amountOut);

        emit Swap(msg.sender, address(tokenIn), amountIn, amountOut);
    }

    /// @notice Calculates output using the constant-product formula with a 0.3% fee.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) {
            revert ZeroInput();
        }

        if (reserveIn == 0 || reserveOut == 0) {
            revert NoLiquidity();
        }

        uint256 amountInWithFee = amountIn * FEE_NUMERATOR;

        amountOut = (amountInWithFee * reserveOut) / (reserveIn * FEE_DENOMINATOR + amountInWithFee);
    }
}
