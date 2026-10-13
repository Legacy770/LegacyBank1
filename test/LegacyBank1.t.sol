// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LegacyBank} from "../src/LegacyBank.sol";
import {MockUSDC, MockAToken, MockAavePool} from "./mocks/Mocks.sol";

contract LegacyBankTest is Test {
    LegacyBank bank;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockAavePool pool;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");

    uint256 constant AMT = 1_000e6;
    uint256 constant NET = 995e6; // after 0.5% fee

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        pool = new MockAavePool(usdc, aUsdc);
        bank = new LegacyBank(owner, treasury, address(pool), 8_000); // 80% cap

        vm.prank(owner);
        bank.configureToken(address(usdc), true, address(aUsdc));

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(bank), type(uint256).max);
    }

    function _deposit(uint256 duration) internal returns (uint256 id) {
        vm.prank(alice);
        id = bank.deposit(address(usdc), AMT, duration);
    }

    function test_depositTakesFeeAndLocks() public {
        uint256 id = _deposit(120 days);
        assertEq(usdc.balanceOf(treasury), 5e6);
        assertEq(bank.totalLocked(address(usdc)), NET);
        (address o,,, address t, uint128 a) = bank.positions(id);
        assertEq(o, alice);
        assertEq(t, address(usdc));
        assertEq(a, NET);
    }

    function test_durationBounds() public {
        vm.startPrank(alice);
        vm.expectRevert(LegacyBank.InvalidDuration.selector);
        bank.deposit(address(usdc), AMT, 119 days);
        vm.expectRevert(LegacyBank.InvalidDuration.selector);
        bank.deposit(address(usdc), AMT, 1096 days);
        bank.deposit(address(usdc), AMT, 1095 days); // ok
        vm.stopPrank();
    }

    function test_withdrawAfterUnlock() public {
        uint256 id = _deposit(120 days);
        vm.prank(alice);
        vm.expectRevert(LegacyBank.StillLocked.selector);
        bank.withdraw(id);

        vm.warp(block.timestamp + 120 days);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        bank.withdraw(id);
        assertEq(usdc.balanceOf(alice) - before, NET);
        assertEq(bank.totalLocked(address(usdc)), 0);
    }

    function test_emergencyWithdrawPenalty() public {
        uint256 id = _deposit(365 days);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        bank.emergencyWithdraw(id);
        assertEq(usdc.balanceOf(alice) - before, 895_500_000); // 90% of 995
        assertEq(usdc.balanceOf(treasury), 5e6 + 99_500_000);
    }

    function test_cannotWithdrawTwiceOrByOthers() public {
        uint256 id = _deposit(120 days);
        vm.expectRevert(LegacyBank.NotPositionOwner.selector);
        bank.withdraw(id);
        vm.warp(block.timestamp + 120 days);
        vm.startPrank(alice);
        bank.withdraw(id);
        vm.expectRevert(LegacyBank.PositionClosed.selector);
        bank.withdraw(id);
        vm.stopPrank();
    }

    function test_allocationCapAndAutoPull() public {
        uint256 id = _deposit(120 days);

        vm.startPrank(owner);
        vm.expectRevert(LegacyBank.ExceedsAllocationCap.selector);
        bank.allocateToAave(address(usdc), 800e6); // cap = 796e6
        bank.allocateToAave(address(usdc), 700e6);
        vm.stopPrank();
        assertEq(bank.allocated(address(usdc)), 700e6);

        // idle is only 295e6; withdrawal must auto-pull from Aave
        vm.warp(block.timestamp + 120 days);
        vm.prank(alice);
        bank.withdraw(id);
        assertEq(bank.allocated(address(usdc)), 0);
    }

    function test_harvestYieldToTreasury() public {
        _deposit(120 days);
        vm.prank(owner);
        bank.allocateToAave(address(usdc), 700e6);

        // simulate 10 USDC of Aave yield
        aUsdc.mint(address(bank), 10e6);
        usdc.mint(address(pool), 10e6);

        uint256 before = usdc.balanceOf(treasury);
        vm.prank(owner);
        bank.harvestYield(address(usdc));
        assertEq(usdc.balanceOf(treasury) - before, 10e6);
    }

    function test_onlyOperatorCanAllocate() public {
        _deposit(120 days);
        vm.prank(alice);
        vm.expectRevert(LegacyBank.NotOperator.selector);
        bank.allocateToAave(address(usdc), 1e6);
    }

    function test_pauseBlocksDepositsNotWithdrawals() public {
        uint256 id = _deposit(120 days);
        vm.prank(owner);
        bank.pause();
        vm.prank(alice);
        vm.expectRevert();
        bank.deposit(address(usdc), AMT, 120 days);

        vm.prank(alice);
        bank.emergencyWithdraw(id); // still works
    }
}