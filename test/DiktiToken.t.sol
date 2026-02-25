// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/tokens/DiktiToken.sol";

contract DiktiTokenTest is Test {
    DiktiToken public token;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        token = new DiktiToken(admin);
    }

    // ─── Deployment ───────────────────────────────────────────────────────────
    function test_Deployment_NameAndSymbol() public view {
        assertEq(token.name(), "Dikti Token");
        assertEq(token.symbol(), "DKT");
        assertEq(token.decimals(), 18);
    }

    function test_Deployment_AdminHasRoles() public view {
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
    }

    function test_Deployment_ZeroSupply() public view {
        assertEq(token.totalSupply(), 0);
        assertEq(token.remainingSupply(), token.MAX_SUPPLY());
    }

    function test_Deployment_RejectsZeroAdmin() public {
        vm.expectRevert(DiktiToken.ZeroAddress.selector);
        new DiktiToken(address(0));
    }

    // ─── Minting ─────────────────────────────────────────────────────────────
    function test_Mint_AdminCanMint() public {
        vm.prank(admin);
        token.mint(alice, 1000 ether);
        assertEq(token.balanceOf(alice), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }

    function test_Mint_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit DiktiToken.TokensMinted(alice, 1000 ether, 1000 ether);
        token.mint(alice, 1000 ether);
    }

    function test_Mint_GrantedMinterCanMint() public {
        bytes32 minterRole = token.MINTER_ROLE(); // read before prank
        vm.prank(admin);
        token.grantRole(minterRole, minter);

        vm.prank(minter);
        token.mint(bob, 500 ether);
        assertEq(token.balanceOf(bob), 500 ether);
    }

    function test_Mint_RevertsIfNotMinter() public {
        vm.prank(alice);
        vm.expectRevert();
        token.mint(alice, 100 ether);
    }

    function test_Mint_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(DiktiToken.ZeroAddress.selector);
        token.mint(address(0), 100 ether);
    }

    function test_Mint_RevertsZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(DiktiToken.ZeroAmount.selector);
        token.mint(alice, 0);
    }

    function test_Mint_RevertsExceedsMaxSupply() public {
        uint256 cap = token.MAX_SUPPLY();
        vm.prank(admin);
        vm.expectRevert();
        token.mint(alice, cap + 1);
    }

    function test_Mint_ExactlyAtMaxSupply() public {
        uint256 cap = token.MAX_SUPPLY();
        vm.prank(admin);
        token.mint(alice, cap);
        assertEq(token.totalSupply(), cap);
        assertEq(token.remainingSupply(), 0);
    }

    // ─── Transfer ─────────────────────────────────────────────────────────────
    function test_Transfer_Works() public {
        vm.prank(admin);
        token.mint(alice, 1000 ether);

        vm.prank(alice);
        token.transfer(bob, 400 ether);

        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.balanceOf(bob), 400 ether);
    }

    function test_Approve_And_TransferFrom() public {
        vm.prank(admin);
        token.mint(alice, 1000 ether);

        vm.prank(alice);
        token.approve(bob, 300 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 300 ether);

        assertEq(token.balanceOf(alice), 700 ether);
        assertEq(token.balanceOf(bob), 300 ether);
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────
    function testFuzz_Mint_AnyValidAmount(uint96 amount) public {
        vm.assume(amount > 0);
        vm.assume(uint256(amount) <= token.MAX_SUPPLY());

        vm.prank(admin);
        token.mint(alice, uint256(amount));
        assertEq(token.balanceOf(alice), uint256(amount));
    }

    function testFuzz_Transfer_PartialAmount(uint96 mintAmount, uint96 transferAmount) public {
        vm.assume(mintAmount > 0);
        vm.assume(transferAmount > 0 && uint256(transferAmount) <= uint256(mintAmount));
        vm.assume(uint256(mintAmount) <= token.MAX_SUPPLY());

        vm.prank(admin);
        token.mint(alice, uint256(mintAmount));

        vm.prank(alice);
        token.transfer(bob, uint256(transferAmount));

        assertEq(token.balanceOf(alice), uint256(mintAmount) - uint256(transferAmount));
        assertEq(token.balanceOf(bob), uint256(transferAmount));
    }
}
