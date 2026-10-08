// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {IBCTokenFactory} from "frontier/interfaces/IBCTokenFactory.sol";

import {ICurrentHook} from "kit/HookGated.sol";

import {TwapObserver} from "contracts/twap-observer/TwapObserver.sol";

/**
 * @notice Deploys the `TwapObserver` singleton against the chain's Frontier `BCTokenFactory`.
 * @dev Dry run, then broadcast with a Foundry keystore account:
 *   forge script script/DeployTwapObserver.s.sol --rpc-url robinhood
 *   forge script script/DeployTwapObserver.s.sol --rpc-url robinhood --account <name> --broadcast
 * The factory is picked by chain id; `BC_TOKEN_FACTORY` overrides it.
 */
contract DeployTwapObserver is Script {
    uint256 internal constant ROBINHOOD = 4663;
    uint256 internal constant ARBITRUM_SEPOLIA = 421_614;

    /// @dev Frontier `BCTokenFactory` on Robinhood Chain.
    address internal constant ROBINHOOD_FACTORY = 0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5;

    /// @dev Frontier `BCTokenFactory` on Arbitrum Sepolia.
    address internal constant ARBITRUM_SEPOLIA_FACTORY = 0xc3593bCAD9D853Be5b1f4F568EAE93404634F1aD;

    function run() external returns (TwapObserver observer) {
        address factory = vm.envOr("BC_TOKEN_FACTORY", _knownFactory());
        require(factory != address(0), "no factory known for this chain, set BC_TOKEN_FACTORY");
        require(factory.code.length != 0, "BC_TOKEN_FACTORY has no code on this chain");

        address liquidityManager = IBCTokenFactory(factory).liquidityManager();
        address hook = ICurrentHook(liquidityManager).hook();
        require(hook.code.length != 0, "the factory's current hook has no code");

        vm.startBroadcast();
        observer = new TwapObserver(factory);
        vm.stopBroadcast();

        require(observer.BC_TOKEN_FACTORY() == factory, "factory not pinned");

        console.log("chain id:         ", block.chainid);
        console.log("BCTokenFactory:   ", factory);
        console.log("liquidity manager:", liquidityManager);
        console.log("current hook:     ", hook);
        console.log("TwapObserver:     ", address(observer));
    }

    function _knownFactory() internal view returns (address) {
        if (block.chainid == ROBINHOOD) return ROBINHOOD_FACTORY;
        if (block.chainid == ARBITRUM_SEPOLIA) return ARBITRUM_SEPOLIA_FACTORY;
        return address(0);
    }
}
