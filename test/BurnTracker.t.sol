// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Swarm, SwarmLaunchToken} from "../src/Swarm.sol";
import {BurnTracker} from "../src/BurnTracker.sol";
import {SwarmTestSupport} from "./Swarm.t.sol";

/// @notice Dependency-free tracker unit and sequence tests; run with `forge test --gas-report`.
/// @dev Gas report with Forge 1.7.1, solc 0.8.26, default compiler settings: deployment 252,391 gas,
/// creation code including constructor argument 1,329 bytes; totalBurned 6,858 gas; token 547 gas.
contract BurnTrackerTest is SwarmTestSupport {
    Swarm internal token;
    BurnTracker internal tracker;

    function setUp() public {
        token = new Swarm();
        tracker = new BurnTracker(address(token));
    }

    function test_constructorBindsTokenWithoutMovingSupply() public view {
        eq(address(tracker.token()), address(token), "bound token");
        eq(tracker.totalBurned(), 0, "initial burned amount");
        eq(token.totalSupply(), SUPPLY, "tracker preserves supply");
        eq(token.balanceOf(address(this)), SUPPLY, "tracker preserves deployer balance");
        eq(token.balanceOf(address(tracker)), 0, "tracker receives no tokens");
    }

    function test_constructorRejectsZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.InvalidToken.selector, address(0)));
        new BurnTracker(address(0));
    }

    function test_constructorRejectsAddressWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.InvalidToken.selector, ALICE));
        new BurnTracker(ALICE);
    }

    function test_constructorRejectsNotYetDeployedAddress() public {
        address futureToken = address(0xF070);
        eq(futureToken.code.length, 0, "future address has no code");
        vm.expectRevert(abi.encodeWithSelector(BurnTracker.InvalidToken.selector, futureToken));
        new BurnTracker(futureToken);
    }

    function test_tracksTransferBurnImmediatelyWithoutUpdateCall() public {
        require(token.transfer(ALICE, 100 ether), "transfer");
        assertBurned(1 ether);
        vm.prank(BOB);
        eq(tracker.totalBurned(), 1 ether, "any caller can read");
        eq(tracker.totalBurned(), 1 ether, "reads do not double count");
    }

    function test_tracksBurnsBeforeAndAfterItsDeployment() public {
        require(token.transfer(ALICE, 100 ether), "historical transfer");
        BurnTracker lateTracker = new BurnTracker(address(token));
        eq(lateTracker.totalBurned(), 1 ether, "historical burn included");
        eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "late constructor preserves balance");
        vm.prank(ALICE);
        require(token.transfer(BOB, 50 ether), "later transfer");
        assertBurned(1.5 ether);
        eq(lateTracker.totalBurned(), 1.5 ether, "late and early trackers agree");
    }

    function test_tracksSelfAndDelegatedTransfersCumulatively() public {
        require(token.transfer(ALICE, 100 ether), "normal transfer");
        vm.prank(ALICE);
        require(token.transfer(ALICE, 50 ether), "self transfer");
        require(token.approve(SPENDER, 200 ether), "approval");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), BOB, 100 ether), "delegated transfer");
        vm.prank(SPENDER);
        require(token.transferFrom(address(this), address(this), 100 ether), "delegated self transfer");
        assertBurned(3.5 ether);
        eq(token.balanceOf(ALICE), 98.5 ether, "self burn reflected in holder balance");
        eq(token.balanceOf(BOB), 99 ether, "delegated net reflected in holder balance");
        eq(token.allowance(address(this), SPENDER), 0, "gross allowance consumed");
    }

    function test_zeroTransfersAndApprovalsDoNotIncreaseBurned() public {
        require(token.transfer(ALICE, 100 ether), "establish existing burn");
        require(token.transfer(BOB, 0), "zero transfer");
        vm.prank(BOB);
        require(token.transfer(BOB, 0), "empty self transfer");
        vm.prank(SPENDER);
        require(token.transferFrom(BOB, ALICE, 0), "zero delegated transfer");
        require(token.approve(SPENDER, type(uint256).max), "approval");
        require(token.approve(SPENDER, 0), "revocation");
        assertBurned(1 ether);
    }

    function test_roundingIsPerTransferRatherThanOnAggregatedVolume() public {
        require(token.transfer(ALICE, 99), "first sub-threshold transfer");
        require(token.transfer(ALICE, 99), "second sub-threshold transfer");
        assertBurned(0);
        require(token.transfer(ALICE, 101), "first one-unit burn");
        assertBurned(1);
        require(token.transfer(ALICE, 199), "second one-unit burn");
        assertBurned(2);
        eq(token.balanceOf(ALICE), 496, "rounding retains indivisible remainder");
        eq(token.balanceOf(address(this)), SUPPLY - 498, "rounding gross debit");
    }

    function test_burningEntireSupplyTransferIsReportedExactly() public {
        require(token.transfer(ALICE, SUPPLY), "entire balance transfer");
        assertBurned(10_000 ether);
        vm.prank(ALICE);
        require(token.transfer(BOB, 990_000 ether), "entire recipient balance transfer");
        assertBurned(19_900 ether);
        eq(token.balanceOf(address(this)), 0, "initial holder empty");
        eq(token.balanceOf(ALICE), 0, "intermediate holder empty");
        eq(token.balanceOf(BOB), 980_100 ether, "remaining supply belongs to recipient");
    }

    function test_failedTransferCannotIncreaseBurned() public {
        require(token.transfer(ALICE, 100 ether), "establish burn");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, ALICE, 99 ether, 100 ether));
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertBurned(1 ether);
        eq(token.balanceOf(ALICE), 99 ether, "failed sender unchanged");
        eq(token.balanceOf(BOB), 0, "failed recipient unchanged");
    }

    function test_failedDelegatedTransferCannotIncreaseBurnedOrSpendAllowance() public {
        require(token.transfer(ALICE, 100 ether), "establish burn");
        vm.prank(ALICE);
        require(token.approve(SPENDER, 100 ether), "approve more than balance");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientBalance.selector, ALICE, 99 ether, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertBurned(1 ether);
        eq(token.allowance(ALICE, SPENDER), 100 ether, "failed delegated allowance unchanged");
        eq(token.balanceOf(ALICE), 99 ether, "failed delegated sender unchanged");
        eq(token.balanceOf(BOB), 0, "failed delegated recipient unchanged");
    }

    function test_insufficientAllowanceLeavesBurnsUnchangedAndValidRetryCountsOnce() public {
        require(token.transfer(ALICE, 200 ether), "establish burn and fund holder");
        vm.prank(ALICE);
        require(token.approve(SPENDER, 99 ether), "approve only the net amount");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InsufficientAllowance.selector, SPENDER, 99 ether, 100 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertBurned(2 ether);
        eq(token.allowance(ALICE, SPENDER), 99 ether, "rejected spend preserves allowance");
        eq(token.balanceOf(ALICE), 198 ether, "rejected spend preserves sender balance");
        eq(token.balanceOf(BOB), 0, "rejected spend cannot credit recipient");

        vm.prank(ALICE);
        require(token.approve(SPENDER, 100 ether), "approve gross amount for retry");
        vm.prank(SPENDER);
        require(token.transferFrom(ALICE, BOB, 100 ether), "retry succeeds");
        assertBurned(3 ether);
        eq(token.allowance(ALICE, SPENDER), 0, "retry consumes allowance once");
        eq(token.balanceOf(ALICE), 98 ether, "retry debits gross amount once");
        eq(token.balanceOf(BOB), 99 ether, "retry credits net amount once");
        eq(token.balanceOf(address(this)), SUPPLY - 200 ether, "unrelated holder unchanged");
    }

    function test_transferToZeroCannotBeCountedAsBurn() public {
        require(token.transfer(ALICE, 100 ether), "establish burn");
        vm.expectRevert(abi.encodeWithSelector(Swarm.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 100 ether);
        assertBurned(1 ether);
        eq(token.balanceOf(address(this)), SUPPLY - 100 ether, "invalid receiver debit rolled back");
    }

    function test_independentTrackersRemainBoundToTheirOwnTokens() public {
        Swarm otherToken = new Swarm();
        BurnTracker otherTracker = new BurnTracker(address(otherToken));
        require(token.transfer(ALICE, 100 ether), "first token transfer");
        eq(otherTracker.totalBurned(), 0, "other token unaffected");
        require(otherToken.transfer(BOB, 200 ether), "other token transfer");
        assertBurned(1 ether);
        eq(otherTracker.totalBurned(), 2 ether, "independent burn count");
        eq(address(otherTracker.token()), address(otherToken), "other binding");
    }

    function test_applicationDeploymentAndBurnsRemainSeparateFromLaunchSupply() public {
        SwarmLaunchToken launchToken = new SwarmLaunchToken();
        Swarm application = new Swarm();
        BurnTracker applicationTracker = new BurnTracker(address(application));
        uint256 launchSupply = 1_000_000_000 ether;
        eq(launchToken.totalSupply(), launchSupply, "applications preserve launch supply");
        eq(launchToken.balanceOf(address(this)), launchSupply, "applications preserve launch allocation");
        eq(application.balanceOf(address(this)), SUPPLY, "application constructor allocation");
        eq(address(applicationTracker.token()), address(application), "tracker binds deflationary application");
        eq(applicationTracker.totalBurned(), 0, "application begins without burns");

        require(launchToken.transfer(ALICE, 100 ether), "launch distribution");
        eq(launchToken.balanceOf(ALICE), 100 ether, "launch recipient receives full amount");
        eq(applicationTracker.totalBurned(), 0, "launch transfer cannot affect application burns");
        require(application.transfer(ALICE, 100 ether), "application transfer");
        eq(application.balanceOf(ALICE), 99 ether, "application recipient receives net amount");
        eq(application.totalSupply(), SUPPLY - 1 ether, "application supply decreases");
        eq(applicationTracker.totalBurned(), 1 ether, "tracker counts only application burn");
        eq(launchToken.totalSupply(), launchSupply, "application burn preserves launch supply");
        eq(launchToken.balanceOf(address(this)), launchSupply - 100 ether, "launch allocation after distribution");
        eq(launchToken.balanceOf(ALICE), 100 ether, "application burn preserves launch recipient balance");
    }

    function test_receivingTokensDoesNotConfuseHoldingsWithBurns() public {
        require(token.transfer(address(tracker), 100 ether), "transfer to tracker");
        eq(token.balanceOf(address(tracker)), 99 ether, "tracker holdings");
        assertBurned(1 ether);
    }

    function test_noPublicUpdateOrTokenReplacementCanForgeBurns() public {
        bytes[3] memory calls = [
            abi.encodeWithSignature("setToken(address)", ALICE),
            abi.encodeWithSignature("recordBurn(uint256)", SUPPLY),
            abi.encodeWithSignature("initialize(address)", ALICE)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerOk,) = address(tracker).call(calls[i]);
            require(!deployerOk, "deployer tracker mutation accepted");
            vm.prank(ALICE);
            (bool strangerOk,) = address(tracker).call(calls[i]);
            require(!strangerOk, "stranger tracker mutation accepted");
            eq(address(tracker.token()), address(token), "token binding unchanged");
            assertBurned(0);
        }
    }

    function testFuzz_trackerIncludesHistoricalAndNewBurns(uint256 firstSeed, uint256 secondSeed) public {
        uint256 firstAmount = firstSeed % (SUPPLY + 1);
        require(token.transfer(ALICE, firstAmount), "fuzz historical transfer");
        uint256 firstBurn = firstAmount / 100;
        BurnTracker lateTracker = new BurnTracker(address(token));
        eq(lateTracker.totalBurned(), firstBurn, "fuzz historical burn");
        uint256 secondAmount = secondSeed % (firstAmount - firstBurn + 1);
        vm.prank(ALICE);
        require(token.transfer(BOB, secondAmount), "fuzz later transfer");
        uint256 expectedBurn = firstBurn + secondAmount / 100;
        assertBurned(expectedBurn);
        eq(lateTracker.totalBurned(), expectedBurn, "fuzz late tracker cumulative burn");
    }

    function testFuzz_mixedTransferSequencePreservesAccounting(uint256 seed) public {
        address[4] memory holders = [address(this), ALICE, BOB, SPENDER];
        uint256[4] memory balances = [SUPPLY, uint256(0), uint256(0), uint256(0)];
        uint256 burned;

        // Model every holder after every action, including aliased sender/recipient and spender.
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 from = seed % holders.length;
            uint256 to = (seed >> 8) % holders.length;
            uint256 amount = (seed >> 16) % (balances[from] + 1);
            if (i % 6 == 0) amount = balances[from];
            if (i % 6 == 1) amount = 0;

            if (i % 2 == 0) {
                vm.prank(holders[from]);
                require(token.transfer(holders[to], amount), "sequence direct return");
            } else {
                vm.prank(holders[from]);
                require(token.approve(SPENDER, amount), "sequence approval");
                vm.prank(SPENDER);
                require(token.transferFrom(holders[from], holders[to], amount), "sequence delegated return");
                eq(token.allowance(holders[from], SPENDER), 0, "sequence gross allowance spent");
            }

            uint256 burn = amount / 100;
            balances[from] -= amount;
            balances[to] += amount - burn;
            burned += burn;
            uint256 sum;
            for (uint256 j; j < holders.length; ++j) {
                eq(token.balanceOf(holders[j]), balances[j], "sequence modeled holder balance");
                sum += balances[j];
            }
            eq(sum, token.totalSupply(), "sequence balance sum");
            assertBurned(burned);
        }
    }

    function assertBurned(uint256 expected) internal view {
        eq(tracker.totalBurned(), expected, "cumulative burn amount");
        eq(token.totalSupply(), SUPPLY - expected, "supply reduced by cumulative burns");
        eq(token.totalSupply() + tracker.totalBurned(), SUPPLY, "supply plus burns conserved");
        eq(token.INITIAL_SUPPLY(), SUPPLY, "initial supply constant unchanged");
        eq(token.balanceOf(address(0)), 0, "burn does not credit zero address");
    }
}
