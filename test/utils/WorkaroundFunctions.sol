// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

contract WorkaroundFunctions {
    struct WorkaroundPackageType32 {
        uint8 packageType;
        uint256 session;
        uint256 rule;
        address from;
        address to;
        uint256 tokenData0;
    }

    struct WorkaroundPackageType48 {
        uint8 packageType;
        uint256 session;
        uint256 rule;
        address from;
        address to;
        uint256 tokenData0;
        uint256 tokenData1;
    }

    /**
     * @dev Encodes token data into a single unsigned 256-bit integer
     * @param token Token address (160 bits)
     * @param decimals Token's decimal places (8 bits)
     * @param amount Normalized token value without decimal shift
     * @return encodedTokenData Unsigned 256-bit integer with encoded value structure:
     *   - Top 160 bits: token address
     *   - Next 8 bits: decimal places
     *   - Last 88 bits: amount
     *
     * @notice Input requirements:
     *   - For 0.1 ETH: decimals = 17, amount = 1
     *   - For 59999 wei: decimals = 0, amount = 59999
     *   - For 324 ETH: decimals = 18, amount = 324
     */
    function workaround_encodeTokenData(address token, uint8 decimals, uint256 amount)
        public
        pure
        returns (uint256 encodedTokenData)
    {
        assembly {
            encodedTokenData := shl(8, token)
            encodedTokenData := add(decimals, encodedTokenData)
            encodedTokenData := shl(88, encodedTokenData)
            encodedTokenData := add(encodedTokenData, amount)
        }
    }
}
