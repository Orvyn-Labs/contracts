// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "../src/tokens/DiktiToken.sol";
import "../src/FundingPool.sol";
import "../src/ProjectFactory.sol";
import "../src/ResearchProject.sol";

/**
 * @title ProjectFactoryTest
 * @notice Test suite for ProjectFactory -- BeaconProxy deployment, registry, beacon upgrades.
 *
 *   Covers:
 *     - Constructor validation
 *     - createProject (happy path, events, registry updates)
 *     - createProject reverts (empty title, mismatched arrays, short duration)
 *     - Project registry (allProjects, projectsByResearcher, pagination)
 *     - upgradeBeacon (admin-only)
 *     - View helpers (totalProjects, projectsOf, getProjects)
 */
contract ProjectFactoryTest is Test {
    DiktiToken public dkt;
    FundingPool public pool;
    ProjectFactory public factory;

    address public admin      = makeAddr("admin");
    address public researcher = makeAddr("researcher");
    address public stranger   = makeAddr("stranger");

    uint256 constant MIN_DUR = 1 hours;
    uint256 constant GOAL    = 1_000 ether;

    function setUp() public {
        dkt  = new DiktiToken(admin);
        pool = new FundingPool(admin, address(dkt));

        // Grant factory-to-be ALLOCATOR_ROLE so it can grantRole on pool
        // (factory grants DEPOSITOR_ROLE to each new project on pool)
        vm.startPrank(admin);
        pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), address(this));
        vm.stopPrank();

        ResearchProject impl = new ResearchProject();

        vm.startPrank(admin);
        factory = new ProjectFactory(admin, address(impl), payable(address(pool)), address(dkt));
        // Grant factory DEFAULT_ADMIN_ROLE on pool so it can grantRole(DEPOSITOR_ROLE)
        pool.grantRole(pool.DEFAULT_ADMIN_ROLE(), address(factory));
        vm.stopPrank();
    }

    // --- Helpers --------------------------------------------------------------

    function _makeMilestones(uint256 n)
        internal
        pure
        returns (
            string[] memory titles,
            uint256[] memory goals,
            uint256[] memory durations
        )
    {
        titles    = new string[](n);
        goals     = new uint256[](n);
        durations = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            titles[i]    = string(abi.encodePacked("Milestone ", uint8(65 + i)));
            goals[i]     = GOAL;
            durations[i] = 30 days;
        }
    }

    // --- Constructor ----------------------------------------------------------

    function test_Constructor_SetsBeacon() public view {
        assertNotEq(address(factory.beacon()), address(0));
    }

    function test_Constructor_SetsFundingPool() public view {
        assertEq(address(factory.fundingPool()), address(pool));
    }

    function test_Constructor_SetsDkt() public view {
        assertEq(address(factory.dkt()), address(dkt));
    }

    function test_Constructor_AdminHasRole() public view {
        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(factory.hasRole(factory.FACTORY_ADMIN_ROLE(), admin));
    }

    function test_Constructor_RevertsZeroAdmin() public {
        ResearchProject impl = new ResearchProject();
        vm.expectRevert(ProjectFactory.ZeroAddress.selector);
        new ProjectFactory(address(0), address(impl), payable(address(pool)), address(dkt));
    }

    function test_Constructor_RevertsZeroImpl() public {
        vm.expectRevert(ProjectFactory.ZeroAddress.selector);
        new ProjectFactory(admin, address(0), payable(address(pool)), address(dkt));
    }

    // --- createProject --------------------------------------------------------

    function test_CreateProject_ReturnsNonZeroAddress() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        address p = factory.createProject("Test Project", titles, goals, durations);
        assertTrue(p != address(0));
    }

    function test_CreateProject_IncrementsRegistry() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        factory.createProject("Test Project", titles, goals, durations);
        assertEq(factory.totalProjects(), 1);
    }

    function test_CreateProject_StoresInAllProjects() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        address p = factory.createProject("Test Project", titles, goals, durations);
        assertEq(factory.allProjects(0), p);
    }

    function test_CreateProject_StoresInResearcherMapping() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        address p = factory.createProject("Test Project", titles, goals, durations);

        address[] memory ps = factory.projectsOf(researcher);
        assertEq(ps.length, 1);
        assertEq(ps[0], p);
    }

    function test_CreateProject_SetsResearcherOnProxy() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        address p = factory.createProject("Test Project", titles, goals, durations);

        assertEq(ResearchProject(p).researcher(), researcher);
    }

    function test_CreateProject_SetsTitleOnProxy() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        address p = factory.createProject("My Research", titles, goals, durations);

        assertEq(ResearchProject(p).title(), "My Research");
    }

    function test_CreateProject_GrantsDepositorRoleToProxy() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        address p = factory.createProject("Test", titles, goals, durations);

        assertTrue(pool.hasRole(pool.DEPOSITOR_ROLE(), p));
    }

    function test_CreateProject_EmitsProjectCreated() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);

        // We only check indexed args (researcher) and partial data
        vm.expectEmit(false, true, false, false);
        emit ProjectFactory.ProjectCreated(address(0), researcher, bytes32(0), "Test", 0, 0, block.number);
        factory.createProject("Test", titles, goals, durations);
    }

    function test_CreateProject_MultipleProjects() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.startPrank(researcher);
        factory.createProject("Project 1", titles, goals, durations);
        factory.createProject("Project 2", titles, goals, durations);
        factory.createProject("Project 3", titles, goals, durations);
        vm.stopPrank();

        assertEq(factory.totalProjects(), 3);
        assertEq(factory.projectsOf(researcher).length, 3);
    }

    function test_CreateProject_MultipleMilestones() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(3);
        vm.prank(researcher);
        address p = factory.createProject("Multi-Ms Project", titles, goals, durations);

        assertEq(ResearchProject(p).milestoneCount(), 3);
    }

    function test_CreateProject_RevertsEmptyTitle() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.prank(researcher);
        vm.expectRevert(ProjectFactory.EmptyTitle.selector);
        factory.createProject("", titles, goals, durations);
    }

    function test_CreateProject_RevertsNoMilestones() public {
        string[] memory titles    = new string[](0);
        uint256[] memory goals    = new uint256[](0);
        uint256[] memory durations = new uint256[](0);

        vm.prank(researcher);
        vm.expectRevert();
        factory.createProject("Test", titles, goals, durations);
    }

    function test_CreateProject_RevertsMismatchedArrays() public {
        string[] memory titles    = new string[](2);
        uint256[] memory goals    = new uint256[](1); // mismatch
        uint256[] memory durations = new uint256[](2);
        titles[0] = "A"; titles[1] = "B";
        goals[0]  = GOAL;
        durations[0] = 30 days; durations[1] = 30 days;

        vm.prank(researcher);
        vm.expectRevert();
        factory.createProject("Test", titles, goals, durations);
    }

    function test_CreateProject_RevertsDurationTooShort() public {
        string[] memory titles    = new string[](1);
        uint256[] memory goals    = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        titles[0]    = "A";
        goals[0]     = GOAL;
        durations[0] = 30 minutes; // < 1 hour

        vm.prank(researcher);
        vm.expectRevert();
        factory.createProject("Test", titles, goals, durations);
    }

    function test_CreateProject_RevertsDurationTooLong() public {
        string[] memory titles    = new string[](1);
        uint256[] memory goals    = new uint256[](1);
        uint256[] memory durations = new uint256[](1);
        titles[0]    = "A";
        goals[0]     = GOAL;
        durations[0] = 366 days; // > 365 days

        vm.prank(researcher);
        vm.expectRevert();
        factory.createProject("Test", titles, goals, durations);
    }

    // --- getProjects pagination ------------------------------------------------

    function test_GetProjects_ReturnsPage() public {
        (string[] memory titles, uint256[] memory goals, uint256[] memory durations) = _makeMilestones(1);
        vm.startPrank(researcher);
        address p1 = factory.createProject("P1", titles, goals, durations);
        address p2 = factory.createProject("P2", titles, goals, durations);
        address p3 = factory.createProject("P3", titles, goals, durations);
        vm.stopPrank();

        address[] memory page = factory.getProjects(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0], p1);
        assertEq(page[1], p2);

        address[] memory page2 = factory.getProjects(2, 10);
        assertEq(page2.length, 1);
        assertEq(page2[0], p3);
    }

    function test_GetProjects_ReturnsEmptyOnOutOfBounds() public view {
        address[] memory page = factory.getProjects(100, 10);
        assertEq(page.length, 0);
    }

    // --- upgradeBeacon --------------------------------------------------------

    function test_UpgradeBeacon_AdminCanUpgrade() public {
        ResearchProject newImpl = new ResearchProject();
        address oldImpl = factory.currentImplementation();

        vm.prank(admin);
        factory.upgradeBeacon(address(newImpl));

        assertNotEq(factory.currentImplementation(), oldImpl);
        assertEq(factory.currentImplementation(), address(newImpl));
    }

    function test_UpgradeBeacon_EmitsBeaconUpgraded() public {
        ResearchProject newImpl = new ResearchProject();
        address oldImpl = factory.currentImplementation();

        vm.expectEmit(true, true, false, false);
        emit ProjectFactory.BeaconUpgraded(oldImpl, address(newImpl));
        vm.prank(admin);
        factory.upgradeBeacon(address(newImpl));
    }

    function test_UpgradeBeacon_RevertsForNonAdmin() public {
        ResearchProject newImpl = new ResearchProject();
        vm.prank(stranger);
        vm.expectRevert();
        factory.upgradeBeacon(address(newImpl));
    }

    function test_UpgradeBeacon_RevertsZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ProjectFactory.ZeroAddress.selector);
        factory.upgradeBeacon(address(0));
    }
}
