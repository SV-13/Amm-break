// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Pool {
    error ZeroInput();
    error NoLiquidity();

    /// @notice Calculates output using the constant-product formula, without fees.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        public
        pure
        returns (uint256 amountOut)
    {
        // Reject a trade with no input.
        if (amountIn == 0) {
            revert ZeroInput();
        }

        // Both reserves must contain liquidity.
        if (reserveIn == 0 || reserveOut == 0) {
            revert NoLiquidity();
        }

        // Constant-product formula; integer division rounds down.
        amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
    }
}
