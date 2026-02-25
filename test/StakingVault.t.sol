// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/tokens/DiktiToken.sol";
import "../src/StakingVault.sol";
import "../src/YieldDistributor.sol";

contract StakingVaultTest is Test {
    DiktiToken public dkt;
    StakingVault public vault;
    StakingVault public vaultImpl;
    YieldDistributor public distImpl;
    YieldDistributor public dist;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    uint256 constant LOCK_PERIOD = 7 days;
    uint256 constant INITIAL_RATE = 0.1e18; // 10% APY
    uint256 constant MINT_AMOUNT = 10_000 ether;

    function setUp() public {
        // Deploy DKT
        dkt = new DiktiToken(admin);

        // Deploy YieldDistributor via UUPS proxy
        distImpl = new YieldDistributor();
        bytes memory distInit = abi.encodeCall(YieldDistributor.initialize, (admin, INITIAL_RATE));
        ERC1967Proxy distProxy = new ERC1967Proxy(address(distImpl), distInit);
        dist = YieldDistributor(payable(address(distProxy)));

        // Deploy StakingVault via UUPS proxy
        vaultImpl = new StakingVault();
        bytes memory vaultInit = abi.encodeCall(
            StakingVault.initialize,
            (admin, address(dkt), address(dist), LOCK_PERIOD)
        );
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImpl), vaultInit);
        vault = StakingVault(address(vaultProxy));

        // Wire up: set StakingVault on YieldDistributor
        vm.prank(admin);
        dist.setStakingVault(address(vault));

        // Mint DKT to test users
        vm.startPrank(admin);
        dkt.mint(alice, MINT_AMOUNT);
        dkt.mint(bob, MINT_AMOUNT);
        vm.stopPrank();

        // Fund yield pool with 10 ETH
        vm.deal(admin, 10 ether);
        vm.prank(admin);
        dist.fundYieldPool{value: 10 ether}();
    }

    // ─── Initialization ────────────────────────────────────────────────────────
    function test_Init_CorrectConfig() public view {
        assertEq(vault.dktToken(), address(dkt));
        assertEq(vault.yieldDistributor(), address(dist));
        assertEq(vault.lockPeriod(), LOCK_PERIOD);
        assertEq(vault.totalStaked(), 0);
    }

    function test_Init_RejectsZeroAddress() public {
        StakingVault freshImpl = new StakingVault();
        bytes memory initData = abi.encodeCall(
            StakingVault.initialize,
            (address(0), address(dkt), address(dist), 0)
        );
        vm.expectRevert();
        new ERC1967Proxy(address(freshImpl), initData);
    }

    // ─── Staking ──────────────────────────────────────────────────────────────
    function test_Stake_TransfersDKT() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        assertEq(vault.stakedBalance(alice), 1000 ether);
        assertEq(vault.totalStaked(), 1000 ether);
        assertEq(dkt.balanceOf(alice), MINT_AMOUNT - 1000 ether);
        assertEq(dkt.balanceOf(address(vault)), 1000 ether);
    }

    function test_Stake_SetsLockExpiry() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        assertEq(vault.lockExpiry(alice), block.timestamp + LOCK_PERIOD);
    }

    function test_Stake_EmitsEvent() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vm.expectEmit(true, false, false, false);
        emit StakingVault.Staked(alice, 1000 ether, 1000 ether, block.timestamp + LOCK_PERIOD, block.number);
        vault.stake(1000 ether);
        vm.stopPrank();
    }

    function test_Stake_NotifiesYieldDistributor() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        assertEq(dist.userStakedBalance(alice), 1000 ether);
        assertEq(dist.totalStaked(), 1000 ether);
    }

    function test_Stake_RevertsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_Stake_MultipleUsers() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        vm.startPrank(bob);
        dkt.approve(address(vault), 2000 ether);
        vault.stake(2000 ether);
        vm.stopPrank();

        assertEq(vault.totalStaked(), 3000 ether);
        assertEq(vault.stakedBalance(alice), 1000 ether);
        assertEq(vault.stakedBalance(bob), 2000 ether);
    }

    // ─── Unstaking ────────────────────────────────────────────────────────────
    function test_Unstake_AfterLockPeriod() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(alice);
        vault.unstake(1000 ether);

        assertEq(vault.stakedBalance(alice), 0);
        assertEq(dkt.balanceOf(alice), MINT_AMOUNT);
    }

    function test_Unstake_RevertsBeforeLock() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert();
        vault.unstake(1000 ether);
    }

    function test_Unstake_PartialAmount() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(alice);
        vault.unstake(400 ether);

        assertEq(vault.stakedBalance(alice), 600 ether);
        assertEq(dkt.balanceOf(alice), MINT_AMOUNT - 600 ether);
    }

    function test_Unstake_RevertsInsufficientBalance() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert();
        vault.unstake(1001 ether);
    }

    function test_Unstake_EmitsEvent() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        vm.prank(alice);
        vm.expectEmit(true, false, false, false);
        emit StakingVault.Unstaked(alice, 1000 ether, 0, block.number);
        vault.unstake(1000 ether);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    function test_SetLockPeriod_ByAdmin() public {
        vm.prank(admin);
        vault.setLockPeriod(14 days);
        assertEq(vault.lockPeriod(), 14 days);
    }

    function test_SetLockPeriod_RevertsIfNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setLockPeriod(14 days);
    }

    function test_SetLockPeriod_ZeroAllowed() public {
        vm.prank(admin);
        vault.setLockPeriod(0);
        assertEq(vault.lockPeriod(), 0);
    }

    // ─── Yield accrual ────────────────────────────────────────────────────────
    function test_Yield_AccruesAfterStaking() public {
        vm.startPrank(alice);
        dkt.approve(address(vault), 1000 ether);
        vault.stake(1000 ether);
        vm.stopPrank();

        // Advance 30 days
        vm.warp(block.timestamp + 30 days);

        uint256 pending = dist.pendingYield(alice);
        assertGt(pending, 0, "Yield should accrue after staking");
    }

    function test_Yield_ZeroBeforeStaking() public view {
        assertEq(dist.pendingYield(alice), 0);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────
    function testFuzz_Stake_AnyAmount(uint96 amount) public {
        vm.assume(amount > 0 && uint256(amount) <= MINT_AMOUNT);

        vm.startPrank(alice);
        dkt.approve(address(vault), uint256(amount));
        vault.stake(uint256(amount));
        vm.stopPrank();

        assertEq(vault.stakedBalance(alice), uint256(amount));
    }

    // ─── Invariant: vault DKT balance == totalStaked ──────────────────────────
    function invariant_VaultBalanceEqualsTotalStaked() public view {
        assertEq(dkt.balanceOf(address(vault)), vault.totalStaked());
    }
}
