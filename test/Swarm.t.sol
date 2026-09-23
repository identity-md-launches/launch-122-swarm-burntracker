// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Swarm, SwarmLaunchToken} from "../src/Swarm.sol";

// Minimal Foundry interface keeps these tests runnable without downloaded libraries.
interface SwarmVm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function expectRevert(bytes calldata reason) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
}

abstract contract SwarmTestSupport {
    SwarmVm internal constant vm = SwarmVm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant SUPPLY = 1_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5EED);

    function eq(uint256 actual, uint256 expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function eq(address actual, address expected, string memory reason) internal pure {
        require(actual == expected, reason);
    }

    function assertTransferLog(SwarmVm.Log memory entry, address emitter, address from, address to, uint256 amount)
        internal
        pure
    {
        eq(entry.emitter, emitter, "transfer emitter");
        eq(entry.topics.length, 3, "transfer topics length");
        require(entry.topics[0] == keccak256("Transfer(address,address,uint256)"), "transfer signature");
        require(entry.topics[1] == bytes32(uint256(uint160(from))), "transfer sender topic");
        require(entry.topics[2] == bytes32(uint256(uint160(to))), "transfer recipient topic");
        eq(entry.data.length, 32, "transfer data length");
        eq(abi.decode(entry.data, (uint256)), amount, "transfer event value");
    }
}

contract SwarmConstructorCaller {
    function deploy() external returns (Swarm) {
        return new Swarm();
    }
}

/// @notice Run `forge test --match-path test/Swarm.t.sol`; use `forge test --gas-report` for gas costs.
/// @dev Expectations use base units: indivisible fractions round down separately on each transfer.
/// Test README: deploy `new Swarm()` first, then `new BurnTracker(address(token))`.
/// No initialization, privileged account, or external test library is required. Run `forge build`
/// and `forge test` from the repository root to compile and check both contract suites.
/// Gas report with Forge 1.7.1, solc 0.8.26, default compiler settings: deployment 829,094 gas,
/// creation code 3,655 bytes; transfer 22,330-60,001 gas; transferFrom 25,262-65,993 gas.
/// Ranges include zero, self, normal, and reverted calls; these observations are not gas limits.
/// For project launches, select `src/Swarm.sol:SwarmLaunchToken` as the fixed-supply reward token.
/// Deploy Swarm as an application, then bind BurnTracker to that Swarm address. The separate
/// launch token mints 1,000,000,000 SWORML and transfers without burning, as the protected floor requires.
contract SwarmTest is SwarmTestSupport {
    Swarm internal token;

    function setUp() public {
        token = new Swarm();
    }

    function test_constructorSetsMetadataAndMintsExactlyOneMillionTokens() public view {
        require(keccak256(bytes(token.name())) == keccak256("Swarm"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("SWORM"), "symbol");
        eq(token.decimals(), 18, "decimals");
        eq(token.INITIAL_SUPPLY(), SUPPLY, "initial supply constant");
        assertInitialState();
    }

    function test_constructorMintsToImmediateDeployerAndEmitsMint() public {
        SwarmConstructorCaller factory = new SwarmConstructorCaller();
        vm.recordLogs();
        Swarm deployed = factory.deploy();
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "one mint event");
        assertTransferLog(logs[0], address(deployed), address(0), address(factory), SUPPLY);
        eq(deployed.balanceOf(address(factory)), SUPPLY, "factory receives all tokens");
        eq(deployed.balanceOf(address(this)), 0, "factory caller receives none");
        eq(deployed.totalSupply(), SUPPLY, "constructor supply");
    }

    function test_transferOneHundredTokensBurnsOneAndDeliversNinetyNine() public {
        vm.recordLogs();
        require(token.transfer(ALICE, 100 ether), "transfer return");
        eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "gross debit");
        eq(token.balanceOf(ALICE), 99 ether, "net credit");
        eq(token.balanceOf(address(0)), 0, "burn is not a zero-address balance");
        eq(token.totalSupply(), SUPPLY - 1 ether, "permanent burn");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 2, "delivery and burn events");
        assertTransferLog(logs[0], address(token), address(this), ALICE, 99 ether);
        assertTransferLog(logs[1], address(token), address(this), address(0), 1 ether);
        assertConservation();
    }

    function test_transferEntireBalance() public {
        require(token.transfer(ALICE, SUPPLY), "transfer return");
        eq(token.balanceOf(address(this)), 0, "sender emptied");
        eq(token.balanceOf(ALICE), 990_000 ether, "full balance net");
        eq(token.totalSupply(), 990_000 ether, "full balance supply");
        assertConservation();
    }

    function test_burnRoundingAtBaseUnitBoundaries() public {
        uint256[7] memory amounts = [uint256(0), 1, 99, 100, 101, 199, 200];
        uint256[7] memory burns = [uint256(0), 0, 0, 1, 1, 1, 2];
        uint256 sent;
        uint256 burned;
        for (uint256 i; i < amounts.length; ++i) {
            vm.recordLogs();
            require(token.transfer(ALICE, amounts[i]), "boundary return");
            sent += amounts[i];
            burned += burns[i];
            eq(token.balanceOf(address(this)), SUPPLY - sent, "boundary debit");
            eq(token.balanceOf(ALICE), sent - burned, "boundary credit");
            eq(token.totalSupply(), SUPPLY - burned, "boundary supply");
            SwarmVm.Log[] memory logs = vm.getRecordedLogs();
            eq(logs.length, burns[i] == 0 ? 1 : 2, "boundary event count");
            assertTransferLog(logs[0], address(token), address(this), ALICE, amounts[i] - burns[i]);
            if (burns[i] != 0) {
                assertTransferLog(logs[1], address(token), address(this), address(0), burns[i]);
            }
            assertConservation();
        }
    }

    function test_fractionalTokenBurnUsesBaseUnits() public {
        require(token.transfer(ALICE, 1 ether + 99), "fractional return");
        eq(token.balanceOf(ALICE), 0.99 ether + 99, "fractional credit");
        eq(token.totalSupply(), SUPPLY - 0.01 ether, "fractional burn");
        assertConservation();
    }

    function test_zeroTransferFromEmptyAccountSucceedsAndEmits() public {
        vm.recordLogs();
        vm.prank(ALICE);
        require(token.transfer(BOB, 0), "zero return");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "zero event count");
        assertTransferLog(logs[0], address(token), ALICE, BOB, 0);
        assertInitialState();
    }

    function test_selfTransferLosesOnlyBurnAndEmitsBothEvents() public {
        vm.recordLogs();
        require(token.transfer(address(this), 100 ether), "self return");
        eq(token.balanceOf(address(this)), SUPPLY - 1 ether, "self loses burn only");
        eq(token.totalSupply(), SUPPLY - 1 ether, "self burns supply");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 2, "self event count");
        assertTransferLog(logs[0], address(token), address(this), address(this), 99 ether);
        assertTransferLog(logs[1], address(token), address(this), address(0), 1 ether);
        assertConservation();
    }

    function test_selfTransferEntireBalance() public {
        require(token.transfer(address(this), SUPPLY), "full self return");
        eq(token.balanceOf(address(this)), 990_000 ether, "full self balance");
        eq(token.totalSupply(), 990_000 ether, "full self supply");
        assertConservation();
    }

    function test_zeroAndSubThresholdSelfTransfersDoNotBurn() public {
        vm.prank(ALICE);
        require(token.transfer(ALICE, 0), "empty self return");
        require(token.transfer(address(this), 99), "dust self return");
        assertInitialState();
    }

    function test_repeatedTransfersChargeEveryHolderIncludingTheDeployer() public {
        require(token.transfer(ALICE, 100 ether), "first transfer");
        vm.prank(ALICE);
        require(token.transfer(BOB, 50 ether), "second transfer");
        vm.prank(BOB);
        require(token.transfer(address(this), 10 ether), "return transfer");
        eq(token.balanceOf(address(this)), SUPPLY - 90.1 ether, "deployer net");
        eq(token.balanceOf(ALICE), 49 ether, "alice net");
        eq(token.balanceOf(BOB), 39.5 ether, "bob net");
        eq(token.totalSupply(), SUPPLY - 1.6 ether, "cumulative supply reduction");
        assertConservation();
    }

    function test_approveEmitsAndCanOverwriteAndRevokeWithoutBurning() public {
        vm.recordLogs();
        require(token.approve(SPENDER, 100 ether), "approve return");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "approval event count");
        eq(logs[0].emitter, address(token), "approval emitter");
        eq(logs[0].topics.length, 3, "approval topics");
        require(logs[0].topics[0] == keccak256("Approval(address,address,uint256)"), "approval signature");
        require(logs[0].topics[1] == bytes32(uint256(uint160(address(this)))), "approval owner");
        require(logs[0].topics[2] == bytes32(uint256(uint160(SPENDER))), "approval spender");
        eq(abi.decode(logs[0].data, (uint256)), 100 ether, "approval value");
        eq(token.allowance(address(this), SPENDER), 100 ether, "approved amount");
        require(token.approve(SPENDER, 7), "overwrite return");
        eq(token.allowance(address(this), SPENDER), 7, "overwrite replaces allowance");
        require(token.approve(SPENDER, 0), "revoke return");
        eq(token.allowance(address(this), SPENDER), 0, "revoked allowance");
        assertInitialState();
    }

    function test_approvalsAreIsolatedByOwnerAndSpender() public {
        require(token.approve(SPENDER, 123), "owner approval");
        vm.prank(ALICE);
        require(token.approve(SPENDER, 456), "empty holder may approve");
        require(token.approve(BOB, 789), "other spender approval");
        eq(token.allowance(address(this), SPENDER), 123, "owner allowance isolated");
        eq(token.allowance(ALICE, SPENDER), 456, "alice allowance isolated");
        eq(token.allowance(address(this), BOB), 789, "spender allowance isolated");
        eq(token.allowance(BOB, SPENDER), 0, "unapproved pair");
        assertInitialState();
    }

    function test_transferFromSpendsGrossAllowanceAndBurnsOnce() public {
        require(token.approve(SPENDER, 150 ether), "approval");
        vm.recordLogs();
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "delegated return");
        eq(token.allowance(address(this), SPENDER), 50 ether, "gross allowance deduction");
        eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "delegated debit");
        eq(token.balanceOf(ALICE), 99 ether, "delegated credit");
        eq(token.balanceOf(SPENDER), 0, "spender receives no fee");
        eq(token.totalSupply(), SUPPLY - 1 ether, "delegated burn once");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 2, "delegated transfer events");
        assertTransferLog(logs[0], address(token), address(this), ALICE, 99 ether);
        assertTransferLog(logs[1], address(token), address(this), address(0), 1 ether);
        assertConservation();
    }

    function test_transferFromExactAllowanceCannotBeReplayed() public {
        require(token.approve(SPENDER, 100 ether), "approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "first spend");
        eq(token.allowance(address(this), SPENDER), 0, "allowance exhausted");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "replay cannot debit");
        eq(token.balanceOf(ALICE), 99 ether, "replay cannot credit");
        eq(token.totalSupply(), SUPPLY - 1 ether, "replay cannot burn");
        eq(token.allowance(address(this), SPENDER), 0, "replay leaves allowance");
    }

    function test_transferFromUnlimitedAllowanceRemainsUnlimitedAfterRepeatedSpends() public {
        require(token.approve(SPENDER, type(uint256).max), "unlimited approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "first unlimited spend");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), BOB, 200 ether), "second unlimited spend");
        eq(token.allowance(address(this), SPENDER), type(uint256).max, "unlimited preserved");
        eq(token.balanceOf(ALICE), 99 ether, "first unlimited net");
        eq(token.balanceOf(BOB), 198 ether, "second unlimited net");
        eq(token.totalSupply(), SUPPLY - 3 ether, "unlimited transfers burn");
        assertConservation();
    }

    function test_transferFromZeroFromEmptyUnapprovedHolder() public {
        vm.recordLogs();
        vm.prank(SPENDER);
        require(token.transferFrom(ALICE, BOB, 0), "zero delegated return");
        eq(token.allowance(ALICE, SPENDER), 0, "zero allowance unchanged");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "zero delegated event count");
        assertTransferLog(logs[0], address(token), ALICE, BOB, 0);
        assertInitialState();
    }

    function test_transferFromSelfBurnsAndStillSpendsGrossAllowance() public {
        require(token.approve(SPENDER, 100 ether), "self approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), address(this), 100 ether), "delegated self return");
        eq(token.allowance(address(this), SPENDER), 0, "self consumes gross allowance");
        eq(token.balanceOf(address(this)), SUPPLY - 1 ether, "delegated self burn only");
        eq(token.totalSupply(), SUPPLY - 1 ether, "delegated self supply");
        assertConservation();
    }

    function test_transferFromToSpenderCreditsOnlyNet() public {
        require(token.approve(SPENDER, 100 ether), "approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), SPENDER, 100 ether), "spender recipient return");
        eq(token.balanceOf(SPENDER), 99 ether, "spender net");
        eq(token.allowance(address(this), SPENDER), 0, "spender allowance spent");
        eq(token.totalSupply(), SUPPLY - 1 ether, "spender burn");
        assertConservation();
    }

    function test_transferRevertsWhenBalanceIsInsufficient() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertInitialState();
    }

    function test_transferMaximumUintRevertsWithBalanceErrorWithoutOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        token.transfer(ALICE, type(uint256).max);
        assertInitialState();
    }

    function test_selfTransferRequiresFullAmountEvenWhenBurnWouldBeAffordable() public {
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(address(this), SUPPLY + 1);
        assertInitialState();
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertInitialState();
    }

    function test_transferFromZeroSenderRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidSender.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(0), ALICE, 0);
        assertInitialState();
    }

    function test_approveZeroSpenderRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        eq(token.allowance(address(this), address(0)), 0, "invalid approval unchanged");
        assertInitialState();
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertInitialState();
    }

    function test_transferFromCannotUseAnotherSpendersApproval() public {
        require(token.approve(SPENDER, 100 ether), "approval");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, BOB, 0, 100 ether));
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 100 ether);
        eq(token.allowance(address(this), SPENDER), 100 ether, "other approval unchanged");
        assertInitialState();
    }

    function test_transferFromRejectsNetOnlyAllowance() public {
        require(token.approve(SPENDER, 99 ether), "approval");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 99 ether, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        eq(token.allowance(address(this), SPENDER), 99 ether, "insufficient allowance unchanged");
        assertInitialState();
    }

    function test_transferFromInsufficientBalanceRollsBackAllowance() public {
        require(token.approve(SPENDER, SUPPLY + 1), "approval beyond balance allowed");
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, SUPPLY + 1);
        eq(token.allowance(address(this), SPENDER), SUPPLY + 1, "failed transfer restores allowance");
        assertInitialState();
    }

    function test_transferFromInvalidRecipientRollsBackAllowance() public {
        require(token.approve(SPENDER, 100 ether), "approval");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 100 ether);
        eq(token.allowance(address(this), SPENDER), 100 ether, "invalid recipient restores allowance");
        assertInitialState();
    }

    function test_transferFromSelfRequiresFullBalanceAndRollsBackAllowance() public {
        require(token.approve(SPENDER, SUPPLY + 1), "self approval beyond balance");
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(this), SUPPLY + 1);
        eq(token.allowance(address(this), SPENDER), SUPPLY + 1, "failed self transfer restores allowance");
        assertInitialState();
    }

    function test_transferFromZeroAmountToZeroRecipientStillReverts() public {
        require(token.approve(SPENDER, 100 ether), "approval");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 0);
        eq(token.allowance(address(this), SPENDER), 100 ether, "invalid zero transfer preserves allowance");
        assertInitialState();
    }

    function test_transferFromUnlimitedApprovalCannotExceedBalance() public {
        require(token.approve(SPENDER, type(uint256).max), "approval");
        vm.expectRevert(
            abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        eq(token.allowance(address(this), SPENDER), type(uint256).max, "unlimited unchanged on failure");
        assertInitialState();
    }

    function test_revokedApprovalCannotBeUsed() public {
        require(token.approve(SPENDER, 100 ether), "approval");
        require(token.approve(SPENDER, 0), "revoke");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 0, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        eq(token.allowance(address(this), SPENDER), 0, "revocation persists");
        assertInitialState();
    }

    function test_commonMintInitializationAndAdminSelectorsRejectDeployerAndStranger() public {
        // This bounded selector probe supplements source review; it is not a proof against all backdoors.
        bytes[9] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether),
            abi.encodeWithSignature("mint(uint256)", 1 ether),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("initialize()"),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("setMinter(address)", ALICE),
            abi.encodeWithSignature("setBurnRate(uint256)", 0),
            abi.encodeWithSignature("upgradeTo(address)", ALICE)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(token).call(calls[i]);
            require(!deployerOk, "deployer admin call accepted");
            vm.prank(ALICE);
            (bool strangerOk,) = address(token).call(calls[i]);
            require(!strangerOk, "stranger admin call accepted");
            assertInitialState();
        }
        require(token.transfer(ALICE, 100 ether), "transfer still usable");
        eq(token.balanceOf(ALICE), 99 ether, "burn rate remains one percent");
        eq(token.totalSupply(), SUPPLY - 1 ether, "admin probes do not disable burning");
    }

    function testFuzz_transferConservesBalancesAndBurnsOnePercent(uint256 seed) public {
        uint256 amount = seed % (SUPPLY + 1);
        uint256 burn = amount / 100;
        require(token.transfer(ALICE, amount), "fuzz transfer return");
        eq(token.balanceOf(address(this)), SUPPLY - amount, "fuzz debit");
        eq(token.balanceOf(ALICE), amount - burn, "fuzz net");
        eq(token.totalSupply(), SUPPLY - burn, "fuzz supply");
        assertConservation();
    }

    function testFuzz_selfTransferBurnsOnlyOnePercent(uint256 seed) public {
        uint256 amount = seed % (SUPPLY + 1);
        require(token.transfer(address(this), amount), "fuzz self return");
        eq(token.balanceOf(address(this)), SUPPLY - amount / 100, "fuzz self balance");
        eq(token.totalSupply(), SUPPLY - amount / 100, "fuzz self supply");
        assertConservation();
    }

    function testFuzz_transferFromChargesGrossAllowance(uint256 seed, uint256 allowanceSeed) public {
        uint256 amount = seed % (SUPPLY + 1);
        uint256 approval = amount + allowanceSeed % (SUPPLY + 1);
        require(token.approve(SPENDER, approval), "fuzz approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, amount), "fuzz delegated return");
        eq(token.allowance(address(this), SPENDER), approval - amount, "fuzz gross allowance");
        eq(token.balanceOf(address(this)), SUPPLY - amount, "fuzz delegated debit");
        eq(token.balanceOf(ALICE), amount - amount / 100, "fuzz delegated credit");
        eq(token.totalSupply(), SUPPLY - amount / 100, "fuzz delegated supply");
        assertConservation();
    }

    function testFuzz_insufficientBalanceLeavesStateUnchanged(uint256 seed, bool self) public {
        uint256 amount = SUPPLY + 1 + seed % (type(uint256).max - SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount));
        token.transfer(self ? address(this) : ALICE, amount);
        assertInitialState();
    }

    function assertInitialState() internal view {
        eq(token.totalSupply(), SUPPLY, "initial supply");
        eq(token.balanceOf(address(this)), SUPPLY, "initial deployer balance");
        eq(token.balanceOf(ALICE), 0, "initial alice balance");
        eq(token.balanceOf(BOB), 0, "initial bob balance");
        eq(token.balanceOf(SPENDER), 0, "initial spender balance");
        eq(token.balanceOf(address(0)), 0, "zero address balance");
    }

    function assertConservation() internal view {
        eq(
            token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB) + token.balanceOf(SPENDER),
            token.totalSupply(),
            "sum of balances equals supply"
        );
        eq(token.balanceOf(address(0)), 0, "burned tokens are not held at zero");
        eq(token.INITIAL_SUPPLY(), SUPPLY, "initial supply constant remains fixed");
    }
}

contract SwarmLaunchConstructorCaller {
    function deploy() external returns (SwarmLaunchToken) {
        return new SwarmLaunchToken();
    }
}

/// @notice Regression tests for the separate fixed-supply launch token, including failed spends.
/// @dev Gas report with Forge 1.7.1, solc 0.8.26, default compiler settings: deployment 753,402 gas,
/// creation code 3,393 bytes; transfer 22,330-52,252 gas; transferFrom 25,394-58,448 gas.
/// Reproduce with `forge test --gas-report`; ranges include successful and reverted calls.
contract SwarmLaunchTokenTest is SwarmTestSupport {
    uint256 internal constant LAUNCH_SUPPLY = 1_000_000_000 ether;
    SwarmLaunchToken internal token;

    function setUp() public {
        token = new SwarmLaunchToken();
    }

    function test_constructorSetsLaunchMetadataAndFixedSupply() public view {
        require(keccak256(bytes(token.name())) == keccak256("Swarm Launch Token"), "launch name");
        require(keccak256(bytes(token.symbol())) == keccak256("SWORML"), "launch symbol");
        eq(token.decimals(), 18, "launch decimals");
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);
    }

    function test_constructorMintsEntireLaunchSupplyToImmediateDeployer() public {
        SwarmLaunchConstructorCaller factory = new SwarmLaunchConstructorCaller();
        vm.recordLogs();
        SwarmLaunchToken deployed = factory.deploy();
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "one launch mint event");
        assertTransferLog(logs[0], address(deployed), address(0), address(factory), LAUNCH_SUPPLY);
        eq(deployed.balanceOf(address(factory)), LAUNCH_SUPPLY, "factory holds launch supply");
        eq(deployed.balanceOf(address(this)), 0, "factory caller receives no launch tokens");
        eq(deployed.totalSupply(), LAUNCH_SUPPLY, "factory deployment supply");
    }

    function test_transferDeliversFullAmountWithoutBurnEvent() public {
        vm.recordLogs();
        require(token.transfer(ALICE, 100 ether), "launch transfer return");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "no launch burn event");
        assertTransferLog(logs[0], address(token), address(this), ALICE, 100 ether);
        assertLaunchState(LAUNCH_SUPPLY - 100 ether, 100 ether, 0);
    }

    function test_entireLaunchSupplyCanMoveRepeatedlyWithoutDeflation() public {
        require(token.transfer(ALICE, LAUNCH_SUPPLY), "full launch transfer");
        assertLaunchState(0, LAUNCH_SUPPLY, 0);
        vm.prank(ALICE);
        require(token.transfer(BOB, LAUNCH_SUPPLY), "holder full launch transfer");
        assertLaunchState(0, 0, LAUNCH_SUPPLY);
    }

    function test_zeroTransfersAndFullBalanceSelfTransferPreserveSupplyAndEmit() public {
        vm.recordLogs();
        vm.prank(ALICE);
        require(token.transfer(BOB, 0), "empty launch transfer");
        vm.prank(SPENDER);
        require(token.transferFrom(ALICE, ALICE, 0), "unapproved zero self transfer");
        require(token.transfer(address(this), LAUNCH_SUPPLY), "full launch self transfer");
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 3, "one event per launch transfer");
        assertTransferLog(logs[0], address(token), ALICE, BOB, 0);
        assertTransferLog(logs[1], address(token), ALICE, ALICE, 0);
        assertTransferLog(logs[2], address(token), address(this), address(this), LAUNCH_SUPPLY);
        eq(token.allowance(ALICE, SPENDER), 0, "zero spend leaves zero approval");
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);
    }

    function test_exactAllowanceCannotBeReplayed() public {
        require(token.approve(SPENDER, 100 ether), "launch approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "launch delegated transfer");
        eq(token.allowance(address(this), SPENDER), 0, "launch approval exhausted");
        assertLaunchState(LAUNCH_SUPPLY - 100 ether, 100 ether, 0);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        eq(token.allowance(address(this), SPENDER), 0, "replay preserves exhausted approval");
        assertLaunchState(LAUNCH_SUPPLY - 100 ether, 100 ether, 0);
    }

    function test_unlimitedApprovalSurvivesRepeatedSpendsAndCanBeRevoked() public {
        require(token.approve(SPENDER, type(uint256).max), "unlimited launch approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), ALICE, 100 ether), "first launch spend");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), address(this), LAUNCH_SUPPLY - 100 ether), "launch self spend");
        eq(token.allowance(address(this), SPENDER), type(uint256).max, "unlimited launch approval preserved");
        require(token.approve(SPENDER, 0), "revoke launch approval");
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), BOB, 1);
        eq(token.allowance(address(this), SPENDER), 0, "launch revocation persists");
        assertLaunchState(LAUNCH_SUPPLY - 100 ether, 100 ether, 0);
    }

    function test_approvalCannotBeUsedByAnotherSpenderOrAboveItsLimit() public {
        require(token.approve(SPENDER, 99 ether), "limited launch approval");
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(address(this), ALICE, 1);
        vm.expectRevert(
            abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 99 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 100 ether);
        eq(token.allowance(address(this), SPENDER), 99 ether, "failed launch spends preserve approval");
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);
    }

    function test_failedTransfersRestoreAllowanceAndPreserveSupply() public {
        require(token.approve(SPENDER, LAUNCH_SUPPLY + 1), "launch approval above balance");
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmLaunchToken.ERC20InsufficientBalance.selector, address(this), LAUNCH_SUPPLY, LAUNCH_SUPPLY + 1
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, LAUNCH_SUPPLY + 1);
        eq(token.allowance(address(this), SPENDER), LAUNCH_SUPPLY + 1, "balance failure restores launch approval");
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 100 ether);
        eq(token.allowance(address(this), SPENDER), LAUNCH_SUPPLY + 1, "receiver failure restores launch approval");
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);
    }

    function test_invalidZeroAddressesRevertEvenForZeroAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(address(this), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        eq(token.allowance(address(this), address(0)), 0, "invalid spender approval remains zero");
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);
    }

    function test_maximumAmountAndUnfundedSelfTransferRevertWithBalanceErrors() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                SwarmLaunchToken.ERC20InsufficientBalance.selector, address(this), LAUNCH_SUPPLY, type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SwarmLaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(ALICE, 1);
        assertLaunchState(LAUNCH_SUPPLY, 0, 0);
    }

    function test_noMintInitializationOrAdminPrivilegesForDeployerOrStranger() public {
        bytes[10] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, 1 ether),
            abi.encodeWithSignature("mint(uint256)", 1 ether),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("issue(uint256)", 1 ether),
            abi.encodeWithSignature("setOwner(address)", ALICE),
            abi.encodeWithSignature("transferOwnership(address)", ALICE),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("setMinter(address)", ALICE)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(token).call(calls[i]);
            require(!deployerOk, "launch deployer admin call accepted");
            vm.prank(ALICE);
            (bool strangerOk,) = address(token).call(calls[i]);
            require(!strangerOk, "launch stranger admin call accepted");
            assertLaunchState(LAUNCH_SUPPLY, 0, 0);
        }
    }

    function test_runtimeIsBoundedAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(token).code;
        require(code.length > 0 && code.length <= 24_576, "launch runtime size");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden launch opcode");
        }
    }

    function testFuzz_transfersPreserveFixedSupply(uint256 seed, bool self, bool delegated) public {
        uint256 amount = seed % (LAUNCH_SUPPLY + 1);
        address recipient = self ? address(this) : ALICE;
        if (delegated) require(token.approve(SPENDER, amount + 1), "fuzz launch approval");
        vm.recordLogs();
        if (delegated) {
            vm.prank(SPENDER);
            require(token.transferFrom(address(this), recipient, amount), "fuzz delegated launch transfer");
            eq(token.allowance(address(this), SPENDER), 1, "fuzz launch allowance debit");
        } else {
            require(token.transfer(recipient, amount), "fuzz direct launch transfer");
        }
        SwarmVm.Log[] memory logs = vm.getRecordedLogs();
        eq(logs.length, 1, "fuzz launch emits no burn");
        assertTransferLog(logs[0], address(token), address(this), recipient, amount);
        assertLaunchState(self ? LAUNCH_SUPPLY : LAUNCH_SUPPLY - amount, self ? 0 : amount, 0);
    }

    function assertLaunchState(uint256 deployerBalance, uint256 aliceBalance, uint256 bobBalance) internal view {
        eq(token.INITIAL_SUPPLY(), LAUNCH_SUPPLY, "launch initial supply constant");
        eq(token.totalSupply(), LAUNCH_SUPPLY, "launch supply remains fixed");
        eq(token.balanceOf(address(this)), deployerBalance, "launch deployer balance");
        eq(token.balanceOf(ALICE), aliceBalance, "launch alice balance");
        eq(token.balanceOf(BOB), bobBalance, "launch bob balance");
        eq(token.balanceOf(SPENDER), 0, "launch spender receives no fee");
        eq(token.balanceOf(address(0)), 0, "launch zero address holds no tokens");
        eq(deployerBalance + aliceBalance + bobBalance, LAUNCH_SUPPLY, "launch balances conserve supply");
    }
}
