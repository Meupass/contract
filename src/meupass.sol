// SPDX-License-Identifier: MIT

pragma solidity ^0.8.5;

// Importing required contracts and libraries
import "./ERC20.sol";
import "./IPancake.sol";
import "./SwapHelper.sol";
import "./Ownable.sol";
import "./Strings.sol";

// Definition of the main contract
contract Meupass is Ownable, ERC20 {
    // Token name and symbol
    string constant _name = "Meupass";
    string constant _symbol = "MPS";

    // Token supply control
    uint8 constant decimal = 18; // Standard decimal places
    uint256 constant maxSupply = 25_000_000 * (10**decimal); // Maximum token supply
    uint8 constant decimalUSDT = 18; // Decimal places for USDT

    // Fees defined for development wallets
    uint256 public feeValue = 600; // 6%

    // Special permission mappings for fee exemption
    mapping(address => bool) public excludeFromFee; // Fee exemption control
    mapping(address => bool) public excludeFromFeeReceiver; // Fee exemption control for receivers

    bool public isTradingEnabled; // Control for enabling trading

    // Configuration of trading pairs and special wallets
    address public tokenPool; // Liquidity pool
    address public feeWallet; // Wallet to store fees

    SwapHelper private _sh; // Instance to assist swap operations

    // Definition of specific pairs
    address public WBNB_USDT_PAIR = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;
    address public WBNB_TOKEN_PAIR;

    // Constant addresses for special addresses such as burn and zero
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    bool private _reentrancyProtect = false; // Reentrancy protection

    // Event to log fee processing details
    event FeeProcessed(
        uint256 feeTokenAmount,
        uint256 wbnbAmount,
        uint256 usdtAmount,
        bool success
    );

    // Event to log trading activation
    event TradingEnabled(address indexed owner);
	
	 // Configures fee exemption
    function setExcludeFee(address account, bool operation) public onlyOwner {
        excludeFromFee[account] = operation;
    }

    function setExcludeFeeReceiver(address account, bool operation)
        public
        onlyOwner
    {
        excludeFromFeeReceiver[account] = operation;
    }
	
	function getSwapHelperAddress() external view returns (address) { return address(_sh); }

    // Returns the owner's address
    function getOwner() external view returns (address) {
        return owner();
    }

    // Contract constructor
    constructor() ERC20(_name, _symbol) {
        // PancakeSwap router configuration
        PancakeRouter router = PancakeRouter(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        WBNB_TOKEN_PAIR = address(
            PancakeFactory(router.factory()).createPair(WBNB, address(this))
        );
        tokenPool = WBNB_TOKEN_PAIR;

        // Initial permission setup
        excludeFromFee[address(this)] = true; // Exclude contract from fees

        // Owner setup
        address ownerWallet = 0x50C81f911e6f4E37024336A5949Ad89950BE1Cab;
        address liquidityManager = 0x873d3a32e9ED9dA30A345c8Db1c91F57b694C7f1;
        excludeFromFee[ownerWallet] = true;
        excludeFromFee[liquidityManager] = true;

        // Development wallets configuration (2% staking, 2% liquidity, 2% project fees)
        feeWallet = 0xEc5980B14eFf51ecae00ccDfcA3119D74f4aa34a;
        excludeFromFee[feeWallet] = true;

        // Swap helper setup
        _sh = new SwapHelper();
        _sh.safeApprove(WBNB, address(this), type(uint256).max);
        _sh.transferOwnership(ownerWallet);

        // Initial token minting to the liquidity address
        _mint(liquidityManager, 25_000_000 * (10**decimal));

        // Transfers ownership to the multi-signature wallet
        transferOwnership(ownerWallet);
    }

    // Enables token trading
    function enableTrading() external onlyOwner {
        isTradingEnabled = true;
        emit TradingEnabled(msg.sender);
    }

    // Internal transfer function with fee handling and sell logic
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        require(!_reentrancyProtect, "ReentrancyGuard: reentrant call happens."); // Prevents reentrancy attacks
        _reentrancyProtect = true;
        require(
            sender != address(0) && recipient != address(0),
            "transfer from the zero address."
        ); // Ensures valid addresses
        require(
            isTradingEnabled ||
                excludeFromFee[sender] ||
                excludeFromFeeReceiver[recipient],
            "Trading is currently disabled."
        ); // Checks if trading is enabled or sender/receiver is excluded from fees

        uint256 senderBalance = _balances[sender];
        require(
            senderBalance >= amount,
            "transfer amount exceeds your balance."
        ); // Ensures sufficient balance

        uint256 newSenderBalance = senderBalance - amount;
        _balances[sender] = newSenderBalance;

        uint256 feeAmount = 0;

        // Calculate and apply fees on sell transactions
        if (recipient == tokenPool) {
            if (!excludeFromFee[sender] && !excludeFromFeeReceiver[recipient]) {
                feeAmount = (feeValue * amount) / 10000; // Calculates fee based on set percentage
                if (feeAmount > 0) {
                    bool success = exchangeFeeParts(feeAmount);
                    require(success, "Fee processing failed.");
                }
            }
        }

        uint256 newRecipientAmount = _balances[recipient] +
            (amount - feeAmount);
        _balances[recipient] = newRecipientAmount;

        _reentrancyProtect = false;
        emit Transfer(sender, recipient, amount); // Emits transfer event
    }

    // Function to calculate the output amount based on input and reserves
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "Input amount must be greater than zero.");
        require(
            reserveIn > 0 && reserveOut > 0,
            "Insufficient liquidity in reserves."
        );
        uint256 amountInWithFee = amountIn * 9975; // 0.25% fee deducted
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * 10000) + amountInWithFee;
        amountOut = numerator / denominator; // Returns the output amount based on liquidity pools
    }

    // Determines whether the token order in a pair is reversedTransfer
    function isReversed(address pair, address tokenA)
        internal
        view
        returns (bool)
    {
        address token0;
        bool failed = false;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(
                emptyPointer,
                0x0dfe168100000000000000000000000000000000000000000000000000000000
            )
            failed := iszero(
                staticcall(gas(), pair, emptyPointer, 0x04, emptyPointer, 0x20)
            )
            token0 := mload(emptyPointer)
        }
        if (failed) revert("Unable to check token order in pair.");
        return token0 != tokenA; // Returns true if token order is reversed
    }

    // Optimized token transfer function using low-level assembly calls
    function tokenTransfer(
        address token,
        address recipient,
        uint256 amount
    ) internal {
        bool failed = false;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(
                emptyPointer,
                0xa9059cbb00000000000000000000000000000000000000000000000000000000
            )
            mstore(add(emptyPointer, 0x04), recipient)
            mstore(add(emptyPointer, 0x24), amount)
            failed := iszero(call(gas(), token, 0, emptyPointer, 0x44, 0, 0))
        }
        if (failed) revert("Token transfer failed.");
    }

    // Transferência otimizada de tokens usando transferFrom
    function tokenTransferFrom(
        address token,
        address from,
        address recipient,
        uint256 amount
    ) internal {
        bool failed = false;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(
                emptyPointer,
                0x23b872dd00000000000000000000000000000000000000000000000000000000
            )
            mstore(add(emptyPointer, 0x04), from)
            mstore(add(emptyPointer, 0x24), recipient)
            mstore(add(emptyPointer, 0x44), amount)
            failed := iszero(call(gas(), token, 0, emptyPointer, 0x64, 0, 0))
        }
        if (failed) revert("Unable to transfer from token to address.");
    }

    // Realiza troca em pool de liquidez
    function swapToken(
        address pair,
        uint256 amount0Out,
        uint256 amount1Out,
        address receiver
    ) internal {
        bool failed = false;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(
                emptyPointer,
                0x022c0d9f00000000000000000000000000000000000000000000000000000000
            )
            mstore(add(emptyPointer, 0x04), amount0Out)
            mstore(add(emptyPointer, 0x24), amount1Out)
            mstore(add(emptyPointer, 0x44), receiver)
            mstore(add(emptyPointer, 0x64), 0x80)
            mstore(add(emptyPointer, 0x84), 0)
            failed := iszero(call(gas(), pair, 0, emptyPointer, 0xa4, 0, 0))
        }
        if (failed) revert("Unable to swap to receiver.");
    }

    // Returns the token balance of an address
    function getTokenBalanceOf(address token, address holder)
        internal
        view
        returns (uint112 tokenBalance)
    {
        bool failed = false;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(
                emptyPointer,
                0x70a0823100000000000000000000000000000000000000000000000000000000
            )
            mstore(add(emptyPointer, 0x04), holder)
            failed := iszero(
                staticcall(gas(), token, emptyPointer, 0x24, emptyPointer, 0x40)
            )
            tokenBalance := mload(emptyPointer)
        }
        if (failed) revert("Unable to get balance from wallet.");
    }

    // Function to manage fees and redistribution
    function exchangeFeeParts(uint256 feeTokenAmount) private returns (bool) {
        if (_msgSender() == WBNB_TOKEN_PAIR) return false; // Proteção contra reentrância

        // Swap MPS -> WBNB
        uint256 wbnbAmountReceived = swapToWBNB(feeTokenAmount);

        // Swap WBNB -> USDT
        uint256 usdtAmountReceived = swapToUSDT(wbnbAmountReceived);

        // Transferir USDT para a carteira de taxas
        tokenTransfer(USDT, feeWallet, usdtAmountReceived);

        // Emitir evento de taxa processada
        emit FeeProcessed(
            feeTokenAmount,
            wbnbAmountReceived,
            usdtAmountReceived,
            true
        );

        return true;
    }

    // 🔹 Função separada para swap MPS -> WBNB
    function swapToWBNB(uint256 feeTokenAmount) private returns (uint256) {
        (uint112 reserve0, uint112 reserve1) = getTokenReserves(
            WBNB_TOKEN_PAIR
        );
        bool reversed = isReversed(WBNB_TOKEN_PAIR, WBNB);
        if (reversed) (reserve0, reserve1) = (reserve1, reserve0);

        uint256 wbnbAmountExpected = getAmountOut(
            feeTokenAmount,
            reserve1,
            reserve0
        );
        uint256 minWbnbAmount = (wbnbAmountExpected * 90) / 100; // 10% slippage protection

        _balances[WBNB_TOKEN_PAIR] += feeTokenAmount;
        address shAddress = address(_sh);
        uint256 wbnbBalanceBefore = getTokenBalanceOf(WBNB, shAddress);

        swapToken(
            WBNB_TOKEN_PAIR,
            reversed ? 0 : wbnbAmountExpected,
            reversed ? wbnbAmountExpected : 0,
            shAddress
        );

        uint256 wbnbAmountReceived = getTokenBalanceOf(WBNB, shAddress) -
            wbnbBalanceBefore;
        require(
            wbnbAmountReceived >= minWbnbAmount,
            "Slippage too high: WBNB received < 90% expected."
        );

        return wbnbAmountReceived;
    }

    // 🔹 Função separada para swap WBNB -> USDT
    function swapToUSDT(uint256 wbnbAmountReceived) private returns (uint256) {
        (uint112 reserve0, uint112 reserve1) = getTokenReserves(WBNB_USDT_PAIR);
        bool reversed = isReversed(WBNB_USDT_PAIR, WBNB);
        if (reversed) (reserve0, reserve1) = (reserve1, reserve0);

        uint256 usdtAmountExpected = getAmountOut(
            wbnbAmountReceived,
            reserve0,
            reserve1
        );
        uint256 minUsdtAmount = (usdtAmountExpected * 95) / 100; // 5% slippage protection

        uint256 usdtBalanceBefore = getTokenBalanceOf(USDT, address(this));
        tokenTransferFrom(
            WBNB,
            address(_sh),
            WBNB_USDT_PAIR,
            wbnbAmountReceived
        );

        swapToken(
            WBNB_USDT_PAIR,
            reversed ? usdtAmountExpected : 0,
            reversed ? 0 : usdtAmountExpected,
            address(this)
        );

        uint256 usdtAmountReceived = getTokenBalanceOf(USDT, address(this)) -
            usdtBalanceBefore;
        require(
            usdtAmountReceived >= minUsdtAmount,
            "Slippage too high: USDT received < 95% expected."
        );

        return usdtAmountReceived;
    }

    // Function to retrieve liquidity pair reserves
    function getTokenReserves(address pairAddress)
        internal
        view
        returns (uint112 reserve0, uint112 reserve1)
    {
        bool failed = false;
        assembly {
            let emptyPointer := mload(0x40)
            mstore(
                emptyPointer,
                0x0902f1ac00000000000000000000000000000000000000000000000000000000
            )
            failed := iszero(
                staticcall(
                    gas(),
                    pairAddress,
                    emptyPointer,
                    0x4,
                    emptyPointer,
                    0x40
                )
            )
            reserve0 := mload(emptyPointer)
            reserve1 := mload(add(emptyPointer, 0x20))
        }
        if (failed) revert("Unable to get reserves from pair.");
    }
}
