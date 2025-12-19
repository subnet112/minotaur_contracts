// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "forge-std/StdCheats.sol";
import {Vm} from "forge-std/Vm.sol";

import {Settlement} from "../src/Settlement.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title ExecutionPlanSimulator
/// @notice Utility script to replay a solver-supplied execution plan against a fork
/// @dev Run with forge script --fork-url ... --sig "simulate()"
contract ExecutionPlanSimulator is Script, StdCheats {
    using stdJson for string;

    uint256 internal constant OWNER_PRIVATE_KEY = uint256(keccak256("settlement-owner"));
    uint256 internal constant RELAYER_PRIVATE_KEY = uint256(keccak256("sim-relayer"));
    
    // Fixed address for Settlement contract deployment (same across all forks)
    address internal constant SETTLEMENT_ADDRESS = 0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3;
    
    // Chain IDs
    uint256 internal constant CHAIN_ETHEREUM = 1;
    uint256 internal constant CHAIN_BASE = 8453;
    uint256 internal constant CHAIN_ARBITRUM = 42161;
    uint256 internal constant CHAIN_OPTIMISM = 10;
    
    // WETH addresses per chain (need special deal() handling - proxy contracts)
    address internal constant WETH_ETHEREUM = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WETH_BASE = 0x4200000000000000000000000000000000000006;
    address internal constant WETH_ARBITRUM = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant WETH_OPTIMISM = 0x4200000000000000000000000000000000000006;
    
    // USDT addresses per chain (need special approve handling - non-standard ERC20)
    address internal constant USDT_ETHEREUM = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // Note: Base/Arbitrum/Optimism USDT are bridged versions with standard ERC20 behavior

    bytes32 private constant PERMIT_DATA_TYPEHASH =
        keccak256("PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)");
    bytes32 private constant ORDER_INTENT_TYPEHASH = keccak256(
        "OrderIntent(bytes32 quoteId,address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,address receiver,uint256 deadline,uint256 nonce,bytes32 interactionsHash,uint256 callValue,uint256 gasEstimate,PermitData permit)PermitData(uint8 permitType,bytes permitCall,uint256 amount,uint256 deadline)"
    );

    bytes32 private constant SWAP_SETTLED_TOPIC =
        keccak256("SwapSettled(bytes32,address,address,uint256,address,uint256,uint256,uint256,uint256)");

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function previewApproveCalldata(address spender, uint256 amount) external pure returns (bytes memory) {
        return abi.encodeWithSelector(IERC20.approve.selector, spender, amount);
    }

    function _resolveForkUrl() internal view returns (string memory) {
        string memory forkUrl = vm.envOr("SIM_FORK_URL", string(""));
        if (bytes(forkUrl).length != 0) {
            return forkUrl;
        }

        string memory infuraKey = vm.envOr("INFURA_API_KEY", string(""));
        require(bytes(infuraKey).length != 0, "SIM_FORK_URL or INFURA_API_KEY required");
        return string.concat("https://mainnet.infura.io/v3/", infuraKey);
    }

    function run() external {
        simulate();
    }

    /// @notice Executes the provided execution plan against the configured fork
    /// @dev Expects the following environment variables:
    ///  - SIM_FORK_URL: RPC URL for the fork (e.g. Anvil/Tenderly/mainnet archival)
    ///  - SIM_INPUT_PATH: path to a JSON file with schema:
    ///    { quoteDetails: { quoteId, settlement: { contractAddress, deadline, nonce, callValue, gasEstimate, executionPlan, permit }, details: { availableInputs: [{ user, asset, amount }], requestedOutputs: [{ receiver, asset, amount }] } }, signature }
    ///    Note: chainId is extracted from InteropAddress format in input fields
    function simulate() public {
        string memory inputPath = vm.envString("SIM_INPUT_PATH");
        string memory json = vm.readFile(inputPath);

        // Extract chainId from InteropAddress format (first bytes encode chain ID)
        // Try from first availableInput
        uint256 chainId = _extractChainIdFromInteropAddress(json, "$.quoteDetails.details.availableInputs[0].user");
        if (chainId == 0) {
            // Fallback: try to extract from asset field
            chainId = _extractChainIdFromInteropAddress(json, "$.quoteDetails.details.availableInputs[0].asset");
        }
        if (chainId == 0) {
            chainId = block.chainid; // Default to current chain
        }

        string memory forkUrl = _resolveForkUrl();
        uint256 forkBlock = _readUintOrDefault(json, "$.quoteDetails.settlement.executionPlan.blockNumber", 0);
        
        // Warn about stale blockNumbers (security concern: solver could use old blocks with better liquidity)
        if (forkBlock != 0) {
            // Get current block from RPC to check age
            vm.createSelectFork(forkUrl); // First fork to get current block
            uint256 currentBlock = block.number;
            vm.createSelectFork(forkUrl, forkBlock); // Then fork to specified block
            
            if (currentBlock > forkBlock) {
                uint256 blockAge = currentBlock - forkBlock;
                uint256 MAX_BLOCK_AGE = 256; // ~1 hour on Ethereum mainnet (~12s per block)
                
                if (blockAge > MAX_BLOCK_AGE) {
                    console2.log("\n[WARNING] BlockNumber is stale!");
                    console2.log("  - Fork block:", forkBlock);
                    console2.log("  - Current block:", currentBlock);
                    console2.log("  - Block age:", blockAge, "blocks");
                    console2.log("  - Max recommended:", MAX_BLOCK_AGE, "blocks (~1 hour on mainnet)");
                    console2.log("  - SECURITY RISK: Solver may be using old block with better liquidity/prices");
                    console2.log("  - Order may fail on-chain or execute at worse terms than simulated");
                    console2.log("  - Validators should reject orders with blockNumber older than 256 blocks\n");
                }
            }
        } else {
            vm.createSelectFork(forkUrl);
        }

        address owner = vm.addr(OWNER_PRIVATE_KEY);
        
        // Deploy Settlement contract at a fixed address for consistency across forks
        // Always deploy (or redeploy) to ensure the contract exists at the fixed address
        // This works even if the address has existing state from the fork
        
        // Clear any existing code at the address first (in case of fork state conflicts)
        vm.etch(SETTLEMENT_ADDRESS, bytes(""));
        
        // Get creation code and constructor args
        bytes memory creationCode = vm.getCode("src/Settlement.sol:Settlement");
        bytes memory constructorArgs = abi.encode(owner);
        
        // Place creation code + constructor args at the address
        vm.etch(SETTLEMENT_ADDRESS, abi.encodePacked(creationCode, constructorArgs));
        
        // Execute constructor by calling the address (this will run the constructor and return runtime bytecode)
        // Use a fresh address to avoid any address(this) issues
        address deployer = address(uint160(uint256(keccak256("settlement-deployer"))));
        vm.deal(deployer, 1 ether);
        vm.startPrank(deployer);
        (bool deploySuccess, bytes memory runtimeBytecode) = payable(SETTLEMENT_ADDRESS).call("");
        vm.stopPrank();
        require(deploySuccess, "Settlement constructor execution failed");
        
        // Replace creation code with runtime bytecode
        vm.etch(SETTLEMENT_ADDRESS, runtimeBytecode);
        
        // Verify deployment succeeded
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(SETTLEMENT_ADDRESS)
        }
        require(codeSize > 0, "Settlement deployment failed: no code at address after deployment");
        
        // Cast to Settlement contract instance
        Settlement settlement = Settlement(payable(SETTLEMENT_ADDRESS));
        vm.label(SETTLEMENT_ADDRESS, "Settlement");

        Settlement.ExecutionPlan memory plan = _parsePlan(json);
        (Settlement.OrderIntent memory intent, string memory originalQuoteId) = _parseIntent(json, settlement, plan);

        _prepareState(intent, settlement);
        address relayer = vm.addr(RELAYER_PRIVATE_KEY);
        vm.deal(relayer, intent.callValue + 1 ether);

        uint256 receiverBalanceBefore = intent.tokenOut.balanceOf(intent.receiver);

        vm.recordLogs();
        vm.startPrank(relayer);
        bool success = true;
        bytes memory errorData;
        string memory errorMessage = "";
        uint256 amountOut;
        uint256 gasBefore = gasleft();
        try settlement.executeOrder{value: intent.callValue}(intent, plan) returns (uint256 out) {
            amountOut = out;
        } catch (bytes memory errData) {
            success = false;
            errorData = errData;
            
            // If error data is empty, try to get more context
            if (errData.length == 0) {
                // Log additional context for empty revert
                console2.log("\n=== SIMULATION FAILED (Empty Revert) ===");
                console2.log("The transaction reverted but no error data was provided.");
                console2.log("This usually means:");
                console2.log("  - A plain revert() was called without a reason");
                console2.log("  - An assertion failed (require without message)");
                console2.log("  - An out-of-gas error occurred");
                console2.log("  - The revert happened in a low-level call that didn't bubble up error data");
                console2.log("\nCheck the trace above for the exact point of failure.");
                errorMessage = "Empty revert data - check trace for failure point";
            } else {
                // Decode and format errors for human readability
                errorMessage = _decodeAndFormatError(errData, intent, settlement);
                console2.log("\n=== SIMULATION FAILED ===");
                console2.log(errorMessage);
            }
        }
        uint256 gasAfter = gasleft();
        vm.stopPrank();

        uint256 gasUsed = gasBefore - gasAfter;
        uint256 receiverBalanceAfter = intent.tokenOut.balanceOf(intent.receiver);
        uint256 receiverDelta = receiverBalanceAfter - receiverBalanceBefore;

        uint256 feeAmount;
        Vm.Log[] memory recorded = vm.getRecordedLogs();
        for (uint256 i = 0; i < recorded.length; ++i) {
            Vm.Log memory entry = recorded[i];
            if (entry.topics.length == 3 && entry.topics[0] == SWAP_SETTLED_TOPIC) {
                ( , , , uint256 amountOutLog, uint256 feeAmountLog, , ) = abi.decode(
                    entry.data,
                    (address, uint256, address, uint256, uint256, uint256, uint256)
                );
                amountOut = amountOutLog;
                feeAmount = feeAmountLog;
                break;
            }
        }

        string memory root = "result";
        vm.serializeBool(root, "success", success);
        vm.serializeString(root, "quoteId", originalQuoteId);
        vm.serializeAddress(root, "settlement", address(settlement));
        vm.serializeAddress(root, "user", intent.user);
        vm.serializeAddress(root, "receiver", intent.receiver);
        vm.serializeAddress(root, "tokenIn", address(intent.tokenIn));
        vm.serializeAddress(root, "tokenOut", address(intent.tokenOut));
        vm.serializeUint(root, "amountIn", intent.amountIn);
        vm.serializeUint(root, "amountOut", amountOut);
        vm.serializeUint(root, "receiverDelta", receiverDelta);
        vm.serializeUint(root, "feeAmount", feeAmount);
        vm.serializeUint(root, "gasUsed", gasUsed);
        if (!success) {
            vm.serializeBytes(root, "errorData", errorData);
            // Include human-readable error message in JSON (re-decode to ensure we have settlement context)
            string memory errorMsgForJson = _decodeAndFormatError(errorData, intent, settlement);
            vm.serializeString(root, "errorMessage", errorMsgForJson);
        }
        string memory summaryJson = vm.serializeUint(root, "callValue", intent.callValue);
        console2.log("\n=== Simulation Summary ===");
        console2.log(summaryJson);

        if (!success) {
            // If error data is empty, provide a more helpful error message
            if (errorData.length == 0) {
                revert("Simulation failed with empty revert data. Check the trace above for the exact failure point.");
            }
            assembly {
                revert(add(errorData, 32), mload(errorData))
            }
        }
    }

    function _parsePlan(string memory json) internal view returns (Settlement.ExecutionPlan memory plan) {
        plan.preInteractions = _parseInteractions(json, "$.quoteDetails.settlement.executionPlan.preInteractions");
        plan.interactions = _parseInteractions(json, "$.quoteDetails.settlement.executionPlan.interactions");
        plan.postInteractions = _parseInteractions(json, "$.quoteDetails.settlement.executionPlan.postInteractions");
    }

    function _sliceBytes(bytes memory data, uint256 start) private pure returns (bytes memory result) {
        require(start <= data.length, "slice out of bounds");
        uint256 newLength = data.length - start;
        result = new bytes(newLength);
        for (uint256 i = 0; i < newLength; ++i) {
            result[i] = data[i + start];
        }
    }

    function _parseIntent(
        string memory json,
        Settlement settlement,
        Settlement.ExecutionPlan memory plan
    ) internal view returns (Settlement.OrderIntent memory intent, string memory originalQuoteId) {
        // Read quoteId as string (can be any string, not just hex)
        originalQuoteId = _readStringOrDefault(json, "$.quoteDetails.quoteId", "sim-quote");
        // Hash the string to bytes32 for use in the contract
        intent.quoteId = keccak256(bytes(originalQuoteId));
        
        // Read from first availableInput (assuming single swap)
        intent.user = _requireAddressOrInteropAddress(json, "$.quoteDetails.details.availableInputs[0].user");
        intent.tokenIn = IERC20(_requireAddress(json, "$.quoteDetails.details.availableInputs[0].asset"));
        intent.tokenOut = IERC20(_requireAddress(json, "$.quoteDetails.details.requestedOutputs[0].asset"));
        intent.amountIn = _requireUint(json, "$.quoteDetails.details.availableInputs[0].amount");
        intent.minAmountOut = _readUintOrDefault(json, "$.quoteDetails.details.requestedOutputs[0].amount", intent.amountIn);
        intent.receiver = _readAddressOrInteropAddress(json, "$.quoteDetails.details.requestedOutputs[0].receiver", intent.user);
        intent.deadline = _readUintOrDefault(json, "$.quoteDetails.settlement.deadline", block.timestamp + 30 minutes);
        intent.nonce = _readUintOrDefault(json, "$.quoteDetails.settlement.nonce", 1);
        intent.callValue = _readUintOrDefault(json, "$.quoteDetails.settlement.callValue", 0);
        intent.gasEstimate = _readUintOrDefault(json, "$.quoteDetails.settlement.gasEstimate", 150_000);

        intent.permit = _parsePermit(json, intent, settlement);
        
        // Compute the hash from the execution plan
        bytes32 computedHash = settlement.hashExecutionPlan(plan);
        
        // If an interactionsHash is provided in JSON, validate it matches the computed hash
        if (vm.keyExists(json, "$.quoteDetails.settlement.interactionsHash")) {
            bytes32 providedHash = _readBytes32OrDefault(json, "$.quoteDetails.settlement.interactionsHash", bytes32(0));
            if (providedHash != computedHash) {
                console2.log("ERROR: InteractionsHash mismatch!");
                console2.log("Provided hash:");
                console2.logBytes32(providedHash);
                console2.log("Computed hash from execution plan:");
                console2.logBytes32(computedHash);
                revert("InteractionsHashMismatch: provided hash does not match computed hash from execution plan");
            }
        }
        
        // Use the computed hash (which matches the provided one if it was provided)
        intent.interactionsHash = computedHash;
        
        // Require signature to be provided in JSON
        require(vm.keyExists(json, "$.signature"), "Missing required signature field in JSON. Provide signature at $.signature");
        intent.userSignature = _readBytesOrDefault(json, "$.signature", bytes(""));
        require(intent.userSignature.length > 0, "Signature provided but empty");
    }

    function _parsePermit(
        string memory json,
        Settlement.OrderIntent memory intent,
        Settlement settlement
    ) internal view returns (Settlement.PermitData memory permit) {
        string memory kind = _readStringOrDefault(json, "$.quoteDetails.settlement.permit.permitType", "standard_approval");
        permit.amount = _readUintOrDefault(json, "$.quoteDetails.settlement.permit.amount", intent.amountIn);
        permit.deadline = _readUintOrDefault(json, "$.quoteDetails.settlement.permit.deadline", intent.deadline);

        // Handle snake_case permit types from new schema
        if (_equalsIgnoreCase(kind, "none")) {
            permit.permitType = Settlement.PermitType.None;
            return permit;
        }
        if (_equalsIgnoreCase(kind, "standard_approval") || _equalsIgnoreCase(kind, "StandardApproval")) {
            permit.permitType = Settlement.PermitType.StandardApproval;
            return permit;
        }
        if (_equalsIgnoreCase(kind, "eip2612") || _equalsIgnoreCase(kind, "EIP2612")) {
            permit.permitType = Settlement.PermitType.EIP2612;
            permit.permitCall = _readBytesOrBuildEIP2612(json, intent, settlement, permit);
            return permit;
        }
        if (_equalsIgnoreCase(kind, "eip3009") || _equalsIgnoreCase(kind, "EIP3009")) {
            permit.permitType = Settlement.PermitType.EIP3009;
            permit.permitCall = _readBytesOrBuildEIP3009(json);
            return permit;
        }

        permit.permitType = Settlement.PermitType.Custom;
        permit.permitCall = _readBytesOrDefault(json, "$.quoteDetails.settlement.permit.callData", bytes(""));
        return permit;
    }

    function _prepareState(Settlement.OrderIntent memory intent, Settlement settlement) internal {
        address user = intent.user;
        address settlementAddr = address(settlement);

        address tokenIn = address(intent.tokenIn);
        
        if (_isUSDT(tokenIn)) {
            // USDT (Ethereum mainnet) has a unique storage layout that breaks Foundry's deal()
            // Use vm.store to directly set the balance in USDT's balances mapping
            // USDT balances are stored at slot 2, key is the address
            bytes32 balanceSlot = keccak256(abi.encode(user, uint256(2)));
            vm.store(tokenIn, balanceSlot, bytes32(intent.amountIn));
            
            // USDT's approve doesn't return a boolean, so we need to use low-level call
            // Otherwise the IERC20.approve call reverts expecting a return value
            vm.startPrank(user);
            (bool success,) = tokenIn.call(abi.encodeWithSelector(IERC20.approve.selector, settlementAddr, type(uint256).max));
            require(success, "USDT approve failed");
            vm.stopPrank();
        } else {
            if (_isWETH(tokenIn)) {
                // WETH is a proxy contract on most chains, use deal() without adjusting total supply
                deal(tokenIn, user, intent.amountIn, false);
            } else {
                // Standard ERC20 tokens: use deal() with total supply adjustment
                deal(tokenIn, user, intent.amountIn, true);
            }
            
            vm.startPrank(user);
            intent.tokenIn.approve(settlementAddr, type(uint256).max);
            vm.stopPrank();
        }
    }
    
    /// @dev Check if token is WETH on any supported chain
    function _isWETH(address token) internal view returns (bool) {
        // Check against known WETH addresses for each chain
        // Using block.chainid allows automatic detection after forking
        uint256 chainId = block.chainid;
        
        if (chainId == CHAIN_ETHEREUM) return token == WETH_ETHEREUM;
        if (chainId == CHAIN_BASE) return token == WETH_BASE;
        if (chainId == CHAIN_ARBITRUM) return token == WETH_ARBITRUM;
        if (chainId == CHAIN_OPTIMISM) return token == WETH_OPTIMISM;
        
        // Fallback: check all known WETH addresses for unknown chains
        return token == WETH_ETHEREUM || 
               token == WETH_BASE || 
               token == WETH_ARBITRUM || 
               token == WETH_OPTIMISM;
    }
    
    /// @dev Check if token is USDT with non-standard behavior
    function _isUSDT(address token) internal view returns (bool) {
        // Only Ethereum mainnet USDT has the non-standard approve behavior
        // Bridged USDT on L2s typically follows standard ERC20
        if (block.chainid == CHAIN_ETHEREUM) {
            return token == USDT_ETHEREUM;
        }
        return false;
    }

    function _parseInteractions(string memory json, string memory pointer)
        internal
        view
        returns (Settlement.Interaction[] memory interactions)
    {
        uint256 length = _countInteractions(json, pointer);
        interactions = new Settlement.Interaction[](length);
        for (uint256 i = 0; i < length; ++i) {
            string memory base = string.concat(pointer, "[", vm.toString(i), "]");
            interactions[i].target = _readAddressOrDefault(json, string.concat(base, ".target"), address(0));
            interactions[i].value = _readUintOrDefault(json, string.concat(base, ".value"), 0);
            interactions[i].callData = _readBytesOrDefault(json, string.concat(base, ".callData"), bytes(""));
        }
    }

    function _countInteractions(string memory json, string memory pointer) internal view returns (uint256 count) {
        while (true) {
            string memory checkPath = string.concat(pointer, "[", vm.toString(count), "].target");
            if (!vm.keyExists(json, checkPath)) {
                break;
            }
            count++;
        }
    }


    function _hashOrderIntent(Settlement.OrderIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_INTENT_TYPEHASH,
                intent.quoteId,
                intent.user,
                address(intent.tokenIn),
                address(intent.tokenOut),
                intent.amountIn,
                intent.minAmountOut,
                intent.receiver,
                intent.deadline,
                intent.nonce,
                intent.interactionsHash,
                intent.callValue,
                intent.gasEstimate,
                _hashPermitData(intent.permit)
            )
        );
    }

    function _hashPermitData(Settlement.PermitData memory permit) internal pure returns (bytes32) {
        if (permit.permitType == Settlement.PermitType.None) {
            return bytes32(0);
        }
        return keccak256(
            abi.encode(
                PERMIT_DATA_TYPEHASH,
                uint8(permit.permitType),
                keccak256(permit.permitCall),
                permit.amount,
                permit.deadline
            )
        );
    }

    function _readBytesOrBuildEIP2612(
        string memory json,
        Settlement.OrderIntent memory intent,
        Settlement settlement,
        Settlement.PermitData memory permit
    ) internal view returns (bytes memory) {
        bytes memory existing = _readBytesOrDefault(json, "$.quoteDetails.settlement.permit.callData", bytes(""));
        require(existing.length != 0, "EIP2612 permit requires permitCall to be provided in $.quoteDetails.settlement.permit.callData");
        return existing;
    }

    function _readBytesOrBuildEIP3009(string memory json) internal view returns (bytes memory) {
        bytes memory existing = _readBytesOrDefault(json, "$.quoteDetails.settlement.permit.callData", bytes(""));
        require(existing.length != 0, "EIP3009 callData required");
        return existing;
    }

    function _requireUint(string memory json, string memory pointer) internal pure returns (uint256) {
        return json.readUint(pointer);
    }

    function _requireAddress(string memory json, string memory pointer) internal view returns (address) {
        address addr = _readAddressOrInteropAddress(json, pointer, address(0));
        require(addr != address(0), string.concat("Missing required address at ", pointer));
        return addr;
    }

    function _requireAddressOrInteropAddress(string memory json, string memory pointer) internal view returns (address) {
        require(vm.keyExists(json, pointer), string.concat("Missing required address at ", pointer));
        address addr = _readAddressOrInteropAddress(json, pointer, address(0));
        require(addr != address(0), string.concat("Invalid address format at ", pointer));
        return addr;
    }

    function _readUintOrDefault(string memory json, string memory pointer, uint256 defaultValue)
        internal
        view
        returns (uint256)
    {
        if (vm.keyExists(json, pointer)) {
            return json.readUint(pointer);
        }
        return defaultValue;
    }

    function _readAddressOrDefault(string memory json, string memory pointer, address defaultValue)
        internal
        view
        returns (address)
    {
        if (vm.keyExists(json, pointer)) {
            return json.readAddress(pointer);
        }
        return defaultValue;
    }

    function _readBytes32OrDefault(string memory json, string memory pointer, bytes32 fallbackValue)
        internal
        view
        returns (bytes32)
    {
        if (!vm.keyExists(json, pointer)) {
            return fallbackValue;
        }
        string memory hexValue = json.readString(pointer);
        bytes memory raw = vm.parseBytes(hexValue);
        require(raw.length != 0, "invalid bytes32 length");
        bytes32 value;
        assembly {
            value := mload(add(raw, 32))
        }
        return value;
    }

    function _readStringOrDefault(string memory json, string memory pointer, string memory fallbackValue)
        internal
        view
        returns (string memory)
    {
        if (vm.keyExists(json, pointer)) {
            return json.readString(pointer);
        }
        return fallbackValue;
    }

    function _readBytesOrDefault(string memory json, string memory pointer, bytes memory fallbackValue)
        internal
        view
        returns (bytes memory)
    {
        if (!vm.keyExists(json, pointer)) {
            return fallbackValue;
        }
        string memory hexValue = json.readString(pointer);
        if (bytes(hexValue).length == 0) {
            return fallbackValue;
        }
        return vm.parseBytes(hexValue);
    }

    function _equalsIgnoreCase(string memory a, string memory b) internal pure returns (bool) {
        bytes memory ba = bytes(_lower(a));
        bytes memory bb = bytes(_lower(b));
        if (ba.length != bb.length) {
            return false;
        }
        for (uint256 i = 0; i < ba.length; ++i) {
            if (ba[i] != bb[i]) {
                return false;
            }
        }
        return true;
    }

    function _lower(string memory input) internal pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        for (uint256 i = 0; i < inputBytes.length; ++i) {
            uint8 charCode = uint8(inputBytes[i]);
            if (charCode >= 65 && charCode <= 90) {
                inputBytes[i] = bytes1(charCode + 32);
            }
        }
        return string(inputBytes);
    }

    /// @notice Extracts chainId from InteropAddress format
    /// @dev InteropAddress format: 0x[chainId bytes][address bytes]
    ///      Common formats: first byte (chainId < 256) or first 4 bytes (uint32 chainId, big-endian)
    function _extractChainIdFromInteropAddress(string memory json, string memory pointer)
        internal
        view
        returns (uint256)
    {
        if (!vm.keyExists(json, pointer)) {
            return 0;
        }
        string memory interopAddr = json.readString(pointer);
        
        // Check if it's a valid hex string (starts with 0x)
        bytes memory addrStrBytes = bytes(interopAddr);
        if (addrStrBytes.length < 2 || addrStrBytes[0] != 0x30 || addrStrBytes[1] != 0x78) {
            // Not a hex string (doesn't start with "0x")
            return 0;
        }
        
        // Try to parse as bytes (will fail if not valid hex)
        bytes memory addrBytes;
        try vm.parseBytes(interopAddr) returns (bytes memory parsed) {
            addrBytes = parsed;
        } catch {
            // Not a valid hex string, can't be InteropAddress
            return 0;
        }
        
        // InteropAddress should be at least 21 bytes (1 byte chainId + 20 bytes address)
        // or 24 bytes (4 bytes chainId + 20 bytes address)
        if (addrBytes.length < 21) {
            return 0;
        }

        // Try reading as uint32 from first 4 bytes (big-endian, supports chain IDs up to 2^32-1)
        if (addrBytes.length >= 24) {
            uint32 chainId32 = uint32(uint8(addrBytes[0])) << 24 |
                              uint32(uint8(addrBytes[1])) << 16 |
                              uint32(uint8(addrBytes[2])) << 8 |
                              uint32(uint8(addrBytes[3]));
            // Check if it's a reasonable chain ID (not zero and not too large)
            if (chainId32 > 0 && chainId32 < 1000000) {
                return uint256(chainId32);
            }
        }

        // Fallback: read first byte as chain ID (for chain IDs < 256)
        if (addrBytes.length >= 21) {
            uint8 chainId8 = uint8(addrBytes[0]);
            if (chainId8 > 0) {
                return uint256(chainId8);
            }
        }

        return 0;
    }

    /// @notice Extracts Ethereum address from InteropAddress format
    /// @dev InteropAddress format: 0x[chainId bytes][address bytes]
    ///      Returns the last 20 bytes as the address
    function _extractAddressFromInteropAddress(string memory json, string memory pointer) internal view returns (address) {
        if (!vm.keyExists(json, pointer)) {
            return address(0);
        }
        string memory interopAddr = json.readString(pointer);
        
        // Check if it's a valid hex string (starts with 0x)
        bytes memory addrStrBytes = bytes(interopAddr);
        if (addrStrBytes.length < 2 || addrStrBytes[0] != 0x30 || addrStrBytes[1] != 0x78) {
            // Not a hex string (doesn't start with "0x")
            return address(0);
        }
        
        // Try to parse as bytes (will fail if not valid hex)
        bytes memory addrBytes;
        try vm.parseBytes(interopAddr) returns (bytes memory parsed) {
            addrBytes = parsed;
        } catch {
            // Not a valid hex string, can't be InteropAddress
            return address(0);
        }
        
        if (addrBytes.length < 21) {
            return address(0);
        }
        
        // Extract last 20 bytes as the address
        bytes20 addr;
        assembly {
            addr := mload(add(add(addrBytes, 0x20), sub(mload(addrBytes), 20)))
        }
        return address(addr);
    }

    /// @notice Reads address from JSON, handling both regular addresses and InteropAddress format
    function _readAddressOrInteropAddress(string memory json, string memory pointer, address defaultValue) internal view returns (address) {
        if (!vm.keyExists(json, pointer)) {
            return defaultValue;
        }
        string memory addrStr = json.readString(pointer);
        
        // Check if it's a valid hex string (starts with 0x)
        bytes memory addrStrBytes = bytes(addrStr);
        if (addrStrBytes.length < 2 || addrStrBytes[0] != 0x30 || addrStrBytes[1] != 0x78) {
            // Not a hex string, can't be an address
            return defaultValue;
        }
        
        // Try to parse as bytes (will fail if not valid hex)
        bytes memory addrBytes;
        try vm.parseBytes(addrStr) returns (bytes memory parsed) {
            addrBytes = parsed;
        } catch {
            // Not a valid hex string, can't be an address
            return defaultValue;
        }
        
        // If it's a regular 20-byte address (42 chars: 0x + 40 hex), use it directly
        if (addrBytes.length == 20) {
            bytes20 addr;
            assembly {
                addr := mload(add(addrBytes, 0x20))
            }
            return address(addr);
        }
        
        // Otherwise, treat as InteropAddress and extract the address part
        if (addrBytes.length >= 21) {
            return _extractAddressFromInteropAddress(json, pointer);
        }
        
        return defaultValue;
    }

    /// @notice Decodes and formats error messages for human readability
    /// @param errData The raw error data from the revert
    /// @param intent The order intent for context
    /// @param settlement The Settlement contract instance for domain separator lookup
    /// @return A formatted error message string
    function _decodeAndFormatError(
        bytes memory errData,
        Settlement.OrderIntent memory intent,
        Settlement settlement
    ) internal view returns (string memory)
    {
        if (errData.length < 4) {
            return "Unknown error: insufficient error data";
        }

        bytes4 selector = bytes4(errData);
        string memory message = "";

        // InteractionsHashMismatch(bytes32 expected, bytes32 actual)
        if (selector == Settlement.InteractionsHashMismatch.selector && errData.length >= 68) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            // Decode to verify structure, but values not needed in message
            // (validation already happened earlier in _parseIntent)
            abi.decode(payload, (bytes32, bytes32));
            message = string.concat(
                "[ERROR] INTERACTIONS HASH MISMATCH\n",
                "The interactionsHash in your JSON doesn't match the hash computed from the execution plan.\n\n",
                "This usually means:\n",
                "  - The execution plan (preInteractions, interactions, postInteractions) has changed\n",
                "  - The interactionsHash in $.quoteDetails.settlement.interactionsHash is incorrect\n\n",
                "Fix: Recompute the interactionsHash from your execution plan or update the execution plan to match the hash.\n"
            );
        }
        // InsufficientOutput(uint256 received, uint256 minimum)
        else if (selector == Settlement.InsufficientOutput.selector && errData.length >= 68) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            (uint256 received, uint256 minimum) = abi.decode(payload, (uint256, uint256));
            message = string.concat(
                "[ERROR] INSUFFICIENT OUTPUT AMOUNT\n",
                "The swap received fewer tokens than the minimum required.\n\n",
                "Details:\n",
                "  - Received: ", _formatTokenAmount(received, address(intent.tokenOut)), "\n",
                "  - Minimum required: ", _formatTokenAmount(minimum, address(intent.tokenOut)), "\n",
                "  - Shortfall: ", _formatTokenAmount(minimum - received, address(intent.tokenOut)), "\n\n",
                "Possible causes:\n",
                "  - Slippage too high (market moved against you)\n",
                "  - Insufficient liquidity in the pool\n",
                "  - Incorrect minAmountOut in $.quoteDetails.details.requestedOutputs[0].amount\n",
                "  - The swap interaction (e.g., Uniswap) failed or returned less than expected\n\n",
                "Fix: Increase minAmountOut tolerance or check the swap interaction parameters.\n"
            );
        }
        // InsufficientAllowance(uint256 allowance, uint256 required)
        else if (selector == Settlement.InsufficientAllowance.selector && errData.length >= 68) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            (uint256 allowance, uint256 required) = abi.decode(payload, (uint256, uint256));
            message = string.concat(
                "[ERROR] INSUFFICIENT TOKEN ALLOWANCE\n",
                "The user hasn't approved enough tokens for the settlement contract.\n\n",
                "Details:\n",
                "  - Current allowance: ", _formatTokenAmount(allowance, address(intent.tokenIn)), "\n",
                "  - Required: ", _formatTokenAmount(required, address(intent.tokenIn)), "\n",
                "  - User: ", vm.toString(intent.user), "\n",
                "  - Token: ", vm.toString(address(intent.tokenIn)), "\n\n",
                "Fix: Ensure the user has approved the settlement contract (0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3) for at least the amountIn.\n"
            );
        }
        // InteractionCallFailed(address target, bytes reason)
        else if (selector == Settlement.InteractionCallFailed.selector) {
            uint256 payloadLength = errData.length - 4;
            bytes memory trimmed = new bytes(payloadLength);
            for (uint256 i = 0; i < payloadLength; ++i) {
                trimmed[i] = errData[i + 4];
            }
            (address failedTarget, bytes memory innerReason) = abi.decode(trimmed, (address, bytes));
            string memory targetName = _getContractName(failedTarget);
            message = string.concat(
                "[ERROR] INTERACTION CALL FAILED\n",
                "One of the interactions in your execution plan reverted.\n\n",
                "Details:\n",
                "  - Failed contract: ", vm.toString(failedTarget), " (", targetName, ")\n",
                "  - Check: $.quoteDetails.settlement.executionPlan.interactions or preInteractions/postInteractions\n\n"
            );
            if (innerReason.length >= 4) {
                message = string.concat(message, "Inner error: ", _decodeInnerError(innerReason, failedTarget), "\n");
            }
            message = string.concat(
                message,
                "\nPossible causes:\n",
                "  - Incorrect callData for the interaction\n",
                "  - Insufficient token balance/allowance for the swap\n",
                "  - Invalid parameters (e.g., wrong fee tier, invalid path)\n",
                "  - Contract reverted due to business logic (e.g., deadline passed, insufficient liquidity)\n\n",
                "Fix: Review the interaction parameters and ensure they're correct for the target contract.\n"
            );
        }
        // NonceAlreadyUsed(address user, uint256 nonce)
        else if (selector == Settlement.NonceAlreadyUsed.selector && errData.length >= 68) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            (address user, uint256 nonce) = abi.decode(payload, (address, uint256));
            message = string.concat(
                "[ERROR] NONCE ALREADY USED\n",
                "This nonce has already been consumed and cannot be reused.\n\n",
                "Details:\n",
                "  - User: ", vm.toString(user), "\n",
                "  - Nonce: ", vm.toString(nonce), "\n",
                "  - Check: $.quoteDetails.settlement.nonce\n\n",
                "Fix: Use a different nonce value that hasn't been used before.\n"
            );
        }
        // InvalidSignature()
        else if (selector == Settlement.InvalidSignature.selector) {
            message = _formatInvalidSignatureError(settlement, intent);
        }
        // MissingSignature()
        else if (selector == Settlement.MissingSignature.selector) {
            message = string.concat(
                "[ERROR] MISSING SIGNATURE\n",
                "The user signature is required but was not provided.\n\n",
                "Fix: Ensure the order intent includes a valid user signature.\n"
            );
        }
        // OrderExpired()
        else if (selector == Settlement.OrderExpired.selector) {
            message = string.concat(
                "[ERROR] ORDER EXPIRED\n",
                "The order deadline has passed.\n\n",
                "Details:\n",
                "  - Current block timestamp: ", vm.toString(block.timestamp), "\n",
                "  - Order deadline: ", vm.toString(intent.deadline), "\n",
                "  - Check: $.quoteDetails.settlement.deadline\n\n",
                "Fix: Use a future deadline timestamp or fork from an earlier block.\n"
            );
        }
        // InvalidUser(address user)
        else if (selector == Settlement.InvalidUser.selector && errData.length >= 36) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            address user = abi.decode(payload, (address));
            message = string.concat(
                "[ERROR] INVALID USER ADDRESS\n",
                "The user address cannot be the zero address.\n\n",
                "Details:\n",
                "  - User: ", vm.toString(user), "\n",
                "  - Check: $.quoteDetails.details.availableInputs[0].user\n\n",
                "Fix: Provide a valid user address.\n"
            );
        }
        // InvalidReceiver(address receiver)
        else if (selector == Settlement.InvalidReceiver.selector && errData.length >= 36) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            address receiver = abi.decode(payload, (address));
            message = string.concat(
                "[ERROR] INVALID RECEIVER ADDRESS\n",
                "The receiver address cannot be the zero address.\n\n",
                "Details:\n",
                "  - Receiver: ", vm.toString(receiver), "\n",
                "  - Check: $.quoteDetails.details.requestedOutputs[0].receiver\n\n",
                "Fix: Provide a valid receiver address.\n"
            );
        }
        // CallValueMismatch(uint256 expected, uint256 provided)
        else if (selector == Settlement.CallValueMismatch.selector && errData.length >= 68) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            (uint256 expected, uint256 provided) = abi.decode(payload, (uint256, uint256));
            message = string.concat(
                "[ERROR] CALL VALUE MISMATCH\n",
                "The ETH value sent doesn't match the expected callValue.\n\n",
                "Details:\n",
                "  - Expected: ", vm.toString(expected), " wei\n",
                "  - Provided: ", vm.toString(provided), " wei\n",
                "  - Check: $.quoteDetails.settlement.callValue\n\n",
                "Fix: Ensure callValue matches the sum of value fields in all interactions.\n"
            );
        }
        // PermitDeadlineExpired(uint256 deadline)
        else if (selector == Settlement.PermitDeadlineExpired.selector && errData.length >= 36) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            uint256 deadline = abi.decode(payload, (uint256));
            message = string.concat(
                "[ERROR] PERMIT DEADLINE EXPIRED\n",
                "The permit deadline has passed.\n\n",
                "Details:\n",
                "  - Current block timestamp: ", vm.toString(block.timestamp), "\n",
                "  - Permit deadline: ", vm.toString(deadline), "\n",
                "  - Check: $.quoteDetails.settlement.permit.deadline\n\n",
                "Fix: Use a future deadline or fork from an earlier block.\n"
            );
        }
        // InsufficientInputAmount(uint256 collected, uint256 required)
        else if (selector == Settlement.InsufficientInputAmount.selector && errData.length >= 68) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            (uint256 collected, uint256 required) = abi.decode(payload, (uint256, uint256));
            message = string.concat(
                "[ERROR] INSUFFICIENT INPUT AMOUNT COLLECTED\n",
                "Couldn't collect enough tokens from the user.\n\n",
                "Details:\n",
                "  - Collected: ", _formatTokenAmount(collected, address(intent.tokenIn)), "\n",
                "  - Required: ", _formatTokenAmount(required, address(intent.tokenIn)), "\n",
                "  - Token: ", vm.toString(address(intent.tokenIn)), "\n\n",
                "Possible causes:\n",
                "  - User doesn't have enough token balance\n",
                "  - Insufficient allowance (even if permit was applied)\n",
                "  - Permit didn't work as expected\n\n",
                "Fix: Ensure user has sufficient balance and allowance.\n"
            );
        }
        // InvalidInteractionTarget(address target)
        else if (selector == Settlement.InvalidInteractionTarget.selector && errData.length >= 36) {
            bytes memory payload = new bytes(errData.length - 4);
            for (uint256 i = 0; i < payload.length; ++i) {
                payload[i] = errData[i + 4];
            }
            address target = abi.decode(payload, (address));
            message = string.concat(
                "[ERROR] INVALID INTERACTION TARGET\n",
                "The interaction target is invalid or not allowed.\n\n",
                "Details:\n",
                "  - Target: ", vm.toString(target), "\n",
                "  - Check: $.quoteDetails.settlement.executionPlan.interactions[].target\n\n",
                "Possible causes:\n",
                "  - Target is zero address\n",
                "  - Target is not in the allowlist (if allowlist is enabled)\n\n",
                "Fix: Use a valid, allowed contract address.\n"
            );
        }
        else {
            // Unknown error - show selector
            message = string.concat(
                "[ERROR] UNKNOWN ERROR\n",
                "Error selector: ", _bytes4ToHexString(selector), "\n",
                "Raw error data length: ", vm.toString(errData.length), " bytes\n\n",
                "This error is not yet decoded. Check the Settlement contract for error definitions.\n"
            );
        }

        return message;
    }

    /// @notice Formats a token amount with decimals for readability
    function _formatTokenAmount(uint256 amount, address token) internal view returns (string memory) {
        // Try to get decimals (common tokens have 18, but some like USDC have 6)
        try IERC20Metadata(token).decimals() returns (uint8 decimals) {
            if (decimals == 18) {
                return string.concat(vm.toString(amount / 1e18), ".", _padZeros(amount % 1e18, 18), " (", vm.toString(amount), " wei)");
            } else if (decimals == 6) {
                return string.concat(vm.toString(amount / 1e6), ".", _padZeros(amount % 1e6, 6), " (", vm.toString(amount), " units)");
            }
        } catch {}
        return vm.toString(amount);
    }

    /// @notice Pads a number with zeros for decimal display
    function _padZeros(uint256 num, uint8 decimals) internal pure returns (string memory) {
        string memory str = vm.toString(num);
        uint256 currentLen = bytes(str).length;
        if (currentLen >= decimals) {
            return str;
        }
        string memory zeros = "";
        for (uint256 i = currentLen; i < decimals; ++i) {
            zeros = string.concat(zeros, "0");
        }
        return string.concat(zeros, str);
    }

    /// @notice Gets a human-readable name for a contract address
    function _getContractName(address addr) internal pure returns (string memory) {
        // Common contract addresses
        if (addr == 0xE592427A0AEce92De3Edee1F18E0157C05861564) return "Uniswap V3 SwapRouter";
        if (addr == 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45) return "Uniswap V3 SwapRouter02";
        if (addr == 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F) return "SushiSwap Router";
        if (addr == 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D) return "Uniswap V2 Router";
        return "Unknown contract";
    }

    /// @notice Decodes inner error from interaction failures
    function _decodeInnerError(bytes memory innerReason, address /* target */) internal pure returns (string memory) {
        if (innerReason.length == 0) {
            return "Empty revert data (no error message provided)";
        }
        if (innerReason.length < 4) {
            return string.concat("Invalid error data (length: ", vm.toString(innerReason.length), " bytes)");
        }
        bytes4 selector = bytes4(innerReason);
        // Common Uniswap errors
        if (selector == 0x5c975abb) return "Uniswap: TRANSFER_FAILED";
        if (selector == 0x09b81346) return "Uniswap: INSUFFICIENT_OUTPUT_AMOUNT";
        if (selector == 0xdfe1681d) return "Uniswap: INSUFFICIENT_LIQUIDITY";
        if (selector == 0x08c379a0 && innerReason.length >= 68) {
            // Try to decode as string error
            bytes memory errorString = new bytes(innerReason.length - 4);
            for (uint256 i = 0; i < errorString.length; ++i) {
                errorString[i] = innerReason[i + 4];
            }
            // Skip length prefix (first 32 bytes)
            if (errorString.length > 32) {
                uint256 strLen;
                assembly {
                    strLen := mload(add(errorString, 32))
                }
                if (strLen < errorString.length - 32) {
                    bytes memory actualString = new bytes(strLen);
                    for (uint256 i = 0; i < strLen; ++i) {
                        actualString[i] = errorString[i + 32];
                    }
                    return string(actualString);
                }
            }
        }
        return string.concat("Error selector: ", _bytes4ToHexString(selector));
    }

    /// @notice Converts bytes4 to hex string
    function _bytes4ToHexString(bytes4 value) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(10);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 4; ++i) {
            result[2 + i * 2] = hexChars[uint8(value[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(value[i]) & 0x0f];
        }
        return string(result);
    }

    /// @notice Converts bytes to hex string
    function _bytesToHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(data.length * 2 + 2);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < data.length; ++i) {
            result[2 + i * 2] = hexChars[uint8(data[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
    }

    /// @notice Formats InvalidSignature error with detailed debugging information
    function _formatInvalidSignatureError(
        Settlement settlement,
        Settlement.OrderIntent memory intent
    ) internal view returns (string memory) {
        string memory header = _formatInvalidSignatureHeader(settlement, intent);
        string memory fields = _formatInvalidSignatureFields(intent);
        string memory signature = _formatInvalidSignatureSignature(settlement, intent);
        string memory causes = _formatInvalidSignatureCauses(intent);
        
        return string.concat(header, fields, signature, causes);
    }

    function _formatInvalidSignatureHeader(
        Settlement settlement,
        Settlement.OrderIntent memory intent
    ) internal view returns (string memory) {
        bytes32 domainSep = settlement.domainSeparator();
        bytes32 structHash = _hashOrderIntent(intent);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        
        return string.concat(
            "[ERROR] INVALID SIGNATURE\n",
            "The user signature doesn't match the order intent.\n\n",
            "Details:\n",
            "  - Settlement contract: ", vm.toString(address(settlement)), "\n",
            "  - Domain separator: ", vm.toString(uint256(domainSep)), "\n",
            "  - User: ", vm.toString(intent.user), "\n",
            "  - Chain ID: ", vm.toString(block.chainid), "\n",
            "\n",
            "Computed Hash Values:\n",
            "  - Struct hash: ", vm.toString(uint256(structHash)), "\n",
            "  - EIP-712 digest: ", vm.toString(uint256(digest)), "\n",
            "\n"
        );
    }

    function _formatInvalidSignatureFields(
        Settlement.OrderIntent memory intent
    ) internal view returns (string memory) {
        return string.concat(
            "Order Intent Values Used for Signature:\n",
            "  - quoteId (bytes32): ", vm.toString(uint256(intent.quoteId)), "\n",
            "  - tokenIn: ", vm.toString(address(intent.tokenIn)), "\n",
            "  - tokenOut: ", vm.toString(address(intent.tokenOut)), "\n",
            "  - amountIn: ", vm.toString(intent.amountIn), "\n",
            "  - minAmountOut: ", vm.toString(intent.minAmountOut), "\n",
            "  - receiver: ", vm.toString(intent.receiver), "\n",
            "  - deadline: ", vm.toString(intent.deadline), "\n",
            "  - nonce: ", vm.toString(intent.nonce), "\n",
            "  - interactionsHash: ", vm.toString(uint256(intent.interactionsHash)), "\n",
            "  - callValue: ", vm.toString(intent.callValue), "\n",
            "  - gasEstimate: ", vm.toString(intent.gasEstimate), "\n",
            "  - permitType: ", vm.toString(uint8(intent.permit.permitType)), "\n",
            "  - permitAmount: ", vm.toString(intent.permit.amount), "\n",
            "  - permitDeadline: ", vm.toString(intent.permit.deadline), "\n",
            "\n"
        );
    }

    function _formatInvalidSignatureSignature(
        Settlement settlement,
        Settlement.OrderIntent memory intent
    ) internal view returns (string memory) {
        return string.concat(
            "  - User address: ", vm.toString(intent.user), "\n",
            "\n",
            "Note: The signature must be generated with the private key corresponding to user: ", vm.toString(intent.user), "\n",
            "      Use the signature generation guide to create a valid EIP-712 signature.\n",
            "\n"
        );
    }

    function _formatInvalidSignatureCauses(
        Settlement.OrderIntent memory intent
    ) internal view returns (string memory) {
        return string.concat(
            "Possible causes:\n",
            "  - Domain separator mismatch: The Settlement contract was deployed at a different address than expected\n",
            "  - Signature was generated with different contract address or chain ID\n",
            "  - Wrong private key used to sign (expected key for user: ", vm.toString(intent.user), ")\n",
            "  - Order intent fields don't match what was signed (check all fields above)\n",
            "  - The interactionsHash changed after the signature was created\n",
            "  - minAmountOut mismatch: Check if $.quoteDetails.details.requestedOutputs[0].amount matches what was signed\n",
            "  - Nonce format: Check if $.quoteDetails.settlement.nonce is parsed correctly (hex string vs decimal)\n\n",
            "Fix: Ensure the signature was generated using the exact same values shown above.\n",
            "     Verify the signature in $.signature was signed with the correct domain separator and all field values match.\n",
            "     See docs/signature-generation-guide.md for instructions on generating a valid signature.\n"
        );
    }
}

// Minimal interface for ERC20 metadata
interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

