// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

interface IGATHMintable {
    function mint(address to, uint256 amount) external;
}

interface ISenatorNFTMintable {
    function mintBatch(address to, uint256 count) external;
}

interface IMembershipReferrer {
    function referrerOf(address account) external view returns (address);
}

contract ILOV1 is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // USDC has 6 decimals on Polygon.
    uint256 public constant MIN_PER_CALL = 100e6;     // minimum per subscribe() call
    uint256 public constant MAX_PER_ADDRESS = 50_000e6;
    uint256 public constant SOFT_CAP = 50_000e6;
    uint256 public constant HARD_CAP = 200_000e6;
    // 1 Senator NFT minted for every cumulative 1,000 USDC contributed by a wallet.
    uint256 public constant NFT_UNIT = 1_000e6;
    // 1 USDC raw (1e6) * 5e10 = 5e16 = 0.05 gATH; so 100 USDC -> 5 gATH (gATH has 18 decimals).
    uint256 public constant GATH_PER_USDC = 5e10;
    // 10% of the contributor's gATH is minted on top to their referrer.
    uint256 public constant REFERRER_BPS = 1_000; // 10.00%
    uint256 public constant BPS_DENOM = 10_000;
    address private constant ROOT_REFERRER_SENTINEL = address(1);

    IERC20Upgradeable public usdc;
    IGATHMintable public gath;
    ISenatorNFTMintable public nft;
    IMembershipReferrer public membership;

    mapping(address => uint256) public usdcContributed;
    uint256 public totalRaised;
    uint256 public participantCount;
    bool public finalized;

    event Subscribed(
        address indexed user,
        uint256 amount,
        uint256 gathMinted,
        address indexed referrer,
        uint256 referrerBonus,
        uint256 totalRaised
    );
    event Withdrawn(address indexed treasury, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address usdc_,
        address gath_,
        address nft_,
        address membership_,
        address admin_
    ) external initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);

        usdc = IERC20Upgradeable(usdc_);
        gath = IGATHMintable(gath_);
        nft = ISenatorNFTMintable(nft_);
        membership = IMembershipReferrer(membership_);
    }

    function subscribe(uint256 amount) external nonReentrant {
        require(!finalized, "ILO: finalized");
        require(totalRaised < HARD_CAP, "ILO: hard cap reached");
        require(amount >= MIN_PER_CALL, "ILO: below min");
        require(totalRaised + amount <= HARD_CAP, "ILO: exceeds hard cap");

        uint256 prior = usdcContributed[msg.sender];
        uint256 newTotal = prior + amount;
        require(newTotal <= MAX_PER_ADDRESS, "ILO: exceeds personal max");

        bool isNew = prior == 0;

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        usdcContributed[msg.sender] = newTotal;
        totalRaised += amount;

        if (isNew) {
            participantCount += 1;
        }

        // Senator NFTs are minted on the cumulative-contributed boundary at
        // every NFT_UNIT (1,000 USDC). Only the delta crossing those
        // boundaries with this deposit is minted, so partial-1k deposits
        // accumulate until they cross a boundary.
        uint256 nftDelta = (newTotal / NFT_UNIT) - (prior / NFT_UNIT);
        if (nftDelta > 0) {
            nft.mintBatch(msg.sender, nftDelta);
        }

        uint256 gathAmount = amount * GATH_PER_USDC;
        gath.mint(msg.sender, gathAmount);

        // Referrer bonus: 10% of the participant's gATH minted on top to the
        // referrer recorded in MembershipV1. If the participant has no referrer
        // (not joined, or sentinel root), no bonus is minted.
        address referrer = _resolveReferrer(msg.sender);
        uint256 bonus = 0;
        if (referrer != address(0)) {
            bonus = (gathAmount * REFERRER_BPS) / BPS_DENOM;
            gath.mint(referrer, bonus);
        }

        emit Subscribed(msg.sender, amount, gathAmount, referrer, bonus, totalRaised);
    }

    function withdraw(address treasury) external onlyRole(ADMIN_ROLE) nonReentrant {
        require(treasury != address(0), "ILO: zero treasury");
        uint256 bal = usdc.balanceOf(address(this));
        usdc.safeTransfer(treasury, bal);
        emit Withdrawn(treasury, bal);
    }

    function _resolveReferrer(address user) internal view returns (address) {
        if (address(membership) == address(0)) return address(0);
        try membership.referrerOf(user) returns (address r) {
            if (r == address(0) || r == ROOT_REFERRER_SENTINEL) return address(0);
            return r;
        } catch {
            return address(0);
        }
    }

    function getState()
        external
        view
        returns (
            uint256 totalRaised_,
            uint256 hardCap_,
            uint256 softCap_,
            uint256 minPer_,
            uint256 maxPer_,
            uint256 participantCount_,
            bool finalized_
        )
    {
        return (totalRaised, HARD_CAP, SOFT_CAP, MIN_PER_CALL, MAX_PER_ADDRESS, participantCount, finalized);
    }

    function getUserPosition(address user)
        external
        view
        returns (
            uint256 contributed,
            uint256 gathMinted,
            uint256 nftCount,
            address referrer
        )
    {
        contributed = usdcContributed[user];
        gathMinted = contributed * GATH_PER_USDC;
        nftCount = contributed / NFT_UNIT;
        referrer = _resolveReferrer(user);
    }

    uint256[45] private __gap;
}
