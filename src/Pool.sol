// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Token} from "./Token.sol";

contract Pool {
    Token public immutable token0;
    Token public immutable token1;

    uint256 public reserve0;
    uint256 public reserve1;

    error ZeroInput();
    error NoLiquidity();
    error InvalidToken();
    error SlippageExceeded(uint256 got, uint256 min);
    error ZeroOutput();

    event Swap(address indexed trader, address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(Token _token0, Token _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    /// @dev Bootstrap only. LP shares will be added later.
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        token0.transferFrom(msg.sender, address(this), amount0);
        token1.transferFrom(msg.sender, address(this), amount1);

        reserve0 += amount0;
        reserve1 += amount1;
    }

    function swap(Token tokenIn, uint256 amountIn, uint256 minAmountOut) external returns (uint256 amountOut) {
        // Checks: only accept the two tokens belonging to this pool.
        if (tokenIn != token0 && tokenIn != token1) {
            revert InvalidToken();
        }

        Token tokenOut;

        // Calculate output and update both reserves before token calls.
        if (tokenIn == token0) {
            tokenOut = token1;

            amountOut = getAmountOut(amountIn, reserve0, reserve1);

            if (amountOut == 0) {
                revert ZeroOutput();
            }

            if (amountOut < minAmountOut) {
                revert SlippageExceeded(amountOut, minAmountOut);
            }

            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            tokenOut = token0;

            amountOut = getAmountOut(amountIn, reserve1, reserve0);

            if (amountOut == 0) {
                revert ZeroOutput();
            }

            if (amountOut < minAmountOut) {
                revert SlippageExceeded(amountOut, minAmountOut);
            }

            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        // Interactions: pull input tokens and send output tokens.
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(msg.sender, amountOut);

        emit Swap(msg.sender, address(tokenIn), amountIn, amountOut);
    }

    /// @notice Calculates output using the constant-product formula, without fees.
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

        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    }
}
