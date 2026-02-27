// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "./ResearchProject.sol";
import "./FundingPool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ProjectFactory
 * @notice Deploys new ResearchProject instances as BeaconProxy contracts.
 *         Maintains a registry of all deployed projects for on-chain enumeration
 *         and off-chain indexing.
 *
 * @dev COMPLEXITY LEVEL 4 — contract creation (highest gas cost category).
 *      Immutable — the factory itself is not upgradeable. The ResearchProject
 *      implementation is upgradeable via the UpgradeableBeacon it holds.
 *
 *      Beacon Proxy pattern:
 *        - One UpgradeableBeacon holds the ResearchProject implementation address
 *        - Each project is a cheap BeaconProxy that delegates to the beacon
 *        - Upgrading the beacon implementation upgrades ALL projects simultaneously
 *        - Beacon upgrade is restricted to DEFAULT_ADMIN_ROLE
 *
 *      Gas profile targets:
 *        createProject()  ~300,000-400,000 gas  (BeaconProxy deployment + initialize)
 *        upgradeBeacon()  ~30,000 gas            (single SSTORE on beacon)
 */
contract ProjectFactory is AccessControl {
    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant FACTORY_ADMIN_ROLE = keccak256("FACTORY_ADMIN_ROLE");

    // ─── Errors ───────────────────────────────────────────────────────────────
    error ZeroAddress();
    error EmptyTitle();
    error DurationTooShort(uint256 provided, uint256 minimum);
    error DurationTooLong(uint256 provided, uint256 maximum);

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 365 days;

    // ─── Events ───────────────────────────────────────────────────────────────
    event ProjectCreated(
        address indexed projectAddress,
        address indexed researcher,
        bytes32 indexed projectId,
        string title,
        uint256 goalAmount,
        uint256 deadline,
        uint256 blockNumber
    );
    event BeaconUpgraded(address indexed oldImpl, address indexed newImpl);

    // ─── State ────────────────────────────────────────────────────────────────
    /// @notice The beacon holding the ResearchProject implementation
    UpgradeableBeacon public immutable beacon;

    /// @notice The FundingPool that all projects route funds to
    FundingPool public immutable fundingPool;

    /// @notice The DKT token used for donations
    IERC20 public immutable dkt;

    /// @notice Ordered list of all deployed project addresses
    address[] public allProjects;

    /// @notice Lookup: researcher address → their project addresses
    mapping(address => address[]) public projectsByResearcher;

    // ─── Constructor ──────────────────────────────────────────────────────────
    /**
     * @param admin                 Admin address (DEFAULT_ADMIN_ROLE + FACTORY_ADMIN_ROLE)
     * @param researchProjectImpl   Initial ResearchProject implementation address
     * @param _fundingPool          FundingPool contract address (immutable reference)
     */
    constructor(
        address admin,
        address researchProjectImpl,
        address payable _fundingPool,
        address _dkt
    ) {
        if (admin == address(0)) revert ZeroAddress();
        if (researchProjectImpl == address(0)) revert ZeroAddress();
        if (_fundingPool == address(0)) revert ZeroAddress();
        if (_dkt == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FACTORY_ADMIN_ROLE, admin);

        beacon = new UpgradeableBeacon(researchProjectImpl, address(this));
        fundingPool = FundingPool(payable(_fundingPool));
        dkt = IERC20(_dkt);
    }

    // ─── Core: Create project ─────────────────────────────────────────────────
    /**
     * @notice Deploy a new ResearchProject as a BeaconProxy.
     * @dev    Any address can create a project (permissionless).
     *         The caller becomes the `researcher` of the deployed project.
     *
     * @param  title               Project title
     * @param  milestoneTitles     Array of milestone titles
     * @param  milestoneGoals      Array of milestone DKT goals (informational)
     * @param  milestoneDurations  Array of milestone durations in seconds
     * @return projectAddr         Address of the deployed ResearchProject proxy
     */
    function createProject(
        string calldata title,
        string[] calldata milestoneTitles,
        uint256[] calldata milestoneGoals,
        uint256[] calldata milestoneDurations
    ) external returns (address projectAddr) {
        if (bytes(title).length == 0) revert EmptyTitle();
        require(milestoneTitles.length > 0, "Need at least one milestone");
        require(
            milestoneTitles.length == milestoneGoals.length &&
            milestoneGoals.length == milestoneDurations.length,
            "Milestone array length mismatch"
        );
        for (uint256 i = 0; i < milestoneDurations.length; i++) {
            if (milestoneDurations[i] < MIN_DURATION) revert DurationTooShort(milestoneDurations[i], MIN_DURATION);
            if (milestoneDurations[i] > MAX_DURATION) revert DurationTooLong(milestoneDurations[i], MAX_DURATION);
        }

        bytes memory initData = abi.encodeCall(
            ResearchProject.initialize,
            (
                msg.sender,
                address(fundingPool),
                address(dkt),
                title,
                milestoneTitles,
                milestoneGoals,
                milestoneDurations
            )
        );

        BeaconProxy proxy = new BeaconProxy(address(beacon), initData);
        projectAddr = address(proxy);

        allProjects.push(projectAddr);
        projectsByResearcher[msg.sender].push(projectAddr);

        bytes32 pid = ResearchProject(payable(projectAddr)).projectId();

        fundingPool.grantRole(fundingPool.DEPOSITOR_ROLE(), projectAddr);

        emit ProjectCreated(
            projectAddr,
            msg.sender,
            pid,
            title,
            0,
            0,
            block.number
        );
    }

    // ─── Admin: Upgrade beacon ────────────────────────────────────────────────
    /**
     * @notice Upgrade the ResearchProject implementation for ALL projects.
     * @dev    Only DEFAULT_ADMIN_ROLE. This is a powerful operation —
     *         it upgrades every deployed project simultaneously.
     *         Used in research to compare gas costs across implementation versions.
     */
    function upgradeBeacon(address newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        address old = beacon.implementation();
        beacon.upgradeTo(newImplementation);
        emit BeaconUpgraded(old, newImplementation);
    }

    // ─── View ─────────────────────────────────────────────────────────────────
    function totalProjects() external view returns (uint256) {
        return allProjects.length;
    }

    function projectsOf(address researcher) external view returns (address[] memory) {
        return projectsByResearcher[researcher];
    }

    function projectsOfCount(address researcher) external view returns (uint256) {
        return projectsByResearcher[researcher].length;
    }

    /// @notice Returns a page of projects (pagination for frontend)
    function getProjects(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 total = allProjects.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ) {
            page[i - offset] = allProjects[i];
            unchecked { ++i; }
        }
    }

    function currentImplementation() external view returns (address) {
        return beacon.implementation();
    }
}
