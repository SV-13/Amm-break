// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Math {
    /// @notice Integer square root, rounded down.
    /// @dev Returns the largest r such that r * r <= y.
    function sqrt(uint256 y) internal pure returns (uint256 r) {
        if (y == 0) {
            return 0;
        }

        // Start at or above the true square root.
        r = y / 2 + 1;

        while (true) {
            uint256 next = (r + y / r) / 2;

            // Once the estimate stops shrinking, r is the floor root.
            if (next >= r) {
                return r;
            }

            r = next;
        }
    }
}
